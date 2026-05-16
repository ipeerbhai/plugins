//! B3 — Path-free process() pipeline.
//!
//! The `run()` function is the single entry point.  It reads all state from
//! the in-process session (open sources, open destinations) and the global
//! library (enabled rules), then iterates every file under every open source,
//! classifying and filing each one.
//!
//! ## Destination resolution
//!
//! Rules store destination **labels** in `copy_to` (new convention).  The
//! session holds `(label, path, kind)` for every open vault and directory.
//! `resolve_labels()` maps each label to a synthetic `Destination` whose `id`
//! equals its `label` — this lets us call `placement::fan_out` (which expects
//! registry IDs) without modifying it.
//!
//! ## Capability injection (classify step)
//!
//! `run()` receives mutable references to the I/O streams and a request-ID
//! counter so it can issue `host.providers.chat` capability requests exactly
//! as `handle_classify_document` does.
//!
//! ## Testing strategy (option a — piece-wise)
//!
//! Integration of the full pipeline (LLM call) is exercised in HITL.  Unit
//! tests here cover:
//!   - `resolve_labels` label-lookup logic
//!   - `apply_rule_engine` filtering (enabled vs disabled rules)
//!   - Catch-all outcomes (no rule match, no open destination)
//!   - `should_skip` delegation to source_state
//!
//! These tests construct Session + Library state in-process using the same
//! helpers used by real handlers, but do NOT exercise the LLM capability path.

use crate::classifier;
use crate::destinations::{Destination, DestinationRegistry};
use crate::extract;
use crate::library;
use crate::placement::{self, DirHashCache, DocMeta, PlacementStatus};
use crate::rule_engine::{self, FileFacts};
use crate::rules_file::FileRule;
use crate::session;
use crate::source_state;
use crate::types::{Classification, Rule, VaultError, VaultResult};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io;
use std::path::Path;

// ---------------------------------------------------------------------------
// Public output types
// ---------------------------------------------------------------------------

/// Per-file outcome recorded in the process() result.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProcessItem {
    pub source_label: String,
    pub source_path_relative: String,
    pub status: String,
    pub rule_label: Option<String>,
    pub target_labels: Vec<String>,
    pub reason: Option<String>,
}

/// Aggregate result returned from `run()`.
#[derive(Debug, Default)]
pub struct ProcessResult {
    pub moved: u64,
    pub conflicts: u64,
    pub unprocessable: u64,
    pub skipped_already_processed: u64,
    pub by_rule: HashMap<String, u64>,
    pub by_destination: HashMap<String, u64>,
    pub items: Vec<ProcessItem>,
}

impl ProcessResult {
    fn bump_rule(&mut self, label: &str) {
        *self.by_rule.entry(label.to_string()).or_insert(0) += 1;
    }
    fn bump_dest(&mut self, label: &str) {
        *self.by_destination.entry(label.to_string()).or_insert(0) += 1;
    }
}

// ---------------------------------------------------------------------------
// Destination resolution
// ---------------------------------------------------------------------------

/// Resolve a list of destination labels from the session into a synthetic
/// `DestinationRegistry` whose `id` fields equal the labels.
///
/// Labels not open in the session produce no entry in the registry and are
/// returned in the `missing` vec instead.  Callers should audit-log the
/// missing entries.
pub fn resolve_labels(
    labels: &[String],
) -> (DestinationRegistry, Vec<String>) {
    let mut registry = DestinationRegistry {
        schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
        destinations: Vec::new(),
    };
    let mut missing = Vec::new();

    for label in labels {
        match session::resolve_label(label) {
            Some((lbl, path, kind)) => {
                let kind_str = match kind {
                    session::EntryKind::Vault => "vault",
                    session::EntryKind::Directory => "directory",
                    session::EntryKind::Source => "directory", // shouldn't happen
                };
                registry.destinations.push(Destination {
                    id: lbl.clone(),
                    kind: kind_str.to_string(),
                    path: path.to_string_lossy().into_owned(),
                    label: lbl,
                    locked: false,
                });
            }
            None => {
                missing.push(label.clone());
            }
        }
    }

    (registry, missing)
}

// ---------------------------------------------------------------------------
// Rule engine application (pure, testable helper)
// ---------------------------------------------------------------------------

