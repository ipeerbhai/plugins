// Package tools maintains the registry of MCP tools exposed by the CAD plugin.
//
// TODO(round-2+): register the five concrete CAD tools (mcad_render,
// mcad_export, mcad_validate, mcad_list_edges, mcad_deviation) as grandchild
// tasks are implemented.  Each tool will call bridge methods on the Go ↔
// Python worker bridge (design §8).
package tools

// HandlerFunc is the signature for an MCP tool handler.
// params is the raw JSON params from the MCP tools/call message.
// It returns a result JSON payload or an error.
type HandlerFunc func(params []byte) ([]byte, error)

type entry struct {
	name    string
	handler HandlerFunc
}

// Registry holds MCP tool registrations.
type Registry struct {
	entries []entry
}

// NewRegistry creates an empty Registry.
func NewRegistry() *Registry {
	return &Registry{}
}

// Register adds a named tool with its handler to the registry.
// Registering the same name twice appends a second entry (last one wins in
// dispatch — a later grandchild task will deduplicate).
func (r *Registry) Register(name string, handler HandlerFunc) {
	r.entries = append(r.entries, entry{name: name, handler: handler})
}

// List returns the names of all registered tools.
// Round 1: always returns an empty slice because no tools are registered yet.
func (r *Registry) List() []string {
	names := make([]string, 0, len(r.entries))
	for _, e := range r.entries {
		names = append(names, e.name)
	}
	return names
}
