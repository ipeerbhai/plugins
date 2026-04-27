// Package tools maintains the registry of MCP tools exposed by the CAD plugin.
//
// Register tools at server startup (not in init()) so the registry is empty
// at import time. Each tool's handler is a ToolHandlerFunc that receives raw
// JSON params and returns raw JSON result or an error.
package tools

import (
	"context"
	"encoding/json"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// ToolSpec describes an MCP tool for the tools/list response.
type ToolSpec struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// ToolHandlerFunc is the signature for an MCP tool handler.
// params is the raw JSON params from the tools/call "arguments" field.
// Returns a JSON result payload or an error.
type ToolHandlerFunc func(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error)

type entry struct {
	spec    ToolSpec
	handler ToolHandlerFunc
}

// Registry holds MCP tool registrations.
type Registry struct {
	entries []entry
}

// NewRegistry creates an empty Registry.
func NewRegistry() *Registry {
	return &Registry{}
}

// Register adds a tool with its spec and handler to the registry.
func (r *Registry) Register(spec ToolSpec, handler ToolHandlerFunc) {
	r.entries = append(r.entries, entry{spec: spec, handler: handler})
}

// Specs returns the ToolSpec for every registered tool, in registration order.
// Used to build the tools/list response.
func (r *Registry) Specs() []ToolSpec {
	specs := make([]ToolSpec, len(r.entries))
	for i, e := range r.entries {
		specs[i] = e.spec
	}
	return specs
}

// Dispatch looks up and calls the handler for the named tool.
// Returns (nil, nil) if the name is not found (caller should return method-not-found).
func (r *Registry) Dispatch(ctx context.Context, w *bridge.Worker, name string, params json.RawMessage) (json.RawMessage, error, bool) {
	for _, e := range r.entries {
		if e.spec.Name == name {
			result, err := e.handler(ctx, w, params)
			return result, err, true
		}
	}
	return nil, nil, false
}
