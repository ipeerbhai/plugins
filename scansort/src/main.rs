#![recursion_limit = "512"]
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

mod audit;
mod checklists;
mod classifier;
mod crypto;
mod db;
mod dedup;
mod destination;
mod destinations;
mod doc_type_normalizer;
mod documents;
mod extract;
mod fingerprints;
mod placement;
mod registry;
mod render;
mod reprocess;
mod rule_engine;
mod rules;
mod rules_file;
mod schema;
mod library;
mod process;
mod session;
mod source;
mod source_state;
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
        // Transport "ok" always true on dispatch success; verification result
        // lives in the domain field "verified" so panel callers can distinguish
        // a tool-level error from a wrong-password outcome.
        Ok(verified) => ok_response(id, tool_ok(json!({"ok": true, "verified": verified}))),
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
            tool_ok(json!({"ok": true, "has_password": has_password, "hint": hint})),
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

fn handle_get_project_keys(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let keys: Vec<String> = match args.get("keys").and_then(|v| v.as_array()) {
        Some(arr) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        None => return ok_response(id, tool_err("keys is required and must be an array")),
    };
    match vault_lifecycle::get_project_keys(vault_path, &keys) {
        Ok(map) => {
            let values: serde_json::Map<String, Value> = map
                .into_iter()
                .map(|(k, v)| (k, Value::String(v)))
                .collect();
            ok_response(id, tool_ok(json!({"ok": true, "values": Value::Object(values)})))
        }
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
    // Accept "issuer" (canonical) with "sender" as backward-compat alias.
    let issuer = args.get("issuer")
        .or_else(|| args.get("sender"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let description = args.get("description").and_then(|v| v.as_str()).unwrap_or("");
    let doc_date = args.get("doc_date").and_then(|v| v.as_str()).unwrap_or("");
    let status = args.get("status").and_then(|v| v.as_str()).unwrap_or("");
    let sha256 = args.get("sha256").and_then(|v| v.as_str()).unwrap_or("");
    let simhash = args.get("simhash").and_then(|v| v.as_str()).unwrap_or("");
    let dhash = args.get("dhash").and_then(|v| v.as_str()).unwrap_or("");
    let source_path = args.get("source_path").and_then(|v| v.as_str()).unwrap_or("");
    let rule_snapshot = args.get("rule_snapshot").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    let display_name = args.get("display_name").and_then(|v| v.as_str()).unwrap_or("");
    match documents::insert_document(
        vault_path, file_path, category, confidence, issuer,
        description, doc_date, status, sha256, simhash, dhash, source_path,
        rule_snapshot, password, display_name,
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
    // Accept "issuer" (canonical) with "sender" as backward-compat alias.
    let issuer_filter = args.get("issuer")
        .or_else(|| args.get("sender"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from);
    let filter = types::DocumentFilter {
        category: args.get("category").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        issuer: issuer_filter,
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
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    match documents::extract_document(vault_path, doc_id, dest, password) {
        Ok(out_path) => ok_response(id, tool_ok(json!({"ok": true, "path": out_path}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_set_document_encrypted(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let doc_id = match args.get("doc_id").and_then(|v| v.as_i64()) {
        Some(d) => d,
        None => return ok_response(id, tool_err("doc_id is required")),
    };
    let encrypt = match args.get("encrypt").and_then(|v| v.as_bool()) {
        Some(b) => b,
        None => return ok_response(id, tool_err("encrypt (boolean) is required")),
    };
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    match documents::set_document_encrypted(vault_path, doc_id, encrypt, password) {
        Ok(()) => ok_response(
            id,
            tool_ok(json!({"ok": true, "doc_id": doc_id, "encrypted": encrypt})),
        ),
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

fn handle_extract_text(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let file_path = args.get("file_path").and_then(|v| v.as_str()).unwrap_or("");
    if file_path.is_empty() {
        return ok_response(id, tool_err("file_path is required"));
    }
    match extract::extract_file(file_path) {
        Ok(result) => match serde_json::to_value(&result) {
            Ok(v) => ok_response(id, tool_ok(v)),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_ok(json!({
            "success": false,
            "error": e.message,
        }))),
    }
}

fn handle_render_pages(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let file_path = args.get("file_path").and_then(|v| v.as_str()).unwrap_or("");
    if file_path.is_empty() {
        return ok_response(id, tool_err("file_path is required"));
    }
    let max_pages = args.get("max_pages").and_then(|v| v.as_i64()).unwrap_or(2) as i32;
    let dpi = args.get("dpi").and_then(|v| v.as_i64()).unwrap_or(96) as i32;
    match render::render_pages(file_path, max_pages, dpi) {
        Ok(result) => match serde_json::to_value(&result) {
            Ok(v) => ok_response(id, tool_ok(v)),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_ok(json!({
            "success": false,
            "error": e.message,
        }))),
    }
}

// ---------------------------------------------------------------------------
// Rules tool handlers (T6 R3)
// ---------------------------------------------------------------------------

fn handle_insert_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");

    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let instruction = args.get("instruction").and_then(|v| v.as_str()).unwrap_or("");
    let signals: Vec<String> = args.get("signals")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let subfolder = args.get("subfolder").and_then(|v| v.as_str()).unwrap_or("");
    let rename_pattern = args.get("rename_pattern").and_then(|v| v.as_str()).unwrap_or("");
    let confidence_threshold = args.get("confidence_threshold").and_then(|v| v.as_f64()).unwrap_or(0.6);
    let encrypt = args.get("encrypt").and_then(|v| v.as_bool()).unwrap_or(false);
    let enabled = args.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
    let is_default = args.get("is_default").and_then(|v| v.as_bool()).unwrap_or(false);

    if let Some(rp) = rules_path {
        let p = std::path::Path::new(rp);
        let mut file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&e.message)),
        };
        // Parse optional new v2 fields from args (all default when absent).
        let conditions: Option<types::ConditionNode> = args.get("conditions")
            .and_then(|v| serde_json::from_value(v.clone()).ok());
        let exceptions: Option<types::ConditionNode> = args.get("exceptions")
            .and_then(|v| serde_json::from_value(v.clone()).ok());
        let order = args.get("order").and_then(|v| v.as_i64()).unwrap_or(0);
        let stop_processing = args.get("stop_processing").and_then(|v| v.as_bool()).unwrap_or(false);
        let copy_to: Vec<String> = args.get("copy_to")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let subtypes: Vec<types::Subtype> = args.get("subtypes")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default();

        let rule = rules_file::FileRule {
            label: label.to_string(),
            name: name.to_string(),
            instruction: instruction.to_string(),
            signals,
            subfolder: subfolder.to_string(),
            rename_pattern: rename_pattern.to_string(),
            confidence_threshold,
            encrypt,
            enabled,
            is_default,
            conditions,
            exceptions,
            order,
            stop_processing,
            copy_to,
            subtypes,
        };
        let idx = rules_file::upsert(&mut file, rule);
        if let Err(e) = rules_file::save(p, &file) {
            return ok_response(id, tool_err(&e.message));
        }
        return ok_response(id, tool_ok(json!({"ok": true, "index": idx, "rules_path": rp})));
    }

    if path.is_empty() {
        return ok_response(id, tool_err("rules_path (or legacy `path` for read-only) is required"));
    }
    // Legacy write path: refuse with deprecation message.
    ok_response(id, tool_err(
        "rules table is read-only after migration to 1.1.0 — pass `rules_path` instead of `path`",
    ))
}

fn handle_list_rules(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");

    if let Some(rp) = rules_path {
        let p = std::path::Path::new(rp);
        let file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&e.message)),
        };
        match serde_json::to_value(&file.rules) {
            Ok(v) => return ok_response(id, tool_ok(json!({
                "ok": true,
                "rules": v,
                "count": file.rules.len(),
                "rules_path": rp,
                "exists": p.exists(),
            }))),
            Err(e) => return ok_response(id, tool_err(&e.to_string())),
        }
    }

    if path.is_empty() {
        return ok_response(id, tool_err("rules_path (or legacy `path`) is required"));
    }
    // Legacy read path — embedded table, marked deprecated.
    match rules::list_rules(path, password) {
        Ok(r) => match serde_json::to_value(&r) {
            Ok(v) => ok_response(id, tool_ok(json!({
                "ok": true,
                "rules": v,
                "count": r.len(),
                "deprecated": true,
                "deprecation_reason": "Reading from the embedded vault rules table (legacy). Pass rules_path to read the external rules file.",
            }))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_get_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    let label_opt = args.get("label").and_then(|v| v.as_str()).filter(|s| !s.is_empty());

    if let Some(rp) = rules_path {
        let label = match label_opt {
            Some(l) => l,
            None => return ok_response(id, tool_err("label is required when using rules_path (rule_id is vault-embedded only)")),
        };
        let p = std::path::Path::new(rp);
        let file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&e.message)),
        };
        match rules_file::find_by_label(&file.rules, label) {
            Some(r) => match serde_json::to_value(r) {
                Ok(v) => return ok_response(id, tool_ok(json!({"ok": true, "rule": v, "rules_path": rp}))),
                Err(e) => return ok_response(id, tool_err(&e.to_string())),
            },
            None => return ok_response(id, tool_err(&format!("Rule not found: {label}"))),
        }
    }

    if path.is_empty() {
        return ok_response(id, tool_err("rules_path (or legacy `path`) is required"));
    }
    // Legacy: accept either label or rule_id, embedded table read.
    if let Some(label) = label_opt {
        match rules::get_rule_by_label(path, password, label) {
            Ok(Some(r)) => match serde_json::to_value(&r) {
                Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v, "deprecated": true}))),
                Err(e) => ok_response(id, tool_err(&e.to_string())),
            },
            Ok(None) => ok_response(id, tool_err(&format!("Rule not found: {label}"))),
            Err(e) => ok_response(id, tool_err(&e.message)),
        }
    } else if let Some(rule_id) = args.get("rule_id").and_then(|v| v.as_i64()) {
        match rules::get_rule_by_id(path, password, rule_id) {
            Ok(Some(r)) => match serde_json::to_value(&r) {
                Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v, "deprecated": true}))),
                Err(e) => ok_response(id, tool_err(&e.to_string())),
            },
            Ok(None) => ok_response(id, tool_err(&format!("Rule not found: {rule_id}"))),
            Err(e) => ok_response(id, tool_err(&e.message)),
        }
    } else {
        ok_response(id, tool_err("label or rule_id is required"))
    }
}

fn handle_update_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    let updates_val = args.get("updates").cloned().unwrap_or(Value::Object(Default::default()));
    let updates: std::collections::HashMap<String, Value> = match updates_val {
        Value::Object(map) => map.into_iter().collect(),
        _ => return ok_response(id, tool_err("updates must be an object")),
    };
    if updates.is_empty() {
        return ok_response(id, tool_err("No valid fields to update"));
    }

    if let Some(rp) = rules_path {
        let p = std::path::Path::new(rp);
        let mut file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&e.message)),
        };
        let idx = match rules_file::index_of(&file, label) {
            Some(i) => i,
            None => return ok_response(id, tool_err(&format!("Rule not found: {label}"))),
        };
        let rule = &mut file.rules[idx];

        if let Some(v) = updates.get("name").and_then(|x| x.as_str()) { rule.name = v.to_string(); }
        if let Some(v) = updates.get("instruction").and_then(|x| x.as_str()) { rule.instruction = v.to_string(); }
        if let Some(v) = updates.get("subfolder").and_then(|x| x.as_str()) { rule.subfolder = v.to_string(); }
        if let Some(v) = updates.get("rename_pattern").and_then(|x| x.as_str()) { rule.rename_pattern = v.to_string(); }
        if let Some(v) = updates.get("confidence_threshold").and_then(|x| x.as_f64()) { rule.confidence_threshold = v; }
        if let Some(v) = updates.get("encrypt").and_then(|x| x.as_bool()) { rule.encrypt = v; }
        if let Some(v) = updates.get("enabled").and_then(|x| x.as_bool()) { rule.enabled = v; }
        if let Some(v) = updates.get("is_default").and_then(|x| x.as_bool()) { rule.is_default = v; }
        if let Some(v) = updates.get("signals").and_then(|x| x.as_array()) {
            rule.signals = v.iter().filter_map(|s| s.as_str().map(String::from)).collect();
        }
        // New v2 fields.
        if let Some(v) = updates.get("conditions") {
            rule.conditions = serde_json::from_value(v.clone()).ok();
        }
        if let Some(v) = updates.get("exceptions") {
            rule.exceptions = serde_json::from_value(v.clone()).ok();
        }
        if let Some(v) = updates.get("order").and_then(|x| x.as_i64()) { rule.order = v; }
        if let Some(v) = updates.get("stop_processing").and_then(|x| x.as_bool()) { rule.stop_processing = v; }
        if let Some(v) = updates.get("copy_to").and_then(|x| x.as_array()) {
            rule.copy_to = v.iter().filter_map(|s| s.as_str().map(String::from)).collect();
        }
        // Label renames are supported but must not collide.
        if let Some(new_label) = updates.get("label").and_then(|x| x.as_str()) {
            if !new_label.is_empty() && new_label != label {
                if rules_file::index_of(&file, new_label).is_some() {
                    return ok_response(id, tool_err(&format!("Cannot rename to '{new_label}': label already in use")));
                }
                file.rules[idx].label = new_label.to_string();
            }
        }

        if let Err(e) = rules_file::save(p, &file) {
            return ok_response(id, tool_err(&e.message));
        }
        return ok_response(id, tool_ok(json!({"ok": true, "rules_path": rp})));
    }

    if path.is_empty() {
        return ok_response(id, tool_err("rules_path (or legacy `path` for read-only) is required"));
    }
    ok_response(id, tool_err(
        "rules table is read-only after migration to 1.1.0 — pass `rules_path` instead of `path`",
    ))
}

