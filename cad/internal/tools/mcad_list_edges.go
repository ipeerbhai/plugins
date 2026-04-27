// Package tools — mcad_list_edges tool registration and handler.
//
// List edges of the shape produced by .mcad source.
// Returns a bare array of edge descriptors (id, kind, coords, ...).
// Uses the worker's last_program cache to skip re-tessellation when the
// source matches a recently-evaluated program.
// See Go-python-bridge-design.md §8.4 for the bridge method spec.
package tools

import (
	"context"
	"encoding/json"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// ListEdges is the MCP tool spec for mcad_list_edges.
var ListEdges = ToolSpec{
	Name:        "mcad_list_edges",
	Description: "List edges of the shape produced by .mcad source. Returns an array of {id, kind, coords, ...}. Uses the worker's last_program cache to skip re-tessellation when the source matches a recently-evaluated program.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source code"}
		},
		"required": ["source"]
	}`),
}

// HandleListEdges dispatches a list_edges request to the worker via the bridge.
// The worker method name is "list_edges" (no mcad_ prefix).
// Parse/translate/occt errors are returned as data per §8.4,
// not as MCP errors. Only internal/python errors propagate as Go errors.
func HandleListEdges(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "list_edges", params)
}
