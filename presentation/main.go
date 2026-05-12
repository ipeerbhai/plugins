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
//
//	(a) the matching response (correlated by id), or
//	(b) stdin EOF.
//
// The synchronous read pattern below is safe under that guarantee.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
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
// Phase 5 host.documents.* helpers
// ---------------------------------------------------------------------------

// GetNode reads a subtree at a JSON Pointer path within an editor's panel
// state. The returned value is blob-stripped: blob bytes are replaced by
// handles — caller fetches bytes via GetBlob only when needed.
//
// path: "" for the entire state root, otherwise an RFC 6901 JSON Pointer
// (must start with "/").
//
// Returns (found, value, fault). Not-found is a non-error outcome — the
// caller may legitimately probe for optional fields. Returns fault on
// protocol or validation errors (e.g. unknown editor, malformed path).
func (c *hostClient) GetNode(editorName, path string) (found bool, value interface{}, fault *toolFault) {
	raw, capErr := c.callCapability("host.documents.get_node", map[string]interface{}{
		"editor_name": editorName,
		"path":        path,
	})
	if capErr != nil {
		return false, nil, &toolFault{
			Code: fmt.Sprintf("rpc_error_%d", capErr.Code),
			Msg:  capErr.Message,
		}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			EditorName string      `json:"editor_name"`
			Path       string      `json:"path"`
			Found      bool        `json:"found"`
			Value      interface{} `json:"value"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return false, nil, &toolFault{Code: "parse_error", Msg: "parse host.documents.get_node response: " + err.Error()}
	}
	if !resp.Success {
		return false, nil, &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return false, nil, &toolFault{Code: "parse_error", Msg: "host.documents.get_node returned success but no result"}
	}
	return resp.Result.Found, resp.Result.Value, nil
}

// GetBlob fetches blob bytes for a handle. Returns the decoded bytes and
// content type.
//
// Use only when the bytes are actually needed (e.g. an image-edit tool);
// plain metadata operations should read the handle via GetNode and call
// GetBlob only if the bytes themselves are about to be operated on.
func (c *hostClient) GetBlob(editorName, blobHandle string) (contentType string, data []byte, fault *toolFault) {
	raw, capErr := c.callCapability("host.documents.get_blob", map[string]interface{}{
		"editor_name": editorName,
		"blob_handle": blobHandle,
	})
	if capErr != nil {
		return "", nil, &toolFault{
			Code: fmt.Sprintf("rpc_error_%d", capErr.Code),
			Msg:  capErr.Message,
		}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			EditorName  string `json:"editor_name"`
			BlobHandle  string `json:"blob_handle"`
			ContentType string `json:"content_type"`
			BytesB64    string `json:"bytes_b64"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", nil, &toolFault{Code: "parse_error", Msg: "parse host.documents.get_blob response: " + err.Error()}
	}
	if !resp.Success {
		return "", nil, &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return "", nil, &toolFault{Code: "parse_error", Msg: "host.documents.get_blob returned success but no result"}
	}
	decoded, err := base64.StdEncoding.DecodeString(resp.Result.BytesB64)
	if err != nil {
		return "", nil, &toolFault{Code: "parse_error", Msg: "base64 decode blob bytes: " + err.Error()}
	}
	return resp.Result.ContentType, decoded, nil
}

