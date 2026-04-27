package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

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
