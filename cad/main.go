// Command cad-plugin is the CAD plugin MCP server for Minerva.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// This is the same transport used by the hello_scene Python plugin and by
// all Minerva MCP plugins.  The inner protocol (Go ↔ Python worker) uses
// length-prefixed framing (bridge §3) and is separate.
//
// Round 2 implements:
//   - initialize handshake
//   - tools/list → [mcad_validate]
//   - tools/call mcad_validate → lazily spawns Python worker, calls validate
//   - notifications/initialized → no-op
//   - shutdown → graceful worker shutdown, then exit 0
//
// All logging goes to stderr; stdout carries only JSON-RPC responses.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
	"github.com/ipeerbhai/plugins/cad/internal/runtime"
	"github.com/ipeerbhai/plugins/cad/internal/tools"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "cad"
	serverVersion   = "0.1.0"

	// workerShutdownTimeout is how long we give the worker on plugin shutdown
	// before SIGTERM kicks in (§5).
	workerShutdownTimeout = 2 * time.Second
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelope types (outer / MCP protocol)
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"` // null for notifications
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

func okResponse(id json.RawMessage, result interface{}) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, msg string) rpcResponse {
	return rpcResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &rpcError{Code: code, Message: msg},
	}
}

// stdoutMu serialises every write to stdout. Both the main JSON-RPC response
// path (send) and the stderr-pump-driven notify path (emitHostNotify) target
// os.Stdout. Without this mutex two goroutines can interleave bytes — line
// atomicity on os.Stdout is only POSIX-guaranteed for pipes ≤ PIPE_BUF, which
// the host (Minerva) may capture as a regular file or socket.
var stdoutMu sync.Mutex

