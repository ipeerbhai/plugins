//! Classification rule CRUD operations.
//!
//! Port of vault.py rule functions: insert, list, get, update, delete, import.
//! Signals are stored as JSON arrays in the DB.
//!
//! Note: the `path` arg is the vault path; `password` is accepted by public
//! functions for API consistency but is not used for SQLite auth (rules table
//! is always plaintext, same as documents.rs).

use crate::db;
use crate::types::{Rule, VaultError, VaultResult};
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Row -> Rule
// ---------------------------------------------------------------------------

fn row_to_rule(row: &rusqlite::Row) -> Result<Rule, rusqlite::Error> {
    let signals_raw: Option<String> = row.get("signals")?;
    let signals = signals_raw
        .map(|s| db::parse_json_array(&s))
        .unwrap_or_default();

    Ok(Rule {
        rule_id: row.get("rule_id")?,
        label: db::get_string(row, "label"),
        name: db::get_string(row, "name"),
        instruction: db::get_string(row, "instruction"),
        signals,
        subfolder: db::get_string(row, "subfolder"),
        rename_pattern: db::get_string(row, "rename_pattern"),
        confidence_threshold: db::get_f64(row, "confidence_threshold"),
        encrypt: db::get_bool(row, "encrypt"),
        enabled: db::get_bool(row, "enabled"),
        is_default: db::get_bool(row, "is_default"),
        // New v2 fields — not stored in the legacy embedded table; default values.
        conditions: None,
        exceptions: None,
        order: 0,
        stop_processing: false,
        copy_to: Vec::new(),
        subtypes: Vec::new(),
        stages: Vec::new(),
    })
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Insert a classification rule. Returns the new rule_id.
pub fn insert_rule(
    path: &str,
    _password: &str,
    label: &str,
    name: &str,
    instruction: &str,
    signals: &[String],
    subfolder: &str,
    confidence_threshold: f64,
    encrypt: bool,
    enabled: bool,
) -> VaultResult<i64> {
    if label.is_empty() {
        return Err(VaultError::new("Rule must have a label"));
    }

    let conn = db::connect(path)?;
    let signals_json = db::to_json_array(signals);

    conn.execute(
        "INSERT INTO rules (label, name, instruction, signals, subfolder, \
         rename_pattern, confidence_threshold, encrypt, enabled, is_default) \
         VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, ?7, ?8, 0)",
        rusqlite::params![
            label,
            name,
            instruction,
            signals_json,
            subfolder,
            confidence_threshold,
            encrypt as i64,
            enabled as i64,
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

/// List all rules ordered by rule_id.
pub fn list_rules(path: &str, _password: &str) -> VaultResult<Vec<Rule>> {
    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT rule_id, label, name, instruction, signals, subfolder, \
         rename_pattern, confidence_threshold, encrypt, enabled, is_default \
         FROM rules ORDER BY rule_id",
    )?;

    let rules = stmt
        .query_map([], |row| row_to_rule(row))?
        .filter_map(|r| r.ok())
        .collect();

    Ok(rules)
}

/// Get a single rule by label (exact match).
pub fn get_rule_by_label(path: &str, _password: &str, label: &str) -> VaultResult<Option<Rule>> {
    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT rule_id, label, name, instruction, signals, subfolder, \
         rename_pattern, confidence_threshold, encrypt, enabled, is_default \
         FROM rules WHERE label = ?",
    )?;
    match stmt.query_row([label], |row| row_to_rule(row)) {
        Ok(rule) => Ok(Some(rule)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(VaultError::from(e)),
    }
}

/// Get a single rule by id.
pub fn get_rule_by_id(path: &str, _password: &str, id: i64) -> VaultResult<Option<Rule>> {
    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT rule_id, label, name, instruction, signals, subfolder, \
         rename_pattern, confidence_threshold, encrypt, enabled, is_default \
         FROM rules WHERE rule_id = ?",
    )?;
    match stmt.query_row([id], |row| row_to_rule(row)) {
        Ok(rule) => Ok(Some(rule)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(VaultError::from(e)),
    }
}

/// Update a rule by label. Only keys present in `updates` are changed.
///
/// Supported keys: name, instruction, signals (array or string), subfolder,
/// rename_pattern, confidence_threshold, encrypt, enabled, is_default, label.
pub fn update_rule(
    path: &str,
    _password: &str,
    label: &str,
    updates: &HashMap<String, serde_json::Value>,
) -> VaultResult<()> {
    if label.is_empty() {
        return Err(VaultError::new("Label is required"));
    }
    if updates.is_empty() {
        return Err(VaultError::new("No valid fields to update"));
    }

    let conn = db::connect(path)?;

    let exists: bool = conn
        .prepare("SELECT 1 FROM rules WHERE label = ?")?
        .exists([label])?;
    if !exists {
        return Err(VaultError::new(format!("Rule not found: {label}")));
    }

    let mut set_clauses: Vec<String> = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    for field in &["name", "instruction", "subfolder", "rename_pattern"] {
        if let Some(val) = updates.get(*field) {
            set_clauses.push(format!("{field} = ?"));
            params.push(Box::new(val.as_str().unwrap_or("").to_string()));
        }
    }

    if let Some(val) = updates.get("confidence_threshold") {
        set_clauses.push("confidence_threshold = ?".to_string());
        params.push(Box::new(val.as_f64().unwrap_or(0.6)));
    }

    if let Some(val) = updates.get("signals") {
        set_clauses.push("signals = ?".to_string());
        if let Some(arr) = val.as_array() {
            let strs: Vec<String> = arr
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
            params.push(Box::new(db::to_json_array(&strs)));
        } else {
            params.push(Box::new(val.as_str().unwrap_or("[]").to_string()));
        }
    }

    for field in &["encrypt", "enabled", "is_default"] {
        if let Some(val) = updates.get(*field) {
            set_clauses.push(format!("{field} = ?"));
            params.push(Box::new(val.as_bool().unwrap_or(false) as i64));
        }
    }

    if let Some(new_label) = updates.get("label") {
        let new_label_str = new_label.as_str().unwrap_or("");
        if !new_label_str.is_empty() && new_label_str != label {
            set_clauses.push("label = ?".to_string());
            params.push(Box::new(new_label_str.to_string()));
        }
    }

    if set_clauses.is_empty() {
        return Err(VaultError::new("No valid fields to update"));
    }

    params.push(Box::new(label.to_string()));
    let sql = format!(
        "UPDATE rules SET {} WHERE label = ?",
        set_clauses.join(", ")
    );
    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    conn.execute(&sql, param_refs.as_slice())?;
    Ok(())
}

/// Delete a rule by label. Refuses to delete default rules (is_default = 1).
pub fn delete_rule(path: &str, _password: &str, label: &str) -> VaultResult<()> {
    if label.is_empty() {
        return Err(VaultError::new("Label is required"));
    }

    let conn = db::connect(path)?;

    let mut stmt = conn.prepare("SELECT is_default FROM rules WHERE label = ?")?;
    let is_default = stmt.query_row([label], |row| row.get::<_, i64>(0));

    match is_default {
        Ok(1) => {
            return Err(VaultError::new(format!(
                "Cannot delete default rule '{label}'"
            )));
        }
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            return Err(VaultError::new(format!("Rule not found: {label}")));
        }
        Err(e) => return Err(VaultError::from(e)),
        Ok(_) => {}
    }

    conn.execute("DELETE FROM rules WHERE label = ?", [label])?;
    Ok(())
}

/// Import rules from a JSON array string. Uses INSERT OR REPLACE.
/// Returns the count of rules imported.
///
/// Accepts a JSON array directly: `[{"label": "...", "instruction": "...", ...}, ...]`
pub fn import_rules_from_json(path: &str, _password: &str, json_text: &str) -> VaultResult<i64> {
    let data: serde_json::Value = serde_json::from_str(json_text)?;

    // Accept either a bare array or an object with a "rules" or "categories" key.
    let raw_rules = if let Some(arr) = data.as_array() {
        arr.to_owned()
    } else if let Some(obj) = data.as_object() {
        obj.get("rules")
            .or_else(|| obj.get("categories"))
            .and_then(|v| v.as_array())
            .cloned()
            .ok_or_else(|| VaultError::new("Expected a JSON array, or object with 'rules'/'categories' key"))?
    } else {
        return Err(VaultError::new("Expected a JSON array or object"));
    };

    let default_threshold = if let Some(obj) = data.as_object() {
        obj.get("confidence_threshold")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.6)
    } else {
        0.6
    };

    let conn = db::connect(path)?;
    let mut count: i64 = 0;

    for entry in &raw_rules {
        let label = entry
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if label.is_empty() {
            continue;
        }

        let instruction = entry
            .get("instruction")
            .or_else(|| entry.get("description"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let name = entry
            .get("name")
            .and_then(|v| v.as_str())
            .map(String::from)
            .unwrap_or_else(|| {
                label
                    .replace('-', " ")
                    .split_whitespace()
                    .map(|w| {
                        let mut chars = w.chars();
                        match chars.next() {
                            None => String::new(),
                            Some(f) => f.to_uppercase().to_string() + chars.as_str(),
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            });

        let signals_json = match entry.get("signals") {
            Some(val) if val.is_array() => {
                serde_json::to_string(val).unwrap_or_else(|_| "[]".into())
            }
            Some(val) if val.is_string() => val.as_str().unwrap_or("[]").to_string(),
            _ => "[]".to_string(),
        };

        let subfolder = entry
            .get("subfolder")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let rename_pattern = entry
            .get("rename_pattern")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let threshold = entry
            .get("confidence_threshold")
            .and_then(|v| v.as_f64())
            .unwrap_or(default_threshold);
        let encrypt = entry
            .get("encrypt")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let enabled = entry
            .get("enabled")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let is_default = entry
            .get("is_default")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        conn.execute(
            "INSERT OR REPLACE INTO rules \
             (label, name, instruction, signals, subfolder, rename_pattern, \
              confidence_threshold, encrypt, enabled, is_default) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            rusqlite::params![
                label,
                name,
                instruction,
                signals_json,
                subfolder,
                rename_pattern,
                threshold,
                encrypt as i64,
                enabled as i64,
                is_default as i64,
            ],
        )?;
        count += 1;
    }

    Ok(count)
}

// ---------------------------------------------------------------------------
// Classifier helpers
// ---------------------------------------------------------------------------

/// Returns the default category label (first is_default rule, or first rule,
/// or "unclassified" if no rules exist).
pub fn default_category(rules: &[Rule]) -> &str {
    for r in rules {
        if r.is_default {
            return &r.label;
        }
    }
    if let Some(r) = rules.first() {
        return &r.label;
    }
    "unclassified"
}

/// Returns true if `label` matches an enabled rule in `rules`.
pub fn is_valid_label(rules: &[Rule], label: &str) -> bool {
    rules.iter().any(|r| r.enabled && r.label == label)
}

/// Build the system prompt for Phase 1 classification.
///
/// The prompt requests two things from the LLM:
///
/// 1. **Extracted facts** — `doc_date`, `issuer`, `amount`, `doc_type`,
///    `description`, `tags`, and an overall `confidence`.
/// 2. **Per-rule semantic-match scores** — one entry per enabled rule,
///    scoring how well the document matches that rule's instruction/signals.
///
/// The per-rule score array feeds W3's deterministic rule walk (thresholding,
/// conditions, exceptions, stop_processing).  The LLM must NOT pick a winner
/// — it must score every listed rule independently.
pub fn build_prompt_context(rules: &[Rule]) -> String {
    build_prompt_context_with_strategy(rules, "none")
}

/// Variant of `build_prompt_context` that augments per-rule sections with
/// `Allowed doc_type values:` lines when the B8 `enum`/`both` strategy is
/// active and the rule has `subtypes`. Soft constraint (prompt-only); the
/// canonicalizer is the post-LLM safety net for `both`.
pub fn build_prompt_context_with_strategy(rules: &[Rule], doc_type_strategy: &str) -> String {
    let enum_active = doc_type_strategy == "enum" || doc_type_strategy == "both";
    // Collect enabled rule labels for the score-array schema example.
    let enabled_labels: Vec<&str> = rules
        .iter()
        .filter(|r| r.enabled)
        .map(|r| r.label.as_str())
        .collect();

    let rule_signals_example: String = if enabled_labels.is_empty() {
        r#"[{"label": "<rule_label>", "score": 0.0}]"#.to_string()
    } else {
        let entries: Vec<String> = enabled_labels
            .iter()
            .map(|l| format!(r#"{{"label": "{l}", "score": 0.0}}"#))
            .collect();
        format!("[{}]", entries.join(", "))
    };

    let mut lines: Vec<String> = Vec::new();

    lines.push("You are a document classifier and fact extractor.".to_string());
    lines.push(String::new());
    lines.push("## Task".to_string());
    lines.push("Analyze the document and respond with a single JSON object containing:".to_string());
    lines.push(String::new());
    lines.push("1. **Extracted facts** about the document.".to_string());
    lines.push("2. **Per-rule semantic scores** — for EVERY rule listed below, score how well the document matches that rule (0.0 = no match, 1.0 = perfect match). Score ALL rules independently; do NOT pick just one winner.".to_string());
    lines.push(String::new());

    lines.push("## Required JSON schema".to_string());
    lines.push(r#"{
  "doc_date": "<YYYY-MM-DD document date, or empty string if unknown>",
  "issuer": "<organization or person that issued the document>",
  "amount": "<monetary amount as a string, e.g. '1234.56', or empty string if none>",
  "doc_type": "<short document-type label, e.g. 'W-2', 'invoice', 'bank statement', 'receipt'>",
  "description": "<one-sentence description of the document>",
  "tags": ["<keyword1>", "<keyword2>"],
  "confidence": <overall extraction confidence 0.0–1.0>,
  "rule_signals": <per-rule score array — see below>
}"#.to_string());
    lines.push(String::new());

    lines.push("## Rules to score".to_string());
    lines.push(format!(
        "Provide a `rule_signals` array with EXACTLY one entry per enabled rule below.\n\
         Each entry: {{\"label\": \"<exact rule label>\", \"score\": <0.0-1.0>}}.\n\
         Example shape (fill in real scores): {rule_signals_example}"
    ));
    lines.push(String::new());

    for r in rules {
        if !r.enabled {
            continue;
        }
        lines.push(format!("### {}", r.label));
        if !r.instruction.is_empty() {
            lines.push(r.instruction.clone());
        }
        if !r.signals.is_empty() {
            lines.push(format!("Keywords: {}", r.signals.join(", ")));
        }
        if enum_active && !r.subtypes.is_empty() {
            let names: Vec<&str> = r.subtypes.iter().map(|s| s.name.as_str()).collect();
            lines.push(format!(
                "Allowed `doc_type` values when this rule wins: {}. Use EXACTLY one of these tokens.",
                names.join(", ")
            ));
        }
        lines.push(String::new());
    }

    let def = default_category(rules);
    lines.push("## Important".to_string());
    lines.push("- Score ALL listed rules, even if the score is 0.0.".to_string());
    lines.push("- `issuer` is the entity that created/sent the document (e.g. a bank, employer, or utility company).".to_string());
    lines.push("- `tags` should be 2–5 short keywords relevant to the document content.".to_string());
    lines.push("- `doc_date` must be YYYY-MM-DD format (e.g. \"2024-03-15\") or an empty string.".to_string());
    lines.push(format!(
        "- For the `description` field, if you are unsure of the document type classify it as \"{def}\"."
    ));
    lines.push("- Respond with ONLY the JSON object — no prose, no markdown fences.".to_string());

    lines.join("\n")
}