// PutBlob uploads bytes to the editor's blob store and returns a handle the
// caller can then reference in a subsequent Patch call. Refcount is 1 after
// store; the blob stays in the store until referenced by panel state via
// patch_state, or until the editor is closed.
func (c *hostClient) PutBlob(editorName, contentType string, data []byte) (blobHandle string, fault *toolFault) {
	raw, capErr := c.callCapability("host.documents.put_blob", map[string]interface{}{
		"editor_name":  editorName,
		"content_type": contentType,
		"bytes_b64":    base64.StdEncoding.EncodeToString(data),
	})
	if capErr != nil {
		return "", &toolFault{
			Code: fmt.Sprintf("rpc_error_%d", capErr.Code),
			Msg:  capErr.Message,
		}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			EditorName  string `json:"editor_name"`
			BlobHandle  string `json:"blob_handle"`
			ContentType string `json:"content_type"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", &toolFault{Code: "parse_error", Msg: "parse host.documents.put_blob response: " + err.Error()}
	}
	if !resp.Success {
		return "", &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return "", &toolFault{Code: "parse_error", Msg: "host.documents.put_blob returned success but no result"}
	}
	return resp.Result.BlobHandle, nil
}

// PatchBuilder accumulates RFC 6902 JSON Patch operations for atomic
// application to an editor's panel state. Call Send() to dispatch. The
// builder is single-use: Send consumes it.
//
// Obtain a builder via hostClient.Patch(editorName). Chain op methods, then
// call Send().
type PatchBuilder struct {
	client     *hostClient
	editorName string
	ops        []map[string]interface{}
	sent       bool
}

// Patch returns a new PatchBuilder for the named editor. Chain Add, Remove,
// Replace, Move, Copy, or Test calls, then call Send() to dispatch.
func (c *hostClient) Patch(editorName string) *PatchBuilder {
	return &PatchBuilder{client: c, editorName: editorName}
}

// Add appends an RFC 6902 "add" operation. path must be an RFC 6901 JSON
// Pointer (e.g. "/slides/0/title"). value is the node to add.
func (b *PatchBuilder) Add(path string, value interface{}) *PatchBuilder {
	b.ops = append(b.ops, map[string]interface{}{"op": "add", "path": path, "value": value})
	return b
}

// Remove appends an RFC 6902 "remove" operation. path is the JSON Pointer of
// the node to remove.
func (b *PatchBuilder) Remove(path string) *PatchBuilder {
	b.ops = append(b.ops, map[string]interface{}{"op": "remove", "path": path})
	return b
}

// Replace appends an RFC 6902 "replace" operation. path is the JSON Pointer
// of the node to replace; value is the replacement.
func (b *PatchBuilder) Replace(path string, value interface{}) *PatchBuilder {
	b.ops = append(b.ops, map[string]interface{}{"op": "replace", "path": path, "value": value})
	return b
}

// Move appends an RFC 6902 "move" operation. from is the source JSON Pointer;
// path is the destination.
func (b *PatchBuilder) Move(from, path string) *PatchBuilder {
	b.ops = append(b.ops, map[string]interface{}{"op": "move", "from": from, "path": path})
	return b
}

// Copy appends an RFC 6902 "copy" operation. from is the source JSON Pointer;
// path is the destination.
func (b *PatchBuilder) Copy(from, path string) *PatchBuilder {
	b.ops = append(b.ops, map[string]interface{}{"op": "copy", "from": from, "path": path})
	return b
}

// Test appends an RFC 6902 "test" operation. The broker rejects the entire
// patch (atomically) if the node at path does not equal value.
func (b *PatchBuilder) Test(path string, value interface{}) *PatchBuilder {
	b.ops = append(b.ops, map[string]interface{}{"op": "test", "path": path, "value": value})
	return b
}

// Send dispatches the accumulated patch via host.documents.patch_state.
// Returns (op_count, nil) on success. Returns (0, fault) on validation,
// apply, or write-back failure.
//
// Fail-fast: if no ops have been accumulated, Send returns an "empty_patch"
// fault without making a wire call — the broker rejects empty patches but the
// helper saves the roundtrip.
//
// Single-use guard: a second Send() on the same builder returns "already_sent"
// without making a wire call, so accidental re-dispatch of the same patch is
// caught early rather than silently doubling the mutation.
func (b *PatchBuilder) Send() (opCount int, fault *toolFault) {
	if b.sent {
		return 0, &toolFault{Code: "already_sent", Msg: "PatchBuilder.Send was already called on this builder; create a new builder via hostClient.Patch(...) for a new dispatch"}
	}
	if len(b.ops) == 0 {
		return 0, &toolFault{Code: "empty_patch", Msg: "patch has no operations; add at least one op before calling Send"}
	}
	b.sent = true
	raw, capErr := b.client.callCapability("host.documents.patch_state", map[string]interface{}{
		"editor_name": b.editorName,
		"patch":       b.ops,
	})
	if capErr != nil {
		return 0, &toolFault{
			Code: fmt.Sprintf("rpc_error_%d", capErr.Code),
			Msg:  capErr.Message,
		}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			EditorName string `json:"editor_name"`
			OpCount    int    `json:"op_count"`
			AppliedOps int    `json:"applied_ops"`
			Dirty      bool   `json:"dirty"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return 0, &toolFault{Code: "parse_error", Msg: "parse host.documents.patch_state response: " + err.Error()}
	}
	if !resp.Success {
		return 0, &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return 0, &toolFault{Code: "parse_error", Msg: "host.documents.patch_state returned success but no result"}
	}
	return resp.Result.OpCount, nil
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
	{
		"name":        "minerva_presentation_add_slide",
		"description": "Append (default) or insert a blank slide. Returns the new slide_index and slide_id. Optional `position` (0..slide_count, default = append) and `title`.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"position": map[string]interface{}{"type": "integer"},
				"title":    map[string]interface{}{"type": "string"},
			}),
		},
	},
	{
		"name":        "minerva_presentation_set_slide_title",
		"description": "Set or clear a slide's title. Pass title=\"\" to clear. Requires slide_index and tab_name|path.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"title":       map[string]interface{}{"type": "string"},
			}),
			"required": []string{"slide_index", "title"},
		},
	},
	{
		"name":        "minerva_presentation_set_aspect",
		"description": "Change the deck's aspect ratio. One of '16:9' (default), '4:3', '1:1'. Existing tile coords stay normalized [0,1].",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"aspect": map[string]interface{}{"type": "string"},
			}),
			"required": []string{"aspect"},
		},
	},
	{
		"name":        "minerva_presentation_move_slide",
		"description": "Move a slide from one index to another. No-op if from_index == to_index.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"from_index": map[string]interface{}{"type": "integer"},
				"to_index":   map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"from_index", "to_index"},
		},
	},
	{
		"name":        "minerva_presentation_remove_slide",
		"description": "Remove a slide by index. Refuses if it would leave the deck with zero slides.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"slide_index"},
		},
	},
	{
		"name":        "minerva_presentation_set_slide_background",
		"description": "Set a slide's background. Provide exactly one of color (hex like #A07A4A), image_path (PNG/JPEG file embedded as base64), or image_base64 (bare base64).",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index":  map[string]interface{}{"type": "integer"},
				"color":        map[string]interface{}{"type": "string", "description": "Hex color (with or without leading #)."},
				"image_path":   map[string]interface{}{"type": "string", "description": "Path to a PNG/JPEG file."},
				"image_base64": map[string]interface{}{"type": "string", "description": "Bare base64 PNG/JPEG (no data: prefix)."},
			}),
			"required": []string{"slide_index"},
		},
	},
	{
		"name":        "minerva_presentation_create_deck",
		"description": "Create a new .mdeck slide deck file on disk with one blank slide. Returns the path written. The .mdeck extension is appended if missing. Optional title (first slide), aspect (16:9, 4:3, 1:1).",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"path":   map[string]interface{}{"type": "string", "description": "Filesystem path to write."},
				"title":  map[string]interface{}{"type": "string", "description": "Optional title for the first slide."},
				"aspect": map[string]interface{}{"type": "string", "description": "16:9 (default), 4:3, or 1:1."},
			},
			"required": []string{"path"},
		},
	},
	{
		"name":        "minerva_presentation_remove_tile",
		"description": "Remove a tile from a slide by tile_id. Also scrubs reveal-order references to the removed tile.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"tile_id":     map[string]interface{}{"type": "string"},
			}),
			"required": []string{"slide_index", "tile_id"},
		},
	},
	{
		"name":        "minerva_presentation_add_spreadsheet_tile",
		"description": "Add a spreadsheet tile to a slide. rows × cols grid. cells is an optional 2D array matching rows × cols (each cell may be a dict {value, type?, formatting...}, a bare scalar, or null). Cell types: 0=empty, 1=text, 2=number, 3=date, 4=formula. header_row/header_col are optional flags.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"x":           map[string]interface{}{"type": "number"},
				"y":           map[string]interface{}{"type": "number"},
				"w":           map[string]interface{}{"type": "number"},
				"h":           map[string]interface{}{"type": "number"},
				"rows":        map[string]interface{}{"type": "integer"},
				"cols":        map[string]interface{}{"type": "integer"},
				"cells":       map[string]interface{}{"type": "array"},
				"header_row":  map[string]interface{}{"type": "boolean"},
				"header_col":  map[string]interface{}{"type": "boolean"},
				"rotation":    map[string]interface{}{"type": "number"},
			}),
			"required": []string{"slide_index", "x", "y", "w", "h", "rows", "cols"},
		},
	},
	{
		"name":        "minerva_presentation_modify_spreadsheet_cells",
		"description": "Patch individual cells on a spreadsheet tile. cells is a sparse list of [{row, col, value, type?, ...}] — only the named fields change. Out-of-bounds entries are skipped (counted in skipped[]).",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"tile_id":     map[string]interface{}{"type": "string"},
				"cells":       map[string]interface{}{"type": "array"},
			}),
			"required": []string{"slide_index", "tile_id", "cells"},
		},
	},
	{
		"name":        "minerva_presentation_resize_spreadsheet",
		"description": "Resize a spreadsheet tile's grid. Existing cells preserved when growing; truncated when shrinking. New cells are CELL_EMPTY. Pixel rect (w/h) unchanged.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"tile_id":     map[string]interface{}{"type": "string"},
				"rows":        map[string]interface{}{"type": "integer"},
				"cols":        map[string]interface{}{"type": "integer"},
			}),
			"required": []string{"slide_index", "tile_id", "rows", "cols"},
		},
	},
	{
		"name":        "minerva_presentation_add_text_tile",
		"description": "Add a text tile to a slide. Coords x/y/w/h are 0..1 normalized. text_mode is plain (BBCode supported), bullet, or numbered. Optional font_size (8..200, fixed mode), auto_fit (largest font that fits), rotation.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index": map[string]interface{}{"type": "integer"},
				"x":           map[string]interface{}{"type": "number"},
				"y":           map[string]interface{}{"type": "number"},
				"w":           map[string]interface{}{"type": "number"},
				"h":           map[string]interface{}{"type": "number"},
				"content":     map[string]interface{}{"type": "string"},
				"text_mode":   map[string]interface{}{"type": "string", "description": "plain | bullet | numbered. Defaults to plain."},
				"font_size":   map[string]interface{}{"type": "integer", "description": "Optional fixed font size in pixels (8..200)."},
				"auto_fit":    map[string]interface{}{"type": "boolean", "description": "When true and no font_size, picks largest font that fits."},
				"rotation":    map[string]interface{}{"type": "number", "description": "Optional rotation in radians."},
			}),
			"required": []string{"slide_index", "x", "y", "w", "h", "content"},
		},
	},
	{
		"name":        "minerva_presentation_list_open_annotations",
		"description": "Return all annotations across the deck whose lifecycle is 'open' (not resolved/applied/stale). Each entry includes slide_index, annotation_id, kind, and summary. Use this to find work the LLM still needs to address.",
		"inputSchema": map[string]interface{}{
			"type":       "object",
			"properties": targetSchema,
		},
	},
	{
		"name":        "minerva_presentation_add_annotation",
		"description": "Add an annotation envelope to a slide. kind is one of: callout, 2d_arrow, 2d_text. summary is required (surfaced by list_annotations). Optional: anchor (substrate anchor dict — defaults: callout→plugin=\"presentation\", 2d_arrow/2d_text→plugin=\"core\"); kind_payload (kind-specific dict — text-bearing kinds get summary mirrored to kind_payload.text when not set); lifecycle (open|applied|resolved|stale; default open). Returns annotation_id.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index":  map[string]interface{}{"type": "integer"},
				"kind":         map[string]interface{}{"type": "string"},
				"summary":      map[string]interface{}{"type": "string"},
				"anchor":       map[string]interface{}{"type": "object"},
				"kind_payload": map[string]interface{}{"type": "object"},
				"lifecycle":    map[string]interface{}{"type": "string", "description": "open | applied | resolved | stale (default open)"},
			}),
			"required": []string{"slide_index", "kind", "summary"},
		},
	},
	{
		"name":        "minerva_presentation_remove_annotation",
		"description": "Remove an annotation from a slide by annotation_id. If the slide.annotations array empties, the key is removed entirely (omit-when-default). Also scrubs any reveal[] entries that reference this annotation_id.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index":   map[string]interface{}{"type": "integer"},
				"annotation_id": map[string]interface{}{"type": "string"},
			}),
			"required": []string{"slide_index", "annotation_id"},
		},
	},
	{
		"name":        "minerva_presentation_set_annotation_resolved",
		"description": "Mark an annotation resolved (true) or open (false). Maps onto substrate's lifecycle field: true → 'resolved', false → 'open'. To set 'applied' or 'stale' explicitly, pass lifecycle directly. Optional note appends to a resolution_notes array on the envelope.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": withProps(targetSchema, map[string]interface{}{
				"slide_index":   map[string]interface{}{"type": "integer"},
				"annotation_id": map[string]interface{}{"type": "string"},
				"resolved":      map[string]interface{}{"type": "boolean"},
				"lifecycle":     map[string]interface{}{"type": "string", "description": "Explicit lifecycle state — overrides resolved when present."},
				"note":          map[string]interface{}{"type": "string"},
			}),
			"required": []string{"slide_index", "annotation_id"},
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
// minerva_presentation_list_annotation_kinds. The kinds here MUST match
// what presentation_tile_annotation_host.gd accepts AND what
// AnnotationV2Schema validates as substrate-compatible. See
// MCPPresentationTools.gd:144 ANNOTATION_KINDS_VALID. The pre-T6-tail
// catalogue (comment / review_note / speaker_note) was a doc bug —
// substrate would reject all three at validation time.
//
// Anchor-compat (AnnotationV2Schema._GENERIC_KIND_ANCHORS):
//   - callout            anchor "*/*"    → any anchor.plugin works
//   - 2d_arrow / 2d_text anchor "core/*" → anchor.plugin must be "core"
//   (handled by anchorDefault when caller omits anchor)
var supportedAnnotationKinds = []map[string]interface{}{
	{"kind": "callout"},
	{"kind": "2d_arrow"},
	{"kind": "2d_text"},
}

// annotationKindsValid is the validation set — same names, sans the wrapping
// dict.  Mirrors MCPPresentationTools.gd:144.
var annotationKindsValid = []string{"callout", "2d_arrow", "2d_text"}

// annotationKindsTextBearing: text-bearing kinds whose summary is mirrored
// into kind_payload.text when the caller didn't supply one. Mirrors
// MCPPresentationTools.gd:149.
var annotationKindsTextBearing = map[string]bool{
	"callout": true,
	"2d_text": true,
}

// annotationLifecyclesValid mirrors MCPPresentationTools.gd:128.
var annotationLifecyclesValid = []string{"open", "applied", "resolved", "stale"}

const annotationSchemaVersion = 2

func stringInSlice(needle string, hay []string) bool {
	for _, v := range hay {
		if v == needle {
			return true
		}
	}
	return false
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
	case "minerva_presentation_add_slide":
		respondTool(client.enc, msg.ID, toolAddSlide(client, p.Arguments))
	case "minerva_presentation_set_slide_title":
		respondTool(client.enc, msg.ID, toolSetSlideTitle(client, p.Arguments))
	case "minerva_presentation_set_aspect":
		respondTool(client.enc, msg.ID, toolSetAspect(client, p.Arguments))
	case "minerva_presentation_move_slide":
		respondTool(client.enc, msg.ID, toolMoveSlide(client, p.Arguments))
	case "minerva_presentation_remove_slide":
		respondTool(client.enc, msg.ID, toolRemoveSlide(client, p.Arguments))
	case "minerva_presentation_remove_tile":
		respondTool(client.enc, msg.ID, toolRemoveTile(client, p.Arguments))
	case "minerva_presentation_add_text_tile":
		respondTool(client.enc, msg.ID, toolAddTextTile(client, p.Arguments))
	case "minerva_presentation_add_spreadsheet_tile":
		respondTool(client.enc, msg.ID, toolAddSpreadsheetTile(client, p.Arguments))
	case "minerva_presentation_modify_spreadsheet_cells":
		respondTool(client.enc, msg.ID, toolModifySpreadsheetCells(client, p.Arguments))
	case "minerva_presentation_resize_spreadsheet":
		respondTool(client.enc, msg.ID, toolResizeSpreadsheet(client, p.Arguments))
	case "minerva_presentation_create_deck":
		respondTool(client.enc, msg.ID, toolCreateDeck(client, p.Arguments))
	case "minerva_presentation_list_open_annotations":
		respondTool(client.enc, msg.ID, toolListOpenAnnotations(client, p.Arguments))
	case "minerva_presentation_add_annotation":
		respondTool(client.enc, msg.ID, toolAddAnnotation(client, p.Arguments))
	case "minerva_presentation_remove_annotation":
		respondTool(client.enc, msg.ID, toolRemoveAnnotation(client, p.Arguments))
	case "minerva_presentation_set_annotation_resolved":
		respondTool(client.enc, msg.ID, toolSetAnnotationResolved(client, p.Arguments))
	case "minerva_presentation_set_slide_background":
		respondTool(client.enc, msg.ID, toolSetSlideBackground(client, p.Arguments))
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
			"success":    false,
			"error":      capErr.Message,
			"error_code": fmt.Sprintf("rpc_error_%d", capErr.Code),
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
	// Mirrors core _list_annotation_kinds shape: kinds + lifecycle_states +
	// schema_version. Earlier plugin shape (just {success, kinds}) omitted
	// the lifecycle catalogue and schema_version pinning.
	return map[string]interface{}{
		"success":          true,
		"kinds":            supportedAnnotationKinds,
		"lifecycle_states": annotationLifecyclesValid,
		"schema_version":   annotationSchemaVersion,
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

	// tab_name mode: fetch only the subtree we need via GetNode.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		return toolListSlidesFromTab(client, tabName)
	}

	// disk mode: unchanged.
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	return listSlidesSummary(deck)
}

func toolListSlidesFromTab(client *hostClient, tabName string) map[string]interface{} {
	// Fetch /slides subtree — blob-stripped, metadata only.
	found, slidesVal, fault := client.GetNode(tabName, "/slides")
	if fault != nil {
		return failResult(fault)
	}
	if !found {
		return failResult(&toolFault{Code: "not_found", Msg: "/slides not present in deck state"})
	}
	slides, _ := slidesVal.([]interface{})

	// Fetch aspect + version from the root for the metadata fields.
	foundRoot, rootVal, fault := client.GetNode(tabName, "")
	if fault != nil {
		return failResult(fault)
	}
	aspect := "16:9"
	version := 1
	if foundRoot {
		if root, ok := rootVal.(map[string]interface{}); ok {
			if a, _ := root["aspect"].(string); a != "" {
				aspect = a
			}
			if v, ok := root["version"].(float64); ok {
				version = int(v)
			}
		}
	}

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
	return map[string]interface{}{
		"success": true,
		"slides":  summaries,
		"aspect":  aspect,
		"version": version,
	}
}

// listSlidesSummary builds the slides summary response from a loaded deck dict.
// Used by the disk-mode path.
func listSlidesSummary(deck map[string]interface{}) map[string]interface{} {
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

	// tab_name mode: fetch only the specific slide's tiles subtree.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		return toolListTilesFromTab(client, tabName, idx)
	}

	// disk mode: unchanged.
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slide, fault := slideAt(deck, idx)
	if fault != nil {
		return failResult(fault)
	}
	return tilesSummary(slide, idx)
}