fn handle_delete_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }

    if let Some(rp) = rules_path {
        let p = std::path::Path::new(rp);
        let mut file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&e.message)),
        };
        if let Some(idx) = rules_file::index_of(&file, label) {
            if file.rules[idx].is_default {
                return ok_response(id, tool_err(&format!("Cannot delete default rule '{label}'")));
            }
        }
        let removed = rules_file::remove(&mut file, label);
        if !removed {
            return ok_response(id, tool_err(&format!("Rule not found: {label}")));
        }
        if let Err(e) = rules_file::save(p, &file) {
            return ok_response(id, tool_err(&e.message));
        }
        return ok_response(id, tool_ok(json!({"ok": true, "rules_path": rp})));
    }

    if path.is_empty() {
        return ok_response(id, tool_err("rules_path (or legacy `path` for read-only) is required"));
    }
    ok_response(id, tool_err(
        "rules table is read-only after migration to 1.1.0 — pass `rules_path` instead of `path`",
    ))
}

fn handle_import_rules_from_json(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    let json_text = args.get("json_text").and_then(|v| v.as_str()).unwrap_or("");
    if json_text.is_empty() {
        return ok_response(id, tool_err("json_text is required"));
    }

    if let Some(rp) = rules_path {
        let p = std::path::Path::new(rp);
        // Accept three input shapes:
        //   1. A full RulesFile object {schema_version, rules: [...]}
        //   2. A bare array of rule entries
        //   3. An object with a "rules" or "categories" array key
        // For shapes 2 and 3 the top-level RulesFile metadata is preserved
        // from any existing file (or defaults), and rules are UPSERTED by label.
        let parsed: Value = match serde_json::from_str(json_text) {
            Ok(v) => v,
            Err(e) => return ok_response(id, tool_err(&format!("JSON parse error: {e}"))),
        };

        // Try to parse as a full RulesFile first.
        if let Ok(file) = serde_json::from_value::<rules_file::RulesFile>(parsed.clone()) {
            if file.schema_version > rules_file::CURRENT_SCHEMA_VERSION {
                return ok_response(id, tool_err(&format!(
                    "Imported rules file has schema_version {} (supported: {})",
                    file.schema_version, rules_file::CURRENT_SCHEMA_VERSION,
                )));
            }
            let count = file.rules.len();
            if let Err(e) = rules_file::save(p, &file) {
                return ok_response(id, tool_err(&e.message));
            }
            return ok_response(id, tool_ok(json!({"ok": true, "count": count, "mode": "replace", "rules_path": rp})));
        }

        // Otherwise treat as a list of rule entries (shape 2 or 3).
        let entries: Vec<Value> = if let Some(arr) = parsed.as_array() {
            arr.to_owned()
        } else if let Some(obj) = parsed.as_object() {
            obj.get("rules")
                .or_else(|| obj.get("categories"))
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        if entries.is_empty() {
            return ok_response(id, tool_err("Expected a RulesFile object, a bare array, or an object with a 'rules'/'categories' array"));
        }

        let mut file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&e.message)),
        };
        let mut count: i64 = 0;
        for entry in entries {
            let rule: rules_file::FileRule = match serde_json::from_value(entry.clone()) {
                Ok(r) => r,
                Err(e) => return ok_response(id, tool_err(&format!("Invalid rule entry: {e} ({entry})"))),
            };
            if rule.label.is_empty() {
                continue;
            }
            rules_file::upsert(&mut file, rule);
            count += 1;
        }
        if let Err(e) = rules_file::save(p, &file) {
            return ok_response(id, tool_err(&e.message));
        }
        return ok_response(id, tool_ok(json!({"ok": true, "count": count, "mode": "upsert", "rules_path": rp})));
    }

    if path.is_empty() {
        return ok_response(id, tool_err("rules_path (or legacy `path` for read-only) is required"));
    }
    let _ = password;
    ok_response(id, tool_err(
        "rules table is read-only after migration to 1.1.0 — pass `rules_path` instead of `path`",
    ))
}

fn handle_classify_document(
    params: &Value,
    id: Value,
    out: &mut impl std::io::Write,
    lines: &mut impl Iterator<Item = Result<String, std::io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }

    let mode = args.get("mode").and_then(|v| v.as_str()).unwrap_or("text");
    let max_chars = args.get("max_chars").and_then(|v| v.as_u64()).unwrap_or(4000) as usize;
    // Accept `model` (preferred) or `model_id` (deprecated back-compat alias).
    let model = args.get("model").and_then(|v| v.as_str())
        .or_else(|| args.get("model_id").and_then(|v| v.as_str()))
        .unwrap_or("default");
    let model_spec = args.get("model_spec").cloned();
    let vault_id = args.get("vault_id").and_then(|v| v.as_str());
    // user_rules_path is accepted for back-compat but silently ignored.
    // B5: classify_document now reads rules exclusively from the global library.
    // To populate the library from a per-vault sidecar, call
    // library_import_from_sidecar first.
    let _user_rules_path_deprecated = args.get("user_rules_path");
    let _ = password; // legacy param accepted for back-compat but no longer used here

    // 1. Load rules from the global library (B2/B7 cached path).
    //    Only enabled rules are sent to the LLM — disabled rules must not
    //    influence classification prompts (matches process.rs:177).
    let rule_file_rules: Vec<rules_file::FileRule> = match library::library_list() {
        Ok(rules) => rules.into_iter().filter(|r| r.enabled).collect(),
        Err(e) => return ok_response(id, tool_err(&format!("Failed to load library rules: {}", e.message))),
    };
    // Build a synthetic RulesFile so existing snapshot/find helpers still work.
    let rules_file_doc = rules_file::RulesFile {
        rules: rule_file_rules.clone(),
        ..rules_file::RulesFile::default()
    };
    let rule_list: Vec<types::Rule> = rule_file_rules.into_iter().map(|r| r.into_rule()).collect();

    // 2. Build messages
    let messages: Vec<Value> = match mode {
        "vision" => {
            let page_images: Vec<Value> = args.get("page_images")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            if page_images.is_empty() {
                return ok_response(id, tool_err("page_images is required and must be non-empty for vision mode"));
            }
            classifier::build_vision_messages(&page_images, &rule_list)
        }
        _ => {
            // text mode
            let document_text = args.get("document_text").and_then(|v| v.as_str()).unwrap_or("");
            if document_text.is_empty() {
                return ok_response(id, tool_err("document_text is required and must be non-empty for text mode"));
            }
            classifier::build_messages(document_text, max_chars, &rule_list)
        }
    };

    // 3. Issue host.providers.chat capability request
    let mut chat_args = json!({
        "messages": messages,
        "model": model,
    });
    // Only forward spec when it's a non-empty object — broker rejects empty {} as "unknown kind".
    if let Some(spec) = model_spec {
        let is_empty_obj = spec.as_object().map_or(false, |o| o.is_empty());
        if !spec.is_null() && !is_empty_obj {
            chat_args["model_spec"] = spec;
        }
    }
    if let Some(vid) = vault_id {
        chat_args["vault_id"] = json!(vid);
    }

    let chat_result = request_capability(out, lines, next_id, "host.providers.chat", chat_args);
    let chat_response = match chat_result {
        Ok(v) => v,
        Err(e) => {
            log::error!("host.providers.chat failed: {e}");
            return ok_response(id, tool_err(&format!("host.providers.chat error: {e}")));
        }
    };

    // 4. Extract content from OpenAI-format response
    let response_text = chat_response
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("");

    if response_text.is_empty() {
        // Broker error envelope: {success:false, error_code, error_message, detail}.
        // Detect by explicit success:false (avoid false positives from absent key).
        if chat_response.get("success").and_then(|v| v.as_bool()) == Some(false) {
            let msg = chat_response.get("error_message").and_then(|v| v.as_str()).unwrap_or("broker error");
            let detail = chat_response.get("detail").and_then(|v| v.as_str()).unwrap_or("");
            let code = chat_response.get("error_code").and_then(|v| v.as_str()).unwrap_or("");
            let suffix = if detail.is_empty() { String::new() } else { format!(": {detail}") };
            let code_prefix = if code.is_empty() { String::new() } else { format!("[{code}] ") };
            return ok_response(id, tool_err(&format!("{code_prefix}{msg}{suffix}")));
        }
        // Legacy single-key error envelope.
        if let Some(err_val) = chat_response.get("error") {
            let err_str = err_val.as_str().map(String::from).unwrap_or_else(|| err_val.to_string());
            return ok_response(id, tool_err(&format!("LLM error: {err_str}")));
        }
        return ok_response(id, tool_err("Empty response from LLM"));
    }

    // 5. Parse and build a rule_snapshot for the resolved category
    let classification = classifier::parse_response(response_text, &rule_list);
    let rule_snapshot = rules_file::find_by_label(&rules_file_doc.rules, &classification.category)
        .map(rules_file::build_snapshot)
        .unwrap_or_default();

    match serde_json::to_value(&classification) {
        Ok(v) => ok_response(
            id,
            tool_ok(json!({
                "ok": true,
                "classification": v,
                "rule_snapshot": rule_snapshot,
            })),
        ),
        Err(e) => ok_response(id, tool_err(&e.to_string())),
    }
}

// ---------------------------------------------------------------------------
// Checklist tool handlers (T7 R6)
// ---------------------------------------------------------------------------

