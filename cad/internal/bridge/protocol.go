// Package bridge — protocol types for the Go ↔ Python worker IPC (design §4).
//
// These types are NOT wire-compatible with JSON-RPC 2.0 libraries; they match
// the minimal custom protocol defined in §4 of the bridge design document.
package bridge

import (
	"encoding/json"
	"fmt"
	"sync/atomic"
)

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

var reqCounter atomic.Uint64

// NextID returns the next monotonic request ID in the form "req_NNNNN" (§4).
func NextID() string {
	n := reqCounter.Add(1)
	return fmt.Sprintf("req_%05d", n)
}

// ---------------------------------------------------------------------------
// Wire types (Go → Python)
// ---------------------------------------------------------------------------

// Request is sent from Go to the Python worker (design §4).
type Request struct {
	ID         string          `json:"id"`
	Method     string          `json:"method"`
	Params     json.RawMessage `json:"params,omitempty"`
	DeadlineMS int64           `json:"deadline_ms,omitempty"`
}

// ---------------------------------------------------------------------------
// Wire types (Python → Go)
// ---------------------------------------------------------------------------

// Response is received from the Python worker (design §4).
// Either Result or Error is set, determined by the OK flag.
type Response struct {
	ID     string          `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *WorkerError    `json:"error,omitempty"`
}

// WorkerError carries structured error information from the worker (design §7).
// Kind must be one of: parse, translate, occt, python, timeout, cancelled,
// internal, crashed.
type WorkerError struct {
	Kind      string          `json:"kind"`
	Message   string          `json:"message"`
	Details   json.RawMessage `json:"details,omitempty"`
	Traceback string          `json:"traceback,omitempty"`
}

// Notification is an unsolicited message from the worker (no ID, design §4).
// Used for: worker.ready, log, progress.
type Notification struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// ---------------------------------------------------------------------------
// Marshal helpers
// ---------------------------------------------------------------------------

// MarshalRequest serialises req to JSON.
func MarshalRequest(req *Request) ([]byte, error) {
	b, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("bridge.MarshalRequest: %w", err)
	}
	return b, nil
}

// MarshalResponse serialises resp to JSON.
func MarshalResponse(resp *Response) ([]byte, error) {
	b, err := json.Marshal(resp)
	if err != nil {
		return nil, fmt.Errorf("bridge.MarshalResponse: %w", err)
	}
	return b, nil
}

// MarshalNotification serialises n to JSON.
func MarshalNotification(n *Notification) ([]byte, error) {
	b, err := json.Marshal(n)
	if err != nil {
		return nil, fmt.Errorf("bridge.MarshalNotification: %w", err)
	}
	return b, nil
}

// ---------------------------------------------------------------------------
// Unmarshal helpers
// ---------------------------------------------------------------------------

// UnmarshalResponse parses raw bytes as a Response.
func UnmarshalResponse(data []byte) (*Response, error) {
	var resp Response
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("bridge.UnmarshalResponse: %w", err)
	}
	return &resp, nil
}

// UnmarshalNotification parses raw bytes as a Notification.
func UnmarshalNotification(data []byte) (*Notification, error) {
	var n Notification
	if err := json.Unmarshal(data, &n); err != nil {
		return nil, fmt.Errorf("bridge.UnmarshalNotification: %w", err)
	}
	return &n, nil
}
