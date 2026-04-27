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

func send(enc *json.Encoder, v interface{}) {
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

	ctx := context.Background()
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
			// Return structured error as tool content.
			errJSON, _ := json.Marshal(we)
			return okResponse(id, map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": string(errJSON)},
				},
				"isError": true,
			})
		}
		return errResponse(id, -32603, fmt.Sprintf("tool error: %v", err))
	}

	// Wrap the raw result in MCP tool result shape.
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(result)},
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
