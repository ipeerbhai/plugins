// scansort-plugin is the Scansort plugin MCP server for Minerva.
//
// T4: establishes the bidirectional host capability client
// (synchronous request/response over stdio, correlated by JSON-RPC id) and the
// single smoke-test tool — minerva_scansort_probe.
//
// T5 R1: vault creation, opening, password set/verify, project KV ops.
// Adds 6 new tools backed by the ported vault_lifecycle + crypto modules.
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
//   (a) the matching response (correlated by id), or
//   (b) stdin EOF.
//
// The synchronous read pattern below is safe under that guarantee.

mod crypto;
mod db;
mod documents;
mod fingerprints;
mod registry;
mod schema;
mod types;
mod vault_lifecycle;

use std::io::{self, BufRead, Write};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "scansort";
const SERVER_VERSION: &str = "0.0.1";

#[derive(Deserialize, Debug)]
struct RpcRequest {
    #[serde(default)]
    jsonrpc: String,
    #[serde(default)]
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Serialize)]
struct RpcResponse {
    jsonrpc: String,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<RpcError>,
}

#[derive(Serialize)]
struct RpcError {
    code: i64,
    message: String,
}

fn ok_response(id: Value, result: Value) -> RpcResponse {
    RpcResponse { jsonrpc: "2.0".into(), id, result: Some(result), error: None }
}

fn err_response(id: Value, code: i64, message: String) -> RpcResponse {
    RpcResponse { jsonrpc: "2.0".into(), id, result: None, error: Some(RpcError { code, message }) }
}

fn write_line(out: &mut impl Write, v: &impl Serialize) {
    let s = serde_json::to_string(v).unwrap_or_else(|e| {
        log::error!("serialize response: {e}");
        String::new()
    });
    if let Err(e) = writeln!(out, "{}", s) {
        log::error!("write response: {e}");
    }
    let _ = out.flush();
}

// request_capability sends a minerva/capability request to Minerva and reads
// the matching response. Safe only within a tools/call handler (re-entrancy
// contract above).
fn request_capability(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    capability: &str,
    args: Value,
) -> Result<Value, String> {
    *next_id += 1;
    let id = format!("cap-{}", next_id);

    let req = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "minerva/capability",
        "params": {
            "capability": capability,
            "args": args,
        }
    });
    write_line(out, &req);
    log::debug!("sent capability request id={id} capability={capability}");

    // Per re-entrancy contract, the next message on stdin is our response.
    // Defensively skip non-JSON and unexpected ids rather than deadlocking.
    for line_result in lines.by_ref() {
        let line = line_result.map_err(|e| format!("stdin read error: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("non-JSON line while waiting for capability response: {e}");
                continue;
            }
        };
        let msg_id = msg.get("id").cloned().unwrap_or(Value::Null);
        if msg_id.as_str() != Some(&id) {
            log::warn!("unexpected message id {:?} while waiting for {} (skipped)", msg_id, id);
            continue;
        }
        if let Some(err) = msg.get("error") {
            return Err(format!("capability error: {err}"));
        }
        return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
    }
    Err("stdin closed waiting for capability response".into())
}

// ---------------------------------------------------------------------------
// Tool content helpers
// ---------------------------------------------------------------------------

/// Wrap a JSON value as a text content MCP tool result.
fn tool_ok(payload: Value) -> Value {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| r#"{"ok":false}"#.into());
    json!({ "content": [{"type": "text", "text": text}] })
}

