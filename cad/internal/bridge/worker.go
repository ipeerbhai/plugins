// Package bridge — Worker manages the long-lived Python CAD worker subprocess.
//
// Design references: Go-python-bridge-design.md §2 (process model),
// §4 (request/response), §5 (worker lifecycle), §7 (error surfaces).
package bridge

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

const (
	// readyTimeout is the hard deadline for the worker.ready notification (§5).
	readyTimeout = 15 * time.Second

	// shutdownGrace is the window after sending "shutdown" before SIGTERM.
	shutdownGrace = 2 * time.Second

	// sigkillDelay is how long after SIGTERM before SIGKILL.
	sigkillDelay = 3 * time.Second

	// circuitBreakerWindow is the sliding window for crash counting (§2).
	circuitBreakerWindow = 60 * time.Second

	// circuitBreakerLimit is the number of crashes that trip the breaker (§2).
	circuitBreakerLimit = 3
)

// inflightEntry tracks a pending request.
type inflightEntry struct {
	ch chan Response
}

// Worker manages a single Python subprocess and the correlation of requests
// to responses. It is safe for concurrent use from multiple goroutines.
type Worker struct {
	mu sync.Mutex

	// Configuration (immutable after New).
	pythonPath string
	workerDir  string

	// Subprocess state (guarded by mu).
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader

	// Crash timestamps for circuit breaker (§2).
	crashTimes []time.Time

	// In-flight request correlation table (guarded by mu).
	inflight map[string]*inflightEntry

	// readyC is closed when the worker emits worker.ready (or hits timeout).
	// It is recreated each time the worker is spawned.
	readyC chan struct{}

	// doneC is closed when the reader goroutine exits (worker crashed/stopped).
	doneC chan struct{}
}

// New creates a Worker that will use the given Python interpreter and worker
// directory. It does NOT spawn the subprocess — spawning is lazy (§2).
func New(pythonPath, workerDir string) *Worker {
	return &Worker{
		pythonPath: pythonPath,
		workerDir:  workerDir,
		inflight:   make(map[string]*inflightEntry),
	}
}

// IsAlive reports whether the worker subprocess is currently running.
func (w *Worker) IsAlive() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.isAliveLocked()
}

// isAliveLocked requires mu held.
func (w *Worker) isAliveLocked() bool {
	return w.cmd != nil && w.cmd.ProcessState == nil
}

// circuitOpen reports whether the circuit breaker has tripped (§2).
// Requires mu held.
func (w *Worker) circuitOpen() bool {
	cutoff := time.Now().Add(-circuitBreakerWindow)
	recent := 0
	for _, t := range w.crashTimes {
		if t.After(cutoff) {
			recent++
		}
	}
	return recent >= circuitBreakerLimit
}

// recordCrash adds a crash timestamp for circuit-breaker tracking.
// Requires mu held.
func (w *Worker) recordCrash() {
	cutoff := time.Now().Add(-circuitBreakerWindow)
	// Prune old entries.
	fresh := w.crashTimes[:0]
	for _, t := range w.crashTimes {
		if t.After(cutoff) {
			fresh = append(fresh, t)
		}
	}
	w.crashTimes = append(fresh, time.Now())
}

// Start spawns the Python worker subprocess and waits for it to emit
// worker.ready (§5). Returns once the worker is ready for requests.
func (w *Worker) Start(ctx context.Context) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.startLocked(ctx)
}

