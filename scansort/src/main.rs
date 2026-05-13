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

mod checklists;
mod classifier;
mod crypto;
mod db;
mod documents;
mod extract;
mod fingerprints;
mod registry;
mod render;
mod rules;
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
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
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
    let confidence_threshold = args.get("confidence_threshold").and_then(|v| v.as_f64()).unwrap_or(0.6);
    let encrypt = args.get("encrypt").and_then(|v| v.as_bool()).unwrap_or(false);
    let enabled = args.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);

    match rules::insert_rule(path, password, label, name, instruction, &signals, subfolder, confidence_threshold, encrypt, enabled) {
        Ok(rule_id) => ok_response(id, tool_ok(json!({"ok": true, "rule_id": rule_id}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_list_rules(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    match rules::list_rules(path, password) {
        Ok(r) => match serde_json::to_value(&r) {
            Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rules": v, "count": r.len()}))),
            Err(e) => ok_response(id, tool_err(&e.to_string())),
        },
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_get_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    // Accept either label (string) or rule_id (integer)
    if let Some(label) = args.get("label").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        match rules::get_rule_by_label(path, password, label) {
            Ok(Some(r)) => match serde_json::to_value(&r) {
                Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v}))),
                Err(e) => ok_response(id, tool_err(&e.to_string())),
            },
            Ok(None) => ok_response(id, tool_err(&format!("Rule not found: {label}"))),
            Err(e) => ok_response(id, tool_err(&e.message)),
        }
    } else if let Some(rule_id) = args.get("rule_id").and_then(|v| v.as_i64()) {
        match rules::get_rule_by_id(path, password, rule_id) {
            Ok(Some(r)) => match serde_json::to_value(&r) {
                Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "rule": v}))),
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
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    let updates_val = args.get("updates").cloned().unwrap_or(Value::Object(Default::default()));
    let updates: std::collections::HashMap<String, Value> = match updates_val {
        Value::Object(map) => map.into_iter().collect(),
        _ => return ok_response(id, tool_err("updates must be an object")),
    };
    match rules::update_rule(path, password, label, &updates) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_delete_rule(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let label = args.get("label").and_then(|v| v.as_str()).unwrap_or("");
    if label.is_empty() {
        return ok_response(id, tool_err("label is required"));
    }
    match rules::delete_rule(path, password, label) {
        Ok(()) => ok_response(id, tool_ok(json!({"ok": true}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
}

fn handle_import_rules_from_json(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let password = args.get("password").and_then(|v| v.as_str()).unwrap_or("");
    if path.is_empty() {
        return ok_response(id, tool_err("path is required"));
    }
    let json_text = args.get("json_text").and_then(|v| v.as_str()).unwrap_or("");
    if json_text.is_empty() {
        return ok_response(id, tool_err("json_text is required"));
    }
    match rules::import_rules_from_json(path, password, json_text) {
        Ok(count) => ok_response(id, tool_ok(json!({"ok": true, "count": count}))),
        Err(e) => ok_response(id, tool_err(&e.message)),
    }
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
    let model_id = args.get("model_id").and_then(|v| v.as_str()).unwrap_or("");
    let vault_id = args.get("vault_id").and_then(|v| v.as_str());

    // 1. Load rules
    let rule_list = match rules::list_rules(vault_path, password) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&format!("Failed to load rules: {}", e.message))),
    };

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
        "model_id": model_id,
    });
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
        // If the broker returned an error envelope, pass it through
        if let Some(err_val) = chat_response.get("error") {
            let err_str = err_val.as_str().map(String::from).unwrap_or_else(|| err_val.to_string());
            return ok_response(id, tool_err(&format!("LLM error: {err_str}")));
        }
        return ok_response(id, tool_err("Empty response from LLM"));
    }

    // 5. Parse and return
    let classification = classifier::parse_response(response_text, &rule_list);
    match serde_json::to_value(&classification) {
        Ok(v) => ok_response(id, tool_ok(json!({"ok": true, "classification": v}))),
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
                        "description": "Insert a classification rule into a vault. Returns {ok, rule_id}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional, for API consistency)."},
                                "label": {"type": "string", "description": "Unique label for the rule (used as category key)."},
                                "name": {"type": "string", "description": "Human-readable rule name."},
                                "instruction": {"type": "string", "description": "LLM instruction for classifying documents into this category."},
                                "signals": {"type": "array", "items": {"type": "string"}, "description": "Keywords/signals that hint at this category."},
                                "subfolder": {"type": "string", "description": "Subfolder to place classified documents."},
                                "confidence_threshold": {"type": "number", "description": "Minimum confidence for auto-classification (default: 0.6)."},
                                "encrypt": {"type": "boolean", "description": "Whether documents in this category should be encrypted."},
                                "enabled": {"type": "boolean", "description": "Whether this rule is active (default: true)."},
                            },
                            "required": ["path", "label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_list_rules",
                        "description": "List all classification rules in a vault. Returns {ok, rules, count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_get_rule",
                        "description": "Get a single classification rule by label or rule_id. Returns {ok, rule}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "label": {"type": "string", "description": "Rule label to look up (mutually exclusive with rule_id)."},
                                "rule_id": {"type": "integer", "description": "Rule ID to look up (mutually exclusive with label)."},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "minerva_scansort_update_rule",
                        "description": "Update fields of an existing classification rule by label. Returns {ok}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "label": {"type": "string", "description": "Label of the rule to update."},
                                "updates": {"type": "object", "description": "Map of field names to new values. Allowed: name, instruction, signals, subfolder, rename_pattern, confidence_threshold, encrypt, enabled, is_default, label."},
                            },
                            "required": ["path", "label", "updates"],
                        },
                    },
                    {
                        "name": "minerva_scansort_delete_rule",
                        "description": "Delete a classification rule by label. Refuses to delete default rules. Returns {ok}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "label": {"type": "string", "description": "Label of the rule to delete."},
                            },
                            "required": ["path", "label"],
                        },
                    },
                    {
                        "name": "minerva_scansort_import_rules_from_json",
                        "description": "Bulk-import classification rules from a JSON array string (or object with 'rules' key). Uses INSERT OR REPLACE. Returns {ok, count}.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string", "description": "Absolute path to the vault file."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "json_text": {"type": "string", "description": "JSON string containing a rules array or object with 'rules' key."},
                            },
                            "required": ["path", "json_text"],
                        },
                    },
                    {
                        "name": "minerva_scansort_classify_document",
                        "description": "Classify a document using LLM via host.providers.chat. Loads rules from the vault, builds classification messages, calls the LLM, and returns a Classification result with category, confidence, sender, description, doc_date, and tags.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "vault_path": {"type": "string", "description": "Absolute path to the vault file (for loading rules)."},
                                "password": {"type": "string", "description": "Vault password (optional)."},
                                "mode": {"type": "string", "description": "'text' (default) or 'vision'."},
                                "document_text": {"type": "string", "description": "Extracted document text (required for text mode)."},
                                "page_images": {"type": "array", "description": "Array of {page_num, base64} objects (required for vision mode).", "items": {"type": "object"}},
                                "max_chars": {"type": "integer", "description": "Maximum characters of text to send to LLM (default: 4000)."},
                                "model_id": {"type": "string", "description": "Model identifier to pass to host.providers.chat."},
                                "vault_id": {"type": "string", "description": "Optional vault_id context for host.providers.chat."},
                            },
                            "required": ["vault_path", "model_id"],
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
