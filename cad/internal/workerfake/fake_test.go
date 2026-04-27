package workerfake_test

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"testing"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
	"github.com/ipeerbhai/plugins/cad/internal/workerfake"
)

// ---------------------------------------------------------------------------
// Test 1: framer round-trip
// ---------------------------------------------------------------------------

func TestFramerRoundTrip(t *testing.T) {
	t.Parallel()

	want := []byte(`{"hello":"world","num":42}`)

	var buf bytes.Buffer
	if err := bridge.WriteFrame(&buf, want); err != nil {
		t.Fatalf("WriteFrame: %v", err)
	}

	got, err := bridge.ReadFrame(bufio.NewReader(&buf))
	if err != nil {
		t.Fatalf("ReadFrame: %v", err)
	}

	if !bytes.Equal(want, got) {
		t.Errorf("body mismatch\n  want: %s\n   got: %s", want, got)
	}
}

// ---------------------------------------------------------------------------
// Test 2: worker.ready notification arrives before any response
// ---------------------------------------------------------------------------

func TestFakeEmitsWorkerReadyFirst(t *testing.T) {
	t.Parallel()

	f := workerfake.New()
	// Register a canned response for the "init" method (wildcard params).
	f.Register("init", "", bridge.Response{
		OK:     true,
		Result: json.RawMessage(`{"worker_version":"fake-1.0.0"}`),
	})

	// Plumb two pairs of io.Pipe so the fake is the "server" and the test is
	// the "client".
	//   clientW → workerIn   (test writes requests, fake reads)
	//   workerOut → clientR  (fake writes responses, test reads)
	workerIn_r, clientW := io.Pipe()
	clientR, workerOut_w := io.Pipe()

	go f.Run(workerIn_r, workerOut_w)

	reader := bufio.NewReader(clientR)

	// --- First frame must be the worker.ready notification ---
	notifBytes, err := bridge.ReadFrame(reader)
	if err != nil {
		t.Fatalf("ReadFrame (worker.ready): %v", err)
	}

	// Distinguish notification from response: notifications have no "id" field
	// but have "method".
	var notif bridge.Notification
	if err := json.Unmarshal(notifBytes, &notif); err != nil {
		t.Fatalf("unmarshal notification: %v", err)
	}
	if notif.Method != "worker.ready" {
		t.Errorf("expected worker.ready notification first, got method=%q", notif.Method)
	}

	// --- Send an init request ---
	reqID := bridge.NextID()
	initParams, _ := json.Marshal(map[string]string{"plugin_version": "0.1.0"})
	req := &bridge.Request{
		ID:         reqID,
		Method:     "init",
		Params:     json.RawMessage(initParams),
		DeadlineMS: 5000,
	}
	reqBytes, err := bridge.MarshalRequest(req)
	if err != nil {
		t.Fatalf("MarshalRequest: %v", err)
	}
	if err := bridge.WriteFrame(clientW, reqBytes); err != nil {
		t.Fatalf("WriteFrame (init): %v", err)
	}

	// Close the write side so the fake's Run loop exits cleanly after this
	// one request; we don't need to read more.
	defer clientW.Close() //nolint:errcheck

	// --- Read the response ---
	respBytes, err := bridge.ReadFrame(reader)
	if err != nil {
		t.Fatalf("ReadFrame (response): %v", err)
	}
	resp, err := bridge.UnmarshalResponse(respBytes)
	if err != nil {
		t.Fatalf("UnmarshalResponse: %v", err)
	}

	// Assertions
	if resp.ID != reqID {
		t.Errorf("response ID mismatch: want %q, got %q", reqID, resp.ID)
	}
	if !resp.OK {
		t.Errorf("expected ok=true, got ok=false (error: %+v)", resp.Error)
	}
}

// ---------------------------------------------------------------------------
// Test 3: fake init response carries expected result shape
// ---------------------------------------------------------------------------

func TestFakeInitResponseShape(t *testing.T) {
	t.Parallel()

	f := workerfake.New()
	f.Register("init", "", bridge.Response{
		OK:     true,
		Result: json.RawMessage(`{"worker_version":"fake-1.0.0","occt_version":"fake"}`),
	})

	workerIn_r, clientW := io.Pipe()
	clientR, workerOut_w := io.Pipe()
	go f.Run(workerIn_r, workerOut_w)

	reader := bufio.NewReader(clientR)

	// Consume the worker.ready notification.
	if _, err := bridge.ReadFrame(reader); err != nil {
		t.Fatalf("ReadFrame (worker.ready): %v", err)
	}

	// Send init request.
	reqID := bridge.NextID()
	req := &bridge.Request{ID: reqID, Method: "init", Params: json.RawMessage(`{}`)}
	reqBytes, _ := bridge.MarshalRequest(req)
	if err := bridge.WriteFrame(clientW, reqBytes); err != nil {
		t.Fatalf("WriteFrame: %v", err)
	}
	clientW.Close() //nolint:errcheck

	// Read response.
	respBytes, err := bridge.ReadFrame(reader)
	if err != nil {
		t.Fatalf("ReadFrame (response): %v", err)
	}
	resp, err := bridge.UnmarshalResponse(respBytes)
	if err != nil {
		t.Fatalf("UnmarshalResponse: %v", err)
	}

	if !resp.OK {
		t.Fatalf("expected ok=true")
	}

	// Decode result and check expected keys.
	var result map[string]string
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if result["worker_version"] == "" {
		t.Errorf("expected non-empty worker_version in result")
	}
	if result["occt_version"] == "" {
		t.Errorf("expected non-empty occt_version in result")
	}

	// Verify call count was incremented.
	if f.CallCount("init") != 1 {
		t.Errorf("expected call count 1, got %d", f.CallCount("init"))
	}
}

// ---------------------------------------------------------------------------
// Test 4: framer handles empty body
// ---------------------------------------------------------------------------

func TestFramerEmptyBody(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	if err := bridge.WriteFrame(&buf, []byte{}); err != nil {
		t.Fatalf("WriteFrame empty body: %v", err)
	}
	got, err := bridge.ReadFrame(bufio.NewReader(&buf))
	if err != nil {
		t.Fatalf("ReadFrame empty body: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty body, got %d bytes", len(got))
	}
}
