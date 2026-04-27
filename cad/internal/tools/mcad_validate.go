// Package tools — mcad_validate tool registration and handler.
//
// Validate .mcad source: parse + translate without tessellation.
// Returns structured errors with line/col suitable for the LLM inner loop.
// See Go-python-bridge-design.md §8.3 for the bridge method spec.
package tools

import (
	"context"
	"encoding/json"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// Validate is the MCP tool spec for mcad_validate.
var Validate = ToolSpec{
	Name:        "mcad_validate",
	Description: "Validate .mcad source: parse + translate, no tessellation. Returns structured errors with line/col for the LLM inner loop.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source code"}
		},
		"required": ["source"]
	}`),
}

// HandleValidate dispatches a validate request to the worker via the bridge.
// Parse/translate errors are returned as data (ok=true, errors=[...]) per §8.3,
// not as MCP errors. Only internal/python errors propagate as Go errors.
func HandleValidate(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "validate", params)
}