func toolListTilesFromTab(client *hostClient, tabName string, idx int) map[string]interface{} {
	path := fmt.Sprintf("/slides/%d/tiles", idx)
	found, tilesVal, fault := client.GetNode(tabName, path)
	if fault != nil {
		return failResult(fault)
	}
	if !found {
		return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range or no tiles: %d", idx)})
	}
	tiles, _ := tilesVal.([]interface{})
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

// tilesSummary builds the tiles listing from a slide dict. Used by disk-mode path.
func tilesSummary(slide map[string]interface{}, idx int) map[string]interface{} {
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

	// tab_name mode: fetch only the annotations subtree for this slide.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		path := fmt.Sprintf("/slides/%d/annotations", idx)
		found, annVal, fault := client.GetNode(tabName, path)
		if fault != nil {
			return failResult(fault)
		}
		// annotations key may be absent (slide has none) — treat not-found as empty.
		var annotations []interface{}
		if found {
			annotations, _ = annVal.([]interface{})
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": idx,
			"annotations": annotations,
		}
	}

	// disk mode: unchanged.
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

	// tab_name mode: fetch only the specific slide subtree.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		path := fmt.Sprintf("/slides/%d", idx)
		found, slideVal, fault := client.GetNode(tabName, path)
		if fault != nil {
			return failResult(fault)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", idx)})
		}
		slide, ok := slideVal.(map[string]interface{})
		if !ok {
			return failResult(&toolFault{Code: "schema_violation", Msg: "slide entry is not a JSON object"})
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": idx,
			"slide":       slide,
		}
	}

	// disk mode: unchanged.
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

	// tab_name mode: fetch only the specific tile subtree.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		path := fmt.Sprintf("/slides/%d/tiles/%d", slideIdx, tileIdx)
		found, tileVal, fault := client.GetNode(tabName, path)
		if fault != nil {
			return failResult(fault)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range",
				Msg: fmt.Sprintf("tile_index out of range: %d (slide %d)", tileIdx, slideIdx)})
		}
		tile, ok := tileVal.(map[string]interface{})
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

	// disk mode: unchanged.
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
// Deck writer — shared mutate-and-save pipeline (T6 R3)
// ---------------------------------------------------------------------------
//
// mutateDeck is the single tested round-trip every write tool goes through:
//   1. loadDeck (tab via host.documents.get_state | path via os.ReadFile)
//   2. caller's mutation closure mutates the deck Dict in place
//   3. saveDeck (tab via host.documents.set_state | path via os.WriteFile)
//
// The closure can return additional result fields to merge into the response;
// returning a *toolFault aborts before save. This keeps every write tool's
// body to ~10-15 lines and centralizes the addressing + persistence logic.

func mutateDeck(
	client *hostClient,
	args map[string]interface{},
	mutate func(deck map[string]interface{}) (map[string]interface{}, *toolFault),
) map[string]interface{} {
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	extra, fault := mutate(deck)
	if fault != nil {
		return failResult(fault)
	}
	if fault := saveDeck(client, args, deck); fault != nil {
		return failResult(fault)
	}
	out := map[string]interface{}{"success": true}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

func saveDeck(client *hostClient, args map[string]interface{}, deck map[string]interface{}) *toolFault {
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		return saveDeckToTab(client, tabName, deck)
	}
	if path, _ := args["path"].(string); path != "" {
		return saveDeckToPath(path, deck)
	}
	return &toolFault{Code: "schema_validation_failed", Msg: "no target supplied"}
}

func saveDeckToTab(client *hostClient, tabName string, deck map[string]interface{}) *toolFault {
	raw, capErr := client.callCapability("host.documents.set_state", map[string]interface{}{
		"editor_name": tabName,
		"panel_state": deck,
	})
	if capErr != nil {
		return &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return &toolFault{Code: "parse_error", Msg: "parse host.documents.set_state response: " + err.Error()}
	}
	if !resp.Success {
		return &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	return nil
}

func saveDeckToPath(path string, deck map[string]interface{}) *toolFault {
	body, err := json.MarshalIndent(deck, "", "  ")
	if err != nil {
		return &toolFault{Code: "marshal_error", Msg: err.Error()}
	}
	// Match GDScript _write_deck_to_disk which called DirAccess.make_dir_recursive_absolute
	// before writing — create_deck must work when the parent dir doesn't yet exist.
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return &toolFault{Code: "io_error", Msg: err.Error()}
		}
	}
	if err := os.WriteFile(path, body, 0644); err != nil {
		return &toolFault{Code: "io_error", Msg: err.Error()}
	}
	return nil
}

// ---------------------------------------------------------------------------
// ID generation + slide construction — mirror MCPPresentationTools._gen_id
// ---------------------------------------------------------------------------

var idSeed int = -1

func genID(prefix string) string {
	// Match the pattern used by core: <prefix>_<6 random hex>. Initial seed
	// from time + crypto rand is overkill; for plugin-side IDs we use a
	// simple counter + os PID hash to keep IDs stable within a run.
	if idSeed < 0 {
		idSeed = (os.Getpid()*1000 + int(timeNowUnix())%1000) & 0xffffff
	}
	idSeed++
	return fmt.Sprintf("%s_%06x", prefix, idSeed&0xffffff)
}

func makeSlide(title string) map[string]interface{} {
	s := map[string]interface{}{
		"id":         genID("slide"),
		"background": map[string]interface{}{"kind": "color", "value": "#ffffff"},
		"tiles":      []interface{}{},
		"reveal":     []interface{}{},
	}
	if title != "" {
		s["title"] = title
	}
	return s
}

// timeNowUnix is a small indirection so tests can keep idSeed deterministic
// without spawning real time. genID's seed is salted by os.Getpid() anyway.
func timeNowUnix() int64 {
	return time.Now().Unix()
}

// ---------------------------------------------------------------------------
// Aspect validation — must match MCPPresentationTools.ASPECTS_VALID
// ---------------------------------------------------------------------------

var validAspects = []string{"16:9", "4:3", "1:1"}