/// Return an MCP isError tool result with a message string.
fn tool_err(message: &str) -> Value {
    let text = serde_json::to_string(&json!({"error": message}))
        .unwrap_or_else(|_| r#"{"error":"serialisation failed"}"#.into());
    json!({ "isError": true, "content": [{"type": "text", "text": text}] })
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

fn handle_probe(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    id: Value,
) -> RpcResponse {
    let echo_result = request_capability(
        out,
        lines,
        next_id,
        "host.echo",
        json!({"message": "probe"}),
    );
    let (echo_value, ok) = match echo_result {
        Ok(v) => (v, true),
        Err(e) => {
            log::error!("host.echo failed: {e}");
            (json!({"error": e}), false)
        }
    };
    let text = serde_json::to_string(&json!({
        "version": SERVER_VERSION,
        "build": env!("CARGO_PKG_VERSION"),
        "echo_result": echo_value,
        "ok": ok,
    }))
    .unwrap_or_else(|_| r#"{"ok":false}"#.into());

    ok_response(id, json!({
        "content": [{"type": "text", "text": text}]
    }))
}

fn handle_create_vault(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    if name.is_empty() {
        return ok_response(id, tool_err("name is required"));
    }
    match vault_lifecycle::create_vault(path, name) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true, "path": path}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_set_password(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match crypto::set_password(path, password) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_verify_password(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match crypto::verify_password(path, password) {
        // Mismatch is a valid result, not an error
        Ok(ok) => ok_response(id, tool_ok(json!({"ok": ok}))),
        // I/O or structural failures are errors
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_check_vault_has_password(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match crypto::check_vault_has_password(path) {
        Ok((has_password, hint)) => ok_response(
            id,
            tool_ok(json!({"has_password": has_password, "hint": hint})),
        ),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_open_vault(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match vault_lifecycle::open_vault(path) {
        Ok(info) => match serde_json::to_value(&info) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "info": v}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_update_project_key(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let key = args.get("key").and_then(|v| v.as_str()).unwrap_or("");
    let value = args.get("value").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match vault_lifecycle::update_project_key(path, key, value) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_registry_list(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let registry_path = args.get("registry_path").and_then(|v| v.as_str());
    let rp: Option<&str> = registry_path.filter(|s| !s.is_empty());
    match registry::registry_list(rp) {
        Ok(entries) => ok_response(id, tool_ok(json!({"entries": entries}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_registry_add(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let registry_path = args.get("registry_path").and_then(|v| v.as_str());
    let rp: Option<&str> = registry_path.filter(|s| !s.is_empty());
    match registry::registry_add(vault_path, rp) {
        Ok(added) => ok_response(id, tool_ok(json!({"ok": true, "added": added}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_registry_remove(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let registry_path = args.get("registry_path").and_then(|v| v.as_str());
    let rp: Option<&str> = registry_path.filter(|s| !s.is_empty());
    match registry::registry_remove(vault_path, rp) {
        Ok(removed) => ok_response(id, tool_ok(json!({"ok": true, "removed": removed}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_check_sha256(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    let sha256 = args.get("sha256").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    if sha256.is_empty() {
        return ok_response(id, tool_err("sha256 is required"));
    }
    match fingerprints::check_sha256(vault_path, sha256) {
        Ok(Some(doc_id)) => ok_response(id, tool_ok(json!({"found": true, "doc_id": doc_id}))),
        Ok(None) => ok_response(id, tool_ok(json!({"found": false, "doc_id": null}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_check_sha256_all_vaults(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let sha256 = args.get("sha256").and_then(|v| v.as_str()).unwrap_or("");
    if sha256.is_empty() {
        return ok_response(id, tool_err("sha256 is required"));
    }
    let registry_path = args.get("registry_path").and_then(|v| v.as_str());
    let rp: Option<&str> = registry_path.filter(|s| !s.is_empty());
    match registry::check_sha256_all_vaults(sha256, rp, None) {
        Ok(Some((vault_path, _vault_name, doc_id))) => ok_response(
            id,
            tool_ok(json!({"found": true, "vault_path": vault_path, "doc_id": doc_id})),
        ),
        Ok(None) => ok_response(
            id,
            tool_ok(json!({"found": false, "vault_path": null, "doc_id": null})),
        ),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_insert_document(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    let file_path = args.get("file_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    if file_path.is_empty() {
        return ok_response(id, tool_err("file_path is required"));
    }
    let category = args.get("category").and_then(|v| v.as_str()).unwrap_or("");
    let confidence = args.get("confidence").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let sender = args.get("sender").and_then(|v| v.as_str()).unwrap_or("");
    let description = args.get("description").and_then(|v| v.as_str()).unwrap_or("");
    let doc_date = args.get("doc_date").and_then(|v| v.as_str()).unwrap_or("");
    let status = args.get("status").and_then(|v| v.as_str()).unwrap_or("");
    let sha256 = args.get("sha256").and_then(|v| v.as_str()).unwrap_or("");
    let simhash = args.get("simhash").and_then(|v| v.as_str()).unwrap_or("");
    let dhash = args.get("dhash").and_then(|v| v.as_str()).unwrap_or("");
    let source_path = args.get("source_path").and_then(|v| v.as_str()).unwrap_or("");
    match documents::insert_document(
        vault_path, file_path, category, confidence, sender,
        description, doc_date, status, sha256, simhash, dhash, source_path,
    ) {
        Ok(doc_id) => ok_response(id, tool_ok(json!({"ok": true, "doc_id": doc_id}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_query_documents(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let filter = types::DocumentFilter {
        category: args.get("category").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        sender: args.get("sender").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        status: args.get("status").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        date_from: args.get("date_from").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        date_to: args.get("date_to").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        pattern: args.get("pattern").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        tag: args.get("tag").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        doc_id: args.get("doc_id").and_then(|v| v.as_i64()),
    };
    match documents::query_documents(vault_path, &filter) {
        Ok(docs) => match serde_json::to_value(&docs) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "documents": v}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_get_document(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let doc_id = match args.get("doc_id").and_then(|v| v.as_i64()) {
        Some(d) => d,
        None => return ok_response(id, tool_err("doc_id is required")),
    };
    match documents::get_document(vault_path, doc_id) {
        Ok(doc) => match serde_json::to_value(&doc) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "document": v}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_extract_document(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let doc_id = match args.get("doc_id").and_then(|v| v.as_i64()) {
        Some(d) => d,
        None => return ok_response(id, tool_err("doc_id is required")),
    };
    let dest = args.get("dest").and_then(|v| v.as_str()).unwrap_or("");
    if dest.is_empty() {
        return ok_response(id, tool_err("dest is required"));
    }
    match documents::extract_document(vault_path, doc_id, dest) {
        Ok(out_path) => ok_response(id, tool_ok(json!({"ok": true, "path": out_path}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_update_document(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let doc_id = match args.get("doc_id").and_then(|v| v.as_i64()) {
        Some(d) => d,
        None => return ok_response(id, tool_err("doc_id is required")),
    };
    let updates_val = args.get("updates").cloned().unwrap_or(Value::Object(Default::default()));
    let updates: std::collections::HashMap<String, Value> = match updates_val {
        Value::Object(map) => map.into_iter().collect(),
        _ => return ok_response(id, tool_err("updates must be an object")),
    };
    match documents::update_document(vault_path, doc_id, &updates) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_vault_inventory(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    match documents::vault_inventory(vault_path) {
        Ok(docs) => match serde_json::to_value(&docs) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "documents": v, "count": docs.len()}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn main() {
    // Logging goes to stderr so it never pollutes the JSON-RPC stdout channel.
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();

    log::info!("{SERVER_NAME} {SERVER_VERSION} starting");

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut lines = stdin.lock().lines();
    let mut next_id: u64 = 0;

    while let Some(line_result) = lines.next() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                log::error!("stdin read: {e}");
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let req: RpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                log::warn!("malformed request: {e} — {trimmed}");
                continue;
            }
        };

        log::debug!("← {}", req.method);

        let resp = match req.method.as_str() {
            "initialize" => ok_response(req.id, json!({
                "protocolVersion": PROTOCOL_VERSION,
                "serverName": SERVER_NAME,
                "serverVersion": SERVER_VERSION,
                "capabilities": {"tools": {}},
            })),

            "tools/list" => ok_response(req.id, json!({
                "tools": [
                    {
                        "name": "minerva_scansort_probe",
                        "description": "Returns plugin version + a host.echo round-trip result; smoke-test only.",
                        "inputSchema": {"type": "object", "properties": {}, "required": []},
                    },
                    {
                        "name": "minerva_scansort_create_vault",
                        "description": "Create a new .ssort vault at the given path with the given display name.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute filesystem path for the new vault file (must end in .ssort)."},
                                "name": {"type": "string", "description": "Human-readable display name for the vault."},
                            },
                            "required": ["path", "name"],
                        },
                    },
                    {
                        "name": "minerva_scansort_set_password",
                        "description": "Set the encryption password on a vault; writes verifier to project table.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Password to set on the vault."},
                            },
                            "required": ["path", "password"],
                        },
                    },
                    {
                        "name": "minerva_scansort_verify_password",
                        "description": "Verify a password against the stored verifier. Returns {ok: bool}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Password to verify."},
                            },
                            "required": ["path", "password"],
                        },
                    },
                    {
                        "name": "minerva_scansort_check_vault_has_password",
                        "description": "Check whether a vault has a password set. Returns {has_password: bool}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_open_vault",
                        "description": "Open an existing vault and return vault_info.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_update_project_key",
                        "description": "Update a key/value pair in the project metadata table.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "key": {"type": "string", "description": "Metadata key to set."},
                                "value": {"type": "string", "description": "Value to store."},
                            },
                            "required": ["path", "key", "value"],
                        },
                    },
                    {
                        "name": "minerva_scansort_registry_list",
                        "description": "List entries in a vault registry.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "registry_path": {"type": "string", "description": "Optional path to the registry JSON file. Defaults to ~/.config/scansort/vault_registry.json or $SCANSORT_REGISTRY."},
                            },
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_registry_add",
                        "description": "Add a vault to a registry (reads the vault for its name).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file to register."},
                                "registry_path": {"type": "string", "description": "Optional path to the registry JSON file."},
                            },
                            "required": ["vault_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_registry_remove",
                        "description": "Remove a vault from a registry.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file to remove."},
                                "registry_path": {"type": "string", "description": "Optional path to the registry JSON file."},
                            },
                            "required": ["vault_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_check_sha256",
                        "description": "Check whether a sha256 exists in a single vault's fingerprints table.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "sha256": {"type": "string", "description": "SHA-256 hex string to look up."},
                            },
                            "required": ["vault_path", "sha256"],
                        },
                    },
                    {
                        "name": "minerva_scansort_check_sha256_all_vaults",
                        "description": "Check whether a sha256 exists in any registered vault.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "sha256": {"type": "string", "description": "SHA-256 hex string to look up."},
                                "registry_path": {"type": "string", "description": "Optional path to the registry JSON file."},
                            },
                            "required": ["sha256"],
                        },
                    },
                    {
                        "name": "minerva_scansort_insert_document",
                        "description": "Read a file from disk, compress with zstd, and insert it into the vault's documents table.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "file_path": {"type": "string", "description": "Absolute path to the file to ingest."},
                                "category": {"type": "string", "description": "Classification category."},
                                "confidence": {"type": "number", "description": "Classification confidence (0.0–1.0)."},
                                "sender": {"type": "string", "description": "Document sender / source."},
                                "description": {"type": "string", "description": "Human-readable description."},
                                "doc_date": {"type": "string", "description": "Document date (ISO-8601 preferred)."},
                                "status": {"type": "string", "description": "Document status (default: classified)."},
                                "sha256": {"type": "string", "description": "Pre-computed SHA-256 (computed from file if empty)."},
                                "simhash": {"type": "string", "description": "SimHash hex string."},
                                "dhash": {"type": "string", "description": "dHash hex string."},
                                "source_path": {"type": "string", "description": "Original source path (defaults to file_path)."},
                            },
                            "required": ["vault_path", "file_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_query_documents",
                        "description": "Query documents with optional filters (category, sender, status, date range, pattern, tag, doc_id).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "category": {"type": "string", "description": "Filter by category."},
                                "sender": {"type": "string", "description": "Filter by sender (substring match)."},
                                "status": {"type": "string", "description": "Filter by status."},
                                "date_from": {"type": "string", "description": "Filter by doc_date >= date_from."},
                                "date_to": {"type": "string", "description": "Filter by doc_date <= date_to."},
                                "pattern": {"type": "string", "description": "Substring match across description/filename/sender/tags."},
                                "tag": {"type": "string", "description": "Filter by tag."},
                                "doc_id": {"type": "integer", "description": "Filter by specific doc_id."},
                            },
                            "required": ["vault_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_get_document",
                        "description": "Get a single document's metadata by doc_id.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "doc_id": {"type": "integer", "description": "Document ID to retrieve."},
                            },
                            "required": ["vault_path", "doc_id"],
                        },
                    },
                    {
                        "name": "minerva_scansort_extract_document",
                        "description": "Extract a document from the vault to the filesystem, decompressing zstd.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "doc_id": {"type": "integer", "description": "Document ID to extract."},
                                "dest": {"type": "string", "description": "Destination path or directory for the extracted file."},
                            },
                            "required": ["vault_path", "doc_id", "dest"],
                        },
                    },
                    {
                        "name": "minerva_scansort_update_document",
                        "description": "Update document metadata fields (status, category, display_name, description, tags) by doc_id.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "doc_id": {"type": "integer", "description": "Document ID to update."},
                                "updates": {"type": "object", "description": "Map of field names to new values. Allowed: status, category, display_name, description, tags."},
                            },
                            "required": ["vault_path", "doc_id", "updates"],
                        },
                    },
                    {
                        "name": "minerva_scansort_vault_inventory",
                        "description": "List all documents in a vault with metadata (no file data blob).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                            },
                            "required": ["vault_path"],
                        },
                    },
                ]
            })),

            "tools/call" => {
                let name = req.params.get("name").and_then(|v| v.as_str()).unwrap_or("");
                match name {
                    "minerva_scansort_probe" => {
                        handle_probe(&mut out, &mut lines, &mut next_id, req.id)
                    }
                    "minerva_scansort_create_vault" => {
                        handle_create_vault(&req.params, req.id)
                    }
                    "minerva_scansort_set_password" => {
                        handle_set_password(&req.params, req.id)
                    }
                    "minerva_scansort_verify_password" => {
                        handle_verify_password(&req.params, req.id)
                    }
                    "minerva_scansort_check_vault_has_password" => {
                        handle_check_vault_has_password(&req.params, req.id)
                    }
                    "minerva_scansort_open_vault" => {
                        handle_open_vault(&req.params, req.id)
                    }
                    "minerva_scansort_update_project_key" => {
                        handle_update_project_key(&req.params, req.id)
                    }
                    "minerva_scansort_registry_list" => {
                        handle_registry_list(&req.params, req.id)
                    }
                    "minerva_scansort_registry_add" => {
                        handle_registry_add(&req.params, req.id)
                    }
                    "minerva_scansort_registry_remove" => {
                        handle_registry_remove(&req.params, req.id)
                    }
                    "minerva_scansort_check_sha256" => {
                        handle_check_sha256(&req.params, req.id)
                    }
                    "minerva_scansort_check_sha256_all_vaults" => {
                        handle_check_sha256_all_vaults(&req.params, req.id)
                    }
                    "minerva_scansort_insert_document" => {
                        handle_insert_document(&req.params, req.id)
                    }
                    "minerva_scansort_query_documents" => {
                        handle_query_documents(&req.params, req.id)
                    }
                    "minerva_scansort_get_document" => {
                        handle_get_document(&req.params, req.id)
                    }
                    "minerva_scansort_extract_document" => {
                        handle_extract_document(&req.params, req.id)
                    }
                    "minerva_scansort_update_document" => {
                        handle_update_document(&req.params, req.id)
                    }
                    "minerva_scansort_vault_inventory" => {
                        handle_vault_inventory(&req.params, req.id)
                    }
                    other => err_response(req.id, -32601, format!("unknown tool: {other}")),
                }
            }

            // notifications/initialized has no id — ignore silently.
            "notifications/initialized" => continue,

            other => {
                log::warn!("unknown method: {other}");
                err_response(req.id, -32601, format!("method not found: {other}"))
            }
        };

        write_line(&mut out, &resp);
    }

    log::info!("{SERVER_NAME} exiting");
}