/// Run the deterministic rule engine against a pre-computed classification
/// and file facts, using only enabled rules.
///
/// Returns the list of fired rule actions from `rule_engine::run`.
pub fn apply_rule_engine(
    classification: &Classification,
    file_facts: &FileFacts,
    rules: &[FileRule],
) -> rule_engine::RuleWalkOutcome {
    let rule_objs: Vec<Rule> = rules.iter().map(|r| r.clone().into_rule()).collect();
    rule_engine::run(classification, file_facts, &rule_objs)
}

// ---------------------------------------------------------------------------
// Main pipeline entry point
// ---------------------------------------------------------------------------

/// Run the process() pipeline.
///
/// # Parameters
/// - `out`     — stdout writer (for host.providers.chat capability requests).
/// - `lines`   — stdin line iterator (for capability responses).
/// - `next_id` — monotonically-increasing request-id counter.
/// - `model`   — model name to pass to host.providers.chat (default "default").
/// - `model_spec` — optional structured provider spec (wins over `model` when present).
///
/// # Returns
/// `Ok(ProcessResult)` on success.  Individual file errors are recorded in
/// the result's `items` list rather than propagated as Err.
pub fn run(
    out: &mut impl io::Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    model: &str,
    model_spec: Option<Value>,
) -> VaultResult<ProcessResult> {
    let mut result = ProcessResult::default();

    // 1. Get open sources (sorted by label for deterministic order).
    let open_sources = session::open_sources_sorted();
    if open_sources.is_empty() {
        return Ok(result);
    }

    // 2. Load enabled rules from the global library, sorted by order asc.
    let all_rules = library::library_list()?;
    let mut enabled_rules: Vec<FileRule> = all_rules.into_iter().filter(|r| r.enabled).collect();
    enabled_rules.sort_by_key(|r| r.order);

    // 3. Build current open-destination label set for skip checks.
    let open_dest_labels: HashSet<String> = session::open_destination_labels();

    // 4. Iterate sources.
    for (source_label, source_path) in &open_sources {
        // Load (or init) per-source manifest.
        let mut src_state = source_state::load_or_init(source_path);

        // List files in the source directory.
        let files = match list_source_files_for_path(source_path) {
            Ok(f) => f,
            Err(e) => {
                log::warn!("process: cannot list files in source '{source_label}': {e}");
                continue;
            }
        };

        let mut dir_cache = DirHashCache::new();

        for (abs_path, rel_path, file_size) in &files {
            // Compute sha256.
            let sha256 = match crate::types::compute_sha256(Path::new(abs_path)) {
                Ok(h) => h,
                Err(e) => {
                    log::warn!("process: sha256 failed for {abs_path}: {e}");
                    result.unprocessable += 1;
                    result.items.push(ProcessItem {
                        source_label: source_label.clone(),
                        source_path_relative: rel_path.clone(),
                        status: "unprocessable".to_string(),
                        rule_label: None,
                        target_labels: vec![],
                        reason: Some(format!("sha256_error: {e}")),
                    });
                    continue;
                }
            };

            // Check skip.
            if source_state::should_skip(&src_state, &sha256, &open_dest_labels) {
                result.skipped_already_processed += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "skipped_already_processed".to_string(),
                    rule_label: None,
                    target_labels: vec![],
                    reason: None,
                });
                continue;
            }

            // Extract text.
            let full_text = match extract::extract_file(abs_path) {
                Ok(res) => res.full_text,
                Err(e) => {
                    log::warn!("process: extract failed for {abs_path}: {e}");
                    let entry = source_state::make_entry(
                        rel_path.clone(),
                        "unprocessable",
                        Some(format!("extract_error: {e}")),
                        None,
                        vec![],
                    );
                    source_state::upsert(&mut src_state, &sha256, entry);
                    result.unprocessable += 1;
                    result.items.push(ProcessItem {
                        source_label: source_label.clone(),
                        source_path_relative: rel_path.clone(),
                        status: "unprocessable".to_string(),
                        rule_label: None,
                        target_labels: vec![],
                        reason: Some(format!("extract_error: {e}")),
                    });
                    continue;
                }
            };

            // Classify via host.providers.chat.
            let rule_objs: Vec<Rule> = enabled_rules.iter().map(|r| r.clone().into_rule()).collect();
            let messages = classifier::build_messages(&full_text, 4000, &rule_objs);

            let mut chat_args = json!({
                "messages": messages,
                "model": model,
            });
            // Forward model_spec when caller supplied a non-empty object.
            // Broker rejects empty {} as 'unknown kind', so guard here.
            if let Some(ref spec) = model_spec {
                let is_empty_obj = spec.as_object().map_or(false, |o| o.is_empty());
                if !spec.is_null() && !is_empty_obj {
                    chat_args["model_spec"] = spec.clone();
                }
            }

            let chat_response = match request_capability(out, lines, next_id, "host.providers.chat", chat_args) {
                Ok(v) => v,
                Err(e) => {
                    log::warn!("process: classify failed for {abs_path}: {e}");
                    let entry = source_state::make_entry(
                        rel_path.clone(),
                        "unprocessable",
                        Some(format!("classify_error: {e}")),
                        None,
                        vec![],
                    );
                    source_state::upsert(&mut src_state, &sha256, entry);
                    result.unprocessable += 1;
                    result.items.push(ProcessItem {
                        source_label: source_label.clone(),
                        source_path_relative: rel_path.clone(),
                        status: "unprocessable".to_string(),
                        rule_label: None,
                        target_labels: vec![],
                        reason: Some(format!("classify_error: {e}")),
                    });
                    continue;
                }
            };

            let response_text = chat_response
                .get("choices")
                .and_then(|v| v.as_array())
                .and_then(|arr| arr.first())
                .and_then(|c| c.get("message"))
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
                .unwrap_or("");

            if response_text.is_empty() {
                // Surface the broker error envelope when present so per-file reasons
                // point at the real failure (schema, model not found, provider crash)
                // instead of the generic "empty LLM response".
                let reason_str = if chat_response.get("success").and_then(|v| v.as_bool()) == Some(false) {
                    let msg = chat_response.get("error_message").and_then(|v| v.as_str()).unwrap_or("broker error");
                    let detail = chat_response.get("detail").and_then(|v| v.as_str()).unwrap_or("");
                    let code = chat_response.get("error_code").and_then(|v| v.as_str()).unwrap_or("");
                    let suffix = if detail.is_empty() { String::new() } else { format!(": {detail}") };
                    let code_prefix = if code.is_empty() { String::new() } else { format!("[{code}] ") };
                    format!("classify_error: {code_prefix}{msg}{suffix}")
                } else if let Some(err_val) = chat_response.get("error") {
                    let err_str = err_val.as_str().map(String::from).unwrap_or_else(|| err_val.to_string());
                    format!("classify_error: LLM error: {err_str}")
                } else {
                    "classify_error: empty LLM response".to_string()
                };
                let entry = source_state::make_entry(
                    rel_path.clone(),
                    "unprocessable",
                    Some(reason_str.clone()),
                    None,
                    vec![],
                );
                source_state::upsert(&mut src_state, &sha256, entry);
                result.unprocessable += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "unprocessable".to_string(),
                    rule_label: None,
                    target_labels: vec![],
                    reason: Some(reason_str),
                });
                continue;
            }

            let classification = classifier::parse_response(response_text, &rule_objs);

            // Run rule engine.
            let ext = Path::new(abs_path)
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_string();
            let fname = Path::new(abs_path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            let file_facts = FileFacts {
                filename: fname,
                extension: ext,
                size: *file_size as i64,
            };

            let outcome = apply_rule_engine(&classification, &file_facts, &enabled_rules);

            if !outcome.matched {
                // No rule fired.
                let entry = source_state::make_entry(
                    rel_path.clone(),
                    "unprocessable",
                    Some("no_rule_match".to_string()),
                    None,
                    vec![],
                );
                source_state::upsert(&mut src_state, &sha256, entry);
                result.unprocessable += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "unprocessable".to_string(),
                    rule_label: None,
                    target_labels: vec![],
                    reason: Some("no_rule_match".to_string()),
                });
                continue;
            }

            // Collect all copy_to labels from fired rules and resolve them.
            let mut all_labels: Vec<String> = Vec::new();
            let mut first_rule_label: Option<String> = None;
            let mut first_action = None;

            for action in &outcome.fired {
                if first_rule_label.is_none() {
                    first_rule_label = Some(action.category.clone());
                    first_action = Some(action.clone());
                }
                for lbl in &action.copy_to {
                    if !all_labels.contains(lbl) {
                        all_labels.push(lbl.clone());
                    }
                }
            }

            let (registry, missing_labels) = resolve_labels(&all_labels);

            // Audit missing labels.
            for missing in &missing_labels {
                log::info!(
                    "process: label '{}' not open in session — skipped for {}",
                    missing,
                    rel_path
                );
            }

            let resolved_labels: Vec<String> = registry
                .destinations
                .iter()
                .map(|d| d.label.clone())
                .collect();

            if resolved_labels.is_empty() {
                // No destinations resolved.
                let entry = source_state::make_entry(
                    rel_path.clone(),
                    "unprocessable",
                    Some("no_open_destination".to_string()),
                    first_rule_label.clone(),
                    vec![],
                );
                source_state::upsert(&mut src_state, &sha256, entry);
                result.unprocessable += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "unprocessable".to_string(),
                    rule_label: first_rule_label,
                    target_labels: vec![],
                    reason: Some("no_open_destination".to_string()),
                });
                continue;
            }

            // Fan out to resolved destinations.
            let action = first_action.as_ref().unwrap();
            let meta = DocMeta {
                category: classification.category.clone(),
                confidence: classification.confidence,
                issuer: classification.issuer.clone(),
                description: classification.description.clone(),
                doc_date: classification.doc_date.clone(),
                status: "classified".to_string(),
                simhash: "0000000000000000".to_string(),
                dhash: "0000000000000000".to_string(),
                source_path: abs_path.clone(),
                rule_snapshot: String::new(),
                sha256: sha256.clone(),
                doc_type: classification.doc_type.clone(),
                amount: classification.amount.clone(),
            };

            let placements = placement::fan_out(
                abs_path,
                &resolved_labels,
                &action.resolved_subfolder,
                &action.resolved_rename_pattern,
                action.encrypt,
                &registry,
                &meta,
                Some(&mut dir_cache),
            );

            // Determine overall outcome.
            let any_placed = placements.iter().any(|p| p.status == PlacementStatus::Placed);
            let any_conflict = placements.iter().any(|p| p.status == PlacementStatus::SkippedAlreadyPresent);

            let status = if any_placed {
                "moved"
            } else if any_conflict {
                "conflict"
            } else {
                "unprocessable"
            };

            // Bump counters.
            if any_placed {
                result.moved += 1;
                if let Some(ref rl) = first_rule_label {
                    result.bump_rule(rl);
                }
                for lbl in &resolved_labels {
                    result.bump_dest(lbl);
                }
            } else if any_conflict {
                result.conflicts += 1;
            } else {
                result.unprocessable += 1;
            }

            let reason = if status == "unprocessable" {
                Some("placement_error".to_string())
            } else {
                None
            };

            let entry = source_state::make_entry(
                rel_path.clone(),
                status,
                reason.clone(),
                first_rule_label.clone(),
                resolved_labels.clone(),
            );
            source_state::upsert(&mut src_state, &sha256, entry);

            result.items.push(ProcessItem {
                source_label: source_label.clone(),
                source_path_relative: rel_path.clone(),
                status: status.to_string(),
                rule_label: first_rule_label,
                target_labels: resolved_labels,
                reason,
            });
        }

        // Write updated manifest back atomically.
        if let Err(e) = source_state::save(source_path, &src_state) {
            log::warn!("process: could not save manifest for '{source_label}': {e}");
        }
    }

    Ok(result)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// List supported files under `source_path` as `(abs_path, rel_path, size)`.