func aspectIsValid(a string) bool {
	for _, v := range validAspects {
		if v == a {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Tile helpers — text mode validation, coord validation, tile lookup
// ---------------------------------------------------------------------------

const (
	tileKindText     = "text"
	textModePlain    = "plain"
	textModeBullet   = "bullet"
	textModeNumbered = "numbered"
)

var validTextModes = []string{textModePlain, textModeBullet, textModeNumbered}

func textModeIsValid(m string) bool {
	for _, v := range validTextModes {
		if v == m {
			return true
		}
	}
	return false
}

// validateCoords mirrors MCPPresentationTools._validate_coords: x/y/w/h must
// be present, numeric, and each in [0,1]. (The original deliberately does not
// constrain x+w / y+h — tile rect overflow is a renderer concern, not a model
// concern, and legacy decks rely on this leniency.)
func validateCoords(args map[string]interface{}) *toolFault {
	for _, k := range []string{"x", "y", "w", "h"} {
		v, ok := args[k]
		if !ok || v == nil {
			return &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("%s is required", k)}
		}
		f, ok := v.(float64)
		if !ok {
			return &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("%s must be a number", k)}
		}
		if f < 0.0 || f > 1.0 {
			return &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("%s must be in [0, 1], got %v", k, f)}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Spreadsheet helpers — cell type constants + normalization
// ---------------------------------------------------------------------------

const (
	tileKindSpreadsheet = "spreadsheet"
	cellEmpty           = 0
	cellText            = 1
	cellNumber          = 2
	cellDate            = 3
	cellFormula         = 4
)

var validCellTypes = []int{cellEmpty, cellText, cellNumber, cellDate, cellFormula}

func cellTypeIsValid(t int) bool {
	for _, v := range validCellTypes {
		if v == t {
			return true
		}
	}
	return false
}

func emptyCell() map[string]interface{} {
	return map[string]interface{}{"value": "", "type": cellEmpty}
}

func emptyCellGrid(rows, cols int) []interface{} {
	grid := make([]interface{}, rows)
	for r := 0; r < rows; r++ {
		row := make([]interface{}, cols)
		for c := 0; c < cols; c++ {
			row[c] = emptyCell()
		}
		grid[r] = row
	}
	return grid
}

func autoCellType(value interface{}) int {
	switch v := value.(type) {
	case nil:
		return cellEmpty
	case float64, int:
		return cellNumber
	case string:
		if v == "" {
			return cellEmpty
		}
		if strings.HasPrefix(v, "=") {
			return cellFormula
		}
		return cellText
	}
	return cellText
}

// normalizeCell mirrors MCPPresentationTools._normalize_cell. Returns
// (cell, fault). On bad type it returns a structured fault.
func normalizeCell(v interface{}) (map[string]interface{}, *toolFault) {
	if v == nil {
		return emptyCell(), nil
	}
	if d, ok := v.(map[string]interface{}); ok {
		// Shallow copy.
		out := make(map[string]interface{}, len(d))
		for k, vv := range d {
			out[k] = vv
		}
		if _, has := out["value"]; !has {
			out["value"] = ""
		}
		if t, has := out["type"]; has {
			ti := 0
			switch x := t.(type) {
			case float64:
				ti = int(x)
			case int:
				ti = x
			default:
				return nil, &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("bad type %v (valid: 0..4)", t)}
			}
			if !cellTypeIsValid(ti) {
				return nil, &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("bad type %d (valid: 0..4)", ti)}
			}
			out["type"] = ti
		} else {
			out["type"] = autoCellType(out["value"])
		}
		return out, nil
	}
	return map[string]interface{}{"value": v, "type": autoCellType(v)}, nil
}

// findTileInSlide returns (tile, idx, found) for the given tile id.
func findTileInSlide(slide map[string]interface{}, tileID string) (map[string]interface{}, int, bool) {
	tiles, _ := slide["tiles"].([]interface{})
	for i, t := range tiles {
		td, ok := t.(map[string]interface{})
		if !ok {
			continue
		}
		if id, _ := td["id"].(string); id == tileID {
			return td, i, true
		}
	}
	return nil, -1, false
}

// ---------------------------------------------------------------------------
// Write tools — slide-level mutators (T6 R3, R6 tab_name paths)
// ---------------------------------------------------------------------------

func toolAddSlide(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}

	// tab_name mode: read /slides count, then patch with add op.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		// Need the current slides to determine append index + validate position.
		found, slidesVal, fault := client.GetNode(tabName, "/slides")
		if fault != nil {
			return failResult(fault)
		}
		if !found {
			return failResult(&toolFault{Code: "not_found", Msg: "/slides not present in deck state"})
		}
		slides, _ := slidesVal.([]interface{})
		insertAt := len(slides)
		if p, ok := intArg(args, "position", -1); ok {
			if p < 0 {
				p = 0
			}
			if p > len(slides) {
				p = len(slides)
			}
			insertAt = p
		}
		title, _ := args["title"].(string)
		newSlide := makeSlide(title)
		// JSON Pointer for array insert: use index for mid-deck, "-" suffix for append.
		var patchPath string
		if insertAt == len(slides) {
			patchPath = "/slides/-"
		} else {
			patchPath = fmt.Sprintf("/slides/%d", insertAt)
		}
		_, patchFault := client.Patch(tabName).Add(patchPath, newSlide).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": insertAt,
			"slide_id":    newSlide["id"],
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slides, _ := deck["slides"].([]interface{})
		insertAt := len(slides)
		if p, ok := intArg(args, "position", -1); ok {
			if p < 0 {
				p = 0
			}
			if p > len(slides) {
				p = len(slides)
			}
			insertAt = p
		}
		title, _ := args["title"].(string)
		newSlide := makeSlide(title)
		// Insert at position: append to grow, then shift right of insertAt.
		slides = append(slides, nil)
		copy(slides[insertAt+1:], slides[insertAt:])
		slides[insertAt] = newSlide
		deck["slides"] = slides
		return map[string]interface{}{
			"slide_index": insertAt,
			"slide_id":    newSlide["id"],
		}, nil
	})
}

func toolSetSlideTitle(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	if _, ok := args["title"]; !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "title is required (use \"\" to clear)"})
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	title, _ := args["title"].(string)

	// tab_name mode: one replace or remove op on the title field.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		titlePath := fmt.Sprintf("/slides/%d/title", idx)
		var patchFault *toolFault
		if title == "" {
			// Verify the slide exists before attempting remove.
			found, _, f := client.GetNode(tabName, fmt.Sprintf("/slides/%d", idx))
			if f != nil {
				return failResult(f)
			}
			if !found {
				return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", idx)})
			}
			_, patchFault = client.Patch(tabName).Remove(titlePath).Send()
		} else {
			// Use add (idempotent: sets whether key exists or not).
			_, patchFault = client.Patch(tabName).Add(titlePath, title).Send()
		}
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": idx,
			"title":       title,
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, idx)
		if fault != nil {
			return nil, fault
		}
		if title == "" {
			delete(slide, "title")
		} else {
			slide["title"] = title
		}
		return map[string]interface{}{
			"slide_index": idx,
			"title":       title,
		}, nil
	})
}

func toolSetAspect(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	aspect, _ := args["aspect"].(string)
	if aspect == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "aspect is required"})
	}
	if !aspectIsValid(aspect) {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("aspect must be one of %v", validAspects)})
	}

	// tab_name mode: single replace op on /aspect.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		_, patchFault := client.Patch(tabName).Replace("/aspect", aspect).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{"success": true, "aspect": aspect}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		deck["aspect"] = aspect
		return map[string]interface{}{"aspect": aspect}, nil
	})
}

func toolMoveSlide(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	from, okFrom := intArg(args, "from_index", -1)
	to, okTo := intArg(args, "to_index", -1)
	if !okFrom || !okTo {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "from_index and to_index are required"})
	}

	// tab_name mode: use JSON Patch move op.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		if from == to {
			return map[string]interface{}{"success": true, "from_index": from, "to_index": to, "no_op": true}
		}
		// Validate indices exist before patching.
		found, slidesVal, f := client.GetNode(tabName, "/slides")
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "not_found", Msg: "/slides not present in deck state"})
		}
		slides, _ := slidesVal.([]interface{})
		n := len(slides)
		if from < 0 || from >= n {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("from_index out of range: %d (deck has %d slides)", from, n)})
		}
		if to < 0 || to >= n {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("to_index out of range: %d (deck has %d slides)", to, n)})
		}
		fromPath := fmt.Sprintf("/slides/%d", from)
		toPath := fmt.Sprintf("/slides/%d", to)
		_, patchFault := client.Patch(tabName).Move(fromPath, toPath).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{"success": true, "from_index": from, "to_index": to}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slides, _ := deck["slides"].([]interface{})
		n := len(slides)
		if from < 0 || from >= n {
			return nil, &toolFault{Code: "out_of_range", Msg: fmt.Sprintf("from_index out of range: %d (deck has %d slides)", from, n)}
		}
		if to < 0 || to >= n {
			return nil, &toolFault{Code: "out_of_range", Msg: fmt.Sprintf("to_index out of range: %d (deck has %d slides)", to, n)}
		}
		if from == to {
			return map[string]interface{}{"from_index": from, "to_index": to, "no_op": true}, nil
		}
		s := slides[from]
		slides = append(slides[:from], slides[from+1:]...)
		slides = append(slides[:to], append([]interface{}{s}, slides[to:]...)...)
		deck["slides"] = slides
		return map[string]interface{}{"from_index": from, "to_index": to}, nil
	})
}

func toolRemoveSlide(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}

	// tab_name mode: read slides to validate, then patch remove.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		found, slidesVal, f := client.GetNode(tabName, "/slides")
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "not_found", Msg: "/slides not present in deck state"})
		}
		slides, _ := slidesVal.([]interface{})
		n := len(slides)
		if idx < 0 || idx >= n {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d (deck has %d slides)", idx, n)})
		}
		if n <= 1 {
			return failResult(&toolFault{Code: "deck_empty_forbidden", Msg: "Cannot remove the only slide (would leave deck empty)"})
		}
		removedID := ""
		if removed, ok := slides[idx].(map[string]interface{}); ok {
			removedID, _ = removed["id"].(string)
		}
		_, patchFault := client.Patch(tabName).Remove(fmt.Sprintf("/slides/%d", idx)).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":          true,
			"slide_index":      idx,
			"slide_id":         removedID,
			"remaining_slides": n - 1,
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slides, _ := deck["slides"].([]interface{})
		n := len(slides)
		if idx < 0 || idx >= n {
			return nil, &toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d (deck has %d slides)", idx, n)}
		}
		if n <= 1 {
			return nil, &toolFault{Code: "deck_empty_forbidden", Msg: "Cannot remove the only slide (would leave deck empty)"}
		}
		removed, _ := slides[idx].(map[string]interface{})
		removedID := ""
		if removed != nil {
			removedID, _ = removed["id"].(string)
		}
		slides = append(slides[:idx], slides[idx+1:]...)
		deck["slides"] = slides
		return map[string]interface{}{
			"slide_index":      idx,
			"slide_id":         removedID,
			"remaining_slides": len(slides),
		}, nil
	})
}

