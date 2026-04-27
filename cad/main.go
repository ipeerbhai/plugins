// Command cad-plugin is the CAD plugin MCP server for Minerva.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// This is the same transport used by the hello_scene Python plugin and by
// all Minerva MCP plugins.  The inner protocol (Go ↔ Python worker) uses
// length-prefixed framing (bridge §3) and is separate.
//
// Round 1 implements:
//   - initialize handshake
//   - tools/list → empty list
//   - tools/call → method-not-found (no real tools yet)
//   - notifications/initialized → no-op
//   - shutdown → exit 0
//
// All logging goes to stderr; stdout carries only JSON-RPC responses.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "cad"
	serverVersion   = "0.1.0"
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
	return okResponse(id, map[string]interface{}{
		"tools": []interface{}{},
	})
}

func handleToolsCall(id json.RawMessage, params json.RawMessage) rpcResponse {
	// Extract tool name for logging; round 1 has no real tools.
	var p struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(params, &p); err == nil {
		log.Printf("cad-plugin: tools/call: %s (not implemented in round 1)", p.Name)
	}
	return errResponse(id, -32601, fmt.Sprintf("method not found: no tools implemented in round 1"))
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
		log.Printf("cad-plugin: shutdown requested — exiting")
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
		os.Exit(1)
	}
	log.Printf("stdin closed — exiting")
}
