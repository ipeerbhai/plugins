// Package tools — cad.cancel_eval tool registration.
//
// cancel_eval is a control-plane tool that cancels an in-flight cad.evaluate
// keyed by request_id. The handler logic lives in main.go (it needs access to
// the inflight request_id → context.CancelFunc map maintained at the server
// level), so this file only declares the spec. main.go intercepts cancel_eval
// in its dispatcher before delegating to the tool registry.
package tools

import "encoding/json"

// CancelEval is the MCP tool spec for cad.cancel_eval.
//
// Channel name = MCP tool name = manifest.ipc_channels entry.
// Args: {request_id: string} — the request_id passed in the original
// cad.evaluate args. Calling cancel_eval with an unknown request_id is a
// no-op (returns ok=true) so the panel can fire-and-forget when superseding.
var CancelEval = ToolSpec{
	Name:        "cad.cancel_eval",
	Description: "Cancel an in-flight cad.evaluate keyed by request_id. Unknown request_id is a no-op. Returns {ok:true, request_id}.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"request_id": {"type": "string", "description": "request_id of the in-flight cad.evaluate to cancel"}
		},
		"required": ["request_id"]
	}`),
}