// ---------------------------------------------------------------------------
// Write tools — tile-level mutators (T6 R4)
// ---------------------------------------------------------------------------

func toolRemoveTile(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	tileID, _ := args["tile_id"].(string)
	tileID = strings.TrimSpace(tileID)
	if tileID == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "tile_id is required"})
	}
	sIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}

	// tab_name mode: read the slide, find tile index, patch remove tile + scrub reveal.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		slidePath := fmt.Sprintf("/slides/%d", sIdx)
		found, slideVal, f := client.GetNode(tabName, slidePath)
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", sIdx)})
		}
		slide, ok := slideVal.(map[string]interface{})
		if !ok {
			return failResult(&toolFault{Code: "schema_violation", Msg: "slide is not a JSON object"})
		}
		_, tileIdx, tileFound := findTileInSlide(slide, tileID)
		if !tileFound {
			return failResult(&toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)})
		}
		// Build patch: remove tile, then rebuild reveal without this tile id.
		pb := client.Patch(tabName).Remove(fmt.Sprintf("/slides/%d/tiles/%d", sIdx, tileIdx))
		if rev, ok := slide["reveal"].([]interface{}); ok {
			// Rebuild reveal list without the removed tile, then replace.
			newReveal := []interface{}{}
			for _, r := range rev {
				if s, _ := r.(string); s != tileID {
					newReveal = append(newReveal, s)
				}
			}
			pb = pb.Replace(fmt.Sprintf("/slides/%d/reveal", sIdx), newReveal)
		}
		if _, patchFault := pb.Send(); patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": sIdx,
			"tile_id":     tileID,
			"removed_at":  tileIdx,
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		_, idx, found := findTileInSlide(slide, tileID)
		if !found {
			return nil, &toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)}
		}
		tiles, _ := slide["tiles"].([]interface{})
		tiles = append(tiles[:idx], tiles[idx+1:]...)
		slide["tiles"] = tiles
		// Scrub reveal-order entries that referenced this tile id.
		if rev, ok := slide["reveal"].([]interface{}); ok {
			out := rev[:0]
			for _, r := range rev {
				if s, _ := r.(string); s != tileID {
					out = append(out, r)
				}
			}
			slide["reveal"] = out
		}
		return map[string]interface{}{
			"slide_index": sIdx,
			"tile_id":     tileID,
			"removed_at":  idx,
		}, nil
	})
}

func toolAddTextTile(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	sIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	if fault := validateCoords(args); fault != nil {
		return failResult(fault)
	}
	content, _ := args["content"].(string)
	textMode := textModePlain
	if v, ok := args["text_mode"].(string); ok && v != "" {
		textMode = v
	}
	if !textModeIsValid(textMode) {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("text_mode must be one of %v", validTextModes)})
	}
	// Optional fields validated up front so we fail fast before any I/O.
	var fontSize int
	if v, has := args["font_size"]; has && v != nil {
		fs, _ := intArg(args, "font_size", 0)
		if fs != 0 {
			if fs < 8 || fs > 200 {
				return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("font_size must be in [8, 200], got %d", fs)})
			}
			fontSize = fs
		}
	}
	autoFit := false
	if v, ok := args["auto_fit"].(bool); ok {
		autoFit = v
	}
	rotation := 0.0
	if v, ok := args["rotation"].(float64); ok {
		rotation = v
	}

	// Build the tile dict (shared by both paths).
	buildTile := func() map[string]interface{} {
		tile := map[string]interface{}{
			"id":        genID("tile"),
			"kind":      tileKindText,
			"x":         args["x"],
			"y":         args["y"],
			"w":         args["w"],
			"h":         args["h"],
			"text_mode": textMode,
			"content":   content,
		}
		if fontSize != 0 {
			tile["font_size"] = fontSize
		}
		if autoFit {
			tile["auto_fit"] = true
		}
		if rotation != 0.0 {
			tile["rotation"] = rotation
		}
		return tile
	}

	// tab_name mode: verify slide exists, append tile via patch.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		found, _, f := client.GetNode(tabName, fmt.Sprintf("/slides/%d", sIdx))
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", sIdx)})
		}
		tile := buildTile()
		_, patchFault := client.Patch(tabName).Add(fmt.Sprintf("/slides/%d/tiles/-", sIdx), tile).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{"success": true, "tile_id": tile["id"]}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		tile := buildTile()
		tiles, _ := slide["tiles"].([]interface{})
		tiles = append(tiles, tile)
		slide["tiles"] = tiles
		return map[string]interface{}{"tile_id": tile["id"]}, nil
	})
}

// ---------------------------------------------------------------------------
// Write tools — spreadsheet ops (T6 R5)
// ---------------------------------------------------------------------------

func toolAddSpreadsheetTile(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	sIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	if fault := validateCoords(args); fault != nil {
		return failResult(fault)
	}
	rows, _ := intArg(args, "rows", 0)
	cols, _ := intArg(args, "cols", 0)
	if rows < 1 || cols < 1 {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "rows and cols must both be >= 1"})
	}

	var cells []interface{}
	if v, has := args["cells"]; has {
		callerCells, ok := v.([]interface{})
		if !ok {
			return failResult(&toolFault{Code: "schema_validation_failed", Msg: "cells must be a 2D array"})
		}
		if len(callerCells) != rows {
			return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("cells row count %d != rows=%d", len(callerCells), rows)})
		}
		cells = make([]interface{}, rows)
		for r := 0; r < rows; r++ {
			rowIn, ok := callerCells[r].([]interface{})
			if !ok {
				return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("cells[%d] is not an Array", r)})
			}
			if len(rowIn) != cols {
				return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("cells[%d] col count %d != cols=%d", r, len(rowIn), cols)})
			}
			rowOut := make([]interface{}, cols)
			for c := 0; c < cols; c++ {
				normalized, fault := normalizeCell(rowIn[c])
				if fault != nil {
					return failResult(&toolFault{Code: fault.Code, Msg: fmt.Sprintf("cells[%d][%d]: %s", r, c, fault.Msg)})
				}
				rowOut[c] = normalized
			}
			cells[r] = rowOut
		}
	} else {
		cells = emptyCellGrid(rows, cols)
	}

	headerRow, _ := args["header_row"].(bool)
	headerCol, _ := args["header_col"].(bool)
	rotation := 0.0
	if v, ok := args["rotation"].(float64); ok {
		rotation = v
	}

	// Build tile dict (shared by both paths).
	buildTile := func() map[string]interface{} {
		tile := map[string]interface{}{
			"id":         genID("tile"),
			"kind":       tileKindSpreadsheet,
			"x":          args["x"],
			"y":          args["y"],
			"w":          args["w"],
			"h":          args["h"],
			"rows":       rows,
			"cols":       cols,
			"cells":      cells,
			"header_row": headerRow,
			"header_col": headerCol,
		}
		if rotation != 0.0 {
			tile["rotation"] = rotation
		}
		return tile
	}

	// tab_name mode: verify slide exists, append tile via patch.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		found, _, f := client.GetNode(tabName, fmt.Sprintf("/slides/%d", sIdx))
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", sIdx)})
		}
		tile := buildTile()
		_, patchFault := client.Patch(tabName).Add(fmt.Sprintf("/slides/%d/tiles/-", sIdx), tile).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": sIdx,
			"tile_id":     tile["id"],
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		tile := buildTile()
		tiles, _ := slide["tiles"].([]interface{})
		tiles = append(tiles, tile)
		slide["tiles"] = tiles
		return map[string]interface{}{
			"slide_index": sIdx,
			"tile_id":     tile["id"],
		}, nil
	})
}

func toolModifySpreadsheetCells(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	tileID, _ := args["tile_id"].(string)
	tileID = strings.TrimSpace(tileID)
	if tileID == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "tile_id is required"})
	}
	sIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	patches, ok := args["cells"].([]interface{})
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "cells must be an array"})
	}

	// applyPatchesToTile performs the cell mutation logic on a tile dict and
	// returns (updated, skipped, fault). Shared by both tab and disk paths.
	applyPatchesToTile := func(tile map[string]interface{}) (int, []interface{}, *toolFault) {
		if k, _ := tile["kind"].(string); k != tileKindSpreadsheet {
			return 0, nil, &toolFault{Code: "kind_mismatch", Msg: "modify_spreadsheet_cells only applies to spreadsheet tiles"}
		}
		rows, _ := intArg(tile, "rows", 0)
		cols, _ := intArg(tile, "cols", 0)
		cells, _ := tile["cells"].([]interface{})
		updated := 0
		skipped := []interface{}{}
		for _, pv := range patches {
			p, ok := pv.(map[string]interface{})
			if !ok {
				skipped = append(skipped, map[string]interface{}{"reason": "patch is not a Dictionary"})
				continue
			}
			r, _ := intArg(p, "row", -1)
			c, _ := intArg(p, "col", -1)
			if r < 0 || r >= rows || c < 0 || c >= cols {
				skipped = append(skipped, map[string]interface{}{"row": r, "col": c, "reason": "out of bounds"})
				continue
			}
			rowArr, _ := cells[r].([]interface{})
			cell, _ := rowArr[c].(map[string]interface{})
			if cell == nil {
				cell = emptyCell()
				rowArr[c] = cell
			}
			// Match GDScript: a bad `type` is noted in skipped[] but does NOT
			// abort the rest of the patch keys, and the cell still counts as
			// updated for the other fields that landed.
			for k, v := range p {
				if k == "row" || k == "col" {
					continue
				}
				if k == "type" {
					ti, _ := intArg(p, k, -1)
					if !cellTypeIsValid(ti) {
						skipped = append(skipped, map[string]interface{}{"row": r, "col": c, "reason": fmt.Sprintf("bad type %v", v)})
						continue
					}
					cell["type"] = ti
				} else {
					cell[k] = v
				}
			}
			updated++
		}
		return updated, skipped, nil
	}

	// tab_name mode: fetch the tile via GetNode, apply patch logic in memory,
	// then replace the cells array via Patch.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		// Fetch the full slide to locate the tile by id.
		found, slideVal, f := client.GetNode(tabName, fmt.Sprintf("/slides/%d", sIdx))
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", sIdx)})
		}
		slide, ok := slideVal.(map[string]interface{})
		if !ok {
			return failResult(&toolFault{Code: "schema_violation", Msg: "slide is not a JSON object"})
		}
		tile, tileIdx, tileFound := findTileInSlide(slide, tileID)
		if !tileFound {
			return failResult(&toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)})
		}
		updated, skipped, applyFault := applyPatchesToTile(tile)
		if applyFault != nil {
			return failResult(applyFault)
		}
		// Patch only the cells array (smallest affected subtree).
		cellsPath := fmt.Sprintf("/slides/%d/tiles/%d/cells", sIdx, tileIdx)
		_, patchFault := client.Patch(tabName).Replace(cellsPath, tile["cells"]).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":       true,
			"slide_index":   sIdx,
			"tile_id":       tileID,
			"cells_updated": updated,
			"skipped":       skipped,
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		tile, _, found := findTileInSlide(slide, tileID)
		if !found {
			return nil, &toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)}
		}
		updated, skipped, applyFault := applyPatchesToTile(tile)
		if applyFault != nil {
			return nil, applyFault
		}
		return map[string]interface{}{
			"slide_index":   sIdx,
			"tile_id":       tileID,
			"cells_updated": updated,
			"skipped":       skipped,
		}, nil
	})
}

