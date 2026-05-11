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
// Write tools — slide-level mutators (T6 R3)
// ---------------------------------------------------------------------------

func toolAddSlide(client *hostClient, rawArgs json.RawMessage) map[string]interface{} {
	args, fault := parseTargetArgs(rawArgs)
	if fault != nil {
		return failResult(fault)
	}
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
	// Optional fields validated up front so we fail fast before disk I/O.
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

	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
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

	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
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

	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		tile, _, found := findTileInSlide(slide, tileID)
		if !found {
			return nil, &toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)}
		}
		if k, _ := tile["kind"].(string); k != tileKindSpreadsheet {
			return nil, &toolFault{Code: "kind_mismatch", Msg: "modify_spreadsheet_cells only applies to spreadsheet tiles"}
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

	return mutateDeck(client, args, func(deck map[string]interface{}) (map[string]interface{}, *toolFault) {
		slide, fault := slideAt(deck, sIdx)
		if fault != nil {
			return nil, fault
		}
		tile, _, found := findTileInSlide(slide, tileID)
		if !found {
			return nil, &toolFault{Code: "tile_not_found", Msg: fmt.Sprintf("tile_id not found on slide %d: %s", sIdx, tileID)}
		}
		if k, _ := tile["kind"].(string); k != tileKindSpreadsheet {
			return nil, &toolFault{Code: "kind_mismatch", Msg: "resize_spreadsheet only applies to spreadsheet tiles"}
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

	var bg map[string]interface{}
	switch {
	case hasColor:
		bg = map[string]interface{}{"kind": bgKindColor, "value": normalizeHex(color)}
	case hasPath:
		b64, fault := readFileAsBase64(imagePath)
		if fault != nil {
			return failResult(fault)
		}
		bg = map[string]interface{}{"kind": bgKindImage, "value": b64}
	default:
		bg = map[string]interface{}{"kind": bgKindImage, "value": imageBase64}
	}

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
