// Command presentation-plugin is the Presentation plugin MCP server for Minerva.
//
// Migration scaffold for broker T6: introduces the bidirectional host
// capability client (synchronous request/response over the existing stdio
// transport, correlated by JSON-RPC id) and the first migrated tool —
// minerva_presentation_list_open_decks, which calls host.documents.list_open
// and filters for the plugin's own editors. The bulk MCP migration follows
// in subsequent rounds, all building on this client.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// Logging goes to stderr; stdout carries only JSON-RPC traffic.
//
// Capability re-entrancy contract (from Minerva broker, see
// MCPServerConnection._in_stdio_request): while the plugin is handling a
// tools/call, Minerva will NOT send another tools/call. So when a handler
// writes a minerva/capability request to stdout, the next line on stdin is
// guaranteed to be either:
//   (a) the matching response (correlated by id), or
//   (b) stdin EOF.
// The synchronous read pattern below is safe under that guarantee.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
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
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

// outResponse is what we WRITE to stdout (Result is interface{} so we can
// assemble nested maps without manually pre-marshaling).
type outResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

func okResponse(id json.RawMessage, result interface{}) outResponse {
	return outResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, msg string) outResponse {
	return outResponse{
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

// hostClient bundles the stdio handles + a request-id sequencer for
// host capability calls. Single-flight by design (see file header).
type hostClient struct {
	enc     *json.Encoder
	scanner *bufio.Scanner
	nextID  int
}

func newHostClient(enc *json.Encoder, scanner *bufio.Scanner) *hostClient {
	return &hostClient{enc: enc, scanner: scanner}
}

// callCapability sends a minerva/capability request and reads stdin until
// the matching response arrives. Returns (result, nil) on success or
// (nil, *rpcError) on failure. The result envelope mirrors the broker's
// success/failure dict — callers should still inspect result["success"].
func (c *hostClient) callCapability(capability string, args map[string]interface{}) (json.RawMessage, *rpcError) {
	c.nextID++
	id := fmt.Sprintf(`"cap-%d"`, c.nextID)

	paramsBytes, err := json.Marshal(map[string]interface{}{
		"capability": capability,
		"args":       args,
	})
	if err != nil {
		return nil, &rpcError{Code: -32603, Message: "marshal capability params: " + err.Error()}
	}

	req := outResponse{
		JSONRPC: "2.0",
		ID:      json.RawMessage(id),
		// Reuse outResponse — it has matching JSON shape with Method
		// substituted via Result. Actually let's not be cute here.
	}
	_ = req

	// Compose the request manually so we don't reuse the response struct.
	wireReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(id),
		"method":  "minerva/capability",
		"params":  json.RawMessage(paramsBytes),
	}
	if err := c.enc.Encode(wireReq); err != nil {
		return nil, &rpcError{Code: -32603, Message: "encode capability request: " + err.Error()}
	}

	// Read stdin until matching id (or EOF). Per the re-entrancy contract,
	// the next message MUST be the response — but defensively log and skip
	// anything else rather than blocking the whole plugin on a malformed
	// inbound.
	for c.scanner.Scan() {
		line := c.scanner.Bytes()
		var resp rpcResponse
		if err := json.Unmarshal(line, &resp); err != nil {
			log.Printf("non-json line while waiting for capability response: %s", line)
			continue
		}
		if string(resp.ID) == id {
			if resp.Error != nil {
				return nil, resp.Error
			}
			return resp.Result, nil
		}
		log.Printf("unexpected message id %s while waiting for %s (skipped)", string(resp.ID), id)
	}
	if err := c.scanner.Err(); err != nil {
		return nil, &rpcError{Code: -32603, Message: "stdin read error: " + err.Error()}
	}
	return nil, &rpcError{Code: -32603, Message: "stdin closed waiting for capability response"}
}

// ---------------------------------------------------------------------------
// Tool registry
// ---------------------------------------------------------------------------

// toolList is what we advertise via tools/list. Each entry conforms to the
// MCP tool schema (name + description + inputSchema). Auto-prefix policy
// requires names start with "minerva_<plugin_id>_" — see Minerva's
// PluginToolRegistry.
var toolList = []map[string]interface{}{
	{
		"name":        "minerva_presentation_list_open_decks",
		"description": "Lists currently-open .mdeck presentation tabs in Minerva, with editor name, kind, plugin id, and on-disk path. Filters host.documents.list_open by plugin_id == 'presentation' or path ending in '.mdeck'.",
		"inputSchema": map[string]interface{}{
			"type":       "object",
			"properties": map[string]interface{}{},
		},
	},
}

// dispatchTool routes a tools/call by tool name.
func dispatchTool(client *hostClient, msg *rpcRequest) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments,omitempty"`
	}
	if err := json.Unmarshal(msg.Params, &p); err != nil {
		send(client.enc, errResponse(msg.ID, -32700, "tools/call: parse params: "+err.Error()))
		return
	}

	switch p.Name {
	case "minerva_presentation_list_open_decks":
		respondTool(client.enc, msg.ID, toolListOpenDecks(client, p.Arguments))
	default:
		send(client.enc, errResponse(msg.ID, -32601, "tools/call: unknown tool: "+p.Name))
	}
}