func toolResizeSpreadsheet(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	tileID, _ := args["tile_id"].(string)
	tileID = strings.TrimSpace(tileID)
	if tileID == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "tile_id is required"})
	}
	sIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	newRows, okR := intArg(args, "rows", 0)
	newCols, okC := intArg(args, "cols", 0)
	if !okR || !okC || newRows < 1 || newCols < 1 {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "rows and cols must both be >= 1"})
	}

	// computeNewCells builds the resized cell grid from an existing tile dict.
	computeNewCells := func(tile map[string]interface{}) ([]interface{}, int, int, *toolFault) {
		if k, _ := tile["kind"].(string); k != tileKindSpreadsheet {
			return nil, 0, 0, &toolFault{Code: "kind_mismatch", Msg: "resize_spreadsheet only applies to spreadsheet tiles"}
		}
		oldRows, _ := intArg(tile, "rows", 0)
		oldCols, _ := intArg(tile, "cols", 0)
		oldCells, _ := tile["cells"].([]interface{})
		newCells := make([]interface{}, newRows)
		for r := 0; r < newRows; r++ {
			row := make([]interface{}, newCols)
			for c := 0; c < newCols; c++ {
				if r < oldRows && c < oldCols {
					oldRow, _ := oldCells[r].([]interface{})
					row[c] = oldRow[c]
				} else {
					row[c] = emptyCell()
				}
			}
			newCells[r] = row
		}
		return newCells, oldRows, oldCols, nil
	}

	// tab_name mode: fetch the tile, compute new cells, patch rows/cols/cells.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		found, slideVal, f := client.GetNode(tabName, fmt.Sprintf("/slides/%d", sIdx))
		if f != nil {
			return failResult(f)
		}
		if !found {
			return failResult(&toolFault{Code: "out_of_range", Msg: fmt.Sprintf("slide_index out of range: %d", sIdx)})
		}
		slide, ok := slideVal.(map[string]interface{})
		if !ok {
			return failResult(&toolFault{Code: "schema_violation", Msg: "slide is not a JSON object"})
		}
		tile, tileIdx, tileFound := findTileInSlide(slide, tileID)
		if !tileFound {
			return failResult(&toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)})
		}
		newCells, oldRows, oldCols, computeFault := computeNewCells(tile)
		if computeFault != nil {
			return failResult(computeFault)
		}
		tileBase := fmt.Sprintf("/slides/%d/tiles/%d", sIdx, tileIdx)
		_, patchFault := client.Patch(tabName).
			Replace(tileBase+"/rows", newRows).
			Replace(tileBase+"/cols", newCols).
			Replace(tileBase+"/cells", newCells).
			Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{
			"success":     true,
			"slide_index": sIdx,
			"tile_id":     tileID,
			"old_rows":    oldRows, "old_cols": oldCols,
			"new_rows": newRows, "new_cols": newCols,
		}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		tile, _, found := findTileInSlide(slide, tileID)
		if !found {
			return nil, &toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)}
		}
		newCells, oldRows, oldCols, computeFault := computeNewCells(tile)
		if computeFault != nil {
			return nil, computeFault
		}
		tile["rows"] = newRows
		tile["cols"] = newCols
		tile["cells"] = newCells
		return map[string]interface{}{
			"slide_index": sIdx,
			"tile_id":     tileID,
			"old_rows":    oldRows, "old_cols": oldCols,
			"new_rows": newRows, "new_cols": newCols,
		}, nil
	})
}

// ---------------------------------------------------------------------------
// Background helpers (T6 R7) — color normalization, image base64 reading
// ---------------------------------------------------------------------------

const (
	bgKindColor = "color"
	bgKindImage = "image"
)

func normalizeHex(hex string) string {
	s := strings.TrimSpace(hex)
	if s == "" {
		return "#ffffff"
	}
	if !strings.HasPrefix(s, "#") {
		s = "#" + s
	}
	return s
}

func readFileAsBase64(path string) (string, *toolFault) {
	body, err := os.ReadFile(path)
	if err != nil {
		return "", &toolFault{Code: "io_error", Msg: fmt.Sprintf("File not found or unreadable: %s (%v)", path, err)}
	}
	if len(body) == 0 {
		return "", &toolFault{Code: "io_error", Msg: fmt.Sprintf("Empty file: %s", path)}
	}
	return base64.StdEncoding.EncodeToString(body), nil
}

// sniffImageContentType inspects magic bytes to identify the image format.
// Matches the GDScript-side sniff_image_content_type() in slide_model.gd —
// any change here must be mirrored there (the broker strip walker doesn't
// care about content_type accuracy, but host.documents.get_blob consumers do).
func sniffImageContentType(b []byte) string {
	if len(b) >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 {
		return "image/png"
	}
	if len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
		return "image/jpeg"
	}
	if len(b) >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 {
		return "image/gif"
	}
	if len(b) >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
		b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 {
		return "image/webp"
	}
	return "image/png"
}

// sniffContentTypeFromBase64 decodes the head of a base64 string and sniffs
// magic bytes. Used so the bg envelope records an accurate content_type when
// the only input was raw base64 (image_base64 arg). Decodes at most ~24 bytes
// for the sniff (12 base64 chars decode to 9 bytes; we use 16 for slack).
func sniffContentTypeFromBase64(b64 string) string {
	prefix := b64
	if len(prefix) > 24 {
		prefix = prefix[:24]
	}
	raw, err := base64.StdEncoding.DecodeString(prefix)
	if err != nil {
		// Re-try with a padding-safe length (base64 needs multiples of 4).
		safe := (len(b64) / 4) * 4
		if safe == 0 {
			return "image/png"
		}
		if safe > 24 {
			safe = 24
		}
		raw, err = base64.StdEncoding.DecodeString(b64[:safe])
		if err != nil {
			return "image/png"
		}
	}
	return sniffImageContentType(raw)
}

// makeImageBgEnvelope wraps image bytes in the blob envelope shape required by
// phase-5 R3 plugin-side adoption. The broker's strip walker recognises this
// shape and swaps the bytes for a __blob_handle__ on capability responses —
// keeping list_slides bounded on image-heavy decks.
//
// Shape matches slide_model.gd's make_blob_envelope() exactly:
//
//	{"__blob__": true, "content_type": "image/png", "bytes": "<base64>"}
//
// Any divergence breaks the broker's type gate at PluginScenePanelBroker.gd:1452.
func makeImageBgEnvelope(b64, contentType string) map[string]interface{} {
	return map[string]interface{}{
		"__blob__":     true,
		"content_type": contentType,
		"bytes":        b64,
	}
}

func toolSetSlideBackground(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	sIdx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	color, _ := args["color"].(string)
	imagePath, _ := args["image_path"].(string)
	imageBase64, _ := args["image_base64"].(string)
	hasColor := color != ""
	hasPath := imagePath != ""
	hasB64 := imageBase64 != ""
	sourcesSet := 0
	if hasColor {
		sourcesSet++
	}
	if hasPath {
		sourcesSet++
	}
	if hasB64 {
		sourcesSet++
	}
	if sourcesSet != 1 {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "Provide exactly one of: color, image_path, image_base64"})
	}

	// Build the background dict. For image_path, read the file once up front
	// (fail fast before any I/O to the broker).
	var bg map[string]interface{}
	switch {
	case hasColor:
		bg = map[string]interface{}{"kind": bgKindColor, "value": normalizeHex(color)}
	case hasPath:
		b64, fault := readFileAsBase64(imagePath)
		if fault != nil {
			return failResult(fault)
		}
		// Sniff content_type from the on-disk bytes (we have them already).
		raw, _ := os.ReadFile(imagePath)
		ct := sniffImageContentType(raw)
		bg = map[string]interface{}{"kind": bgKindImage, "value": makeImageBgEnvelope(b64, ct)}
	default:
		ct := sniffContentTypeFromBase64(imageBase64)
		bg = map[string]interface{}{"kind": bgKindImage, "value": makeImageBgEnvelope(imageBase64, ct)}
	}

	// tab_name mode: single replace op on the slide's background field.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		bgPath := fmt.Sprintf("/slides/%d/background", sIdx)
		_, patchFault := client.Patch(tabName).Replace(bgPath, bg).Send()
		if patchFault != nil {
			return failResult(patchFault)
		}
		return map[string]interface{}{"success": true, "slide_index": sIdx}
	}

	// disk mode: unchanged.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		slide["background"] = bg
		return map[string]interface{}{"slide_index": sIdx}, nil
	})
}