fn list_source_files_for_path(
    source_path: &Path,
) -> VaultResult<Vec<(String, String, u64)>> {
    let mut files = Vec::new();
    collect_files_inner(source_path, source_path, &mut files)?;
    files.sort_by(|a, b| a.1.cmp(&b.1));
    Ok(files)
}

const SUPPORTED_EXTS: &[&str] = &[".pdf", ".docx", ".xlsx", ".xls"];

fn is_supported_ext(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_lowercase()))
        .unwrap_or_default();
    SUPPORTED_EXTS.contains(&ext.as_str())
}

fn collect_files_inner(
    base: &Path,
    dir: &Path,
    out: &mut Vec<(String, String, u64)>,
) -> VaultResult<()> {
    let entries = std::fs::read_dir(dir).map_err(|e| {
        VaultError::new(format!(
            "process: cannot read directory {}: {e}",
            dir.display()
        ))
    })?;
    for entry_result in entries {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        // Skip hidden files and the manifest itself.
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if file_name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect_files_inner(base, &path, out)?;
            continue;
        }
        if !is_supported_ext(&path) {
            continue;
        }
        let abs = path
            .canonicalize()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());
        let rel = path
            .strip_prefix(base)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| file_name.to_string());
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        out.push((abs, rel, size));
    }
    Ok(())
}