// respondTool wraps a tool result (or error) in the MCP content envelope and
// sends it back as the tools/call response.
func respondTool(enc *json.Encoder, id json.RawMessage, result map[string]interface{}) {
	body, err := json.Marshal(result)
	if err != nil {
		send(enc, errResponse(id, -32603, "marshal tool result: "+err.Error()))
		return
	}
	envelope := map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(body)},
		},
	}
	if isError, _ := result["success"].(bool); !isError && result["success"] != nil {
		envelope["isError"] = true
	}
	send(enc, okResponse(id, envelope))
}

// ---------------------------------------------------------------------------
// Tool: minerva_presentation_list_open_decks
// ---------------------------------------------------------------------------

func toolListOpenDecks(client *hostClient, _ json.RawMessage) map[string]interface{} {
	rawResult, capErr := client.callCapability("host.documents.list_open", map[string]interface{}{})
	if capErr != nil {
		return map[string]interface{}{
			"success":     false,
			"error":       capErr.Message,
			"error_code":  fmt.Sprintf("rpc_error_%d", capErr.Code),
		}
	}

	// host.documents.list_open returns {success: true, result: {documents: [...]}}.
	// Drill in.
	var brokerResp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       struct {
			Documents []map[string]interface{} `json:"documents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rawResult, &brokerResp); err != nil {
		return map[string]interface{}{
			"success":    false,
			"error":      "parse host.documents.list_open response: " + err.Error(),
			"error_code": "parse_error",
		}
	}
	if !brokerResp.Success {
		return map[string]interface{}{
			"success":    false,
			"error":      brokerResp.ErrorMessage,
			"error_code": brokerResp.ErrorCode,
		}
	}

	decks := []map[string]interface{}{}
	for _, doc := range brokerResp.Result.Documents {
		path, _ := doc["path"].(string)
		pluginID, _ := doc["plugin_id"].(string)
		kind, _ := doc["kind"].(string)
		// Match either plugin-scene editors owned by us, or text editors
		// whose file ends in .mdeck (legacy / not-yet-migrated).
		matchesPluginScene := pluginID == "presentation"
		matchesByExt := strings.HasSuffix(strings.ToLower(path), ".mdeck")
		if !matchesPluginScene && !matchesByExt {
			continue
		}
		entry := map[string]interface{}{
			"editor_name": doc["editor_name"],
			"kind":        kind,
		}
		if pluginID != "" {
			entry["plugin_id"] = pluginID
		}
		if path != "" {
			entry["path"] = path
		}
		decks = append(decks, entry)
	}
	return map[string]interface{}{
		"success": true,
		"decks":   decks,
		"count":   len(decks),
	}
}

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

func dispatch(client *hostClient, msg *rpcRequest) {
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		send(client.enc, okResponse(msg.ID, map[string]interface{}{
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
		send(client.enc, okResponse(msg.ID, map[string]interface{}{
			"tools": toolList,
		}))

	case "tools/call":
		if isNotification {
			return
		}
		dispatchTool(client, msg)

	case "shutdown":
		log.Printf("shutdown requested — exiting")
		os.Exit(0)

	default:
		if isNotification {
			log.Printf("unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("unknown method: %s", msg.Method)
		send(client.enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
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
	client := newHostClient(enc, scanner)

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

		dispatch(client, &msg)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
	log.Printf("stdin closed — exiting")
}