fn handle_list_checklists(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let tax_year = args.get("tax_year").and_then(|v| v.as_i64()).map(|y| y as i32);
    let item_type = args.get("item_type").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    match checklists::list_checklist_items(path, password, tax_year, item_type) {
        Ok(items) => match serde_json::to_value(&items) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "items": v, "count": items.len()}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_insert_checklist(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let tax_year = match args.get("tax_year").and_then(|v| v.as_i64()) {
        Some(y) => y as i32,
        None => return ok_response(id, tool_err("tax_year is required")),
    };
    let item_type = args.get("item_type").and_then(|v| v.as_str()).unwrap_or("");
    if item_type.is_empty() {
        return ok_response(id, tool_err("item_type is required (auto_upload or expected_doc)"));
    }
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    if name.is_empty() {
        return ok_response(id, tool_err("name is required"));
    }
    let match_category = args.get("match_category").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let match_sender = args.get("match_sender").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let match_pattern = args.get("match_pattern").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    match checklists::add_checklist_item(path, password, tax_year, item_type, name, match_category, match_sender, match_pattern) {
        Ok(checklist_id) => ok_response(id, tool_ok(json!({"ok": true, "checklist_id": checklist_id}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_get_checklist(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let checklist_id = match args.get("checklist_id").and_then(|v| v.as_i64()) {
        Some(cid) => cid,
        None => return ok_response(id, tool_err("checklist_id is required")),
    };
    match checklists::get_checklist_item(path, password, checklist_id) {
        Ok(item) => match serde_json::to_value(&item) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "item": v}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_update_checklist(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let checklist_id = match args.get("checklist_id").and_then(|v| v.as_i64()) {
        Some(cid) => cid,
        None => return ok_response(id, tool_err("checklist_id is required")),
    };
    let updates_val = args.get("updates").cloned().unwrap_or(Value::Object(Default::default()));
    let updates: std::collections::HashMap<String, Value> = match updates_val {
        Value::Object(map) => map.into_iter().collect(),
        _ => return ok_response(id, tool_err("updates must be an object")),
    };
    match checklists::update_checklist_item(path, password, checklist_id, &updates) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_delete_checklist(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let checklist_id = match args.get("checklist_id").and_then(|v| v.as_i64()) {
        Some(cid) => cid,
        None => return ok_response(id, tool_err("checklist_id is required")),
    };
    match checklists::delete_checklist_item(path, password, checklist_id) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_toggle_checklist_enabled(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let checklist_id = match args.get("checklist_id").and_then(|v| v.as_i64()) {
        Some(cid) => cid,
        None => return ok_response(id, tool_err("checklist_id is required")),
    };
    let enabled = args.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
    match checklists::toggle_checklist_enabled(path, password, checklist_id, enabled) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_run_checklist_check(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let tax_year = match args.get("tax_year").and_then(|v| v.as_i64()) {
        Some(y) => y as i32,
        None => return ok_response(id, tool_err("tax_year is required")),
    };
    match checklists::run_checklist(path, password, tax_year) {
        Ok(result) => ok_response(id, tool_ok(result)),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// Source-directory handlers (U2)
// ---------------------------------------------------------------------------

fn handle_set_source_dir(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let recursive = args.get("recursive").and_then(|v| v.as_bool()).unwrap_or(false);
    match source::set_source_dir(path, recursive) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true, "path": path, "recursive": recursive}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_get_source_dir(params: &Value, id: Value) -> RpcResponse {
    let _args = params.get("arguments").unwrap_or(params);
    let (dir, recursive) = source::get_source_dir();
    ok_response(id, tool_ok(json!({"ok": true, "path": dir, "recursive": recursive})))
}

fn handle_list_source_files(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str());
    let vp: Option<&str> = vault_path.filter(|s| !s.is_empty());
    match source::list_source_files(vp) {
        Ok(files) => {
            let file_values: Vec<Value> = files
                .iter()
                .map(|f| {
                    json!({
                        "path": f.path,
                        "name": f.name,
                        "size": f.size,
                        "sha256": f.sha256,
                        "in_vault": f.in_vault,
                    })
                })
                .collect();
            ok_response(id, tool_ok(json!({"ok": true, "files": file_values})))
        }
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_set_destination(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    let mode = args.get("mode").and_then(|v| v.as_str()).unwrap_or("");
    let disk_root = args.get("disk_root").and_then(|v| v.as_str());
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    if mode.is_empty() {
        return ok_response(id, tool_err("mode is required"));
    }
    match destination::set_destination(vault_path, mode, disk_root) {
        Ok(()) => ok_response(
            id,
            tool_ok(json!({
                "ok": true,
                "mode": mode,
                "disk_root": disk_root.unwrap_or(""),
            })),
        ),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_get_destination(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    match destination::get_destination(vault_path) {
        Ok((mode, disk_root)) => ok_response(
            id,
            tool_ok(json!({
                "ok": true,
                "mode": mode,
                "disk_root": disk_root,
            })),
        ),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_place_on_disk(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    let file_path = args.get("file_path").and_then(|v| v.as_str()).unwrap_or("");
    let subfolder = args.get("subfolder").and_then(|v| v.as_str()).unwrap_or("");
    let doc_date = args.get("doc_date").and_then(|v| v.as_str()).unwrap_or("");
    let rename_pattern = args.get("rename_pattern").and_then(|v| v.as_str());
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    if file_path.is_empty() {
        return ok_response(id, tool_err("file_path is required"));
    }
    if subfolder.is_empty() {
        return ok_response(id, tool_err("subfolder is required"));
    }
    if doc_date.is_empty() {
        return ok_response(id, tool_err("doc_date is required"));
    }
    match destination::place_on_disk(vault_path, file_path, subfolder, doc_date, rename_pattern) {
        Ok(placed_path) => ok_response(
            id,
            tool_ok(json!({
                "ok": true,
                "placed_path": placed_path.to_string_lossy(),
            })),
        ),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_list_disk_files(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    let disk_root_arg = args.get("disk_root").and_then(|v| v.as_str()).unwrap_or("");
    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    let destination_id = args.get("destination_id").and_then(|v| v.as_str()).unwrap_or("");

    let resolved_root: Option<String> = if !disk_root_arg.trim().is_empty() {
        Some(disk_root_arg.to_string())
    } else if !registry_path.is_empty() && !destination_id.is_empty() {
        match destinations::load_or_init(std::path::Path::new(registry_path)) {
            Ok(reg) => match destinations::find_by_id(&reg, destination_id) {
                Some(dest) if dest.kind == "directory" => Some(dest.path.clone()),
                Some(dest) => {
                    return ok_response(
                        id,
                        tool_err(&format!(
                            "destination '{}' is kind '{}', not directory",
                            destination_id, dest.kind
                        )),
                    );
                }
                None => {
                    return ok_response(
                        id,
                        tool_err(&format!("Destination not found: '{}'", destination_id)),
                    );
                }
            },
            Err(e) => return ok_response(id, tool_err(&e.message)),
        }
    } else {
        None
    };

    let list_result = if let Some(root) = resolved_root {
        destination::list_disk_files_under(&root)
    } else if !vault_path.is_empty() {
        destination::list_disk_files(vault_path)
    } else {
        return ok_response(
            id,
            tool_err("vault_path, disk_root, or registry_path + destination_id is required"),
        );
    };

    match list_result {
        Ok(files) => {
            let file_values: Vec<Value> = files
                .iter()
                .map(|(path, name, rel_path, size)| {
                    json!({
                        "path": path,
                        "name": name,
                        "rel_path": rel_path,
                        "size": size,
                    })
                })
                .collect();
            ok_response(id, tool_ok(json!({"ok": true, "files": file_values})))
        }
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// W4: destination registry handlers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// W3: run_rule_engine handler
// ---------------------------------------------------------------------------

fn handle_run_rule_engine(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    // ── Rules source ────────────────────────────────────────────────────────
    // Accept a pre-loaded rules array or load from rules_path.
    let rules_path = args.get("rules_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty());

    let rule_list: Vec<types::Rule> = if let Some(rp) = rules_path {
        let p = std::path::Path::new(rp);
        let file = match rules_file::load_or_init(p) {
            Ok(f) => f,
            Err(e) => return ok_response(id, tool_err(&format!("Failed to load rules: {}", e.message))),
        };
        file.to_rules()
    } else if let Some(rules_val) = args.get("rules") {
        match serde_json::from_value::<Vec<types::Rule>>(rules_val.clone()) {
            Ok(v) => v,
            Err(e) => return ok_response(id, tool_err(&format!("Failed to parse rules: {e}"))),
        }
    } else {
        return ok_response(id, tool_err("rules_path or rules is required"));
    };

    // ── Classification (Phase-1 output) ─────────────────────────────────────
    let classification: types::Classification = match args.get("classification") {
        Some(v) => match serde_json::from_value(v.clone()) {
            Ok(c) => c,
            Err(e) => return ok_response(id, tool_err(&format!("Failed to parse classification: {e}"))),
        },
        None => return ok_response(id, tool_err("classification is required")),
    };

    // ── File facts ───────────────────────────────────────────────────────────
    let file_facts = rule_engine::FileFacts {
        filename: args.get("filename").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        extension: args.get("extension").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        size: args.get("size").and_then(|v| v.as_i64()).unwrap_or(0),
    };

    // ── Run the walk ──────────────────────────────────────────────────────────
    let outcome = rule_engine::run(&classification, &file_facts, &rule_list);

    match serde_json::to_value(&outcome) {
        Ok(v) => ok_response(id, tool_ok(json!({
            "ok": true,
            "outcome": v,
        }))),
        Err(e) => ok_response(id, tool_err(&e.to_string())),
    }
}

fn handle_destination_add(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    if registry_path.is_empty() {
        return ok_response(id, tool_err("registry_path is required"));
    }
    let kind = args.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    if kind.is_empty() {
        return ok_response(id, tool_err("kind is required"));
    }
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let label = args.get("label").and_then(|v| v.as_str());
    let locked = args.get("locked").and_then(|v| v.as_bool()).unwrap_or(false);

    let p = std::path::Path::new(registry_path);
    let mut reg = match destinations::load_or_init(p) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&e.message)),
    };
    match destinations::add(&mut reg, kind, path, label, locked) {
        Ok(dest) => {
            if let Err(e) = destinations::save(p, &reg) {
                return ok_response(id, tool_err(&e.message));
            }
            match serde_json::to_value(&dest) {
                Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "destination": v}))),
                Err(e) => ok_response(id, tool_err(&e.to_string())),
            }
        }
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_destination_list(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    if registry_path.is_empty() {
        return ok_response(id, tool_err("registry_path is required"));
    }
    let p = std::path::Path::new(registry_path);
    let reg = match destinations::load_or_init(p) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&e.message)),
    };
    let all = destinations::list(&reg);
    match serde_json::to_value(all) {
        Ok(v) => ok_response(id, tool_ok(json!({
            "ok": true,
            "destinations": v,
            "count": all.len(),
        }))),
        Err(e) => ok_response(id, tool_err(&e.to_string())),
    }
}

fn handle_destination_remove(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    if registry_path.is_empty() {
        return ok_response(id, tool_err("registry_path is required"));
    }
    let dest_id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
    if dest_id.is_empty() {
        return ok_response(id, tool_err("id is required"));
    }
    let p = std::path::Path::new(registry_path);
    let mut reg = match destinations::load_or_init(p) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&e.message)),
    };
    let removed = destinations::remove(&mut reg, dest_id);
    if let Err(e) = destinations::save(p, &reg) {
        return ok_response(id, tool_err(&e.message));
    }
    ok_response(id, tool_ok(json!({"ok": true, "removed": removed})))
}

// ---------------------------------------------------------------------------
// W8: reprocess + locked/final flag handlers
// ---------------------------------------------------------------------------

/// `minerva_scansort_reprocess_destination` — W8.
///
/// Clears a destination's state so a fresh Process All re-run re-populates it.
/// REFUSED if the destination is locked.  The caller MUST gate this behind an
/// explicit confirm dialog; the backend enforces `locked` as a second defence.
fn handle_reprocess_destination(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    if registry_path.is_empty() {
        return ok_response(id, tool_err("registry_path is required"));
    }
    let destination_id = args.get("destination_id").and_then(|v| v.as_str()).unwrap_or("");
    if destination_id.is_empty() {
        return ok_response(id, tool_err("destination_id is required"));
    }
    let p = std::path::Path::new(registry_path);
    match reprocess::reprocess_destination(p, destination_id) {
        Ok(r) => ok_response(id, tool_ok(json!({
            "ok": true,
            "destination_id": r.destination_id,
            "kind": r.kind,
            "summary": r.summary,
            "cleared_count": r.cleared_count,
        }))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

/// `minerva_scansort_set_destination_locked` — W8.
///
/// Toggle the `locked` flag on a destination.  A locked destination refuses
/// reprocess at the backend level.  This persists via the registry JSON.
fn handle_set_destination_locked(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    if registry_path.is_empty() {
        return ok_response(id, tool_err("registry_path is required"));
    }
    let destination_id = args.get("destination_id").and_then(|v| v.as_str()).unwrap_or("");
    if destination_id.is_empty() {
        return ok_response(id, tool_err("destination_id is required"));
    }
    let locked = match args.get("locked").and_then(|v| v.as_bool()) {
        Some(b) => b,
        None => return ok_response(id, tool_err("locked (boolean) is required")),
    };
    let p = std::path::Path::new(registry_path);
    match reprocess::set_destination_locked(p, destination_id, locked) {
        Ok(dest) => match serde_json::to_value(&dest) {
            Ok(v) => ok_response(id, tool_ok(json!({
                "ok": true,
                "destination": v,
            }))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// W7: near-dup detection handlers
// ---------------------------------------------------------------------------

/// `minerva_scansort_check_simhash` — query a vault for near-duplicate text
/// documents using SimHash Hamming distance.
///
/// Returns all matching `(doc_id, distance, existing_hash)` entries within
/// the given threshold.  A zero hash always returns an empty matches array.
///
/// **HARD CONSTRAINT**: the caller MUST surface non-empty results as an
/// explicit disposition prompt (keep-both / replace / skip).  Near-duplicate
/// matches MUST NEVER be auto-discarded.
fn handle_check_simhash(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let simhash = args.get("simhash").and_then(|v| v.as_str()).unwrap_or("");
    if simhash.is_empty() {
        return ok_response(id, tool_err("simhash is required"));
    }
    let threshold = args
        .get("threshold")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32)
        .unwrap_or(dedup::DEFAULT_SIMHASH_THRESHOLD);

    match dedup::check_simhash(vault_path, simhash, threshold) {
        Ok(matches) => {
            let matches_json: Vec<Value> = matches
                .iter()
                .map(|m| json!({
                    "doc_id": m.doc_id,
                    "distance": m.distance,
                    "existing_hash": m.existing_hash,
                    "hash_kind": m.hash_kind,
                }))
                .collect();
            ok_response(id, tool_ok(json!({
                "ok": true,
                "found": !matches_json.is_empty(),
                "matches": matches_json,
                "count": matches_json.len(),
                "threshold": threshold,
            })))
        }
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

/// `minerva_scansort_check_dhash` — query a vault for near-duplicate image
/// documents using perceptual dHash Hamming distance.
///
/// Same shape as `check_simhash` but operates on the `dhash` column.
/// The default threshold is 0 (disabled); set > 0 to enable image near-dup.
///
/// **HARD CONSTRAINT**: non-empty results MUST surface a disposition prompt —
/// never auto-skipped.
fn handle_check_dhash(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let vault_path = args.get("vault_path").and_then(|v| v.as_str()).unwrap_or("");
    if vault_path.is_empty() {
        return ok_response(id, tool_err("vault_path is required"));
    }
    let dhash = args.get("dhash").and_then(|v| v.as_str()).unwrap_or("");
    if dhash.is_empty() {
        return ok_response(id, tool_err("dhash is required"));
    }
    let threshold = args
        .get("threshold")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32)
        .unwrap_or(dedup::DEFAULT_DHASH_THRESHOLD);

    match dedup::check_dhash(vault_path, dhash, threshold) {
        Ok(matches) => {
            let matches_json: Vec<Value> = matches
                .iter()
                .map(|m| json!({
                    "doc_id": m.doc_id,
                    "distance": m.distance,
                    "existing_hash": m.existing_hash,
                    "hash_kind": m.hash_kind,
                }))
                .collect();
            ok_response(id, tool_ok(json!({
                "ok": true,
                "found": !matches_json.is_empty(),
                "matches": matches_json,
                "count": matches_json.len(),
                "threshold": threshold,
            })))
        }
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// W6: fan-out placement handler
// ---------------------------------------------------------------------------

/// `minerva_scansort_place_fanout` — execute copy_to fan-out for one document.
///
/// Takes a source file path, the resolved action fields from the W3 rule
/// engine, a registry_path, and doc metadata.  Fans the document out to every
/// destination in `copy_to`.  Returns a per-destination result list.
///
/// The `(path,mtime,size)` directory hash cache is NOT shared across tool
/// calls (the tool is stateless); W10 Process All should drive this in-process
/// using `placement::fan_out` directly with a long-lived `DirHashCache`.
fn handle_place_fanout(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let file_path = args.get("file_path").and_then(|v| v.as_str()).unwrap_or("");
    if file_path.is_empty() {
        return ok_response(id, tool_err("file_path is required"));
    }

    let registry_path = args.get("registry_path").and_then(|v| v.as_str()).unwrap_or("");
    if registry_path.is_empty() {
        return ok_response(id, tool_err("registry_path is required"));
    }

    let copy_to_val = args.get("copy_to").and_then(|v| v.as_array());
    let copy_to: Vec<String> = match copy_to_val {
        Some(arr) => arr
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect(),
        None => vec![],
    };

    let resolved_subfolder =
        args.get("resolved_subfolder").and_then(|v| v.as_str()).unwrap_or("");
    let resolved_rename_pattern =
        args.get("resolved_rename_pattern").and_then(|v| v.as_str()).unwrap_or("");
    let encrypt = args.get("encrypt").and_then(|v| v.as_bool()).unwrap_or(false);

    // Load destination registry.
    let reg_path = std::path::Path::new(registry_path);
    let registry = match destinations::load_or_init(reg_path) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&e.message)),
    };

    // Build DocMeta from params.
    let meta = placement::DocMeta {
        category: args
            .get("category")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        confidence: args.get("confidence").and_then(|v| v.as_f64()).unwrap_or(0.0),
        issuer: args
            .get("issuer")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        description: args
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        doc_date: args
            .get("doc_date")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        status: args
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("classified")
            .to_string(),
        simhash: args
            .get("simhash")
            .and_then(|v| v.as_str())
            .unwrap_or("0000000000000000")
            .to_string(),
        dhash: args
            .get("dhash")
            .and_then(|v| v.as_str())
            .unwrap_or("0000000000000000")
            .to_string(),
        source_path: args
            .get("source_path")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        rule_snapshot: args
            .get("rule_snapshot")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        sha256: args
            .get("sha256")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        doc_type: args
            .get("doc_type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        amount: args
            .get("amount")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    };

    let results = placement::fan_out(
        file_path,
        &copy_to,
        resolved_subfolder,
        resolved_rename_pattern,
        encrypt,
        &registry,
        &meta,
        None,
    );

    // Serialise to JSON-friendly form.
    let results_json: Vec<Value> = results
        .iter()
        .map(|r| {
            json!({
                "destination_id": r.destination_id,
                "kind": r.kind,
                "target_path": r.target_path,
                "doc_id": r.doc_id,
                "status": serde_json::to_value(&r.status).unwrap_or(json!("error")),
                "message": r.message,
            })
        })
        .collect();

    ok_response(
        id,
        tool_ok(json!({
            "ok": true,
            "file_path": file_path,
            "placements": results_json,
            "count": results_json.len(),
        })),
    )
}

/// `minerva_scansort_scan_directory_hashes` — scan a directory for content
/// sha256 hashes.
///
/// Walks `dir_path` recursively and returns the set of sha256 hex strings for
/// every regular file found.  Stateless (no cache shared across tool calls).
/// W10 Process All should use the in-process `DirHashCache` struct directly
/// for performance within a single run.
fn handle_scan_directory_hashes(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let dir_path = args.get("dir_path").and_then(|v| v.as_str()).unwrap_or("");
    if dir_path.is_empty() {
        return ok_response(id, tool_err("dir_path is required"));
    }

    let p = std::path::Path::new(dir_path);
    match placement::scan_directory_hashes(p) {
        Ok(set) => {
            let hashes: Vec<&str> = set.iter().map(|s| s.as_str()).collect();
            ok_response(
                id,
                tool_ok(json!({
                    "ok": true,
                    "dir_path": dir_path,
                    "sha256_hashes": hashes,
                    "count": hashes.len(),
                })),
            )
        }
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// W9: audit log append handler
// ---------------------------------------------------------------------------

/// `minerva_scansort_audit_append` — W9.
///
/// Append one or more rows to the append-only CSV audit log at `log_path`.
///
/// ## Toggle split
///
/// This tool does NOT check whether the audit-log toggle is enabled — that
/// check lives in the GDScript panel (Settings → `audit_log_enabled`).
/// Call this tool only when the toggle is ON; it will write unconditionally.
///
/// ## Non-fatal contract
///
/// If `log_path` is unwritable the tool returns `{ok: false, error: "..."}`.
/// It does NOT panic. W10 MUST treat audit failures as non-fatal.
///
/// ## Parameters
///
/// - `log_path`  — absolute path to the CSV log file (outside any vault).
/// - `rows`      — array of row objects; each has the 10 CSV column fields.
///   Each row object: `{timestamp, event, source_sha256, source_filename,
///   rule_label, destination_id, destination_kind, resolved_path,
///   disposition, detail}`.
fn handle_audit_append(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let log_path_str = args.get("log_path").and_then(|v| v.as_str()).unwrap_or("");
    if log_path_str.is_empty() {
        return ok_response(id, tool_err("log_path is required"));
    }

    let rows_val = match args.get("rows").and_then(|v| v.as_array()) {
        Some(arr) => arr.clone(),
        None => return ok_response(id, tool_err("rows is required and must be an array")),
    };

    let mut audit_rows: Vec<audit::AuditRow> = Vec::with_capacity(rows_val.len());
    for (i, rv) in rows_val.iter().enumerate() {
        let get = |key: &str| rv.get(key).and_then(|v| v.as_str()).unwrap_or("");
        audit_rows.push(audit::AuditRow {
            timestamp:        get("timestamp").to_string(),
            event:            get("event").to_string(),
            source_sha256:    get("source_sha256").to_string(),
            source_filename:  get("source_filename").to_string(),
            rule_label:       get("rule_label").to_string(),
            destination_id:   get("destination_id").to_string(),
            destination_kind: get("destination_kind").to_string(),
            resolved_path:    get("resolved_path").to_string(),
            disposition:      get("disposition").to_string(),
            detail:           get("detail").to_string(),
        });
        // Validate required fields per row.
        if audit_rows.last().map_or(true, |r| r.event.is_empty()) {
            return ok_response(id, tool_err(&format!("rows[{}].event is required", i)));
        }
    }

    let log_path = std::path::Path::new(log_path_str);
    match audit::append_rows(log_path, &audit_rows) {
        Ok(()) => ok_response(id, tool_ok(json!({
            "ok": true,
            "log_path": log_path_str,
            "rows_written": audit_rows.len(),
        }))),
        Err(e) => ok_response(id, tool_ok(json!({
            "ok": false,
            "error": e.message,
        }))),
    }
}

// ---------------------------------------------------------------------------
// B1: Session handlers
// ---------------------------------------------------------------------------

fn handle_session_open_vault(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match session::add_vault(label, std::path::PathBuf::from(path)) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true, "label": label}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_session_close_vault(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match session::remove_vault(label) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_session_open_directory(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match session::add_dir(label, std::path::PathBuf::from(path)) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true, "label": label}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_session_close_directory(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match session::remove_dir(label) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_session_open_source(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match session::add_source(label, std::path::PathBuf::from(path)) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true, "label": label}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_session_close_source(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match session::remove_source(label) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_session_state(_params: &Value, id: Value) -> RpcResponse {
    let st = session::state();
    let vaults: Vec<Value> = st.vaults.iter().map(|l| json!({"label": l})).collect();
    let dirs: Vec<Value> = st.dirs.iter().map(|l| json!({"label": l})).collect();
    let sources: Vec<Value> = st.sources.iter().map(|l| json!({"label": l})).collect();
    ok_response(id, tool_ok(json!({
        "ok": true,
        "vaults":  vaults,
        "dirs":    dirs,
        "sources": sources,
    })))
}

// ---------------------------------------------------------------------------
// B2: Library handlers — path-free global rules library
// ---------------------------------------------------------------------------

fn handle_library_insert_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let instruction = args.get("instruction").and_then(|v| v.as_str()).unwrap_or("");
    let signals: Vec<String> = args.get("signals")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let subfolder = args.get("subfolder").and_then(|v| v.as_str()).unwrap_or("");
    let rename_pattern = args.get("rename_pattern").and_then(|v| v.as_str()).unwrap_or("");
    let confidence_threshold = args.get("confidence_threshold").and_then(|v| v.as_f64()).unwrap_or(0.6);
    let encrypt = args.get("encrypt").and_then(|v| v.as_bool()).unwrap_or(false);
    let enabled = args.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
    let is_default = args.get("is_default").and_then(|v| v.as_bool()).unwrap_or(false);
    let conditions: Option<types::ConditionNode> = args.get("conditions")
        .and_then(|v| serde_json::from_value(v.clone()).ok());
    let exceptions: Option<types::ConditionNode> = args.get("exceptions")
        .and_then(|v| serde_json::from_value(v.clone()).ok());
    let order = args.get("order").and_then(|v| v.as_i64()).unwrap_or(0);
    let stop_processing = args.get("stop_processing").and_then(|v| v.as_bool()).unwrap_or(false);
    let copy_to: Vec<String> = args.get("copy_to")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let subtypes: Vec<types::Subtype> = args.get("subtypes")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_default();

    let rule = rules_file::FileRule {
        label: label.to_string(),
        name: name.to_string(),
        instruction: instruction.to_string(),
        signals,
        subfolder: subfolder.to_string(),
        rename_pattern: rename_pattern.to_string(),
        confidence_threshold,
        encrypt,
        enabled,
        is_default,
        conditions,
        exceptions,
        order,
        stop_processing,
        copy_to,
        subtypes,
    };
    match library::library_insert(rule) {
        Ok(r) => match serde_json::to_value(&r) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_library_list_rules(_params: &Value, id: Value) -> RpcResponse {
    match library::library_list() {
        Ok(rules) => match serde_json::to_value(&rules) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rules": v, "count": rules.len()}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_library_get_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match library::library_get(label) {
        Ok(Some(r)) => match serde_json::to_value(&r) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Ok(None) => ok_response(id, tool_ok(json!({"ok": false, "error": format!("Rule not found: {label}")}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_library_update_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }

    // Load current rule, apply partial field updates, save back.
    let mut file = match library::library_load() {
        Ok(f) => f,
        Err(e) => return ok_response(id, tool_err(&e.message)),
    };
    let idx = match rules_file::index_of(&file, label) {
        Some(i) => i,
        None => return ok_response(id, tool_ok(json!({"ok": false, "error": format!("Rule not found: {label}")}))),
    };
    let rule = &mut file.rules[idx];

    if let Some(v) = args.get("name").and_then(|x| x.as_str()) { rule.name = v.to_string(); }
    if let Some(v) = args.get("instruction").and_then(|x| x.as_str()) { rule.instruction = v.to_string(); }
    if let Some(v) = args.get("subfolder").and_then(|x| x.as_str()) { rule.subfolder = v.to_string(); }
    if let Some(v) = args.get("rename_pattern").and_then(|x| x.as_str()) { rule.rename_pattern = v.to_string(); }
    if let Some(v) = args.get("confidence_threshold").and_then(|x| x.as_f64()) { rule.confidence_threshold = v; }
    if let Some(v) = args.get("encrypt").and_then(|x| x.as_bool()) { rule.encrypt = v; }
    if let Some(v) = args.get("enabled").and_then(|x| x.as_bool()) { rule.enabled = v; }
    if let Some(v) = args.get("is_default").and_then(|x| x.as_bool()) { rule.is_default = v; }
    if let Some(v) = args.get("signals").and_then(|x| x.as_array()) {
        rule.signals = v.iter().filter_map(|s| s.as_str().map(String::from)).collect();
    }
    if let Some(v) = args.get("conditions") {
        rule.conditions = serde_json::from_value(v.clone()).ok();
    }
    if let Some(v) = args.get("exceptions") {
        rule.exceptions = serde_json::from_value(v.clone()).ok();
    }
    if let Some(v) = args.get("order").and_then(|x| x.as_i64()) { rule.order = v; }
    if let Some(v) = args.get("stop_processing").and_then(|x| x.as_bool()) { rule.stop_processing = v; }
    if let Some(v) = args.get("copy_to").and_then(|x| x.as_array()) {
        rule.copy_to = v.iter().filter_map(|s| s.as_str().map(String::from)).collect();
    }

    let updated_rule = file.rules[idx].clone();
    if let Err(e) = library::library_save(&file) {
        return ok_response(id, tool_err(&e.message));
    }
    match serde_json::to_value(&updated_rule) {
        Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v}))),
        Err(e) => ok_response(id, tool_err(&e.to_string())),
    }
}

fn handle_library_delete_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match library::library_delete(label) {
        Ok(deleted) => ok_response(id, tool_ok(json!({"ok": true, "deleted": deleted}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_library_enable_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match library::library_set_enabled(label, true) {
        Ok(true) => ok_response(id, tool_ok(json!({"ok": true, "enabled": true}))),
        Ok(false) => ok_response(id, tool_ok(json!({"ok": false, "error": format!("Rule not found: {label}")}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_library_disable_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match library::library_set_enabled(label, false) {
        Ok(true) => ok_response(id, tool_ok(json!({"ok": true, "enabled": false}))),
        Ok(false) => ok_response(id, tool_ok(json!({"ok": false, "error": format!("Rule not found: {label}")}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// B5: Sidecar export / import handlers
// ---------------------------------------------------------------------------

fn handle_library_export_to_sidecar(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_label = args.get("vault_label").and_then(|v| v.as_str()).unwrap_or("");
    if vault_label.is_empty() {
        return ok_response(id, tool_err("vault_label is required"));
    }
    // Resolve vault label → path (must be a Vault kind, not a Directory).
    let (_, vault_path, kind) = match session::resolve_label(vault_label) {
        Some(t) => t,
        None => return ok_response(id, tool_err("vault label not in session")),
    };
    if kind != session::EntryKind::Vault {
        return ok_response(id, tool_err("vault label not in session"));
    }
    match library::library_export_to_sidecar(&vault_path) {
        Ok((sidecar_path, count)) => ok_response(id, tool_ok(json!({
            "ok": true,
            "sidecar_path": sidecar_path.to_string_lossy(),
            "count": count,
        }))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_library_import_from_sidecar(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let vault_label = args.get("vault_label").and_then(|v| v.as_str()).unwrap_or("");
    if vault_label.is_empty() {
        return ok_response(id, tool_err("vault_label is required"));
    }
    let (_, vault_path, kind) = match session::resolve_label(vault_label) {
        Some(t) => t,
        None => return ok_response(id, tool_err("vault label not in session")),
    };
    if kind != session::EntryKind::Vault {
        return ok_response(id, tool_err("vault label not in session"));
    }
    match library::library_import_from_sidecar(&vault_path) {
        Ok((sidecar_path, imported, conflicts, total_after)) => ok_response(id, tool_ok(json!({
            "ok": true,
            "sidecar_path": sidecar_path.to_string_lossy(),
            "imported": imported,
            "conflicts": conflicts,
            "total_after": total_after,
        }))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

// ---------------------------------------------------------------------------
// B3: process() pipeline handler
// ---------------------------------------------------------------------------

fn handle_process(
    id: Value,
    params: &Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    // Resolves bug 019e2d82ca72: caller can pin classifier model via `model`
    // (string) or `model_spec` (structured). `model_spec` wins when present.
    // Empty/absent → "default" for back-compat.
    let args = params.get("arguments").unwrap_or(params);
    let model = args.get("model").and_then(|v| v.as_str())
        .unwrap_or("default");
    let model_spec = args.get("model_spec").cloned();
    let doc_type_strategy = args.get("doc_type_strategy").and_then(|v| v.as_str())
        .unwrap_or("none");
    match process::run(out, lines, next_id, model, model_spec, doc_type_strategy) {
        Err(e) => ok_response(id, tool_err(&e.message)),
        Ok(result) => {
            let items_json: Vec<Value> = result.items.iter().map(|item| {
                let mut obj = json!({
                    "source_label": item.source_label,
                    "source_path_relative": item.source_path_relative,
                    "status": item.status,
                    "target_labels": item.target_labels,
                });
                if let Some(ref rl) = item.rule_label {
                    obj["rule_label"] = json!(rl);
                }
                if let Some(ref r) = item.reason {
                    obj["reason"] = json!(r);
                }
                obj
            }).collect();

            ok_response(id, tool_ok(json!({
                "ok": true,
                "summary": {
                    "moved": result.moved,
                    "conflicts": result.conflicts,
                    "unprocessable": result.unprocessable,
                    "skipped_already_processed": result.skipped_already_processed,
                },
                "by_rule": result.by_rule,
                "by_destination": result.by_destination,
                "items": items_json,
            })))
        }
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
                        "name": "minerva_scansort_get_project_keys",
                        "description": "Read multiple project metadata keys from a vault in one call. Missing keys map to an empty string. Returns {ok, values: {<key>: <value>, ...}}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "keys": {"type": "array", "items": {"type": "string"}, "description": "List of project key names to read."},
                            },
                            "required": ["vault_path", "keys"],
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
                        "description": "Read a file from disk, compress with zstd, optionally encrypt with AES-256-GCM, and insert it into the vault's documents table.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "file_path": {"type": "string", "description": "Absolute path to the file to ingest."},
                                "category": {"type": "string", "description": "Classification category."},
                                "confidence": {"type": "number", "description": "Classification confidence (0.0–1.0)."},
                                "issuer": {"type": "string", "description": "Document issuer / source (\"sender\" accepted as backward-compat alias)."},
                                "description": {"type": "string", "description": "Human-readable description."},
                                "doc_date": {"type": "string", "description": "Document date (ISO-8601 preferred)."},
                                "status": {"type": "string", "description": "Document status (default: classified)."},
                                "sha256": {"type": "string", "description": "Pre-computed SHA-256 (computed from file if empty)."},
                                "simhash": {"type": "string", "description": "SimHash hex string."},
                                "dhash": {"type": "string", "description": "dHash hex string."},
                                "source_path": {"type": "string", "description": "Original source path (defaults to file_path)."},
                                "rule_snapshot": {"type": "string", "description": "JSON blob from classify_document.rule_snapshot — captures the rule revision that produced this classification. Optional; empty means \"no rule recorded\"."},
                                "password": {"type": "string", "description": "Optional vault password. If set, the compressed blob is encrypted with AES-256-GCM using the vault's stored KDF + salt. The vault must already have a password set."},
                                "display_name": {"type": "string", "description": "Optional resolved display name for the vault (e.g., from a rule's rename_pattern). Empty means vault_inventory falls back to original_filename."},
                            },
                            "required": ["vault_path", "file_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_query_documents",
                        "description": "Query documents with optional filters (category, issuer, status, date range, pattern, tag, doc_id).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "category": {"type": "string", "description": "Filter by category."},
                                "issuer": {"type": "string", "description": "Filter by issuer (substring match). \"sender\" accepted as backward-compat alias."},
                                "status": {"type": "string", "description": "Filter by status."},
                                "date_from": {"type": "string", "description": "Filter by doc_date >= date_from."},
                                "date_to": {"type": "string", "description": "Filter by doc_date <= date_to."},
                                "pattern": {"type": "string", "description": "Substring match across description/filename/issuer/tags."},
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
                        "description": "Extract a document from the vault to the filesystem: decrypt if encrypted (requires password), then decompress zstd.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "doc_id": {"type": "integer", "description": "Document ID to extract."},
                                "dest": {"type": "string", "description": "Destination path or directory for the extracted file."},
                                "password": {"type": "string", "description": "Vault password. Required if the document is encrypted; ignored for plaintext documents."},
                            },
                            "required": ["vault_path", "doc_id", "dest"],
                        },
                    },
                    {
                        "name": "minerva_scansort_set_document_encrypted",
                        "description": "Toggle a document's at-rest encryption in place. encrypt=true encrypts a plaintext document; encrypt=false decrypts an encrypted one. A state change requires the vault password; already-in-state is a no-op.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "doc_id": {"type": "integer", "description": "Document ID to encrypt or decrypt."},
                                "encrypt": {"type": "boolean", "description": "true = encrypt the document at rest; false = decrypt it."},
                                "password": {"type": "string", "description": "Vault password. Required to change encryption state; ignored when the document is already in the requested state."},
                            },
                            "required": ["vault_path", "doc_id", "encrypt"],
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
                    {
                        "name": "minerva_scansort_extract_text",
                        "description": "Extract text and compute fingerprints (sha256, simhash) from a file. Supports PDF, Excel (.xlsx/.xls), Word (.docx), PPTX, plain text, and images. Returns full_text, per-page breakdown, char_count, page_count, and file_type.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "file_path": {"type": "string", "description": "Absolute path to the file to extract text from."},
                            },
                            "required": ["file_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_render_pages",
                        "description": "Render PDF or image file pages to base64-encoded PNGs for vision model classification. Returns an array of {page_num, base64} objects.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "file_path": {"type": "string", "description": "Absolute path to the PDF or image file to render."},
                                "max_pages": {"type": "integer", "description": "Maximum number of pages to render (default: 2)."},
                                "dpi": {"type": "integer", "description": "Rendering resolution in dots per inch (default: 96)."},
                            },
                            "required": ["file_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_insert_rule",
                        "description": "Deprecated for direct LLM use — prefer library_* tools. Path-driven CRUD is retained as the implementation of library_export_to_sidecar / library_import_from_sidecar. Insert or replace a classification rule in the rules file. Pass `rules_path` (preferred) — the new external rules JSON. Legacy `path`/`password` args are accepted for back-compat but write operations against the embedded vault rules table are no longer supported (returns an error pointing at rules_path).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file (e.g. <vault-stem>.rules.json sibling or a user-level library file). Created if absent."},
                                "path": {"type": "string", "description": "Deprecated: legacy vault path. Write ops return an error; use rules_path instead."},
                                "password": {"type": "string", "description": "Deprecated: unused for rule operations."},
                                "label": {"type": "string", "description": "Unique label for the rule (used as category key). Upserts if a rule with this label already exists."},
                                "name": {"type": "string", "description": "Human-readable rule name."},
                                "instruction": {"type": "string", "description": "LLM instruction for classifying documents into this category."},
                                "signals": {"type": "array", "items": {"type": "string"}, "description": "Keywords/signals that hint at this category."},
                                "subfolder": {"type": "string", "description": "Subfolder to place classified documents."},
                                "rename_pattern": {"type": "string", "description": "Per-rule rename pattern override (defaults to the file-level pattern)."},
                                "confidence_threshold": {"type": "number", "description": "Minimum confidence for auto-classification (default: 0.6)."},
                                "encrypt": {"type": "boolean", "description": "Whether documents in this category should be encrypted."},
                                "enabled": {"type": "boolean", "description": "Whether this rule is active (default: true)."},
                                "is_default": {"type": "boolean", "description": "Mark this rule as the default fallback. At most one rule should have this set."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_list_rules",
                        "description": "Deprecated for direct LLM use — prefer library_* tools. Path-driven CRUD is retained as the implementation of library_export_to_sidecar / library_import_from_sidecar. List classification rules from a rules file (preferred) or the legacy embedded vault rules table (read-only, deprecated). Returns {ok, rules, count, rules_path?, deprecated?}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file. Returns an empty rules array if the file does not yet exist."},
                                "path": {"type": "string", "description": "Deprecated: legacy vault path. Reads the embedded rules table read-only with a deprecated:true flag."},
                                "password": {"type": "string", "description": "Deprecated: unused."},
                            },
                        },
                    },
                    {
                        "name": "minerva_scansort_get_rule",
                        "description": "Deprecated for direct LLM use — prefer library_* tools. Path-driven CRUD is retained as the implementation of library_export_to_sidecar / library_import_from_sidecar. Get a single classification rule. Use rules_path + label (preferred) or the legacy embedded-table read path. Returns {ok, rule}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file."},
                                "path": {"type": "string", "description": "Deprecated: legacy vault path."},
                                "password": {"type": "string", "description": "Deprecated: unused."},
                                "label": {"type": "string", "description": "Rule label to look up. Required when using rules_path."},
                                "rule_id": {"type": "integer", "description": "Legacy: rule_id lookup only works against the embedded vault rules table (no rule_ids in the rules file)."},
                            },
                        },
                    },
                    {
                        "name": "minerva_scansort_update_rule",
                        "description": "Deprecated for direct LLM use — prefer library_* tools. Path-driven CRUD is retained as the implementation of library_export_to_sidecar / library_import_from_sidecar. Update fields of an existing classification rule by label. Pass rules_path (preferred). Legacy path returns deprecation error.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file."},
                                "path": {"type": "string", "description": "Deprecated: legacy vault path. Write ops return an error."},
                                "password": {"type": "string", "description": "Deprecated: unused."},
                                "label": {"type": "string", "description": "Label of the rule to update."},
                                "updates": {"type": "object", "description": "Map of field names to new values. Allowed: name, instruction, signals, subfolder, rename_pattern, confidence_threshold, encrypt, enabled, is_default, label."},
                            },
                            "required": ["label", "updates"],
                        },
                    },
                    {
                        "name": "minerva_scansort_delete_rule",
                        "description": "Deprecated for direct LLM use — prefer library_* tools. Path-driven CRUD is retained as the implementation of library_export_to_sidecar / library_import_from_sidecar. Delete a classification rule by label. Refuses to delete rules marked is_default. Pass rules_path (preferred).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file."},
                                "path": {"type": "string", "description": "Deprecated: legacy vault path. Write ops return an error."},
                                "password": {"type": "string", "description": "Deprecated: unused."},
                                "label": {"type": "string", "description": "Label of the rule to delete."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_import_rules_from_json",
                        "description": "Deprecated for direct LLM use — prefer library_* tools. Path-driven CRUD is retained as the implementation of library_export_to_sidecar / library_import_from_sidecar. Bulk import classification rules into a rules file. json_text accepts a full RulesFile object (replaces file content), a bare array, or an object with a 'rules'/'categories' key (upserts entries into the existing or new file). Returns {ok, count, mode, rules_path}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file. Created if absent."},
                                "path": {"type": "string", "description": "Deprecated: legacy vault path. Write ops return an error."},
                                "password": {"type": "string", "description": "Deprecated: unused."},
                                "json_text": {"type": "string", "description": "JSON string: RulesFile object, bare rule array, or {rules: [...]}/{categories: [...]}."},
                            },
                            "required": ["json_text"],
                        },
                    },
                    {
                        "name": "minerva_scansort_classify_document",
                        "description": "B5: Classify a document using LLM via host.providers.chat. Rules are loaded from the plugin's global library (B2). To populate the library from a per-vault sidecar, call library_import_from_sidecar first. Builds classification messages, calls the LLM, and returns {ok, classification, rule_snapshot}. The rule_snapshot JSON should be passed to insert_document so the vault stays self-describing.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file (used for context; rules now come from the global library, not a sibling sidecar)."},
                                "password": {"type": "string", "description": "Vault password (accepted for back-compat; no longer used for rule loading)."},
                                "user_rules_path": {"type": "string", "description": "Deprecated — silently ignored. Rules are loaded from the global library. Call library_import_from_sidecar to bring sidecar rules into the library."},
                                "mode": {"type": "string", "description": "'text' (default) or 'vision'."},
                                "document_text": {"type": "string", "description": "Extracted document text (required for text mode)."},
                                "page_images": {"type": "array", "description": "Array of {page_num, base64} objects (required for vision mode).", "items": {"type": "object"}},
                                "max_chars": {"type": "integer", "description": "Maximum characters of text to send to LLM (default: 4000)."},
                                "model": {"type": "string", "description": "Model identifier to pass to host.providers.chat (preferred; defaults to 'default')."},
                                "model_id": {"type": "string", "description": "Deprecated alias for 'model'. Use 'model' instead."},
                                "model_spec": {"type": "object", "description": "Structured provider spec from ProviderOptionButton (kind, model_id, etc.). Wins over 'model' when broker supports it."},
                                "vault_id": {"type": "string", "description": "Optional vault_id context for host.providers.chat."},
                            },
                            "required": ["vault_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_list_checklists",
                        "description": "List checklist items for a vault, optionally filtered by tax_year and/or item_type. Returns {ok, items, count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "tax_year": {"type": "integer", "description": "Filter by tax year (optional)."},
                                "item_type": {"type": "string", "description": "Filter by type: 'auto_upload' or 'expected_doc' (optional)."},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_insert_checklist",
                        "description": "Add a new checklist item (auto_upload or expected_doc). Returns {ok, checklist_id}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "tax_year": {"type": "integer", "description": "Tax year this item belongs to."},
                                "item_type": {"type": "string", "description": "Type: 'auto_upload' or 'expected_doc'."},
                                "name": {"type": "string", "description": "Human-readable label for this checklist item."},
                                "match_category": {"type": "string", "description": "Category to match against documents (optional)."},
                                "match_sender": {"type": "string", "description": "Sender substring to match (optional)."},
                                "match_pattern": {"type": "string", "description": "Description substring to match (optional)."},
                            },
                            "required": ["path", "tax_year", "item_type", "name"],
                        },
                    },
                    {
                        "name": "minerva_scansort_get_checklist",
                        "description": "Get a single checklist item by checklist_id. Returns {ok, item}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "checklist_id": {"type": "integer", "description": "Checklist item ID to retrieve."},
                            },
                            "required": ["path", "checklist_id"],
                        },
                    },
                    {
                        "name": "minerva_scansort_update_checklist",
                        "description": "Update fields of a checklist item by checklist_id. Returns {ok}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "checklist_id": {"type": "integer", "description": "Checklist item ID to update."},
                                "updates": {"type": "object", "description": "Map of fields to update. Allowed: name, match_category, match_sender, match_pattern, status, type, tax_year, enabled, matched_doc_id."},
                            },
                            "required": ["path", "checklist_id", "updates"],
                        },
                    },
                    {
                        "name": "minerva_scansort_delete_checklist",
                        "description": "Delete a checklist item by checklist_id. Returns {ok}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "checklist_id": {"type": "integer", "description": "Checklist item ID to delete."},
                            },
                            "required": ["path", "checklist_id"],
                        },
                    },
                    {
                        "name": "minerva_scansort_toggle_checklist_enabled",
                        "description": "Enable or disable a checklist item. Returns {ok}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "checklist_id": {"type": "integer", "description": "Checklist item ID to toggle."},
                                "enabled": {"type": "boolean", "description": "True to enable, false to disable."},
                            },
                            "required": ["path", "checklist_id", "enabled"],
                        },
                    },
                    {
                        "name": "minerva_scansort_run_checklist_check",
                        "description": "Run all enabled checklist items for a tax year against vault documents. Updates status (found/missing) and returns a summary with expected doc results and auto_uploaded count.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "tax_year": {"type": "integer", "description": "Tax year to run the check for."},
                            },
                            "required": ["path", "tax_year"],
                        },
                    },
                    {
                        "name": "minerva_scansort_set_source_dir",
                        "description": "Set the transitory source directory the plugin watches for incoming documents. State is process-memory only — not persisted. Returns {ok, path, recursive}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute filesystem path to the source/incoming directory."},
                                "recursive": {"type": "boolean", "description": "If true, walk subdirectories when listing files. Defaults to false."},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_get_source_dir",
                        "description": "Return the current transitory source directory. Returns {ok, path, recursive}. path is empty when no directory has been set.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {},
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_list_source_files",
                        "description": "List supported document files (.pdf, .docx, .xlsx, .xls) under the stored source directory. For each file returns {path, name, size, sha256, in_vault}. Pass vault_path to enable dedup check.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Optional absolute path to a vault file. When provided, in_vault is set via SHA-256 fingerprint lookup."},
                            },
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_set_destination",
                        "description": "Persist the destination mode for a vault. mode must be vault_only, disk_only, or vault_and_disk. disk_root is required (non-empty) for disk_only and vault_and_disk. Returns {ok, mode, disk_root}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the .ssort vault file."},
                                "mode": {"type": "string", "description": "One of: vault_only, disk_only, vault_and_disk."},
                                "disk_root": {"type": "string", "description": "Absolute path to the on-disk destination directory. Required for disk_only and vault_and_disk."},
                            },
                            "required": ["vault_path", "mode"],
                        },
                    },
                    {
                        "name": "minerva_scansort_get_destination",
                        "description": "Read the persisted destination settings for a vault. Defaults to {mode: vault_only, disk_root: ''} when unset. Returns {ok, mode, disk_root}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the .ssort vault file."},
                            },
                            "required": ["vault_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_list_disk_files",
                        "description": "List every regular file under a directory destination, recursively. Pass vault_path for the vault's configured disk_root, disk_root for a direct directory, or registry_path + destination_id for a registered directory destination. Returns {ok, files: [{path, name, rel_path, size}]}, sorted by rel_path. Returns ok:true with empty files array when the root is unset/empty or does not exist.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the .ssort vault file."},
                                "disk_root": {"type": "string", "description": "Absolute directory path to list directly."},
                                "registry_path": {"type": "string", "description": "Destination registry path. Use with destination_id."},
                                "destination_id": {"type": "string", "description": "Registered directory destination id. Use with registry_path."},
                            },
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_place_on_disk",
                        "description": "Copy a file to its resolved on-disk location under the vault's configured disk_root. Resolves {year} and {date} templates in subfolder and rename_pattern. Creates missing directories. Collision-safe (appends (1), (2), … before extension). Returns {ok, placed_path}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the .ssort vault file."},
                                "file_path": {"type": "string", "description": "Absolute path to the source file to copy."},
                                "subfolder": {"type": "string", "description": "Subdirectory under disk_root. Supports {year} and {date} templates."},
                                "doc_date": {"type": "string", "description": "ISO date string (YYYY-MM-DD) used to resolve {year} and {date} templates."},
                                "rename_pattern": {"type": "string", "description": "Optional base-name pattern (extension preserved). Supports {year} and {date}. Omit to keep the original filename."},
                            },
                            "required": ["vault_path", "file_path", "subfolder", "doc_date"],
                        },
                    },
                    {
                        "name": "minerva_scansort_run_rule_engine",
                        "description": "Phase-2 deterministic rule walk (W3). Takes Phase-1 classification output (extracted facts + per-rule semantic scores) and file facts, walks the rule set in `order` order, applies semantic-threshold + condition + exception gates, and returns which rules fired with their resolved actions (category, copy_to, resolved subfolder/rename_pattern). No LLM calls; pure deterministic function. W10 Process-All calls this for each document.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "rules_path": {"type": "string", "description": "Absolute path to the rules JSON file. Loaded via load_or_init (returns empty rules set when file does not yet exist). Provide either rules_path OR rules."},
                                "rules": {"type": "array", "description": "Pre-loaded rules array (alternative to rules_path). Each element is a Rule object. Provide either rules_path OR rules.", "items": {"type": "object"}},
                                "classification": {
                                    "type": "object",
                                    "description": "Phase-1 Classification output from minerva_scansort_classify_document. Must include rule_signals (per-rule scores) and extracted facts (doc_date, year, issuer, amount, doc_type, confidence)."
                                },
                                "filename": {"type": "string", "description": "Source file name (e.g. 'invoice_2024.pdf'). Used in filename/extension conditions."},
                                "extension": {"type": "string", "description": "File extension without dot (e.g. 'pdf'). Used in extension conditions."},
                                "size": {"type": "integer", "description": "File size in bytes. Used in size conditions."},
                            },
                            "required": ["classification"],
                        },
                    },
                    {
                        "name": "minerva_scansort_destination_add",
                        "description": "Register a new filing destination (vault file or directory) in the session-level destination registry. The plugin generates a stable unique id. Returns {ok, destination: {id, kind, path, label, locked}}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "registry_path": {"type": "string", "description": "Absolute path to the destination registry JSON file. Created on first use."},
                                "kind": {"type": "string", "description": "\"vault\" (a .ssort vault file) or \"directory\" (a plain directory)."},
                                "path": {"type": "string", "description": "Absolute path to the vault file or directory."},
                                "label": {"type": "string", "description": "Optional human-readable label. Defaults to the file/dir name of path."},
                                "locked": {"type": "boolean", "description": "When true, marks this destination as locked/final (W8 will use this to refuse reprocessing). Defaults to false."},
                            },
                            "required": ["registry_path", "kind", "path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_destination_list",
                        "description": "List all destinations in the session-level destination registry. Returns {ok, destinations: [{id, kind, path, label, locked}], count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "registry_path": {"type": "string", "description": "Absolute path to the destination registry JSON file."},
                            },
                            "required": ["registry_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_destination_remove",
                        "description": "Remove a destination from the session-level registry by its id. Returns {ok, removed: bool}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "registry_path": {"type": "string", "description": "Absolute path to the destination registry JSON file."},
                                "id": {"type": "string", "description": "The stable id of the destination to remove (from destination_add or destination_list)."},
                            },
                            "required": ["registry_path", "id"],
                        },
                    },
                    {
                        "name": "minerva_scansort_check_simhash",
                        "description": "W7: Query a vault for near-duplicate text documents using SimHash Hamming distance. Returns all stored documents whose simhash is within `threshold` bits of the candidate. A zero hash ('0000000000000000') always returns empty matches. Non-empty results MUST surface a disposition prompt (keep-both/replace/skip) — never auto-discard. Returns {ok, found, matches: [{doc_id, distance, existing_hash, hash_kind}], count, threshold}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "simhash": {"type": "string", "description": "16-hex-char SimHash of the candidate document."},
                                "threshold": {"type": "integer", "description": "Maximum Hamming distance to flag as near-duplicate (default: 3). Set 0 to find only exact-hash duplicates."},
                            },
                            "required": ["vault_path", "simhash"],
                        },
                    },
                    {
                        "name": "minerva_scansort_check_dhash",
                        "description": "W7: Query a vault for near-duplicate image documents using perceptual dHash Hamming distance. Same shape as check_simhash but operates on the dhash column. Default threshold is 0 (disabled by default — set > 0 to enable image near-dup detection). Non-empty results MUST surface a disposition prompt — never auto-discard. Returns {ok, found, matches: [{doc_id, distance, existing_hash, hash_kind}], count, threshold}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file."},
                                "dhash": {"type": "string", "description": "16-hex-char perceptual dHash of the candidate document."},
                                "threshold": {"type": "integer", "description": "Maximum Hamming distance to flag as near-duplicate (default: 0 = disabled). Set > 0 to enable image near-dup."},
                            },
                            "required": ["vault_path", "dhash"],
                        },
                    },
                    {
                        "name": "minerva_scansort_place_fanout",
                        "description": "W6: Execute copy_to fan-out for a single document — copy/insert it into every destination in copy_to. For directory destinations: copies file to <dest.path>/<resolved_subfolder>/<resolved_rename>, sanitised against path traversal, collision-safe. For vault destinations: calls insert_document. Skips (SkippedAlreadyPresent) if content sha256 already present at that destination. Bad/unknown destination ids produce an error row without aborting the rest. Returns {ok, placements: [{destination_id, kind, target_path, doc_id, status, message}]}. Note: directory hash cache is NOT shared across tool calls (stateless); use the in-process DirHashCache for W10 Process All runs.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "file_path": {"type": "string", "description": "Absolute path to the source file. Never moved or deleted."},
                                "registry_path": {"type": "string", "description": "Absolute path to the destination registry JSON file (W4)."},
                                "copy_to": {"type": "array", "items": {"type": "string"}, "description": "List of destination ids from the registry (from copy_to in the fired rule action)."},
                                "resolved_subfolder": {"type": "string", "description": "Token-expanded subfolder from the W3 FiredRuleAction. Will be sanitised against path traversal here."},
                                "resolved_rename_pattern": {"type": "string", "description": "Token-expanded rename pattern from W3. Will be sanitised. Empty = keep original filename."},
                                "encrypt": {"type": "boolean", "description": "Encrypt flag from the rule. Stored in vault rule_snapshot for vault destinations."},
                                "category": {"type": "string", "description": "Document category (from classification/rule)."},
                                "confidence": {"type": "number", "description": "Classification confidence score."},
                                "issuer": {"type": "string", "description": "Document issuer/sender."},
                                "description": {"type": "string", "description": "Document description."},
                                "doc_date": {"type": "string", "description": "Document date (YYYY-MM-DD)."},
                                "status": {"type": "string", "description": "Document status (default: classified)."},
                                "sha256": {"type": "string", "description": "Pre-computed content sha256 hex. When empty the tool computes it from file_path."},
                                "simhash": {"type": "string", "description": "SimHash for near-dup detection. Default: 0000000000000000."},
                                "dhash": {"type": "string", "description": "Perceptual dhash. Default: 0000000000000000."},
                                "source_path": {"type": "string", "description": "Original source directory path for provenance."},
                                "rule_snapshot": {"type": "string", "description": "JSON snapshot of the rule that fired."},
                                "doc_type": {"type": "string", "description": "Short document type string (e.g. 'invoice', 'W-2'). Used for {doc_type} token in rename/subfolder patterns. Default: ''."},
                                "amount": {"type": "string", "description": "Monetary amount extracted from the document. Used for {amount} token. Default: ''."},
                            },
                            "required": ["file_path", "registry_path", "copy_to"],
                        },
                    },
                    {
                        "name": "minerva_scansort_scan_directory_hashes",
                        "description": "W6: Scan a directory recursively and return the set of content sha256 hex strings for every regular file found. Stateless — no cache shared across calls. Use to check processed-state for directory destinations. For W10 Process All, use the in-process DirHashCache for performance. Returns {ok, dir_path, sha256_hashes: [string], count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "dir_path": {"type": "string", "description": "Absolute path to the directory to scan."},
                            },
                            "required": ["dir_path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_reprocess_destination",
                        "description": "W8: Clear a destination's state so a fresh Process All re-run re-populates it. DESTRUCTIVE — caller MUST gate behind an explicit confirm dialog. REFUSED (error) if the destination is locked/final. For a directory destination: deletes all regular files in the directory (subdirectories untouched). For a vault destination: deletes ALL documents and fingerprints rows. Default Process All is unaffected — this is a separate path. Returns {ok, destination_id, kind, summary, cleared_count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "registry_path": {"type": "string", "description": "Absolute path to the destination registry JSON file."},
                                "destination_id": {"type": "string", "description": "The stable id of the destination to reprocess (from destination_add or destination_list)."},
                            },
                            "required": ["registry_path", "destination_id"],
                        },
                    },
                    {
                        "name": "minerva_scansort_set_destination_locked",
                        "description": "W8: Set or clear the locked/final flag on a destination. A locked destination refuses reprocess at the backend level (defence-in-depth). Returns {ok, destination} with the updated destination record.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "registry_path": {"type": "string", "description": "Absolute path to the destination registry JSON file."},
                                "destination_id": {"type": "string", "description": "The stable id of the destination to update."},
                                "locked": {"type": "boolean", "description": "true to lock/finalise the destination; false to unlock it."},
                            },
                            "required": ["registry_path", "destination_id", "locked"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_open_vault",
                        "description": "B1: Register an opened vault in the in-process session under a caller-chosen label. Returns {ok, label}. Errors if the label is already open.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Short human-readable label for this vault (e.g. vault filename stem). Must be unique within the session's vault set."},
                                "path":  {"type": "string", "description": "Absolute path to the vault file."},
                            },
                            "required": ["label", "path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_close_vault",
                        "description": "B1: Deregister a vault from the in-process session by label. Returns {ok}. Errors if the label is not present.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label that was passed to session_open_vault."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_open_directory",
                        "description": "B1: Register an opened directory destination in the in-process session under a caller-chosen label. Returns {ok, label}. Errors if the label is already open.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Short human-readable label for this directory. Must be unique within the session's dirs set."},
                                "path":  {"type": "string", "description": "Absolute path to the directory."},
                            },
                            "required": ["label", "path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_close_directory",
                        "description": "B1: Deregister a directory from the in-process session by label. Returns {ok}. Errors if the label is not present.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label that was passed to session_open_directory."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_open_source",
                        "description": "B1: Register the active source directory in the in-process session under a caller-chosen label. Returns {ok, label}. Errors if the label is already open.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Short human-readable label for this source directory (e.g. its basename). Must be unique within the session's sources set."},
                                "path":  {"type": "string", "description": "Absolute path to the source directory."},
                            },
                            "required": ["label", "path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_close_source",
                        "description": "B1: Deregister a source directory from the in-process session by label. Returns {ok}. Errors if the label is not present.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label that was passed to session_open_source."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_session_state",
                        "description": "B1: Return the current in-process session state — which vaults, directories, and source directories are currently open — as label-only lists. Paths are never included. Returns {ok, vaults: [{label}], dirs: [{label}], sources: [{label}]}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {},
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_insert_rule",
                        "description": "B2: Upsert a rule into the global library (OS app-data path, no vault required). If a rule with the same label exists it is replaced. Returns {ok, rule}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label":                {"type": "string",  "description": "Unique rule label (primary key). Required."},
                                "name":                 {"type": "string",  "description": "Human-readable display name."},
                                "instruction":          {"type": "string",  "description": "LLM classification instruction."},
                                "signals":              {"type": "array",   "items": {"type": "string"}, "description": "Keywords / signals that trigger this rule."},
                                "subfolder":            {"type": "string",  "description": "Destination subfolder override."},
                                "rename_pattern":       {"type": "string",  "description": "Output filename pattern (e.g. {date}_{issuer}_{description})."},
                                "confidence_threshold": {"type": "number",  "description": "Minimum LLM confidence to apply the rule (0.0–1.0, default 0.6)."},
                                "encrypt":              {"type": "boolean", "description": "Encrypt matching documents."},
                                "enabled":              {"type": "boolean", "description": "Whether the rule is active (default true)."},
                                "is_default":           {"type": "boolean", "description": "Mark as the catch-all default rule."},
                                "order":                {"type": "integer", "description": "Evaluation order — lower values sort first."},
                                "stop_processing":      {"type": "boolean", "description": "Stop evaluating subsequent rules after this one matches."},
                                "copy_to":              {"type": "array",   "items": {"type": "string"}, "description": "Additional destination IDs to copy the document to."},
                                "conditions":           {"type": "object",  "description": "Deterministic gate (ConditionNode) evaluated before LLM classification."},
                                "exceptions":           {"type": "object",  "description": "When this evaluates true, the rule match is negated."},
                                "subtypes":             {"type": "array",   "items": {"type": "object"}, "description": "B8 document subtypes: [{name, also_known_as: [alias...]}]. Used by process() doc_type_strategy=enum|both to constrain prompt, and canonicalize|both to normalize raw LLM output."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_list_rules",
                        "description": "B2: List all rules in the global library in stable insertion order. Returns {ok, rules: [FileRule], count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {},
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_get_rule",
                        "description": "B2: Get a single rule from the global library by label. Returns {ok:true, rule} if found or {ok:false, error} if not found.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label of the rule to retrieve."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_update_rule",
                        "description": "B2: Apply partial field updates to a rule in the global library by label. Only provided fields are changed. Returns {ok:true, rule} if found or {ok:false, error} if not found.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label":                {"type": "string",  "description": "Label of the rule to update. Required."},
                                "name":                 {"type": "string"},
                                "instruction":          {"type": "string"},
                                "signals":              {"type": "array", "items": {"type": "string"}},
                                "subfolder":            {"type": "string"},
                                "rename_pattern":       {"type": "string"},
                                "confidence_threshold": {"type": "number"},
                                "encrypt":              {"type": "boolean"},
                                "enabled":              {"type": "boolean"},
                                "is_default":           {"type": "boolean"},
                                "order":                {"type": "integer"},
                                "stop_processing":      {"type": "boolean"},
                                "copy_to":              {"type": "array", "items": {"type": "string"}},
                                "conditions":           {"type": "object"},
                                "exceptions":           {"type": "object"},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_delete_rule",
                        "description": "B2: Remove a rule from the global library by label. Returns {ok:true, deleted:true} if removed, {ok:true, deleted:false} if the label was not found.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label of the rule to delete."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_enable_rule",
                        "description": "B2: Set enabled=true on a rule in the global library by label. Returns {ok:true, enabled:true} if found, {ok:false, error} if not found.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label of the rule to enable."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_disable_rule",
                        "description": "B2: Set enabled=false on a rule in the global library by label. Returns {ok:true, enabled:false} if found, {ok:false, error} if not found.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Label of the rule to disable."},
                            },
                            "required": ["label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_export_to_sidecar",
                        "description": "B5: Export all rules from the global library to the per-vault sidecar file (<vault-stem>.rules.json next to the vault). vault_label must be open in the current session (kind=Vault). Returns {ok, sidecar_path, count}. Use this to snapshot the library for a specific vault or to share rules with external tools.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_label": {"type": "string", "description": "Session label of an open vault. The sidecar is written to <vault-stem>.rules.json next to the vault file."},
                            },
                            "required": ["vault_label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_library_import_from_sidecar",
                        "description": "B5: Import rules from a per-vault sidecar file (<vault-stem>.rules.json) into the global library. vault_label must be open in the current session (kind=Vault). Each rule is upserted (last-write-wins). Returns {ok, sidecar_path, imported, conflicts, total_after} where conflicts counts rules whose label already existed with different content (informational only — import still proceeds).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_label": {"type": "string", "description": "Session label of an open vault. The sidecar path is <vault-stem>.rules.json next to the vault file. Error if the sidecar doesn't exist."},
                            },
                            "required": ["vault_label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_process",
                        "description": "B3: Path-free process() pipeline. Reads all state from the in-process session (open sources + open destinations) and the global library (enabled rules). For every file under every open source: (1) skips files already processed (B4 manifest), (2) extracts text, (3) classifies via host.providers.chat, (4) runs the deterministic rule engine, (5) fans out to matching open destinations resolved by label, (6) records per-file outcome in the B4 source state manifest. Returns {ok, summary:{moved,conflicts,unprocessable,skipped_already_processed}, by_rule:{<rule_label>:count}, by_destination:{<dest_label>:count}, items:[{source_label,source_path_relative,status,rule_label?,target_labels,reason?}]}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "model": {"type": "string", "description": "Optional model identifier to pass to host.providers.chat (default 'default' = TurnRock Core)."},
                                "model_spec": {"type": "object", "description": "Optional structured provider spec (wins over 'model' when present). Use {kind:'core_action', service_client_id:'model-chat', action_name:'<model>'} to route through a specific Core service."},
                                "doc_type_strategy": {"type": "string", "enum": ["none", "enum", "canonicalize", "both"], "description": "B8 doc_type normalization strategy. 'none' (default): raw LLM output. 'enum': prompt is augmented with the winning rule's allowed subtypes. 'canonicalize': post-LLM alias→canonical map applied. 'both': enum prompt + canonicalize safety net."},
                            },
                            "required": [],
                        },
                    },
                    {
                        "name": "minerva_scansort_audit_append",
                        "description": "W9: Append one or more rows to the append-only CSV audit log. Creates the file with a header row on first write; never truncates. The toggle (audit_log_enabled) is checked by the panel — call this tool only when the toggle is ON. Non-fatal: if log_path is unwritable, returns {ok:false, error:...} without panicking. W10 MUST treat audit failure as non-fatal. CSV columns: timestamp, event, source_sha256, source_filename, rule_label, destination_id, destination_kind, resolved_path, disposition, detail. Returns {ok, log_path, rows_written}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "log_path": {"type": "string", "description": "Absolute path to the CSV audit log file. Must be OUTSIDE any vault. Created on first call; appended on subsequent calls."},
                                "rows": {
                                    "type": "array",
                                    "description": "Array of audit row objects. Each row has 10 fields: timestamp (ISO-8601), event (placement|skipped|superseded), source_sha256, source_filename, rule_label, destination_id, destination_kind, resolved_path, disposition (placed|skipped-already-present|kept-both|replaced|superseded|error), detail.",
                                    "items": {
                                        "type": "object",
                                        "properties": {
                                            "timestamp":        {"type": "string", "description": "ISO-8601 UTC timestamp."},
                                            "event":            {"type": "string", "description": "placement, skipped, or superseded."},
                                            "source_sha256":    {"type": "string", "description": "Hex SHA-256 of the source file."},
                                            "source_filename":  {"type": "string", "description": "Original source filename (basename)."},
                                            "rule_label":       {"type": "string", "description": "Classification rule label that fired."},
                                            "destination_id":   {"type": "string", "description": "Destination registry id."},
                                            "destination_kind": {"type": "string", "description": "vault or directory."},
                                            "resolved_path":    {"type": "string", "description": "For directory: absolute target path; for vault: vault path."},
                                            "disposition":      {"type": "string", "description": "placed, skipped-already-present, kept-both, replaced, superseded, or error."},
                                            "detail":           {"type": "string", "description": "Human-readable detail (error message, doc_id, cleared count, etc.)."},
                                        },
                                        "required": ["timestamp", "event", "source_sha256", "source_filename", "destination_id", "destination_kind", "disposition"],
                                    },
                                },
                            },
                            "required": ["log_path", "rows"],
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
                    "minerva_scansort_get_project_keys" => {
                        handle_get_project_keys(&req.params, req.id)
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
                    "minerva_scansort_set_document_encrypted" => {
                        handle_set_document_encrypted(&req.params, req.id)
                    }
                    "minerva_scansort_update_document" => {
                        handle_update_document(&req.params, req.id)
                    }
                    "minerva_scansort_vault_inventory" => {
                        handle_vault_inventory(&req.params, req.id)
                    }
                    "minerva_scansort_extract_text" => {
                        handle_extract_text(&req.params, req.id)
                    }
                    "minerva_scansort_render_pages" => {
                        handle_render_pages(&req.params, req.id)
                    }
                    "minerva_scansort_insert_rule" => {
                        handle_insert_rule(&req.params, req.id)
                    }
                    "minerva_scansort_list_rules" => {
                        handle_list_rules(&req.params, req.id)
                    }
                    "minerva_scansort_get_rule" => {
                        handle_get_rule(&req.params, req.id)
                    }
                    "minerva_scansort_update_rule" => {
                        handle_update_rule(&req.params, req.id)
                    }
                    "minerva_scansort_delete_rule" => {
                        handle_delete_rule(&req.params, req.id)
                    }
                    "minerva_scansort_import_rules_from_json" => {
                        handle_import_rules_from_json(&req.params, req.id)
                    }
                    "minerva_scansort_classify_document" => {
                        handle_classify_document(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_scansort_list_checklists" => {
                        handle_list_checklists(&req.params, req.id)
                    }
                    "minerva_scansort_insert_checklist" => {
                        handle_insert_checklist(&req.params, req.id)
                    }
                    "minerva_scansort_get_checklist" => {
                        handle_get_checklist(&req.params, req.id)
                    }
                    "minerva_scansort_update_checklist" => {
                        handle_update_checklist(&req.params, req.id)
                    }
                    "minerva_scansort_delete_checklist" => {
                        handle_delete_checklist(&req.params, req.id)
                    }
                    "minerva_scansort_toggle_checklist_enabled" => {
                        handle_toggle_checklist_enabled(&req.params, req.id)
                    }
                    "minerva_scansort_run_checklist_check" => {
                        handle_run_checklist_check(&req.params, req.id)
                    }
                    "minerva_scansort_set_source_dir" => {
                        handle_set_source_dir(&req.params, req.id)
                    }
                    "minerva_scansort_get_source_dir" => {
                        handle_get_source_dir(&req.params, req.id)
                    }
                    "minerva_scansort_list_source_files" => {
                        handle_list_source_files(&req.params, req.id)
                    }
                    "minerva_scansort_set_destination" => {
                        handle_set_destination(&req.params, req.id)
                    }
                    "minerva_scansort_get_destination" => {
                        handle_get_destination(&req.params, req.id)
                    }
                    "minerva_scansort_place_on_disk" => {
                        handle_place_on_disk(&req.params, req.id)
                    }
                    "minerva_scansort_list_disk_files" => {
                        handle_list_disk_files(&req.params, req.id)
                    }
                    "minerva_scansort_run_rule_engine" => {
                        handle_run_rule_engine(&req.params, req.id)
                    }
                    "minerva_scansort_destination_add" => {
                        handle_destination_add(&req.params, req.id)
                    }
                    "minerva_scansort_destination_list" => {
                        handle_destination_list(&req.params, req.id)
                    }
                    "minerva_scansort_destination_remove" => {
                        handle_destination_remove(&req.params, req.id)
                    }
                    "minerva_scansort_check_simhash" => {
                        handle_check_simhash(&req.params, req.id)
                    }
                    "minerva_scansort_check_dhash" => {
                        handle_check_dhash(&req.params, req.id)
                    }
                    "minerva_scansort_place_fanout" => {
                        handle_place_fanout(&req.params, req.id)
                    }
                    "minerva_scansort_scan_directory_hashes" => {
                        handle_scan_directory_hashes(&req.params, req.id)
                    }
                    "minerva_scansort_reprocess_destination" => {
                        handle_reprocess_destination(&req.params, req.id)
                    }
                    "minerva_scansort_set_destination_locked" => {
                        handle_set_destination_locked(&req.params, req.id)
                    }
                    "minerva_scansort_audit_append" => {
                        handle_audit_append(&req.params, req.id)
                    }
                    "minerva_scansort_session_open_vault" => {
                        handle_session_open_vault(&req.params, req.id)
                    }
                    "minerva_scansort_session_close_vault" => {
                        handle_session_close_vault(&req.params, req.id)
                    }
                    "minerva_scansort_session_open_directory" => {
                        handle_session_open_directory(&req.params, req.id)
                    }
                    "minerva_scansort_session_close_directory" => {
                        handle_session_close_directory(&req.params, req.id)
                    }
                    "minerva_scansort_session_open_source" => {
                        handle_session_open_source(&req.params, req.id)
                    }
                    "minerva_scansort_session_close_source" => {
                        handle_session_close_source(&req.params, req.id)
                    }
                    "minerva_scansort_session_state" => {
                        handle_session_state(&req.params, req.id)
                    }
                    "minerva_scansort_library_insert_rule" => {
                        handle_library_insert_rule(&req.params, req.id)
                    }
                    "minerva_scansort_library_list_rules" => {
                        handle_library_list_rules(&req.params, req.id)
                    }
                    "minerva_scansort_library_get_rule" => {
                        handle_library_get_rule(&req.params, req.id)
                    }
                    "minerva_scansort_library_update_rule" => {
                        handle_library_update_rule(&req.params, req.id)
                    }
                    "minerva_scansort_library_delete_rule" => {
                        handle_library_delete_rule(&req.params, req.id)
                    }
                    "minerva_scansort_library_enable_rule" => {
                        handle_library_enable_rule(&req.params, req.id)
                    }
                    "minerva_scansort_library_disable_rule" => {
                        handle_library_disable_rule(&req.params, req.id)
                    }
                    "minerva_scansort_library_export_to_sidecar" => {
                        handle_library_export_to_sidecar(&req.params, req.id)
                    }
                    "minerva_scansort_library_import_from_sidecar" => {
                        handle_library_import_from_sidecar(&req.params, req.id)
                    }
                    "minerva_scansort_process" => {
                        handle_process(req.id, &req.params, &mut out, &mut lines, &mut next_id)
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