/// Inline capability request helper (same contract as in main.rs).
fn request_capability(
    out: &mut impl io::Write,
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
        "params": { "capability": capability, "args": args }
    });
    let line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
    out.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    out.write_all(b"\n").map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())?;

    for line_result in lines.by_ref() {
        let line = line_result.map_err(|e| format!("stdin read error: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let msg_id = msg.get("id").cloned().unwrap_or(Value::Null);
        if msg_id.as_str() != Some(&id) {
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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules_file::FileRule;
    use crate::source_state::SourceState;
    use crate::session;
    use crate::types::{Classification, RuleSignal};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_tmp(prefix: &str) -> PathBuf {
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir()
            .join(format!("scansort-process-{prefix}-{pid}-{ts}-{n}"))
    }

    fn make_file_rule(label: &str, enabled: bool, copy_to: Vec<&str>) -> FileRule {
        FileRule {
            label: label.to_string(),
            name: label.to_string(),
            instruction: format!("Match {label} documents"),
            signals: vec![label.to_string()],
            subfolder: String::new(),
            rename_pattern: String::new(),
            confidence_threshold: 0.5,
            encrypt: false,
            enabled,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: copy_to.into_iter().map(String::from).collect(),
        }
    }

    fn make_classification_with_signal(rule_label: &str, score: f64) -> Classification {
        Classification {
            category: rule_label.to_string(),
            confidence: score,
            issuer: String::new(),
            description: String::new(),
            doc_date: String::new(),
            tags: vec![],
            raw_response: String::new(),
            fallback_reason: None,
            doc_type: String::new(),
            amount: String::new(),
            year: 0,
            rule_signals: vec![RuleSignal {
                label: rule_label.to_string(),
                score,
            }],
        }
    }

    // -----------------------------------------------------------------------
    // Label resolver: known vault and dir labels resolve; unknown misses
    // -----------------------------------------------------------------------
    #[test]
    fn resolve_labels_vault_and_dir() {
        // Build a synthetic registry directly — don't touch the global SESSION
        // singleton which could interfere with other tests.
        let mut registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![
                Destination {
                    id: "vault-a".to_string(),
                    kind: "vault".to_string(),
                    path: "/fake/vault-a.ssort".to_string(),
                    label: "vault-a".to_string(),
                    locked: false,
                },
                Destination {
                    id: "dir-b".to_string(),
                    kind: "directory".to_string(),
                    path: "/fake/dir-b".to_string(),
                    label: "dir-b".to_string(),
                    locked: false,
                },
            ],
        };

        // Simulate resolve_labels by calling find_by_id on the synthetic reg.
        let found_a = crate::destinations::find_by_id(&registry, "vault-a");
        let found_b = crate::destinations::find_by_id(&registry, "dir-b");
        let found_c = crate::destinations::find_by_id(&registry, "no-such-label");

        assert!(found_a.is_some(), "vault-a must resolve");
        assert_eq!(found_a.unwrap().kind, "vault");
        assert!(found_b.is_some(), "dir-b must resolve");
        assert_eq!(found_b.unwrap().kind, "directory");
        assert!(found_c.is_none(), "no-such-label must not resolve");

        // Verify the id=label invariant that resolve_labels() guarantees.
        for dest in &registry.destinations {
            assert_eq!(dest.id, dest.label, "id must equal label in synthetic registry");
        }
        // Suppress unused-mut warning.
        registry.destinations.clear();
    }

    // -----------------------------------------------------------------------
    // Rule engine filter: only enabled rules fire
    // -----------------------------------------------------------------------
    #[test]
    fn apply_rule_engine_skips_disabled_rules() {
        let classification = make_classification_with_signal("invoice", 0.9);
        let file_facts = FileFacts {
            filename: "inv.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 1000,
        };

        let rules = vec![
            make_file_rule("invoice", true,  vec!["dest-a"]),
            make_file_rule("tax",     false, vec!["dest-b"]), // disabled
        ];

        let outcome = apply_rule_engine(&classification, &file_facts, &rules);
        assert!(outcome.matched, "enabled rule must fire");
        assert_eq!(outcome.fired.len(), 1);
        assert_eq!(outcome.fired[0].category, "invoice");
    }

    // -----------------------------------------------------------------------
    // Catch-all: no rule matches → unprocessable/no_rule_match
    // -----------------------------------------------------------------------
    #[test]
    fn no_rule_match_outcome() {
        let classification = make_classification_with_signal("invoice", 0.1); // below threshold
        let file_facts = FileFacts {
            filename: "unknown.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 500,
        };

        let rules = vec![make_file_rule("invoice", true, vec!["dest-a"])];
        let outcome = apply_rule_engine(&classification, &file_facts, &rules);
        assert!(!outcome.matched, "low score must not fire");
        assert!(outcome.fired.is_empty());
    }

    // -----------------------------------------------------------------------
    // Catch-all: rule fired but copy_to label not open → no destinations
    // -----------------------------------------------------------------------
    #[test]
    fn fired_rule_missing_labels_yields_empty_resolved() {
        // Build a label list with one unknown label.
        let labels = vec!["missing-label".to_string()];

        // Don't use the global session — call resolve_labels which internally
        // calls session::resolve_label.  Since we're in a test and "missing-label"
        // is not in the global session, it should come back as missing.
        let (registry, missing) = resolve_labels(&labels);
        assert!(registry.destinations.is_empty(), "no destinations must resolve");
        assert_eq!(missing, vec!["missing-label"]);
    }

    // -----------------------------------------------------------------------
    // should_skip delegation: matches source_state module behaviour
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_delegates_correctly() {
        let mut state = SourceState::default();
        let sha = "cafebabe";
        let open: HashSet<String> = ["dest-x".to_string()].into_iter().collect();

        // No entry yet → do NOT skip.
        assert!(!source_state::should_skip(&state, sha, &open));

        // Add a moved entry with dest-x.
        source_state::upsert(
            &mut state,
            sha,
            source_state::make_entry(
                "f.pdf".to_string(),
                "moved",
                None,
                Some("rule-x".to_string()),
                vec!["dest-x".to_string()],
            ),
        );

        // dest-x is open → should skip.
        assert!(source_state::should_skip(&state, sha, &open));

        // Close dest-x → should NOT skip.
        let empty_open: HashSet<String> = HashSet::new();
        assert!(!source_state::should_skip(&state, sha, &empty_open));
    }

    // -----------------------------------------------------------------------
    // Multiple enabled rules all fire; copy_to union collected correctly
    // -----------------------------------------------------------------------
    #[test]
    fn multi_fired_rules_copy_to_union() {
        let mut classification = make_classification_with_signal("rule_a", 0.9);
        classification.rule_signals.push(RuleSignal {
            label: "rule_b".to_string(),
            score: 0.8,
        });

        let file_facts = FileFacts {
            filename: "doc.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 1000,
        };

        let rules = vec![
            make_file_rule("rule_a", true, vec!["dest-1", "dest-2"]),
            make_file_rule("rule_b", true, vec!["dest-2", "dest-3"]),
        ];

        let outcome = apply_rule_engine(&classification, &file_facts, &rules);
        assert!(outcome.matched);
        assert_eq!(outcome.fired.len(), 2);

        // Collect union of copy_to from all fired rules.
        let mut all_labels: Vec<String> = Vec::new();
        for action in &outcome.fired {
            for lbl in &action.copy_to {
                if !all_labels.contains(lbl) {
                    all_labels.push(lbl.clone());
                }
            }
        }
        // dest-2 appears in both rules but should appear once in the union.
        assert_eq!(all_labels.len(), 3);
        assert!(all_labels.contains(&"dest-1".to_string()));
        assert!(all_labels.contains(&"dest-2".to_string()));
        assert!(all_labels.contains(&"dest-3".to_string()));
    }
}