// ---------------------------------------------------------------------------
// Deck creation (T6 R6) — pure file IO, no host roundtrip
// ---------------------------------------------------------------------------

const fileExt = ".mdeck"
const schemaVersion = 1

func makeDeck(aspect string) map[string]interface{} {
	return map[string]interface{}{
		"version": schemaVersion,
		"aspect":  aspect,
		"slides":  []interface{}{makeSlide("")},
	}
}

func toolCreateDeck(_ *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args := map[string]interface{}{}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return failResult(&toolFault{Code: "schema_validation_failed", Msg: err.Error()})
		}
	}
	path, _ := args["path"].(string)
	path = strings.TrimSpace(path)
	if path == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "path is required"})
	}
	if !strings.HasSuffix(path, fileExt) {
		path += fileExt
	}
	aspect := "16:9"
	if v, ok := args["aspect"].(string); ok && v != "" {
		aspect = v
	}
	if !aspectIsValid(aspect) {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("aspect must be one of %v", validAspects)})
	}
	deck := makeDeck(aspect)
	if title, ok := args["title"].(string); ok && title != "" {
		slides := deck["slides"].([]interface{})
		(slides[0].(map[string]interface{}))["title"] = title
	}
	if fault := saveDeckToPath(path, deck); fault != nil {
		return failResult(fault)
	}
	return map[string]interface{}{
		"success":     true,
		"path":        path,
		"slide_count": 1,
		"deck_id":     fmt.Sprintf("v%d/%s", schemaVersion, aspect),
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

// ---------------------------------------------------------------------------
// Tool: minerva_presentation_list_open_annotations
// ---------------------------------------------------------------------------

// toolListOpenAnnotations scans every slide in the deck and returns annotations
// whose lifecycle is "open" (the default for annotations the LLM hasn't yet
// addressed). Mirrors the contract previously implemented by core
// MCPPresentationTools._list_open_annotations (T6 tail migration).
//
// An annotation envelope without an explicit lifecycle is treated as "open"
// — matches the core behavior at MCPPresentationTools.gd:1115.
func toolListOpenAnnotations(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	deck, fault := loadDeck(client, args)
	if fault != nil {
		return failResult(fault)
	}
	slides, _ := deck["slides"].([]interface{})
	open := []interface{}{}
	for i, sv := range slides {
		slide, _ := sv.(map[string]interface{})
		if slide == nil {
			continue
		}
		anns, _ := slide["annotations"].([]interface{})
		for _, a := range anns {
			env, _ := a.(map[string]interface{})
			if env == nil {
				continue
			}
			lc, _ := env["lifecycle"].(string)
			if lc == "" {
				lc = "open"
			}
			if lc != "open" {
				continue
			}
			id, _ := env["id"].(string)
			kind, _ := env["kind"].(string)
			summary, _ := env["summary"].(string)
			open = append(open, map[string]interface{}{
				"slide_index":   i,
				"annotation_id": id,
				"kind":          kind,
				"summary":       summary,
			})
		}
	}
	return map[string]interface{}{
		"success": true,
		"open":    open,
		"count":   len(open),
	}
}

// ---------------------------------------------------------------------------
// Tool: minerva_presentation_add_annotation
// ---------------------------------------------------------------------------

// anchorDefault builds the substrate anchor when the caller omits one.
// Mirrors MCPPresentationTools._resolve_annotation_anchor:
//   callout  → plugin="presentation" (anchor compat "*/*")
//   2d_arrow / 2d_text → plugin="core" (anchor compat "core/*")
// All defaults set snapshot.position = [0.5, 0.5] (slide center).
func anchorDefault(kind, slideID string) map[string]interface{} {
	plugin := "core"
	if kind == "callout" {
		plugin = "presentation"
	}
	return map[string]interface{}{
		"plugin": plugin,
		"type":   "slide",
		"id":     slideID,
		"snapshot": map[string]interface{}{
			"position": []interface{}{0.5, 0.5},
		},
	}
}

// validateAnnotationEnvelope does the minimum shape checks that the substrate
// AnnotationV2Schema would otherwise fail at read-time. Returns "" on success.
// Mirrors MCPPresentationTools._validate_annotation_envelope but is intentionally
// narrower: we trust the broker-side validator the next layer up; this is the
// fail-fast convenience layer for the LLM.
func validateAnnotationEnvelope(env map[string]interface{}) string {
	if id, _ := env["id"].(string); id == "" {
		return "id must be non-empty"
	}
	kind, _ := env["kind"].(string)
	if !stringInSlice(kind, annotationKindsValid) {
		return fmt.Sprintf("kind must be one of %v", annotationKindsValid)
	}
	sv, _ := env["schema_version"].(float64)
	if int(sv) != annotationSchemaVersion {
		return fmt.Sprintf("schema_version must be %d", annotationSchemaVersion)
	}
	anchor, _ := env["anchor"].(map[string]interface{})
	if anchor == nil {
		return "anchor is required"
	}
	if plugin, _ := anchor["plugin"].(string); plugin == "" {
		return "anchor.plugin must be non-empty"
	}
	if typ, _ := anchor["type"].(string); typ == "" {
		return "anchor.type must be non-empty"
	}
	author, _ := env["author"].(map[string]interface{})
	if author == nil {
		return "author is required"
	}
	if ak, _ := author["kind"].(string); ak == "" {
		return "author.kind must be non-empty"
	}
	if vc, _ := env["view_context"].(string); vc == "" {
		return "view_context must be non-empty"
	}
	visible, _ := env["visible_in_views"].([]interface{})
	if len(visible) == 0 {
		return "visible_in_views must be a non-empty array"
	}
	if s, _ := env["summary"].(string); s == "" {
		return "summary must be non-empty"
	}
	lc, _ := env["lifecycle"].(string)
	if !stringInSlice(lc, annotationLifecyclesValid) {
		return fmt.Sprintf("lifecycle must be one of %v", annotationLifecyclesValid)
	}
	return ""
}

func toolAddAnnotation(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	kind, _ := args["kind"].(string)
	kind = strings.TrimSpace(kind)
	if !stringInSlice(kind, annotationKindsValid) {
		return failResult(&toolFault{
			Code: "schema_validation_failed",
			Msg:  fmt.Sprintf("kind must be one of %v", annotationKindsValid),
		})
	}
	summary, _ := args["summary"].(string)
	if summary == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "summary must be a non-empty string"})
	}
	lifecycle, _ := args["lifecycle"].(string)
	if lifecycle == "" {
		lifecycle = "open"
	}
	if !stringInSlice(lifecycle, annotationLifecyclesValid) {
		return failResult(&toolFault{
			Code: "schema_validation_failed",
			Msg:  fmt.Sprintf("lifecycle must be one of %v", annotationLifecyclesValid),
		})
	}

	// Build envelope shared by both tab and disk paths. slide_id is filled in
	// per-branch (tab path looks up via get_node; disk path reads from the
	// loaded deck) since both modes need to know it for anchor default and
	// view_context.
	buildEnvelope := func(slideID string) (map[string]interface{}, string) {
		annID := genID("ann")

		// Anchor: caller-provided wins verbatim; else synthesize per-kind.
		var anchor map[string]interface{}
		if raw, ok := args["anchor"].(map[string]interface{}); ok {
			anchor = raw
		} else {
			anchor = anchorDefault(kind, slideID)
		}

		// kind_payload: copy if provided; mirror summary → kind_payload.text
		// for text-bearing kinds when caller didn't supply it.
		kindPayload := map[string]interface{}{}
		if rawKP, ok := args["kind_payload"].(map[string]interface{}); ok {
			for k, v := range rawKP {
				kindPayload[k] = v
			}
		}
		if annotationKindsTextBearing[kind] {
			if _, has := kindPayload["text"]; !has {
				kindPayload["text"] = summary
			}
		}

		viewCtxID := slideID
		if viewCtxID == "" {
			viewCtxID = fmt.Sprintf("slide_%d", idx)
		}
		env := map[string]interface{}{
			"id":             annID,
			"kind":           kind,
			"schema_version": float64(annotationSchemaVersion),
			"anchor":         anchor,
			"kind_payload":   kindPayload,
			"lifecycle":      lifecycle,
			"author": map[string]interface{}{
				"kind":       "ai",
				"id":         "mcp",
				"session_id": "minerva_presentation_add_annotation",
			},
			"view_context":     fmt.Sprintf("presentation:%s", viewCtxID),
			"visible_in_views": []interface{}{"presentation"},
			"summary":          summary,
		}
		return env, annID
	}

	// tab_name mode: look up slide_id via get_node, then patch with op=add at
	// /slides/{idx}/annotations/- (end-of-array). If annotations key is absent
	// we must first create it (add with empty array) before appending, since
	// RFC 6902 op=add on /key/- requires the parent array to exist.
	if tabName, _ := args["tab_name"].(string); tabName != "" {
		// Resolve slide_id to fill anchor/view_context defaults.
		_, slideVal, fault := client.GetNode(tabName, fmt.Sprintf("/slides/%d", idx))
		if fault != nil {
			return failResult(fault)
		}
		slide, _ := slideVal.(map[string]interface{})
		if slide == nil {
			return failResult(&toolFault{
				Code: "out_of_range",
				Msg:  fmt.Sprintf("slide_index %d not found", idx),
			})
		}
		slideID, _ := slide["id"].(string)

		env, annID := buildEnvelope(slideID)
		if verr := validateAnnotationEnvelope(env); verr != "" {
			return failResult(&toolFault{
				Code: "schema_validation_failed",
				Msg:  fmt.Sprintf("envelope rejected: %s", verr),
			})
		}

		// Patch: ensure annotations array exists, then append.
		patch := client.Patch(tabName)
		if _, has := slide["annotations"]; !has {
			patch = patch.Add(fmt.Sprintf("/slides/%d/annotations", idx), []interface{}{})
		}
		patch = patch.Add(fmt.Sprintf("/slides/%d/annotations/-", idx), env)
		if _, pf := patch.Send(); pf != nil {
			return failResult(pf)
		}
		return map[string]interface{}{
			"success":       true,
			"slide_index":   idx,
			"annotation_id": annID,
		}
	}

	// disk mode: load, mutate, save.
	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slides, _ := deck["slides"].([]interface{})
		if idx < 0 || idx >= len(slides) {
			return nil, &toolFault{
				Code: "out_of_range",
				Msg:  fmt.Sprintf("slide_index %d out of range [0,%d)", idx, len(slides)),
			}
		}
		slide, _ := slides[idx].(map[string]interface{})
		if slide == nil {
			return nil, &toolFault{Code: "out_of_range", Msg: "slide is not an object"}
		}
		slideID, _ := slide["id"].(string)

		env, annID := buildEnvelope(slideID)
		if verr := validateAnnotationEnvelope(env); verr != "" {
			return nil, &toolFault{
				Code: "schema_validation_failed",
				Msg:  fmt.Sprintf("envelope rejected: %s", verr),
			}
		}

		anns, _ := slide["annotations"].([]interface{})
		slide["annotations"] = append(anns, env)
		return map[string]interface{}{
			"slide_index":   idx,
			"annotation_id": annID,
		}, nil
	})
}

