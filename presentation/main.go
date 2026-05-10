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
// targetSchema is the shared dual-mode addressing block used by every tool
// that operates on a deck. Plugins specify either `tab_name` (live in-memory
// state via host.documents.get_state) or `path` (on-disk .mdeck JSON).
var targetSchema = map[string]interface{}{
	"tab_name": map[string]interface{}{"type": "string", "description": "Tab title of an open .mdeck editor (live state)."},
	"path":     map[string]interface{}{"type": "string", "description": "Absolute path to a .mdeck file on disk."},
}

var toolList = []map[string]interface{}{
	{
		"name":        "minerva_presentation_list_open_decks",
		"description": "Lists currently-open .mdeck presentation tabs in Minerva, with editor name, kind, plugin id, and on-disk path. Filters host.documents.list_open by plugin_id == 'presentation' or path ending in '.mdeck'.",
		"inputSchema": map[string]interface{}{
			"type":       "object",
			"properties": map[string]interface{}{},
		},
	},
	{
		"name":        "minerva_presentation_list_annotation_kinds",
		"description": "Returns the catalogue of supported presentation annotation kinds (id, label, target_scope). Pure constants — no deck argument required.",
		"inputSchema": map[string]interface{}{
			"type":       "object",
			"properties": map[string]interface{}{},
		},
	},
	{
		"name":        "minerva_presentation_list_slides",
		"description": "Lists slides in a deck. Returns {slides:[{index,id,title?,tile_count}], aspect, version}. Provide tab_name for live state or path for on-disk file.",
		"inputSchema": map[string]interface{}{
			"type":       "object",
			"properties": targetSchema,
		},
	},
	{
		"name":        "minerva_presentation_list_tiles",
		"description": "Lists tiles on a slide. Returns {tiles:[{index,id,kind,x,y,w,h}]}. Requires slide_index and tab_name|path.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"slide_index"},
		},
	},
	{
		"name":        "minerva_presentation_list_annotations",
		"description": "Lists annotations on a slide. Returns {annotations:[...]}. Requires slide_index and tab_name|path.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"slide_index"},
		},
	},
	{
		"name":        "minerva_presentation_get_slide",
		"description": "Returns a single slide's full record (id, title, background, tiles, annotations). Requires slide_index and tab_name|path.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"slide_index"},
		},
	},
	{
		"name":        "minerva_presentation_get_tile",
		"description": "Returns a single tile's full record. Requires slide_index, tile_index, and tab_name|path.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"tile_index":  map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"slide_index", "tile_index"},
		},
	},
}

// withProps composes two schema-property maps without mutating either.
func withProps(a, b map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(a)+len(b))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

// supportedAnnotationKinds is the static catalogue exposed by
// minerva_presentation_list_annotation_kinds. Mirrors the core
// MCPPresentationTools.gd ANNOTATION_KIND_* constants — keep in sync until
// the core implementation is fully removed in T6 R3+.
var supportedAnnotationKinds = []map[string]interface{}{
	{"id": "comment", "label": "Comment", "target_scope": "tile"},
	{"id": "review_note", "label": "Review note", "target_scope": "slide"},
	{"id": "speaker_note", "label": "Speaker note", "target_scope": "slide"},
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
	case "minerva_presentation_list_annotation_kinds":
		respondTool(client.enc, msg.ID, toolListAnnotationKinds(p.Arguments))
	case "minerva_presentation_list_slides":
		respondTool(client.enc, msg.ID, toolListSlides(client, p.Arguments))
	case "minerva_presentation_list_tiles":
		respondTool(client.enc, msg.ID, toolListTiles(client, p.Arguments))
	case "minerva_presentation_list_annotations":
		respondTool(client.enc, msg.ID, toolListAnnotations(client, p.Arguments))
	case "minerva_presentation_get_slide":
		respondTool(client.enc, msg.ID, toolGetSlide(client, p.Arguments))
	case "minerva_presentation_get_tile":
		respondTool(client.enc, msg.ID, toolGetTile(client, p.Arguments))
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
// Deck loader — dual-mode addressing for read/write tools
// ---------------------------------------------------------------------------

// toolFault is the structured failure we return from helpers; respondTool
// wraps these into the MCP envelope with isError=true.
type toolFault struct {
	Code string
	Msg  string
}

func failResult(f *toolFault) map[string]interface{} {
	return map[string]interface{}{
		"success":    false,
		"error_code": f.Code,
		"error":      f.Msg,
	}
}

// parseTargetArgs extracts tab_name + path from a tools/call arguments
// payload, enforcing exactly-one semantics.
func parseTargetArgs(rawArgs json.RawMessage) (map[string]interface{}, *toolFault) {
	args := map[string]interface{}{}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return nil, &toolFault{Code: "schema_validation_failed", Msg: "tools/call arguments not a JSON object: " + err.Error()}
		}
	}
	tabName, _ := args["tab_name"].(string)
	path, _ := args["path"].(string)
	if tabName == "" && path == "" {
		return nil, &toolFault{Code: "schema_validation_failed", Msg: "Provide either tab_name (open tab) or path (.mdeck file)"}
	}
	if tabName != "" && path != "" {
		return nil, &toolFault{Code: "schema_validation_failed", Msg: "tab_name and path are mutually exclusive"}
	}
	return args, nil
}

