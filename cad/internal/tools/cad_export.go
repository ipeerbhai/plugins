// Package tools — cad.export tool registration and handler.
//
// Export the last 3D part produced by .mcad source to a file.
// Format is one of: "stl" (binary), "step"/"stp" (AP214), "3mf".
//
// Like cad.evaluate, the MCP tool name is the dotted "cad.export" (which is
// also the IPC channel name). The worker method is the bare verb "export"
// — see worker/mcad_worker/methods.py:_export.
package tools

import (
	"context"
	"encoding/json"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// Export is the MCP tool spec for cad.export.
var Export = ToolSpec{
	Name: "cad.export",
	Description: "Export the last 3D part produced by .mcad source to a file. " +
		"Returns {path, bytes_written, format}. " +
		"Supported formats: \"stl\" (binary STL — build123d default), " +
		"\"step\" or \"stp\" (STEP AP214 — OCCT default schema), " +
		"\"3mf\" (build123d Mesher). " +
		"Path is absolute as-is; ~-prefixed paths are expanded; bare relative " +
		"paths resolve against the user's home directory. " +
		"Errors are returned as data: kind=parse|translate (bad DSL), " +
		"kind=io (disk write failed), kind=internal (bad params).",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source code"},
			"format": {"type": "string", "enum": ["stl", "step", "stp", "3mf"], "description": "Output format. STL is binary."},
			"path": {"type": "string", "description": "Absolute, ~-prefixed, or bare relative path. Bare relative resolves against the user's home directory."}
		},
		"required": ["source", "format", "path"]
	}`),
}

// HandleExport dispatches an export request to the worker via the bridge.
// The worker method name is "export" (no cad./mcad_ prefix).
// DSL/IO errors are returned as data per design §8.2; only internal/python
// errors propagate as Go errors.
func HandleExport(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "export", params)
}
