// Command presentation-plugin is the Presentation plugin MCP server for Minerva.
//
// Scaffold stub: implements only the minimum JSON-RPC 2.0 surface required for
// Minerva to handshake and load the plugin (initialize, notifications/initialized,
// tools/list returning [], shutdown). All later tasks add real tools.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// Logging goes to stderr; stdout carries only JSON-RPC responses.
package main

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "presentation"
	serverVersion   = "0.0.1"
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
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
		log.Printf("write response: %v", err)
	}
}

func dispatch(enc *json.Encoder, msg *rpcRequest) {
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		send(enc, okResponse(msg.ID, map[string]interface{}{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]interface{}{},
			"serverInfo": map[string]string{
				"name":    serverName,
				"version": serverVersion,
			},
		}))

	case "notifications/initialized":
		log.Printf("notifications/initialized (no-op)")

	case "tools/list":
		if isNotification {
			return
		}
		send(enc, okResponse(msg.ID, map[string]interface{}{
			"tools": []interface{}{},
		}))

	case "tools/call":
		if isNotification {
			return
		}
		send(enc, errResponse(msg.ID, -32601, "tools/call: no tools registered yet (scaffold stub)"))

	case "shutdown":
		log.Printf("shutdown requested — exiting")
		os.Exit(0)

	default:
		if isNotification {
			log.Printf("unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("unknown method: %s", msg.Method)
		send(enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[presentation-plugin] ")
	log.SetOutput(os.Stderr)

	log.Printf("starting (pid=%d)", os.Getpid())

	enc := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
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