// loadDeck resolves the args' addressing and returns the parsed deck dict.
// Tab mode goes through host.documents.get_state (live state); path mode
// reads the .mdeck JSON from disk directly.
func loadDeck(client *hostClient, args map[string]interface{}) (map[string]interface{}, *toolFault) {
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		return loadDeckFromTab(client, tabName)
	}
	if path, _ := args["path"].(string); path != "" {
		return loadDeckFromPath(path)
	}
	return nil, &toolFault{Code: "schema_validation_failed", Msg: "no target supplied"}
}

func loadDeckFromTab(client *hostClient, tabName string) (map[string]interface{}, *toolFault) {
	raw, capErr := client.callCapability("host.documents.get_state", map[string]interface{}{
		"editor_name": tabName,
	})
	if capErr != nil {
		return nil, &toolFault{
			Code: fmt.Sprintf("rpc_error_%d", capErr.Code),
			Msg:  capErr.Message,
		}
	}
	var brokerResp struct {
		Success      bool                   `json:"success"`
		ErrorCode    string                 `json:"error_code,omitempty"`
		ErrorMessage string                 `json:"error_message,omitempty"`
		Result       map[string]interface{} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &brokerResp); err != nil {
		return nil, &toolFault{Code: "parse_error", Msg: "parse host.documents.get_state response: " + err.Error()}
	}
	if !brokerResp.Success {
		return nil, &toolFault{Code: brokerResp.ErrorCode, Msg: brokerResp.ErrorMessage}
	}
	panelState, ok := brokerResp.Result["panel_state"].(map[string]interface{})
	if !ok {
		// Some editor types (text editors) won't return panel_state; bail.
		return nil, &toolFault{Code: "no_panel_state", Msg: "editor returned no panel_state — is this a presentation tab?"}
	}
	return panelState, nil
}

func loadDeckFromPath(path string) (map[string]interface{}, *toolFault) {
	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, &toolFault{Code: "io_error", Msg: err.Error()}
	}
	var deck map[string]interface{}
	if err := json.Unmarshal(bytes, &deck); err != nil {
		return nil, &toolFault{Code: "parse_error", Msg: "parse " + path + ": " + err.Error()}
	}
	return deck, nil
}

// slideAt extracts a slide by index from a deck Dictionary, or returns a
// structured error if missing/out-of-range.
func slideAt(deck map[string]interface{}, idx int) (map[string]interface{}, *toolFault) {
	slides, _ := deck["slides"].([]interface{})
	if idx < 0 || idx >= len(slides) {
		return nil, &toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d (deck has %d slides)", idx, len(slides))}
	}
	slide, ok := slides[idx].(map[string]interface{})
	if !ok {
		return nil, &toolFault{Code: "schema_violation", Msg: "slide entry is not a JSON object"}
	}
	return slide, nil
}