// startLocked requires mu held.
func (w *Worker) startLocked(ctx context.Context) error {
	if w.isAliveLocked() {
		return nil // Already running.
	}

	if w.circuitOpen() {
		return &WorkerError{
			Kind:    "crashed",
			Message: "circuit breaker open: worker crashed too many times; restart the plugin to reset",
		}
	}

	cmd := exec.CommandContext(ctx, w.pythonPath, "-m", "mcad_worker") //nolint:gosec
	cmd.Dir = w.workerDir
	cmd.Env = buildEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("bridge.Worker.Start: stdin pipe: %w", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("bridge.Worker.Start: stdout pipe: %w", err)
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("bridge.Worker.Start: stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("bridge.Worker.Start: exec: %w", err)
	}

	w.cmd = cmd
	w.stdin = stdinPipe
	w.stdout = bufio.NewReaderSize(stdoutPipe, 1<<20)
	w.readyC = make(chan struct{})
	w.doneC = make(chan struct{})

	// Pump stderr to parent stderr with [worker] prefix (§5).
	go pumpStderr(stderrPipe)

	// Reader goroutine: consumes frames from stdout and dispatches (§4).
	go w.reader()

	// Wait for cmd.Wait() to reap the process.
	go func() {
		w.cmd.Wait() //nolint:errcheck
	}()

	// Release mu while we wait for ready — reader goroutine holds its own lock
	// for map ops only, so this is safe.
	readyC := w.readyC
	w.mu.Unlock()

	select {
	case <-readyC:
		w.mu.Lock()
		log.Printf("[bridge.Worker] worker ready (pid=%d)", w.cmd.Process.Pid)
		return nil
	case <-time.After(readyTimeout):
		w.mu.Lock()
		log.Printf("[bridge.Worker] worker.ready timeout after %s — killing", readyTimeout)
		w.killLocked()
		w.recordCrash()
		return &WorkerError{
			Kind:    "crashed",
			Message: fmt.Sprintf("worker did not emit worker.ready within %s", readyTimeout),
		}
	case <-ctx.Done():
		w.mu.Lock()
		w.killLocked()
		return ctx.Err()
	}
}

// reader is the goroutine that reads framed responses from stdout and
// dispatches them to the in-flight correlation table (§4).
// It also handles notifications (worker.ready, log, progress).
func (w *Worker) reader() {
	defer close(w.doneC)

	for {
		w.mu.Lock()
		stdout := w.stdout
		w.mu.Unlock()

		if stdout == nil {
			return
		}

		body, err := ReadFrame(stdout)
		if err != nil {
			// EOF or pipe close — worker exited.
			w.mu.Lock()
			w.failInflightLocked("crashed", "worker stdout closed unexpectedly")
			w.mu.Unlock()
			return
		}

		w.handleFrame(body)
	}
}

// handleFrame dispatches a single incoming frame.
func (w *Worker) handleFrame(body []byte) {
	// Detect notification vs response by presence of "id" field.
	var probe struct {
		ID     string `json:"id"`
		Method string `json:"method"`
	}
	if err := json.Unmarshal(body, &probe); err != nil {
		log.Printf("[bridge.Worker] unparse-able frame: %v", err)
		return
	}

	if probe.ID == "" {
		// Notification.
		w.handleNotification(body, probe.Method)
		return
	}

	// Response — correlate.
	resp, err := UnmarshalResponse(body)
	if err != nil {
		log.Printf("[bridge.Worker] unmarshal response: %v", err)
		return
	}

	w.mu.Lock()
	entry, ok := w.inflight[resp.ID]
	if ok {
		delete(w.inflight, resp.ID)
	}
	w.mu.Unlock()

	if !ok {
		log.Printf("[bridge.Worker] unknown/stale response id=%q (dropped)", resp.ID)
		return
	}
	entry.ch <- *resp
}

// handleNotification handles Python→Go notifications (§4).
func (w *Worker) handleNotification(body []byte, method string) {
	switch method {
	case "worker.ready":
		w.mu.Lock()
		rc := w.readyC
		w.mu.Unlock()
		if rc != nil {
			select {
			case <-rc:
				// Already closed.
			default:
				close(rc)
			}
		}
	case "log":
		var n Notification
		if err := json.Unmarshal(body, &n); err == nil {
			log.Printf("[worker] log: %s", string(n.Params))
		}
	case "progress":
		var n Notification
		if err := json.Unmarshal(body, &n); err == nil {
			log.Printf("[worker] progress: %s", string(n.Params))
		}
	default:
		log.Printf("[bridge.Worker] unknown notification method=%q", method)
	}
}

// failInflightLocked cancels all pending in-flight requests with the given
// error kind and message. Requires mu held.
func (w *Worker) failInflightLocked(kind, message string) {
	for id, entry := range w.inflight {
		entry.ch <- Response{
			ID: id,
			OK: false,
			Error: &WorkerError{
				Kind:    kind,
				Message: message,
			},
		}
		delete(w.inflight, id)
	}
}

// killLocked sends SIGKILL to the worker process group. Requires mu held.
func (w *Worker) killLocked() {
	if w.cmd == nil || w.cmd.Process == nil {
		return
	}
	// Kill entire process group to catch any grandchildren.
	pgid := w.cmd.Process.Pid
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
	w.cmd = nil
	w.stdin = nil
	w.stdout = nil
}

// Call sends a request to the worker and waits for the correlated response
// (§4). It handles lazy spawn (§2) if the worker is not yet alive.
func (w *Worker) Call(ctx context.Context, method string, params json.RawMessage) (json.RawMessage, error) {
	// Ensure worker is alive (lazy spawn, §2).
	w.mu.Lock()
	if !w.isAliveLocked() {
		if err := w.startLocked(ctx); err != nil {
			w.mu.Unlock()
			return nil, err
		}
	}
	w.mu.Unlock()

	id := NextID()

	// Compute deadline for the request.
	var deadlineMS int64
	if dl, ok := ctx.Deadline(); ok {
		deadlineMS = time.Until(dl).Milliseconds()
		if deadlineMS <= 0 {
			return nil, &WorkerError{Kind: "cancelled", Message: "context already expired"}
		}
	}

	req := &Request{
		ID:         id,
		Method:     method,
		Params:     params,
		DeadlineMS: deadlineMS,
	}
	reqBytes, err := MarshalRequest(req)
	if err != nil {
		return nil, fmt.Errorf("bridge.Worker.Call: marshal: %w", err)
	}

	// Register inflight entry before writing so the reader goroutine never
	// misses a very-fast response.
	ch := make(chan Response, 1)
	w.mu.Lock()
	w.inflight[id] = &inflightEntry{ch: ch}
	w.mu.Unlock()

	// Write the framed request.
	w.mu.Lock()
	stdin := w.stdin
	w.mu.Unlock()

	if stdin == nil {
		w.mu.Lock()
		delete(w.inflight, id)
		w.mu.Unlock()
		return nil, &WorkerError{Kind: "crashed", Message: "worker not running"}
	}

	if err := WriteFrame(stdin, reqBytes); err != nil {
		w.mu.Lock()
		delete(w.inflight, id)
		// Record a crash and clean up.
		w.recordCrash()
		w.killLocked()
		w.mu.Unlock()
		return nil, &WorkerError{Kind: "crashed", Message: fmt.Sprintf("write to worker: %v", err)}
	}

	// Wait for response, context cancellation, or worker crash.
	select {
	case resp := <-ch:
		if resp.OK {
			return resp.Result, nil
		}
		if resp.Error != nil {
			return nil, resp.Error
		}
		return nil, &WorkerError{Kind: "internal", Message: "worker returned ok=false with no error"}
	case <-ctx.Done():
		// Remove inflight entry; the worker may still finish — we discard the
		// result per §4 (v1 cancellation is deadline-only).
		w.mu.Lock()
		delete(w.inflight, id)
		w.mu.Unlock()
		return nil, &WorkerError{Kind: "cancelled", Message: ctx.Err().Error()}
	case <-w.doneC:
		w.mu.Lock()
		delete(w.inflight, id)
		w.recordCrash()
		w.cmd = nil
		w.stdin = nil
		w.stdout = nil
		w.mu.Unlock()
		return nil, &WorkerError{Kind: "crashed", Message: "worker process exited mid-request"}
	}
}

// Shutdown sends a graceful shutdown request and waits for the process to exit
// (§5). timeout controls how long to wait before SIGTERM; SIGKILL follows
// sigkillDelay later.
func (w *Worker) Shutdown(timeout time.Duration) {
	w.mu.Lock()
	if !w.isAliveLocked() {
		w.mu.Unlock()
		return
	}
	stdin := w.stdin
	doneC := w.doneC
	w.mu.Unlock()

	// Send graceful shutdown request.
	if stdin != nil {
		shutdownReq := &Request{ID: NextID(), Method: "shutdown"}
		reqBytes, _ := MarshalRequest(shutdownReq)
		_ = WriteFrame(stdin, reqBytes)
		_ = stdin.Close()
	}

	// Wait for worker to exit cleanly.
	select {
	case <-doneC:
		log.Printf("[bridge.Worker] worker shut down cleanly")
		return
	case <-time.After(timeout):
	}

	// Graceful window elapsed — send SIGTERM then SIGKILL.
	w.mu.Lock()
	cmd := w.cmd
	w.mu.Unlock()

	if cmd != nil && cmd.Process != nil {
		pgid := cmd.Process.Pid
		log.Printf("[bridge.Worker] worker did not exit in %s — sending SIGTERM", timeout)
		_ = syscall.Kill(-pgid, syscall.SIGTERM)

		select {
		case <-doneC:
			log.Printf("[bridge.Worker] worker exited after SIGTERM")
			return
		case <-time.After(sigkillDelay):
		}

		log.Printf("[bridge.Worker] worker did not exit after SIGTERM — sending SIGKILL")
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}

	// Best-effort wait.
	select {
	case <-doneC:
	case <-time.After(2 * time.Second):
		log.Printf("[bridge.Worker] worker still alive after SIGKILL — giving up")
	}

	w.mu.Lock()
	w.cmd = nil
	w.stdin = nil
	w.stdout = nil
	w.mu.Unlock()
}

// buildEnv constructs a scrubbed environment for the worker subprocess (§5).
func buildEnv() []string {
	env := []string{
		"PYTHONUNBUFFERED=1",
		"PYTHONDONTWRITEBYTECODE=1",
	}
	// Forward PATH so the worker can find system utilities.
	if path := os.Getenv("PATH"); path != "" {
		env = append(env, "PATH="+path)
	}
	// Forward HOME so Python can find user site-packages if needed.
	if home := os.Getenv("HOME"); home != "" {
		env = append(env, "HOME="+home)
	}
	// Intentionally omit PYTHONHOME and PYTHONPATH to avoid polluting the
	// worker's import path from the host environment (§5).
	return env
}

// pumpStderr consumes a reader and forwards each line to stderr with [worker] prefix.
func pumpStderr(r io.Reader) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		log.Printf("[worker] %s", scanner.Text())
	}
}

// Error implements the error interface for WorkerError so callers can use
// errors.As to inspect the kind.
func (e *WorkerError) Error() string {
	if e == nil {
		return "<nil WorkerError>"
	}
	return fmt.Sprintf("worker error [%s]: %s", e.Kind, e.Message)
}
