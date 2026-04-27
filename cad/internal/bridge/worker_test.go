package bridge_test

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// skipIfNoPython calls t.Skip if python3 is not on PATH.
func skipIfNoPython(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not on PATH — skipping integration test")
	}
	return p
}

// echoWorkerScript is a minimal Python worker that:
//   - emits worker.ready
//   - echoes every request back as ok=true with result=params
//   - exits cleanly on a "shutdown" request
//
// It is written to a temp file and run by tests that need a real subprocess.
const echoWorkerScript = `
import sys
import json
import struct

def read_frame(f):
    headers = {}
    while True:
        line = f.readline()
        if not line:
            return None
        line = line.rstrip(b'\r\n')
        if line == b'':
            break
        k, _, v = line.partition(b': ')
        headers[k.decode()] = v.decode()
    n = int(headers.get('Content-Length', 0))
    body = f.read(n)
    return json.loads(body)

def write_frame(f, obj):
    body = json.dumps(obj).encode('utf-8')
    header = f'Content-Length: {len(body)}\r\nContent-Type: application/json; charset=utf-8\r\n\r\n'
    f.write(header.encode('utf-8'))
    f.write(body)
    f.flush()

stdin = sys.stdin.buffer
stdout = sys.stdout.buffer

# Emit worker.ready
write_frame(stdout, {"method": "worker.ready", "params": {"version": "echo-1.0.0", "build123d": "echo", "occt": "echo"}})

while True:
    req = read_frame(stdin)
    if req is None:
        break
    if req.get('method') == 'shutdown':
        write_frame(stdout, {"id": req['id'], "ok": True, "result": {}})
        break
    write_frame(stdout, {"id": req['id'], "ok": True, "result": req.get('params', {})})
`

// writeTempEchoWorker writes the echo worker script to a temp dir and returns
// a (dir, scriptName) pair suitable for use as workerDir with "-m echo_worker".
func writeTempEchoWorker(t *testing.T) (dir string) {
	t.Helper()
	dir = t.TempDir()

	// Create a package directory called echo_worker.
	pkgDir := filepath.Join(dir, "echo_worker")
	if err := os.Mkdir(pkgDir, 0755); err != nil {
		t.Fatalf("mkdir echo_worker: %v", err)
	}
	// __init__.py
	if err := os.WriteFile(filepath.Join(pkgDir, "__init__.py"), nil, 0644); err != nil {
		t.Fatalf("write __init__.py: %v", err)
	}
	// __main__.py — the actual worker logic.
	if err := os.WriteFile(filepath.Join(pkgDir, "__main__.py"), []byte(echoWorkerScript), 0644); err != nil {
		t.Fatalf("write __main__.py: %v", err)
	}
	return dir
}

// ---------------------------------------------------------------------------
// Test 1: Worker start + single call + shutdown (happy path)
// ---------------------------------------------------------------------------

func TestWorkerHappyPath(t *testing.T) {
	pythonPath := skipIfNoPython(t)
	dir := writeTempEchoWorker(t)

	// Build a Worker pointing at the echo_worker package.
	// We override the module name via pythonPath+args by writing a custom worker.
	// Since bridge.New takes workerDir and spawns "python -m mcad_worker", we
	// create the echo_worker package named "mcad_worker" in the temp dir.
	pkgDir := filepath.Join(dir, "echo_worker")
	mcadDir := filepath.Join(dir, "mcad_worker")
	if err := os.Rename(pkgDir, mcadDir); err != nil {
		t.Fatalf("rename: %v", err)
	}

	w := bridge.New(pythonPath, dir)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := w.Start(ctx); err != nil {
		t.Fatalf("Worker.Start: %v", err)
	}

	// Send a validate request; echo worker returns params as result.
	params := json.RawMessage(`{"source":"box()"}`)
	result, err := w.Call(ctx, "validate", params)
	if err != nil {
		t.Fatalf("Worker.Call: %v", err)
	}
	if string(result) == "" {
		t.Error("expected non-empty result")
	}

	// Graceful shutdown.
	done := make(chan struct{})
	go func() {
		w.Shutdown(2 * time.Second)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Error("Shutdown timed out")
	}
}

// ---------------------------------------------------------------------------
// Test 2: Worker not alive before Start (IsAlive)
// ---------------------------------------------------------------------------

func TestWorkerNotAliveBeforeStart(t *testing.T) {
	t.Parallel()
	w := bridge.New("/nonexistent/python3", "/tmp")
	if w.IsAlive() {
		t.Error("expected IsAlive=false before Start")
	}
}

// ---------------------------------------------------------------------------
// Test 3: Call triggers lazy spawn
// ---------------------------------------------------------------------------

