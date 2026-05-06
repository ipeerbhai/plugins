package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// captureNotify redirects notifyOut to a fresh buffer and resets notifyEnc so
// that the next emitHostNotify call encodes into the buffer. It registers a
// cleanup function via t.Cleanup that restores global state after the test.
// Returns a pointer to the buffer so callers can inspect it at any point.
func captureNotify(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	notifyOut = &buf
	notifyEnc = json.NewEncoder(&buf)
	t.Cleanup(func() {
		notifyOut = nil
		notifyEnc = nil
	})
	return &buf
}

// ---------------------------------------------------------------------------
// Test: emitHostNotify writes the expected JSON-RPC 2.0 shape
// ---------------------------------------------------------------------------

func TestEmitHostNotifyShape(t *testing.T) {
	buf := captureNotify(t)

	emitHostNotify("error", "test message", map[string]string{"key": "value"})

	raw := buf.Bytes()
	if len(raw) == 0 {
		t.Fatal("expected non-empty output from emitHostNotify")
	}

	var n struct {
		JSONRPC string           `json:"jsonrpc"`
		Method  string           `json:"method"`
		ID      *json.RawMessage `json:"id,omitempty"`
		Params  struct {
			Level   string      `json:"level"`
			Message string      `json:"message"`
			Details interface{} `json:"details"`
		} `json:"params"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &n); err != nil {
		t.Fatalf("emitHostNotify output is not valid JSON: %v\nraw: %s", err, raw)
	}
	if n.JSONRPC != "2.0" {
		t.Errorf("jsonrpc: want %q, got %q", "2.0", n.JSONRPC)
	}
	if n.Method != "host.notify" {
		t.Errorf("method: want %q, got %q", "host.notify", n.Method)
	}
	if n.ID != nil {
		t.Errorf("notification must have no 'id' field — found: %v", n.ID)
	}
	if n.Params.Level != "error" {
		t.Errorf("params.level: want %q, got %q", "error", n.Params.Level)
	}
	if n.Params.Message != "test message" {
		t.Errorf("params.message: want %q, got %q", "test message", n.Params.Message)
	}
	if n.Params.Details == nil {
		t.Error("params.details: expected non-nil")
	}
}

// ---------------------------------------------------------------------------
// Test: emitHostNotify is a no-op when message is empty
// ---------------------------------------------------------------------------

func TestEmitHostNotifyEmptyMessage(t *testing.T) {
	buf := captureNotify(t)

	emitHostNotify("error", "", nil)

	raw := buf.Bytes()
	if len(bytes.TrimSpace(raw)) != 0 {
		t.Errorf("expected no output for empty message, got: %s", raw)
	}
}

// ---------------------------------------------------------------------------
// Test: workerErrorToast maps kinds to expected levels
// ---------------------------------------------------------------------------

func TestWorkerErrorToastLevels(t *testing.T) {
	cases := []struct {
		kind          string
		wantLevel     string
		wantNonEmpty  bool
	}{
		{"crashed", "error", true},
		{"python", "error", true},
		{"internal", "error", true},
		{"parse", "warning", true},
		{"translate", "warning", true},
		{"occt", "warning", true},
		{"timeout", "warning", true},
		{"cancelled", "info", false}, // suppressed — empty message
		{"unknown_kind", "error", true},
	}

	for _, tc := range cases {
		we := &bridge.WorkerError{Kind: tc.kind, Message: "some detail"}
		level, msg := workerErrorToast("mcad_validate", we)
		if level != tc.wantLevel {
			t.Errorf("kind=%q: want level=%q, got %q", tc.kind, tc.wantLevel, level)
		}
		if tc.wantNonEmpty && msg == "" {
			t.Errorf("kind=%q: expected non-empty toast message", tc.kind)
		}
		if !tc.wantNonEmpty && msg != "" {
			t.Errorf("kind=%q: expected empty toast message (suppressed), got %q", tc.kind, msg)
		}
	}
}

// ---------------------------------------------------------------------------
// Test: isCriticalStderrLine correctly classifies lines
// ---------------------------------------------------------------------------

func TestIsCriticalStderrLine(t *testing.T) {
	critical := []string{
		"FATAL: process crashed",
		"ERROR: something went wrong",
		"  ERROR: leading spaces",
		"ModuleNotFoundError: No module named 'build123d'",
		"ImportError: cannot import name 'foo'",
		"RuntimeError: OCCT failed to initialise",
		"Traceback (most recent call last):",
	}
	nonCritical := []string{
		"INFO: starting up",
		"WARNING: build123d loading slowly",
		"build123d imported in 3.2s",
		"OCCT initialized",
		"worker.ready",
		"progress: 50%",
		"",
	}

	for _, line := range critical {
		if !isCriticalStderrLine(line) {
			t.Errorf("expected critical: %q", line)
		}
	}
	for _, line := range nonCritical {
		if isCriticalStderrLine(line) {
			t.Errorf("expected non-critical: %q", line)
		}
	}
}

// ---------------------------------------------------------------------------
// Test: worker spawn failure (empty pythonPath) triggers error toast via
// workerErrorToast (integration of the Call→WorkerError path without a
// real subprocess — uses the circuit-breaker path via a direct WorkerError).
// ---------------------------------------------------------------------------

func TestSpawnFailureProducesToast(t *testing.T) {
	buf := captureNotify(t)

	// Simulate the WorkerError that bridge.Worker.Call returns when pythonPath=""
	// (exec.Command("", ...) fails at cmd.Start() → wrapped WorkerError).
	we := &bridge.WorkerError{Kind: "crashed", Message: "exec: no such file or directory"}
	level, msg := workerErrorToast("mcad_validate", we)

	// Emit as the real handleToolsCall would.
	emitHostNotify(level, msg, we)

	raw := buf.Bytes()
	if !strings.Contains(string(raw), "host.notify") {
		t.Fatalf("expected host.notify in output, got: %s", raw)
	}
	if !strings.Contains(string(raw), "error") {
		t.Errorf("expected error level in output, got: %s", raw)
	}
	if !strings.Contains(string(raw), "crashed") {
		t.Errorf("expected 'crashed' kind in output, got: %s", raw)
	}
}

// ---------------------------------------------------------------------------
// Inflight cad.evaluate cancellation (DCR 019dfa66 §T6)
// ---------------------------------------------------------------------------

// resetInflight wipes the package-level inflight map between tests so prior
// state can't bleed across test cases.
func resetInflight(t *testing.T) {
	t.Helper()
	inflightMu.Lock()
	defer inflightMu.Unlock()
	for k, c := range inflight {
		c()
		delete(inflight, k)
	}
}

// TestBeginEvaluateCancellable_NoRequestID confirms that args without a
// request_id leave inflight untouched and return the parent context.
func TestBeginEvaluateCancellable_NoRequestID(t *testing.T) {
	resetInflight(t)
	parent := context.Background()
	ctx, key, err := beginEvaluateCancellable(parent, json.RawMessage(`{"source":"box(1,2,3)"}`))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "" {
		t.Errorf("expected empty key when request_id absent, got %q", key)
	}
	if ctx != parent {
		t.Errorf("expected parent context returned when request_id absent")
	}
	inflightMu.Lock()
	defer inflightMu.Unlock()
	if len(inflight) != 0 {
		t.Errorf("expected empty inflight, got %d entries", len(inflight))
	}
}

// TestBeginEvaluateCancellable_RegistersAndCancels covers the happy path:
// request_id present → inflight has the cancel func → cancel_eval trips it.
func TestBeginEvaluateCancellable_RegistersAndCancels(t *testing.T) {
	resetInflight(t)

	parent := context.Background()
	args := json.RawMessage(`{"source":"box(1,2,3)","request_id":"eval_123"}`)
	ctx, key, err := beginEvaluateCancellable(parent, args)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "eval_123" {
		t.Errorf("expected key=eval_123, got %q", key)
	}

	// Verify inflight has the entry.
	inflightMu.Lock()
	_, ok := inflight[key]
	inflightMu.Unlock()
	if !ok {
		t.Fatalf("expected inflight[%s] to be registered", key)
	}

	// Cancel via the public handler — confirm the derived ctx fires Done.
	resp := handleCancelEval(json.RawMessage(`1`),
		json.RawMessage(`{"request_id":"eval_123"}`))
	if resp.Error != nil {
		t.Fatalf("cancel_eval errored: %v", resp.Error)
	}

	select {
	case <-ctx.Done():
		// expected
	case <-time.After(time.Second):
		t.Fatal("expected derived context to be cancelled within 1s")
	}

	// Inflight entry must be gone after cancel.
	inflightMu.Lock()
	_, stillThere := inflight[key]
	inflightMu.Unlock()
	if stillThere {
		t.Errorf("expected inflight[%s] removed after cancel_eval", key)
	}
}

// TestHandleCancelEval_UnknownRequestIDIsNoop confirms that cancel_eval with
// an unknown request_id returns ok:true cancelled:false (fire-and-forget safe).
func TestHandleCancelEval_UnknownRequestIDIsNoop(t *testing.T) {
	resetInflight(t)
	resp := handleCancelEval(json.RawMessage(`1`),
		json.RawMessage(`{"request_id":"never_existed"}`))
	if resp.Error != nil {
		t.Fatalf("cancel_eval errored: %v", resp.Error)
	}
	// The result envelope is wrapped in MCP content[].text — extract it.
	resultMap, ok := resp.Result.(map[string]interface{})
	if !ok {
		t.Fatalf("unexpected response shape: %#v", resp.Result)
	}
	contents := resultMap["content"].([]map[string]interface{})
	textJSON := contents[0]["text"].(string)
	var env map[string]interface{}
	if err := json.Unmarshal([]byte(textJSON), &env); err != nil {
		t.Fatalf("envelope parse: %v", err)
	}
	if env["ok"] != true {
		t.Errorf("expected ok=true, got %v", env["ok"])
	}
	if env["cancelled"] != false {
		t.Errorf("expected cancelled=false for unknown id, got %v", env["cancelled"])
	}
}

// TestEndEvaluateCancellable_RemovesEntry confirms the cleanup path.
func TestEndEvaluateCancellable_RemovesEntry(t *testing.T) {
	resetInflight(t)

	args := json.RawMessage(`{"source":"x","request_id":"eval_end"}`)
	_, key, _ := beginEvaluateCancellable(context.Background(), args)

	inflightMu.Lock()
	_, before := inflight[key]
	inflightMu.Unlock()
	if !before {
		t.Fatalf("setup: expected inflight registration")
	}

	endEvaluateCancellable(key)

	inflightMu.Lock()
	_, after := inflight[key]
	inflightMu.Unlock()
	if after {
		t.Errorf("expected inflight[%s] removed by end", key)
	}
}

// TestBeginEvaluateCancellable_DuplicateRequestIDCancelsPrior covers the
// defensive case where a stale entry exists for the same request_id —
// the prior cancel func must be tripped before the new one overwrites it.
func TestBeginEvaluateCancellable_DuplicateRequestIDCancelsPrior(t *testing.T) {
	resetInflight(t)

	parent := context.Background()
	args := json.RawMessage(`{"source":"a","request_id":"eval_dup"}`)
	ctxA, keyA, _ := beginEvaluateCancellable(parent, args)
	if keyA != "eval_dup" {
		t.Fatalf("setup: keyA=%s", keyA)
	}

	// Re-register under same id.
	ctxB, keyB, _ := beginEvaluateCancellable(parent, args)
	if keyB != "eval_dup" {
		t.Fatalf("setup: keyB=%s", keyB)
	}

	// Prior context must have been cancelled.
	select {
	case <-ctxA.Done():
		// expected
	case <-time.After(time.Second):
		t.Fatal("expected prior ctx cancelled when same request_id re-registered")
	}

	// New context still alive.
	select {
	case <-ctxB.Done():
		t.Fatal("expected new ctx alive after re-register")
	default:
	}

	// Cleanup.
	endEvaluateCancellable("eval_dup")
}