func intArg(args map[string]interface{}, key string, fallback int) (int, bool) {
	v, ok := args[key]
	if !ok {
		return fallback, false
	}
	switch n := v.(type) {
	case float64:
		return int(n), true
	case int:
		return n, true
	}
	return fallback, false
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
// Tool: minerva_presentation_list_annotation_kinds
// ---------------------------------------------------------------------------

func toolListAnnotationKinds(_ json.RawMessage) map[string]interface{} {
	return map[string]interface{}{
		"success": true,
		"kinds":   supportedAnnotationKinds,
	}
}


// ---------------------------------------------------------------------------
// Tool: minerva_presentation_list_slides
// ---------------------------------------------------------------------------

func toolListSlides(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slides, _ := deck["slides"].([]interface{})
	summaries := []map[string]interface{}{}
	for i, raw := range slides {
		s, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		tiles, _ := s["tiles"].([]interface{})
		entry := map[string]interface{}{
			"index":      i,
			"id":         strOr(s, "id", ""),
			"tile_count": len(tiles),
		}
		if title, has := s["title"].(string); has && title != "" {
			entry["title"] = title
		}
		summaries = append(summaries, entry)
	}
	aspect, _ := deck["aspect"].(string)
	if aspect == "" {
		aspect = "16:9"
	}
	version := 1
	if v, ok := deck["version"].(float64); ok {
		version = int(v)
	}
	return map[string]interface{}{
		"success": true,
		"slides":  summaries,
		"aspect":  aspect,
		"version": version,
	}
}


// ---------------------------------------------------------------------------
// Tool: minerva_presentation_list_tiles
// ---------------------------------------------------------------------------

func toolListTiles(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slide, fault := slideAt(deck, idx)
	if fault != nil {
		return failResult(fault)
	}
	tiles, _ := slide["tiles"].([]interface{})
	out := []map[string]interface{}{}
	for i, raw := range tiles {
		t, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		entry := map[string]interface{}{
			"index": i,
			"id":    strOr(t, "id", ""),
			"kind":  strOr(t, "kind", ""),
		}
		for _, axis := range []string{"x", "y", "w", "h"} {
			if v, has := t[axis].(float64); has {
				entry[axis] = v
			}
		}
		out = append(out, entry)
	}
	return map[string]interface{}{
		"success":     true,
		"slide_index": idx,
		"tiles":       out,
	}
}


// ---------------------------------------------------------------------------
// Tool: minerva_presentation_list_annotations
// ---------------------------------------------------------------------------

func toolListAnnotations(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slide, fault := slideAt(deck, idx)
	if fault != nil {
		return failResult(fault)
	}
	annotations, _ := slide["annotations"].([]interface{})
	return map[string]interface{}{
		"success":     true,
		"slide_index": idx,
		"annotations": annotations,
	}
}


// ---------------------------------------------------------------------------
// Tool: minerva_presentation_get_slide
// ---------------------------------------------------------------------------

func toolGetSlide(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slide, fault := slideAt(deck, idx)
	if fault != nil {
		return failResult(fault)
	}
	return map[string]interface{}{
		"success":     true,
		"slide_index": idx,
		"slide":       slide,
	}
}


// ---------------------------------------------------------------------------
// Tool: minerva_presentation_get_tile
// ---------------------------------------------------------------------------

func toolGetTile(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	slideIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	tileIdx, ok := intArg(args, "tile_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "tile_index is required"})
	}
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slide, fault := slideAt(deck, slideIdx)
	if fault != nil {
		return failResult(fault)
	}
	tiles, _ := slide["tiles"].([]interface{})
	if tileIdx < 0 || tileIdx >= len(tiles) {
		return failResult(&toolFault{Code: "out_of_range",
			Msg: fmt.Sprintf("tile_index out of range: %d (slide has %d tiles)", tileIdx, len(tiles))})
	}
	tile, ok := tiles[tileIdx].(map[string]interface{})
	if !ok {
		return failResult(&toolFault{Code: "schema_violation", Msg: "tile entry is not a JSON object"})
	}
	return map[string]interface{}{
		"success":     true,
		"slide_index": slideIdx,
		"tile_index":  tileIdx,
		"tile":        tile,
	}
}


// strOr returns m[key] as string, or fallback if missing/wrong type.
func strOr(m map[string]interface{}, key, fallback string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return fallback
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