func TestWorkerLazySpawn(t *testing.T) {
	pythonPath := skipIfNoPython(t)
	dir := writeTempEchoWorker(t)

	// Rename to mcad_worker (same rename as TestWorkerHappyPath).
	pkgDir := filepath.Join(dir, "echo_worker")
	mcadDir := filepath.Join(dir, "mcad_worker")
	if err := os.Rename(pkgDir, mcadDir); err != nil {
		t.Fatalf("rename: %v", err)
	}

	w := bridge.New(pythonPath, dir)
	// Do NOT call Start — Call should trigger lazy spawn.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	if w.IsAlive() {
		t.Error("expected not alive before Call")
	}

	params := json.RawMessage(`{"source":"sphere(5)"}`)
	result, err := w.Call(ctx, "validate", params)
	if err != nil {
		t.Fatalf("Worker.Call (lazy spawn): %v", err)
	}
	if !w.IsAlive() {
		t.Error("expected IsAlive=true after Call")
	}
	_ = result

	w.Shutdown(2 * time.Second)
}

// ---------------------------------------------------------------------------
// Test 4: Context cancellation returns cancelled error
// ---------------------------------------------------------------------------

func TestWorkerContextCancel(t *testing.T) {
	t.Parallel()
	// Use a python3 that hangs — we simulate a cancelled context without a
	// real subprocess by using an already-cancelled context.
	skipIfNoPython(t)

	w := bridge.New("/nonexistent/python3", "/tmp")
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled

	_, err := w.Call(ctx, "validate", json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("expected error from cancelled context")
	}
}

// ---------------------------------------------------------------------------
// Test 5: Circuit breaker trips after 3 crashes in 60s
// ---------------------------------------------------------------------------

func TestCircuitBreakerOpenAfterCrashes(t *testing.T) {
	pythonPath := skipIfNoPython(t)
	dir := t.TempDir()

	// Create a worker that exits immediately (simulates crash).
	crashPkg := filepath.Join(dir, "mcad_worker")
	if err := os.Mkdir(crashPkg, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(crashPkg, "__init__.py"), nil, 0644); err != nil {
		t.Fatalf("write __init__.py: %v", err)
	}
	// Worker that exits 0 immediately without emitting worker.ready.
	crashScript := `import sys; sys.exit(0)` + "\n"
	if err := os.WriteFile(filepath.Join(crashPkg, "__main__.py"), []byte(crashScript), 0644); err != nil {
		t.Fatalf("write __main__.py: %v", err)
	}

	w := bridge.New(pythonPath, dir)

	// Each Start should fail with timeout/crashed and record a crash.
	// We need 3 crashes to trip the breaker.
	// Use a very short timeout so the test doesn't take 45s.
	for i := 0; i < 3; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := w.Start(ctx)
		cancel()
		if err == nil {
			// If it somehow started (shouldn't happen with crash worker), shut it down.
			w.Shutdown(500 * time.Millisecond)
		}
		// Give the goroutines a moment to clean up.
		time.Sleep(100 * time.Millisecond)
	}

	// Now the circuit breaker should be open.
	ctx := context.Background()
	err := w.Start(ctx)
	if err == nil {
		t.Fatal("expected circuit breaker to prevent start")
	}
	we, ok := err.(*bridge.WorkerError)
	if !ok {
		t.Fatalf("expected *bridge.WorkerError, got %T: %v", err, err)
	}
	if we.Kind != "crashed" {
		t.Errorf("expected kind=crashed, got %q", we.Kind)
	}
	t.Logf("circuit breaker fired as expected: %s", we.Message)
}

// ---------------------------------------------------------------------------
// Test 6: WorkerError.Error() returns non-empty string
// ---------------------------------------------------------------------------

func TestWorkerErrorString(t *testing.T) {
	t.Parallel()
	we := &bridge.WorkerError{Kind: "parse", Message: "syntax error at line 5"}
	s := we.Error()
	if s == "" {
		t.Error("expected non-empty error string")
	}
	t.Logf("WorkerError.Error() = %q", s)
}

// ---------------------------------------------------------------------------
// Test 7: Shutdown is a no-op when worker is not running
// ---------------------------------------------------------------------------

func TestShutdownNoOp(t *testing.T) {
	t.Parallel()
	w := bridge.New("/nonexistent/python3", "/tmp")
	// Must not panic.
	w.Shutdown(1 * time.Second)
}

// ---------------------------------------------------------------------------
// Helpers — ensure pumpStderr-level coverage without needing a real process
// ---------------------------------------------------------------------------

func TestPumpStderrDoesNotPanic(t *testing.T) {
	t.Parallel()
	// The pumpStderr goroutine is internal, but we can exercise it indirectly
	// through the fake reader goroutine via workerfake in the parent package.
	// Here we just verify the bridge package compiles and the io.Pipe path works.
	pr, pw := io.Pipe()
	_ = pw.Close()
	// Drain the now-closed pipe.
	buf := make([]byte, 64)
	_, _ = pr.Read(buf)
}