// ---------------------------------------------------------------------------
// Tool: minerva_presentation_remove_annotation
// ---------------------------------------------------------------------------

// findAnnotationIndex returns the index of an annotation by id within the
// given annotations slice, or -1 if not found.
func findAnnotationIndex(anns []interface{}, annID string) int {
	for i, raw := range anns {
		env, _ := raw.(map[string]interface{})
		if env == nil {
			continue
		}
		if id, _ := env["id"].(string); id == annID {
			return i
		}
	}
	return -1
}

// scrubRevealRefs removes any reveal[] entries equal to the supplied id.
// reveal can contain tile ids OR annotation ids; this is called from
// remove_annotation to honor the "scrub annotation refs" rule from
// MCPPresentationTools.gd:1012-1019.
func scrubRevealRefs(slide map[string]interface{}, id string) {
	reveal, _ := slide["reveal"].([]interface{})
	if len(reveal) == 0 {
		return
	}
	out := reveal[:0]
	for _, r := range reveal {
		if s, _ := r.(string); s == id {
			continue
		}
		out = append(out, r)
	}
	slide["reveal"] = out
}

func toolRemoveAnnotation(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	annID, _ := args["annotation_id"].(string)
	annID = strings.TrimSpace(annID)
	if annID == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "annotation_id is required"})
	}

	if tabName, _ := args["tab_name"].(string); tabName != "" {
		// Need to read the slide to find the annotation index (op=remove takes
		// the numeric index, not the id) and to know whether the resulting
		// annotations array empties (omit-when-default → op=remove the key).
		_, slideVal, fault := client.GetNode(tabName, fmt.Sprintf("/slides/%d", idx))
		if fault != nil {
			return failResult(fault)
		}
		slide, _ := slideVal.(map[string]interface{})
		if slide == nil {
			return failResult(&toolFault{
				Code: "out_of_range",
				Msg:  fmt.Sprintf("slide_index %d not found", idx),
			})
		}
		anns, _ := slide["annotations"].([]interface{})
		if len(anns) == 0 {
			return failResult(&toolFault{Code: "not_found", Msg: "Slide has no annotations"})
		}
		annAt := findAnnotationIndex(anns, annID)
		if annAt < 0 {
			return failResult(&toolFault{
				Code: "not_found",
				Msg:  fmt.Sprintf("annotation_id not found on slide %d: %s", idx, annID),
			})
		}

		patch := client.Patch(tabName).Remove(fmt.Sprintf("/slides/%d/annotations/%d", idx, annAt))
		// If this was the last annotation, also remove the annotations key.
		if len(anns) == 1 {
			patch = patch.Remove(fmt.Sprintf("/slides/%d/annotations", idx))
		}
		// Scrub reveal refs to this id (if any).
		reveal, _ := slide["reveal"].([]interface{})
		removedFromReveal := 0
		for _, r := range reveal {
			if s, _ := r.(string); s == annID {
				removedFromReveal++
			}
		}
		if removedFromReveal > 0 {
			// Build the scrubbed reveal in-place and replace via patch op=replace.
			scrubbed := make([]interface{}, 0, len(reveal)-removedFromReveal)
			for _, r := range reveal {
				if s, _ := r.(string); s == annID {
					continue
				}
				scrubbed = append(scrubbed, r)
			}
			patch = patch.Replace(fmt.Sprintf("/slides/%d/reveal", idx), scrubbed)
		}
		if _, pf := patch.Send(); pf != nil {
			return failResult(pf)
		}
		return map[string]interface{}{
			"success":       true,
			"slide_index":   idx,
			"annotation_id": annID,
		}
	}

	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slides, _ := deck["slides"].([]interface{})
		if idx < 0 || idx >= len(slides) {
			return nil, &toolFault{
				Code: "out_of_range",
				Msg:  fmt.Sprintf("slide_index %d out of range [0,%d)", idx, len(slides)),
			}
		}
		slide, _ := slides[idx].(map[string]interface{})
		if slide == nil {
			return nil, &toolFault{Code: "out_of_range", Msg: "slide is not an object"}
		}
		anns, _ := slide["annotations"].([]interface{})
		if len(anns) == 0 {
			return nil, &toolFault{Code: "not_found", Msg: "Slide has no annotations"}
		}
		annAt := findAnnotationIndex(anns, annID)
		if annAt < 0 {
			return nil, &toolFault{
				Code: "not_found",
				Msg:  fmt.Sprintf("annotation_id not found on slide %d: %s", idx, annID),
			}
		}
		out := append(anns[:annAt:annAt], anns[annAt+1:]...)
		if len(out) == 0 {
			delete(slide, "annotations")
		} else {
			slide["annotations"] = out
		}
		scrubRevealRefs(slide, annID)
		return map[string]interface{}{
			"slide_index":   idx,
			"annotation_id": annID,
		}, nil
	})
}

// ---------------------------------------------------------------------------
// Tool: minerva_presentation_set_annotation_resolved
// ---------------------------------------------------------------------------

func toolSetAnnotationResolved(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	idx, ok := intArg(args, "slide_index", -1)
	if !ok {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "slide_index is required"})
	}
	annID, _ := args["annotation_id"].(string)
	annID = strings.TrimSpace(annID)
	if annID == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "annotation_id is required"})
	}

	// Compute target lifecycle: explicit `lifecycle` arg wins; else `resolved`
	// bool maps true→"resolved", false→"open".
	var targetLifecycle string
	if lc, hasLC := args["lifecycle"].(string); hasLC && lc != "" {
		if !stringInSlice(lc, annotationLifecyclesValid) {
			return failResult(&toolFault{
				Code: "schema_validation_failed",
				Msg:  fmt.Sprintf("lifecycle must be one of %v", annotationLifecyclesValid),
			})
		}
		targetLifecycle = lc
	} else if rb, hasRB := args["resolved"].(bool); hasRB {
		if rb {
			targetLifecycle = "resolved"
		} else {
			targetLifecycle = "open"
		}
	} else {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "Provide either resolved (bool) or lifecycle (string)"})
	}

	note, _ := args["note"].(string)

	applyToEnv := func(env map[string]interface{}) {
		env["lifecycle"] = targetLifecycle
		if note != "" {
			notes, _ := env["resolution_notes"].([]interface{})
			notes = append(notes, map[string]interface{}{
				"at":        time.Now().UTC().Format(time.RFC3339),
				"lifecycle": targetLifecycle,
				"note":      note,
			})
			env["resolution_notes"] = notes
		}
	}

	if tabName, _ := args["tab_name"].(string); tabName != "" {
		_, slideVal, fault := client.GetNode(tabName, fmt.Sprintf("/slides/%d", idx))
		if fault != nil {
			return failResult(fault)
		}
		slide, _ := slideVal.(map[string]interface{})
		if slide == nil {
			return failResult(&toolFault{
				Code: "out_of_range",
				Msg:  fmt.Sprintf("slide_index %d not found", idx),
			})
		}
		anns, _ := slide["annotations"].([]interface{})
		if len(anns) == 0 {
			return failResult(&toolFault{Code: "not_found", Msg: "Slide has no annotations"})
		}
		annAt := findAnnotationIndex(anns, annID)
		if annAt < 0 {
			return failResult(&toolFault{
				Code: "not_found",
				Msg:  fmt.Sprintf("annotation_id not found on slide %d: %s", idx, annID),
			})
		}
		// Read-modify-write the envelope: pull, mutate, replace.
		env, _ := anns[annAt].(map[string]interface{})
		envCopy := map[string]interface{}{}
		for k, v := range env {
			envCopy[k] = v
		}
		applyToEnv(envCopy)
		if _, pf := client.Patch(tabName).Replace(fmt.Sprintf("/slides/%d/annotations/%d", idx, annAt), envCopy).Send(); pf != nil {
			return failResult(pf)
		}
		return map[string]interface{}{
			"success":       true,
			"slide_index":   idx,
			"annotation_id": annID,
			"lifecycle":     targetLifecycle,
		}
	}

	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slides, _ := deck["slides"].([]interface{})
		if idx < 0 || idx >= len(slides) {
			return nil, &toolFault{
				Code: "out_of_range",
				Msg:  fmt.Sprintf("slide_index %d out of range [0,%d)", idx, len(slides)),
			}
		}
		slide, _ := slides[idx].(map[string]interface{})
		if slide == nil {
			return nil, &toolFault{Code: "out_of_range", Msg: "slide is not an object"}
		}
		anns, _ := slide["annotations"].([]interface{})
		if len(anns) == 0 {
			return nil, &toolFault{Code: "not_found", Msg: "Slide has no annotations"}
		}
		annAt := findAnnotationIndex(anns, annID)
		if annAt < 0 {
			return nil, &toolFault{
				Code: "not_found",
				Msg:  fmt.Sprintf("annotation_id not found on slide %d: %s", idx, annID),
			}
		}
		env, _ := anns[annAt].(map[string]interface{})
		applyToEnv(env)
		return map[string]interface{}{
			"slide_index":   idx,
			"annotation_id": annID,
			"lifecycle":     targetLifecycle,
		}, nil
	})
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