func send(enc *json.Encoder, v interface{}) {
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	if err := enc.Encode(v); err != nil {
		log.Printf("cad-plugin: write response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// host.notify — Minerva toast pipe
// ---------------------------------------------------------------------------

// notifyParams is the params payload for the host.notify notification.
type notifyParams struct {
	Level   string      `json:"level"`
	Message string      `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

// hostNotify is the JSON-RPC 2.0 notification envelope (no id field).
type hostNotify struct {
	JSONRPC string       `json:"jsonrpc"`
	Method  string       `json:"method"`
	Params  notifyParams `json:"params"`
}

// notifyOut is the writer used to emit host.notify messages. It is set to
// os.Stdout in main() so tests can redirect it to a buffer.
var notifyOut = io.Writer(os.Stdout)

// notifyEnc is a lazily-initialised encoder that targets notifyOut. Tests
// replace this after overriding notifyOut.
var notifyEnc *json.Encoder

// emitHostNotify writes a host.notify JSON-RPC 2.0 notification to stdout so
// Minerva can display it as a toast. level must be "info", "warning", or "error".
// details may be nil. The call is a no-op if message is empty.
func emitHostNotify(level, message string, details interface{}) {
	if message == "" {
		return
	}
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	if notifyEnc == nil {
		notifyEnc = json.NewEncoder(notifyOut)
	}
	n := hostNotify{
		JSONRPC: "2.0",
		Method:  "host.notify",
		Params: notifyParams{
			Level:   level,
			Message: message,
			Details: details,
		},
	}
	if err := notifyEnc.Encode(n); err != nil {
		log.Printf("cad-plugin: emitHostNotify: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Global worker + tool registry
// ---------------------------------------------------------------------------

var (
	worker   *bridge.Worker
	registry *tools.Registry
)

// initWorker resolves the Python interpreter path and constructs the Worker.
// Called once at startup; the worker is NOT yet spawned (lazy per §2).
func initWorker() {
	// Determine the plugin root (directory containing this binary / manifest.json).
	pluginRoot, err := pluginRootDir()
	if err != nil {
		log.Printf("cad-plugin: WARNING: cannot determine plugin root: %v", err)
		pluginRoot = "."
	}
	workerDir := runtime.WorkerScriptDir(pluginRoot)

	pythonPath, err := runtime.PythonPath(workerDir)
	if err != nil {
		log.Printf("cad-plugin: WARNING: %v — mcad_validate will fail until python3 is on PATH or .venv exists", err)
		emitHostNotify("error",
			"CAD plugin: Python interpreter not found — mcad_validate and mcad_list_edges will fail",
			map[string]string{"detail": err.Error(), "fix": "Install python3 or create a .venv in the plugin worker directory"})
		// Still create a Worker with an empty path so Call returns a clean error.
		pythonPath = ""
	}
	log.Printf("cad-plugin: worker dir=%s, python=%s", workerDir, pythonPath)

	w := bridge.New(pythonPath, workerDir)
	// Attach the stderr callback so critical worker stderr lines surface as toasts.
	w.StderrCallback = func(line string) {
		if isCriticalStderrLine(line) {
			emitHostNotify("error", "CAD worker: "+line, nil)
		}
	}
	worker = w
}

// pluginRootDir returns the directory of the running executable, which by
// convention is the plugin root (contains manifest.json and worker/).
func pluginRootDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("os.Executable: %w", err)
	}
	return filepath.Dir(filepath.Clean(exe)), nil
}

// initRegistry registers all MCP tools. Called once at startup.
func initRegistry() {
	registry = tools.NewRegistry()
	registry.Register(tools.Validate, tools.HandleValidate)
	registry.Register(tools.ListEdges, tools.HandleListEdges)
	registry.Register(tools.Evaluate, tools.HandleEvaluate)
	// cad.cancel_eval is registered here so it appears in tools/list, but its
	// handler is intercepted in handleToolsCall before registry dispatch (it
	// needs access to the server-level inflight map). The registry handler
	// is a stub that returns method-not-found if the dispatcher path is ever
	// reached — that should never happen.
	registry.Register(tools.CancelEval, handleCancelEvalRegistryStub)
}

// handleCancelEvalRegistryStub is a guard that should never run in practice —
// handleToolsCall intercepts cad.cancel_eval before registry dispatch. If it
// does run, returning a clear error makes the misrouting visible.
func handleCancelEvalRegistryStub(_ context.Context, _ *bridge.Worker, _ json.RawMessage) (json.RawMessage, error) {
	return nil, fmt.Errorf("cad.cancel_eval reached registry dispatch (should be intercepted in handleToolsCall)")
}

// ---------------------------------------------------------------------------
// Inflight cad.evaluate tracking — used by cad.cancel_eval.
// ---------------------------------------------------------------------------

// inflightMu guards inflight. Reads and writes are short and uncontended;
// a single mutex is fine.
var inflightMu sync.Mutex

// inflight maps request_id → cancel func for in-flight cad.evaluate calls.
// Entry is added in beginEvaluateCancellable and removed in
// endEvaluateCancellable. cancel_eval looks up by request_id; absent keys are
// a no-op (the eval already finished or was never registered).
var inflight = map[string]context.CancelFunc{}

// beginEvaluateCancellable parses request_id from a cad.evaluate args payload
// (if present) and registers a cancellable context under that key.
//
// Returns the derived context and the registered key (empty string if no
// request_id was supplied — in that case cancellation is unavailable for the
// request, but the call still proceeds with the parent context).
func beginEvaluateCancellable(parent context.Context, args json.RawMessage) (context.Context, string, error) {
	var a struct {
		RequestID string `json:"request_id"`
	}
	// Tolerate missing/non-object args — old callers don't pass request_id.
	if len(args) > 0 {
		_ = json.Unmarshal(args, &a)
	}
	if a.RequestID == "" {
		return parent, "", nil
	}

	ctx, cancel := context.WithCancel(parent)
	inflightMu.Lock()
	// If a prior eval somehow left a stale entry under the same request_id,
	// cancel it before overwriting (defensive — request_ids are usec-keyed
	// and unique in practice, but a re-entrant panel bug shouldn't leak).
	if prior, ok := inflight[a.RequestID]; ok {
		prior()
	}
	inflight[a.RequestID] = cancel
	inflightMu.Unlock()
	return ctx, a.RequestID, nil
}

// endEvaluateCancellable removes the inflight entry for key. Safe to call
// when the key is absent (e.g. cancelled before completion).
func endEvaluateCancellable(key string) {
	if key == "" {
		return
	}
	inflightMu.Lock()
	if cancel, ok := inflight[key]; ok {
		// Cancel before delete to release any goroutine still awaiting the
		// derived context. Cancelling an already-cancelled CancelFunc is a no-op.
		cancel()
		delete(inflight, key)
	}
	inflightMu.Unlock()
}

// handleCancelEval looks up the inflight entry for the supplied request_id
// and cancels it. Unknown request_ids return ok=true with cancelled=false so
// the panel can fire-and-forget.
func handleCancelEval(id json.RawMessage, args json.RawMessage) rpcResponse {
	var a struct {
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(args, &a); err != nil {
		return errResponse(id, -32602, fmt.Sprintf("cad.cancel_eval: parse args: %v", err))
	}
	if a.RequestID == "" {
		return errResponse(id, -32602, "cad.cancel_eval: request_id is required")
	}

	cancelled := false
	inflightMu.Lock()
	if cancel, ok := inflight[a.RequestID]; ok {
		cancel()
		delete(inflight, a.RequestID)
		cancelled = true
	}
	inflightMu.Unlock()

	log.Printf("cad-plugin: cancel_eval request_id=%s cancelled=%v", a.RequestID, cancelled)

	envelope := map[string]interface{}{
		"ok":         true,
		"request_id": a.RequestID,
		"cancelled":  cancelled,
	}
	envelopeJSON, _ := json.Marshal(envelope)
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(envelopeJSON)},
		},
	})
}

// ---------------------------------------------------------------------------
// MCP handler functions
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	log.Printf("cad-plugin: initialize")
	return okResponse(id, map[string]interface{}{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]interface{}{},
		"serverInfo": map[string]string{
			"name":    serverName,
			"version": serverVersion,
		},
	})
}

func handleToolsList(id json.RawMessage) rpcResponse {
	log.Printf("cad-plugin: tools/list")
	specs := registry.Specs()
	// Build the MCP tools array: each entry has name, description, inputSchema.
	type mcpTool struct {
		Name        string          `json:"name"`
		Description string          `json:"description"`
		InputSchema json.RawMessage `json:"inputSchema"`
	}
	mcpTools := make([]mcpTool, len(specs))
	for i, s := range specs {
		mcpTools[i] = mcpTool{
			Name:        s.Name,
			Description: s.Description,
			InputSchema: s.InputSchema,
		}
	}
	return okResponse(id, map[string]interface{}{
		"tools": mcpTools,
	})
}

func handleToolsCall(id json.RawMessage, params json.RawMessage) rpcResponse {
	// Parse the tools/call params envelope.
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return errResponse(id, -32700, fmt.Sprintf("tools/call: parse params: %v", err))
	}

	log.Printf("cad-plugin: tools/call: %s", p.Name)

	// cad.cancel_eval is a control-plane tool: it never reaches the worker.
	// Intercept here so we can mutate the inflight map directly.
	if p.Name == "cad.cancel_eval" {
		return handleCancelEval(id, p.Arguments)
	}

	ctx := context.Background()
	// cad.evaluate may carry request_id for cancellation. If present, derive
	// a cancellable context and register it; the cancel_eval handler will
	// trip the cancel func, which propagates into bridge.Worker.Call as a
	// kind=cancelled error.
	if p.Name == "cad.evaluate" {
		cctx, key, perr := beginEvaluateCancellable(ctx, p.Arguments)
		if perr != nil {
			return errResponse(id, -32602, fmt.Sprintf("cad.evaluate: %v", perr))
		}
		ctx = cctx
		if key != "" {
			defer endEvaluateCancellable(key)
		}
	}

	result, err, found := registry.Dispatch(ctx, worker, p.Name, p.Arguments)
	if !found {
		return errResponse(id, -32601, fmt.Sprintf("method not found: %s", p.Name))
	}

	if err != nil {
		// Worker errors are returned as MCP tool result content (not MCP errors)
		// so the LLM can inspect them. Only internal/protocol errors become MCP errors.
		var we *bridge.WorkerError
		if asWorkerErr(err, &we) {
			// Surface spawn/crash errors (kind: crashed, python, internal) as error
			// toasts; validation failures (kind: parse, translate, occt) as warnings.
			toastLevel, toastMsg := workerErrorToast(p.Name, we)
			emitHostNotify(toastLevel, toastMsg, we)
			// Preserve the {ok, error} envelope shape the worker uses on success
			// so panel-side decoders can read worker_payload.ok / .error uniformly.
			errEnvelope := map[string]interface{}{"ok": false, "error": we}
			errJSON, _ := json.Marshal(errEnvelope)
			return okResponse(id, map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": string(errJSON)},
				},
				"isError": true,
			})
		}
		return errResponse(id, -32603, fmt.Sprintf("tool error: %v", err))
	}

	// Wrap the raw result in {ok: true, result: <result>} so the panel-side
	// decoder is symmetric with the error path (which uses {ok: false, error}).
	// bridge.Worker.Call strips the worker's {ok, result} wrapper on success,
	// so we re-wrap here before forwarding to MCP.
	successEnvelope := map[string]interface{}{"ok": true, "result": json.RawMessage(result)}
	envelopeJSON, _ := json.Marshal(successEnvelope)
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(envelopeJSON)},
		},
	})
}

// asWorkerErr checks whether err is a *bridge.WorkerError and, if so, sets target.
func asWorkerErr(err error, target **bridge.WorkerError) bool {
	if we, ok := err.(*bridge.WorkerError); ok {
		*target = we
		return true
	}
	return false
}

// workerErrorToast maps a WorkerError to a (level, message) pair for toast
// display. Spawn/crash errors surface at "error"; validation failures at
// "warning" so the user can act without alarm.
func workerErrorToast(toolName string, we *bridge.WorkerError) (level, message string) {
	switch we.Kind {
	case "crashed", "python", "internal":
		return "error", fmt.Sprintf("CAD plugin [%s]: worker error (%s) — %s", toolName, we.Kind, we.Message)
	case "parse", "translate", "occt":
		return "warning", fmt.Sprintf("CAD plugin [%s]: validation failed (%s) — %s", toolName, we.Kind, we.Message)
	case "timeout":
		return "warning", fmt.Sprintf("CAD plugin [%s]: request timed out — %s", toolName, we.Message)
	case "cancelled":
		// Cancellation is expected; no toast needed. Return empty to suppress.
		return "info", ""
	default:
		return "error", fmt.Sprintf("CAD plugin [%s]: worker error (%s) — %s", toolName, we.Kind, we.Message)
	}
}

// criticalStderrPrefixes are line prefixes that indicate a critical problem in
// the Python worker's stderr stream and should be surfaced as toast errors.
// Lines that do NOT match any prefix are forwarded to the Go process's stderr
// as-is (for the Activity log) but are NOT toasted.
//
// Design call on cold-start progress (build123d import, OCCT init):
//   - Cold-start INFO/progress lines are intentionally NOT toasted — they are
//     expected during first-use and would be noisy.
//   - Only lines matching these prefixes become toasts; everything else is
//     stderr-only (visible in the Activity log, not in toasts).
var criticalStderrPrefixes = []string{
	"FATAL:",
	"ERROR:",
	"ModuleNotFoundError:",
	"ImportError:",
	"RuntimeError:",
	"Traceback (most recent call last):",
}

// isCriticalStderrLine returns true if line matches the critical filter.
func isCriticalStderrLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	for _, prefix := range criticalStderrPrefixes {
		if strings.HasPrefix(trimmed, prefix) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

func dispatch(enc *json.Encoder, msg *rpcRequest) {
	// Notifications have a null or absent id.  Per JSON-RPC 2.0, no response
	// is sent for notifications.
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		send(enc, handleInitialize(msg.ID))

	case "notifications/initialized":
		// No-op; Minerva sends this after receiving our initialize response.
		log.Printf("cad-plugin: notifications/initialized (no-op)")

	case "tools/list":
		if isNotification {
			return
		}
		send(enc, handleToolsList(msg.ID))

	case "tools/call":
		if isNotification {
			return
		}
		send(enc, handleToolsCall(msg.ID, msg.Params))

	case "shutdown":
		log.Printf("cad-plugin: shutdown requested — shutting down worker")
		if worker != nil {
			worker.Shutdown(workerShutdownTimeout)
		}
		log.Printf("cad-plugin: exiting")
		os.Exit(0)

	default:
		if isNotification {
			log.Printf("cad-plugin: unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("cad-plugin: unknown method: %s", msg.Method)
		send(enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	// Logging goes to stderr only; stdout is reserved for JSON-RPC responses.
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[cad-plugin] ")
	log.SetOutput(os.Stderr)

	log.Printf("starting (pid=%d)", os.Getpid())

	// Initialize the tool registry and worker (lazy spawn) at startup.
	initRegistry()
	initWorker()

	enc := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	// Increase scanner buffer to handle potentially large params.
	scanner.Buffer(make([]byte, 1<<20), 1<<20)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var msg rpcRequest
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("JSON parse error: %v", err)
			send(enc, errResponse(json.RawMessage("null"), -32700, "Parse error"))
			continue
		}

		dispatch(enc, &msg)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("stdin read error: %v", err)
		// Graceful worker shutdown before abnormal exit.
		if worker != nil {
			worker.Shutdown(workerShutdownTimeout)
		}
		os.Exit(1)
	}
	log.Printf("stdin closed — exiting")
	if worker != nil {
		worker.Shutdown(workerShutdownTimeout)
	}
}
