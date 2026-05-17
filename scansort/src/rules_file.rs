//! External rules-file storage.
//!
//! The rules file is a plaintext JSON document that lives either next to the
//! vault (sibling override: `<stem>.rules.json`) or at a user-level path
//! provided by the host. Schema mirrors the experiment's
//! `user://scansort_rules.json` format so files port forward.

use crate::db;
use crate::types::{now_iso, ConditionNode, Rule, Stage, Subtype, VaultError, VaultResult};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const CURRENT_SCHEMA_VERSION: i64 = 2;
pub const DEFAULT_CATEGORY: &str = "memories";
pub const DEFAULT_CONFIDENCE_THRESHOLD: f64 = 0.6;
pub const DEFAULT_RENAME_PATTERN: &str = "{date}_{issuer}_{description}";

// ---------------------------------------------------------------------------
// FileRule — per-rule shape in the JSON file (no rule_id; PK is the label).
// ---------------------------------------------------------------------------

fn default_threshold() -> f64 {
    DEFAULT_CONFIDENCE_THRESHOLD
}
fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FileRule {
    pub label: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub instruction: String,
    /// Deprecated by DCR 019e33bf (W1). Read on load for legacy compatibility;
    /// `skip_serializing_if` keeps the field out of migrated/new files.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signals: Vec<String>,
    #[serde(default)]
    pub subfolder: String,
    #[serde(default)]
    pub rename_pattern: String,
    #[serde(default = "default_threshold")]
    pub confidence_threshold: f64,
    #[serde(default)]
    pub encrypt: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub is_default: bool,
    /// Deterministic gate evaluated before LLM-based classification applies this rule.
    /// W1 stores this only; evaluation is a later work-item.
    #[serde(default)]
    pub conditions: Option<ConditionNode>,
    /// When this evaluates true, the rule match is negated.
    /// W1 stores this only; evaluation is a later work-item.
    #[serde(default)]
    pub exceptions: Option<ConditionNode>,
    /// Explicit ordering key — lower values sort first. Default 0.
    #[serde(default)]
    pub order: i64,
    /// When true, stop evaluating subsequent rules after this one matches.
    #[serde(default)]
    pub stop_processing: bool,
    /// Additional destination IDs to copy the document to.
    /// W1 stores as opaque strings; resolution is a later work-item.
    #[serde(default)]
    pub copy_to: Vec<String>,
    /// Document subtypes within this rule (B8 doc_type normalization).
    ///
    /// Deprecated by DCR 019e33bf (W1). Kept on the on-disk shape during the
    /// W1+W5 transition window so legacy `library.rules.json` files still
    /// deserialize before W5's migration rewrites them into `stages`. W2
    /// removes this field after engine adaptation.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subtypes: Vec<Subtype>,
    /// W1 (DCR 019e33bf): per-rule classification pipeline. Each stage is one
    /// LLM round. Empty until W5 migration runs (for legacy files) or until
    /// new rules are authored via the focused-chat skill (W9).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stages: Vec<Stage>,
}

impl From<Rule> for FileRule {
    fn from(r: Rule) -> Self {
        FileRule {
            label: r.label,
            name: r.name,
            instruction: r.instruction,
            signals: r.signals,
            subfolder: r.subfolder,
            rename_pattern: r.rename_pattern,
            confidence_threshold: r.confidence_threshold,
            encrypt: r.encrypt,
            enabled: r.enabled,
            is_default: r.is_default,
            conditions: r.conditions,
            exceptions: r.exceptions,
            order: r.order,
            stop_processing: r.stop_processing,
            copy_to: r.copy_to,
            subtypes: r.subtypes,
            stages: r.stages,
        }
    }
}

impl FileRule {
    /// Reject duplicate `classify` slot names across stages (DCR 019e33bf
    /// invariant). Returns the first offending slot in its error message;
    /// call this from any insert/upsert path before persisting.
    pub fn validate(&self) -> VaultResult<()> {
        let mut seen: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
        for (i, stage) in self.stages.iter().enumerate() {
            for slot_name in stage.classify.keys() {
                if let Some(&prev) = seen.get(slot_name.as_str()) {
                    return Err(VaultError::new(format!(
                        "slot name '{}' is declared in stage {} but already declared in stage {}; \
                         classify slot names must be unique across all stages of a rule",
                        slot_name, i, prev
                    )));
                }
                seen.insert(slot_name.as_str(), i);
            }
        }
        Ok(())
    }

    /// Convert into the in-memory Rule shape used by classifier helpers.
    /// `rule_id` is 0 since rules from a file don't have a SQLite PK.
    pub fn into_rule(self) -> Rule {
        Rule {
            rule_id: 0,
            label: self.label,
            name: self.name,
            instruction: self.instruction,
            signals: self.signals,
            subfolder: self.subfolder,
            rename_pattern: self.rename_pattern,
            confidence_threshold: self.confidence_threshold,
            encrypt: self.encrypt,
            enabled: self.enabled,
            is_default: self.is_default,
            conditions: self.conditions,
            exceptions: self.exceptions,
            order: self.order,
            stop_processing: self.stop_processing,
            copy_to: self.copy_to,
            subtypes: self.subtypes,
            stages: self.stages,
        }
    }
}

// ---------------------------------------------------------------------------
// RulesFile — top-level JSON document.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RulesFile {
    pub schema_version: i64,
    pub default_category: String,
    pub confidence_threshold: f64,
    pub rename_pattern: String,
    pub rules: Vec<FileRule>,
}

impl Default for RulesFile {
    fn default() -> Self {
        Self {
            schema_version: CURRENT_SCHEMA_VERSION,
            default_category: DEFAULT_CATEGORY.to_string(),
            confidence_threshold: DEFAULT_CONFIDENCE_THRESHOLD,
            rename_pattern: DEFAULT_RENAME_PATTERN.to_string(),
            rules: Vec::new(),
        }
    }
}

impl RulesFile {
    /// Convert the file's rules into the `Rule` shape used by classifier helpers.
    pub fn to_rules(&self) -> Vec<Rule> {
        self.rules.iter().cloned().map(FileRule::into_rule).collect()
    }
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

/// Read and parse a rules file from disk.
pub fn load(path: &Path) -> VaultResult<RulesFile> {
    let text = fs::read_to_string(path).map_err(|e| {
        VaultError::new(format!(
            "Cannot read rules file {}: {}",
            path.display(),
            e
        ))
    })?;
    let file: RulesFile = serde_json::from_str(&text).map_err(|e| {
        VaultError::new(format!(
            "Invalid rules JSON at {}: {}",
            path.display(),
            e
        ))
    })?;
    if file.schema_version > CURRENT_SCHEMA_VERSION {
        return Err(VaultError::new(format!(
            "Rules file schema_version {} is newer than supported version {}",
            file.schema_version, CURRENT_SCHEMA_VERSION
        )));
    }
    Ok(file)
}

/// Write a rules file to disk as pretty-printed UTF-8 JSON.
/// Creates parent directories as needed.
pub fn save(path: &Path, file: &RulesFile) -> VaultResult<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    let text = serde_json::to_string_pretty(file)?;
    fs::write(path, text)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/// The sibling rules path for a given vault: `<stem>.rules.json` next to it.
/// Does not check existence.
pub fn sibling_path(vault_path: &Path) -> PathBuf {
    // parent() returns Some("") for bare filenames, not None — treat both the same.
    let parent = match vault_path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    let stem = vault_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("vault");
    parent.join(format!("{stem}.rules.json"))
}

/// Resolve the rules file path for a vault.
///
/// Order:
/// 1. Sibling `<stem>.rules.json` next to the vault.
/// 2. `user_level` if provided and existing.
///
/// Returns the first existing path, or None if no rules file is found.
pub fn resolve_for_vault(vault_path: &Path, user_level: Option<&Path>) -> Option<PathBuf> {
    let sib = sibling_path(vault_path);
    if sib.exists() {
        return Some(sib);
    }
    if let Some(u) = user_level {
        if u.exists() {
            return Some(u.to_path_buf());
        }
    }
    None
}

/// Load the resolved rules for a vault. Returns the (path, parsed file) pair.
/// Errors with a clear message if no rules file exists at either location.
pub fn load_for_vault(
    vault_path: &Path,
    user_level: Option<&Path>,
) -> VaultResult<(PathBuf, RulesFile)> {
    let path = resolve_for_vault(vault_path, user_level).ok_or_else(|| {
        VaultError::new(format!(
            "No rules file found. Expected sibling `{}` or user-level rules file. \
             Open the rules editor to add one.",
            sibling_path(vault_path).display()
        ))
    })?;
    let file = load(&path)?;
    Ok((path, file))
}

// ---------------------------------------------------------------------------
// CRUD helpers — used by the MCP tool handlers
// ---------------------------------------------------------------------------

/// Load a rules file from disk, or return a default empty file if the path
/// doesn't exist. Used by MCP handlers when the user is starting a new
/// rules set — the first `insert_rule` should just-work without a prior
/// explicit `create` step.
///
/// Existing files still validate normally (schema_version check, JSON parse).
pub fn load_or_init(path: &Path) -> VaultResult<RulesFile> {
    if path.exists() {
        load(path)
    } else {
        Ok(RulesFile::default())
    }
}

/// Find the index of a rule by label. Returns None if no match.
pub fn index_of(file: &RulesFile, label: &str) -> Option<usize> {
    file.rules.iter().position(|r| r.label == label)
}

/// Insert a rule (or replace existing rule with the same label).
/// Returns the resulting index.
pub fn upsert(file: &mut RulesFile, rule: FileRule) -> usize {
    match index_of(file, &rule.label) {
        Some(i) => {
            file.rules[i] = rule;
            i
        }
        None => {
            file.rules.push(rule);
            file.rules.len() - 1
        }
    }
}

/// Remove a rule by label. Returns true if a rule was removed, false if
/// no rule with that label existed.
pub fn remove(file: &mut RulesFile, label: &str) -> bool {
    match index_of(file, label) {
        Some(i) => {
            file.rules.remove(i);
            true
        }
        None => false,
    }
}

// ---------------------------------------------------------------------------
// R5: Vault → Sibling rules migration
// ---------------------------------------------------------------------------

/// Outcome of `migrate_embedded_to_sibling` — what the legacy-rules export
/// step did (or didn't do) for a given vault.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum MigrationOutcome {
    /// The embedded `rules` table had no rows — nothing to migrate.
    NoLegacyRules,
    /// Wrote N rules from the embedded table to a brand-new sibling file.
    Exported { count: usize, sibling: PathBuf },
    /// Sibling exists and contains an equivalent rule set — no action.
    SiblingMatches { sibling: PathBuf },
    /// Sibling exists and diverges from the embedded table.
    /// Caller (UI) decides how to resolve. Leaves both stores untouched.
    Divergent {
        sibling: PathBuf,
        embedded_count: usize,
        sibling_count: usize,
    },
}

/// Read the legacy embedded `rules` table directly from a vault connection
/// and convert to FileRule shape. Used by `migrate_embedded_to_sibling`.
fn read_embedded_rules(conn: &Connection) -> VaultResult<Vec<FileRule>> {
    let mut stmt = conn.prepare(
        "SELECT label, name, instruction, signals, subfolder, rename_pattern, \
         confidence_threshold, encrypt, enabled, is_default \
         FROM rules ORDER BY rule_id",
    )?;
    let rows = stmt.query_map([], |row| {
        let signals_raw: Option<String> = row.get("signals")?;
        let signals: Vec<String> = signals_raw
            .map(|s| db::parse_json_array(&s))
            .unwrap_or_default();
        Ok(FileRule {
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
            // New v2 fields — not present in legacy embedded table; use defaults.
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
            subtypes: Vec::new(),
            stages: Vec::new(),
        })
    })?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// Compare a sibling file's rules with the embedded table's rules.
///
/// Returns true if they diverge in any content field. Order is ignored
/// (compared by label). rule_id is ignored (file format has no PK).
fn rules_diverge(file_rules: &[FileRule], embedded: &[FileRule]) -> bool {
    if file_rules.len() != embedded.len() {
        return true;
    }
    let mut by_label: std::collections::HashMap<&str, &FileRule> =
        std::collections::HashMap::new();
    for r in file_rules {
        by_label.insert(r.label.as_str(), r);
    }
    for er in embedded {
        match by_label.get(er.label.as_str()) {
            None => return true,
            Some(fr) => {
                if fr.name != er.name
                    || fr.instruction != er.instruction
                    || fr.signals != er.signals
                    || fr.subfolder != er.subfolder
                    || fr.rename_pattern != er.rename_pattern
                    || (fr.confidence_threshold - er.confidence_threshold).abs() > 1e-9
                    || fr.encrypt != er.encrypt
                    || fr.enabled != er.enabled
                    || fr.is_default != er.is_default
                {
                    return true;
                }
            }
        }
    }
    false
}

/// On first 1.1.0 open of a legacy vault, export the embedded `rules` table
/// to the sibling `<vault-stem>.rules.json` (if it doesn't yet exist).
///
/// Behavior:
/// - No legacy rules → returns NoLegacyRules, no side-effects.
/// - Sibling doesn't exist → writes it, records `rules_exported_at`/
///   `rules_exported_to` in project keys, returns Exported.
/// - Sibling exists and matches → records `rules_exported_at`, returns SiblingMatches.
/// - Sibling exists and diverges → records `rules_divergence_detected*` project
///   keys, returns Divergent. Caller (UI) decides resolution.
///
/// The embedded `rules` table is left in place in all cases — it remains
/// readable by deprecated tools and external SQLite browsers.
pub fn migrate_embedded_to_sibling(
    conn: &Connection,
    vault_path: &str,
) -> VaultResult<MigrationOutcome> {
    if vault_path.is_empty() {
        return Ok(MigrationOutcome::NoLegacyRules);
    }
    let embedded = read_embedded_rules(conn)?;
    if embedded.is_empty() {
        return Ok(MigrationOutcome::NoLegacyRules);
    }

    let sibling = sibling_path(Path::new(vault_path));

    if !sibling.exists() {
        let mut file = RulesFile::default();
        for r in embedded.iter().cloned() {
            file.rules.push(r);
        }
        let count = file.rules.len();
        save(&sibling, &file)?;
        db::set_project_key(conn, "rules_exported_at", &now_iso())?;
        db::set_project_key(conn, "rules_exported_to", &sibling.to_string_lossy())?;
        return Ok(MigrationOutcome::Exported { count, sibling });
    }

    // Sibling exists — compare for divergence.
    match load(&sibling) {
        Ok(existing) => {
            if rules_diverge(&existing.rules, &embedded) {
                db::set_project_key(conn, "rules_divergence_detected", "true")?;
                db::set_project_key(conn, "rules_divergence_detected_at", &now_iso())?;
                db::set_project_key(conn, "rules_divergence_sibling", &sibling.to_string_lossy())?;
                Ok(MigrationOutcome::Divergent {
                    sibling,
                    embedded_count: embedded.len(),
                    sibling_count: existing.rules.len(),
                })
            } else {
                // No-op match — mark export step as completed.
                db::set_project_key(conn, "rules_exported_at", &now_iso())?;
                db::set_project_key(conn, "rules_exported_to", &sibling.to_string_lossy())?;
                Ok(MigrationOutcome::SiblingMatches { sibling })
            }
        }
        Err(_) => {
            // Sibling exists but failed to parse — treat as divergent so the UI
            // can prompt the user; don't overwrite a potentially-edited file
            // the user cares about.
            db::set_project_key(conn, "rules_divergence_detected", "true")?;
            db::set_project_key(conn, "rules_divergence_detected_at", &now_iso())?;
            db::set_project_key(conn, "rules_divergence_sibling", &sibling.to_string_lossy())?;
            Ok(MigrationOutcome::Divergent {
                sibling,
                embedded_count: embedded.len(),
                sibling_count: 0,
            })
        }
    }
}

// ---------------------------------------------------------------------------
// Snapshot construction
// ---------------------------------------------------------------------------

/// Find a rule by label in the loaded file (case-sensitive exact match).
pub fn find_by_label<'a>(rules: &'a [FileRule], label: &str) -> Option<&'a FileRule> {
    rules.iter().find(|r| r.label == label)
}

/// Build the `documents.rule_snapshot` JSON for a resolved rule.
///
/// Output shape (single-line JSON, stable field order via the inline struct):
/// ```json
/// {
///   "label": "...",
///   "name": "...",
///   "instruction": "...",
///   "signals": [...],
///   "subfolder": "...",
///   "confidence_threshold": 0.7,
///   "snapshot_hash": "<sha256 hex>",
///   "snapshot_at": "<iso>"
/// }
/// ```
///
/// `snapshot_hash` is SHA-256 of the canonical JSON of the rule's
/// content fields (label..confidence_threshold). It is stable across runs and
/// across machines, so two documents classified by the same rule revision
/// share a hash.
pub fn build_snapshot(rule: &FileRule) -> String {
    use sha2::{Digest, Sha256};

    // Canonical content blob — drives the hash. Field order is fixed by the
    // struct definition, which acts as the canonicalization rule.
    #[derive(serde::Serialize)]
    struct Canonical<'a> {
        label: &'a str,
        name: &'a str,
        instruction: &'a str,
        signals: &'a [String],
        subfolder: &'a str,
        confidence_threshold: f64,
    }
    let canon = Canonical {
        label: &rule.label,
        name: &rule.name,
        instruction: &rule.instruction,
        signals: &rule.signals,
        subfolder: &rule.subfolder,
        confidence_threshold: rule.confidence_threshold,
    };
    let canon_json =
        serde_json::to_string(&canon).unwrap_or_else(|_| String::from("{}"));
    let hash = Sha256::digest(canon_json.as_bytes());
    let snapshot_hash = format!("{:x}", hash);
    let snapshot_at = crate::types::now_iso();

    // Output blob — includes the hash and timestamp on top of the canonical fields.
    #[derive(serde::Serialize)]
    struct Snapshot<'a> {
        label: &'a str,
        name: &'a str,
        instruction: &'a str,
        signals: &'a [String],
        subfolder: &'a str,
        confidence_threshold: f64,
        snapshot_hash: String,
        snapshot_at: String,
    }
    let snap = Snapshot {
        label: &rule.label,
        name: &rule.name,
        instruction: &rule.instruction,
        signals: &rule.signals,
        subfolder: &rule.subfolder,
        confidence_threshold: rule.confidence_threshold,
        snapshot_hash,
        snapshot_at,
    };
    serde_json::to_string(&snap).unwrap_or_else(|_| String::from("{}"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
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
        std::env::temp_dir().join(format!("scansort-rulesfile-{prefix}-{pid}-{ts}-{n}"))
    }

    fn sample_rule(label: &str) -> FileRule {
        FileRule {
            label: label.to_string(),
            name: format!("Rule {label}"),
            instruction: format!("Match {label} documents."),
            signals: vec!["alpha".to_string(), "beta".to_string()],
            subfolder: format!("out/{label}"),
            rename_pattern: String::new(),
            confidence_threshold: 0.7,
            encrypt: false,
            enabled: true,
            is_default: label == "memories",
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
            subtypes: Vec::new(),
            stages: Vec::new(),
        }
    }

    fn sample_file() -> RulesFile {
        RulesFile {
            schema_version: 1,
            default_category: "memories".to_string(),
            confidence_threshold: 0.6,
            rename_pattern: "{date}_{sender}_{description}".to_string(),
            rules: vec![sample_rule("tax_w2"), sample_rule("memories")],
        }
    }

    #[test]
    fn round_trip_save_then_load_preserves_content() {
        let dir = unique_tmp("roundtrip");
        let path = dir.join("scansort_rules.json");

        let written = sample_file();
        save(&path, &written).expect("save");
        let read = load(&path).expect("load");

        assert_eq!(read.schema_version, written.schema_version);
        assert_eq!(read.default_category, written.default_category);
        assert_eq!(read.rules.len(), 2);
        assert_eq!(read.rules[0].label, "tax_w2");
        assert_eq!(read.rules[0].signals, vec!["alpha", "beta"]);
        assert!(read.rules[1].is_default);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_rejects_future_schema_version() {
        let dir = unique_tmp("future");
        let path = dir.join("rules.json");
        let mut f = sample_file();
        f.schema_version = 99;
        save(&path, &f).expect("save");

        let err = load(&path).expect_err("should reject future version");
        assert!(err.to_string().contains("schema_version 99"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_returns_helpful_error_on_invalid_json() {
        let dir = unique_tmp("invalid");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rules.json");
        fs::write(&path, "{ not valid json").unwrap();

        let err = load(&path).expect_err("should fail to parse");
        assert!(err.to_string().contains("Invalid rules JSON"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_returns_helpful_error_on_missing_file() {
        let path = unique_tmp("missing").join("rules.json");
        let err = load(&path).expect_err("should fail to read");
        assert!(err.to_string().contains("Cannot read rules file"));
    }

    #[test]
    fn deserializes_minimal_rule_with_defaults() {
        let json = r#"{
            "schema_version": 1,
            "default_category": "memories",
            "confidence_threshold": 0.6,
            "rename_pattern": "x",
            "rules": [{"label": "bare"}]
        }"#;
        let f: RulesFile = serde_json::from_str(json).expect("parse");
        let r = &f.rules[0];
        assert_eq!(r.label, "bare");
        assert_eq!(r.name, "");
        assert_eq!(r.confidence_threshold, DEFAULT_CONFIDENCE_THRESHOLD);
        assert!(r.enabled, "enabled should default to true");
        assert!(!r.is_default);
        assert!(!r.encrypt);
    }

    #[test]
    fn sibling_path_appends_rules_json_to_stem() {
        let v = Path::new("/tmp/archives/taxes_2024.ssort");
        assert_eq!(
            sibling_path(v),
            PathBuf::from("/tmp/archives/taxes_2024.rules.json")
        );
    }

    #[test]
    fn sibling_path_handles_vault_with_no_parent() {
        let v = Path::new("taxes.ssort");
        assert_eq!(sibling_path(v), PathBuf::from("./taxes.rules.json"));
    }

    #[test]
    fn resolve_prefers_sibling_over_user_level() {
        let dir = unique_tmp("resolve_sibling");
        fs::create_dir_all(&dir).unwrap();
        let vault = dir.join("v.ssort");
        let sib = dir.join("v.rules.json");
        let user = dir.join("user_rules.json");
        save(&sib, &sample_file()).expect("save sibling");
        save(&user, &sample_file()).expect("save user");

        let resolved = resolve_for_vault(&vault, Some(&user)).expect("found");
        assert_eq!(resolved, sib, "sibling must win over user-level");

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn resolve_falls_back_to_user_level_when_no_sibling() {
        let dir = unique_tmp("resolve_user");
        fs::create_dir_all(&dir).unwrap();
        let vault = dir.join("v.ssort");
        let user = dir.join("user_rules.json");
        save(&user, &sample_file()).expect("save user");

        let resolved = resolve_for_vault(&vault, Some(&user)).expect("found");
        assert_eq!(resolved, user);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn resolve_returns_none_when_neither_layer_exists() {
        let dir = unique_tmp("resolve_none");
        let vault = dir.join("v.ssort"); // dir doesn't exist
        let user = dir.join("user_rules.json"); // doesn't exist
        assert!(resolve_for_vault(&vault, Some(&user)).is_none());
        assert!(resolve_for_vault(&vault, None).is_none());
    }

    #[test]
    fn load_for_vault_returns_clear_error_when_nothing_found() {
        let dir = unique_tmp("none_error");
        let vault = dir.join("v.ssort");
        let err = load_for_vault(&vault, None).expect_err("should fail");
        let msg = err.to_string();
        assert!(msg.contains("No rules file found"));
        assert!(msg.contains("v.rules.json"), "msg should name sibling path: {msg}");
    }

    #[test]
    fn file_rule_round_trips_through_rule_struct() {
        let fr = sample_rule("tax_w2");
        let r = fr.clone().into_rule();
        assert_eq!(r.rule_id, 0, "file-sourced rules have no PK");
        assert_eq!(r.label, "tax_w2");
        assert_eq!(r.signals, vec!["alpha", "beta"]);
        let fr2: FileRule = FileRule::from(r);
        assert_eq!(fr2.label, fr.label);
        assert_eq!(fr2.confidence_threshold, fr.confidence_threshold);
    }

    #[test]
    fn to_rules_converts_all_entries() {
        let f = sample_file();
        let rules = f.to_rules();
        assert_eq!(rules.len(), 2);
        assert_eq!(rules[0].label, "tax_w2");
        assert!(rules[1].is_default);
    }

    #[test]
    fn save_creates_parent_directories() {
        let dir = unique_tmp("nested");
        let path = dir.join("a/b/c/rules.json");
        save(&path, &sample_file()).expect("save with nested dirs");
        assert!(path.exists());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn find_by_label_returns_matching_rule() {
        let f = sample_file();
        let found = find_by_label(&f.rules, "tax_w2").expect("found");
        assert_eq!(found.label, "tax_w2");
    }

    #[test]
    fn find_by_label_returns_none_for_unknown_label() {
        let f = sample_file();
        assert!(find_by_label(&f.rules, "no_such_thing").is_none());
    }

    #[test]
    fn build_snapshot_yields_valid_json_with_expected_fields() {
        let r = sample_rule("tax_w2");
        let snap = build_snapshot(&r);
        let v: serde_json::Value = serde_json::from_str(&snap).expect("parse snapshot");
        assert_eq!(v["label"], "tax_w2");
        assert_eq!(v["name"], "Rule tax_w2");
        assert_eq!(v["confidence_threshold"], 0.7);
        assert!(v["signals"].is_array());
        let hash = v["snapshot_hash"].as_str().expect("snapshot_hash");
        assert_eq!(hash.len(), 64, "sha256 hex should be 64 chars");
        let ts = v["snapshot_at"].as_str().expect("snapshot_at");
        assert!(!ts.is_empty());
    }

    #[test]
    fn build_snapshot_hash_is_stable_across_calls_for_same_rule() {
        let r = sample_rule("tax_w2");
        let s1: serde_json::Value = serde_json::from_str(&build_snapshot(&r)).unwrap();
        let s2: serde_json::Value = serde_json::from_str(&build_snapshot(&r)).unwrap();
        assert_eq!(
            s1["snapshot_hash"], s2["snapshot_hash"],
            "identical rule must produce identical snapshot_hash across calls"
        );
        // snapshot_at differs across calls — that's by design.
    }

    #[test]
    fn build_snapshot_hash_differs_for_different_rules() {
        let r1 = sample_rule("tax_w2");
        let r2 = sample_rule("memories");
        let s1: serde_json::Value = serde_json::from_str(&build_snapshot(&r1)).unwrap();
        let s2: serde_json::Value = serde_json::from_str(&build_snapshot(&r2)).unwrap();
        assert_ne!(s1["snapshot_hash"], s2["snapshot_hash"]);
    }

    #[test]
    fn load_or_init_returns_default_for_missing_path() {
        let path = unique_tmp("loadinit_missing").join("rules.json");
        let f = load_or_init(&path).expect("default");
        assert_eq!(f.schema_version, CURRENT_SCHEMA_VERSION);
        assert!(f.rules.is_empty());
    }

    #[test]
    fn load_or_init_returns_existing_for_existing_path() {
        let dir = unique_tmp("loadinit_existing");
        let path = dir.join("rules.json");
        save(&path, &sample_file()).expect("save");
        let f = load_or_init(&path).expect("load");
        assert_eq!(f.rules.len(), 2);
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn upsert_appends_new_rule_when_label_absent() {
        let mut f = RulesFile::default();
        let idx = upsert(&mut f, sample_rule("new_rule"));
        assert_eq!(idx, 0);
        assert_eq!(f.rules.len(), 1);
        assert_eq!(f.rules[0].label, "new_rule");
    }

    #[test]
    fn upsert_replaces_existing_rule_with_same_label() {
        let mut f = sample_file();
        let original_count = f.rules.len();
        let mut updated = sample_rule("tax_w2");
        updated.instruction = "REPLACED INSTRUCTION".to_string();
        upsert(&mut f, updated);
        assert_eq!(f.rules.len(), original_count, "count must not grow on replace");
        let r = find_by_label(&f.rules, "tax_w2").expect("found");
        assert_eq!(r.instruction, "REPLACED INSTRUCTION");
    }

    #[test]
    fn remove_returns_true_and_drops_rule_when_label_present() {
        let mut f = sample_file();
        assert!(remove(&mut f, "tax_w2"));
        assert!(find_by_label(&f.rules, "tax_w2").is_none());
    }

    #[test]
    fn remove_returns_false_when_label_absent() {
        let mut f = sample_file();
        assert!(!remove(&mut f, "no_such_label"));
        assert_eq!(f.rules.len(), 2);
    }

    /// R3+R4 vertical slice: simulate what the insert_rule MCP handler does
    /// (write a rule via load_or_init+upsert+save), then run the resolution
    /// path that classify_document uses (load_for_vault) and confirm the
    /// rule round-trips with content intact. Catches any breakage in the
    /// file-format ↔ resolution-path contract.
    #[test]
    fn integration_r3_plus_r4_write_then_classify_resolves() {
        let dir = unique_tmp("integration_r3r4");
        fs::create_dir_all(&dir).unwrap();
        let vault_path = dir.join("v.ssort");
        // (vault file doesn't need to exist — resolve_for_vault only checks paths)
        let sibling = sibling_path(&vault_path);

        // Step 1: insert_rule MCP handler behavior
        let mut file = load_or_init(&sibling).expect("init");
        upsert(&mut file, sample_rule("school"));
        upsert(&mut file, sample_rule("receipt"));
        upsert(&mut file, sample_rule("memories")); // is_default
        save(&sibling, &file).expect("save");

        // Step 2: classify_document path — resolve + load + lookup by label
        let (resolved_path, loaded) =
            load_for_vault(&vault_path, None).expect("load_for_vault");
        assert_eq!(resolved_path, sibling, "resolution must hit the sibling we just wrote");
        assert_eq!(loaded.rules.len(), 3);

        // Step 3: build_snapshot for a hypothetical LLM-returned label
        let resolved_rule = find_by_label(&loaded.rules, "school").expect("school rule");
        let snapshot = build_snapshot(resolved_rule);
        let parsed: serde_json::Value = serde_json::from_str(&snapshot).unwrap();
        assert_eq!(parsed["label"], "school");
        assert_eq!(parsed["confidence_threshold"], 0.7);
        assert!(parsed["snapshot_hash"].as_str().unwrap().len() == 64);

        fs::remove_dir_all(&dir).ok();
    }

    // ----- R5: migrate_embedded_to_sibling tests --------------------------

    /// Create an in-memory SQLite with the legacy rules schema and seed it
    /// with the given rules. Used to simulate a pre-1.1.0 vault.
    fn legacy_vault_with_rules(rows: &[(&str, &str, &[&str])]) -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE project (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE rules (
                rule_id INTEGER PRIMARY KEY AUTOINCREMENT,
                label TEXT UNIQUE NOT NULL,
                name TEXT,
                instruction TEXT,
                signals TEXT,
                subfolder TEXT,
                rename_pattern TEXT DEFAULT '',
                confidence_threshold REAL DEFAULT 0.6,
                encrypt INTEGER DEFAULT 0,
                enabled INTEGER DEFAULT 1,
                is_default INTEGER DEFAULT 0
            );
            "#,
        )
        .unwrap();
        for (label, instruction, signals) in rows {
            let signals_json = serde_json::to_string(signals).unwrap();
            conn.execute(
                "INSERT INTO rules (label, name, instruction, signals, subfolder, \
                 rename_pattern, confidence_threshold, encrypt, enabled, is_default) \
                 VALUES (?1, ?1, ?2, ?3, '', '', 0.6, 0, 1, 0)",
                rusqlite::params![label, instruction, signals_json],
            )
            .unwrap();
        }
        conn
    }

    #[test]
    fn migrate_with_empty_rules_returns_no_legacy_rules() {
        let conn = legacy_vault_with_rules(&[]);
        let dir = unique_tmp("mig_empty");
        fs::create_dir_all(&dir).unwrap();
        let vault = dir.join("v.ssort");
        let outcome =
            migrate_embedded_to_sibling(&conn, vault.to_str().unwrap()).expect("migrate");
        assert_eq!(outcome, MigrationOutcome::NoLegacyRules);
        assert!(!sibling_path(&vault).exists());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn migrate_writes_sibling_when_absent_and_records_keys() {
        let conn = legacy_vault_with_rules(&[
            ("school", "School materials", &["chapter", "homework"]),
            ("receipt", "Purchase receipts", &["total", "subtotal"]),
        ]);
        let dir = unique_tmp("mig_export");
        fs::create_dir_all(&dir).unwrap();
        let vault = dir.join("v.ssort");
        let sibling = sibling_path(&vault);
        assert!(!sibling.exists());

        let outcome =
            migrate_embedded_to_sibling(&conn, vault.to_str().unwrap()).expect("migrate");
        match outcome {
            MigrationOutcome::Exported { count, sibling: out_sib } => {
                assert_eq!(count, 2);
                assert_eq!(out_sib, sibling);
            }
            other => panic!("expected Exported, got: {other:?}"),
        }
        assert!(sibling.exists(), "sibling file must be written");

        let loaded = load(&sibling).expect("load");
        assert_eq!(loaded.rules.len(), 2);
        let labels: Vec<&str> = loaded.rules.iter().map(|r| r.label.as_str()).collect();
        assert!(labels.contains(&"school"));
        assert!(labels.contains(&"receipt"));

        // Project keys recorded the export.
        assert!(db::get_project_key(&conn, "rules_exported_at").unwrap().is_some());
        assert_eq!(
            db::get_project_key(&conn, "rules_exported_to").unwrap().as_deref(),
            Some(sibling.to_str().unwrap()),
        );
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn migrate_detects_sibling_matches_and_does_not_overwrite() {
        let conn = legacy_vault_with_rules(&[
            ("school", "School materials", &["chapter"]),
        ]);
        let dir = unique_tmp("mig_match");
        fs::create_dir_all(&dir).unwrap();
        let vault = dir.join("v.ssort");
        let sibling = sibling_path(&vault);

        // Pre-populate sibling with the SAME content as the embedded table.
        let pre_existing = RulesFile {
            schema_version: 1,
            default_category: "memories".to_string(),
            confidence_threshold: 0.6,
            rename_pattern: "{date}_{sender}_{description}".to_string(),
            rules: vec![FileRule {
                label: "school".to_string(),
                name: "school".to_string(),
                instruction: "School materials".to_string(),
                signals: vec!["chapter".to_string()],
                subfolder: String::new(),
                rename_pattern: String::new(),
                confidence_threshold: 0.6,
                encrypt: false,
                enabled: true,
                is_default: false,
                conditions: None,
                exceptions: None,
                order: 0,
                stop_processing: false,
                copy_to: Vec::new(),
                subtypes: Vec::new(),
                stages: Vec::new(),
            }],
        };
        save(&sibling, &pre_existing).unwrap();
        let mtime_before = fs::metadata(&sibling).unwrap().modified().unwrap();

        let outcome =
            migrate_embedded_to_sibling(&conn, vault.to_str().unwrap()).expect("migrate");
        assert_eq!(outcome, MigrationOutcome::SiblingMatches { sibling: sibling.clone() });

        // Sibling unchanged on disk.
        let mtime_after = fs::metadata(&sibling).unwrap().modified().unwrap();
        assert_eq!(mtime_before, mtime_after, "matching sibling must not be rewritten");
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn migrate_detects_divergence_and_records_marker_keys() {
        let conn = legacy_vault_with_rules(&[
            ("school", "EMBEDDED instruction", &["chapter"]),
        ]);
        let dir = unique_tmp("mig_diverge");
        fs::create_dir_all(&dir).unwrap();
        let vault = dir.join("v.ssort");
        let sibling = sibling_path(&vault);

        // Pre-populate sibling with DIFFERENT instruction.
        let diverging = RulesFile {
            schema_version: 1,
            default_category: "memories".to_string(),
            confidence_threshold: 0.6,
            rename_pattern: String::new(),
            rules: vec![FileRule {
                label: "school".to_string(),
                name: "school".to_string(),
                instruction: "SIBLING instruction (user-edited)".to_string(),
                signals: vec!["chapter".to_string()],
                subfolder: String::new(),
                rename_pattern: String::new(),
                confidence_threshold: 0.6,
                encrypt: false,
                enabled: true,
                is_default: false,
                stages: Vec::new(),
                conditions: None,
                exceptions: None,
                order: 0,
                stop_processing: false,
                copy_to: Vec::new(),
                subtypes: Vec::new(),
            }],
        };
        save(&sibling, &diverging).unwrap();

        let outcome =
            migrate_embedded_to_sibling(&conn, vault.to_str().unwrap()).expect("migrate");
        match outcome {
            MigrationOutcome::Divergent { embedded_count, sibling_count, .. } => {
                assert_eq!(embedded_count, 1);
                assert_eq!(sibling_count, 1);
            }
            other => panic!("expected Divergent, got: {other:?}"),
        }
        // Sibling untouched.
        let after = load(&sibling).expect("reload");
        assert_eq!(after.rules[0].instruction, "SIBLING instruction (user-edited)");
        // Markers recorded.
        assert_eq!(
            db::get_project_key(&conn, "rules_divergence_detected").unwrap().as_deref(),
            Some("true"),
        );
        assert!(db::get_project_key(&conn, "rules_divergence_detected_at").unwrap().is_some());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn migrate_with_empty_vault_path_is_a_noop() {
        let conn = legacy_vault_with_rules(&[("anything", "x", &[])]);
        let outcome = migrate_embedded_to_sibling(&conn, "").expect("migrate");
        assert_eq!(outcome, MigrationOutcome::NoLegacyRules);
    }

    #[test]
    fn build_snapshot_hash_changes_when_instruction_changes() {
        let mut r = sample_rule("tax_w2");
        let h1 = serde_json::from_str::<serde_json::Value>(&build_snapshot(&r))
            .unwrap()["snapshot_hash"]
            .as_str()
            .unwrap()
            .to_string();
        r.instruction = format!("{} more text", r.instruction);
        let h2 = serde_json::from_str::<serde_json::Value>(&build_snapshot(&r))
            .unwrap()["snapshot_hash"]
            .as_str()
            .unwrap()
            .to_string();
        assert_ne!(h1, h2, "editing instruction must change the hash");
    }

    // =========================================================================
    // W1: ConditionNode round-trip tests
    // =========================================================================

    #[test]
    fn condition_node_predicate_round_trips() {
        use crate::types::ConditionNode;
        let json = r#"{"field":"year","op":"equals","value":"2024"}"#;
        let node: ConditionNode = serde_json::from_str(json).expect("parse predicate");
        match &node {
            ConditionNode::Predicate { field, op, value } => {
                assert_eq!(field, "year");
                assert_eq!(op, "equals");
                assert_eq!(value, "2024");
            }
            other => panic!("expected Predicate, got {:?}", other),
        }
        let back = serde_json::to_string(&node).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&back).unwrap();
        assert_eq!(reparsed["field"], "year");
        assert_eq!(reparsed["op"], "equals");
        assert_eq!(reparsed["value"], "2024");
    }

    #[test]
    fn condition_node_all_round_trips() {
        use crate::types::ConditionNode;
        let json = r#"{"all":[{"field":"x","op":"equals","value":"y"}]}"#;
        let node: ConditionNode = serde_json::from_str(json).expect("parse all");
        match &node {
            ConditionNode::All { all } => {
                assert_eq!(all.len(), 1);
                match &all[0] {
                    ConditionNode::Predicate { field, .. } => assert_eq!(field, "x"),
                    other => panic!("expected Predicate child, got {:?}", other),
                }
            }
            other => panic!("expected All, got {:?}", other),
        }
        // Serialize and check shape is preserved.
        let back = serde_json::to_string(&node).unwrap();
        let v: serde_json::Value = serde_json::from_str(&back).unwrap();
        assert!(v.get("all").is_some(), "serialized all must have 'all' key");
    }

    #[test]
    fn condition_node_any_round_trips() {
        use crate::types::ConditionNode;
        let json = r#"{"any":[{"field":"amount","op":">","value":100}]}"#;
        let node: ConditionNode = serde_json::from_str(json).expect("parse any");
        match &node {
            ConditionNode::Any { any } => assert_eq!(any.len(), 1),
            other => panic!("expected Any, got {:?}", other),
        }
        let back = serde_json::to_string(&node).unwrap();
        let v: serde_json::Value = serde_json::from_str(&back).unwrap();
        assert!(v.get("any").is_some());
    }

    #[test]
    fn condition_node_nested_all_any_predicate_round_trips() {
        use crate::types::ConditionNode;
        let json = r#"{"all":[{"any":[{"field":"doc_type","op":"equals","value":"invoice"},{"field":"doc_type","op":"equals","value":"receipt"}]},{"field":"confidence","op":">=","value":0.8}]}"#;
        let node: ConditionNode = serde_json::from_str(json).expect("parse nested");
        match &node {
            ConditionNode::All { all } => {
                assert_eq!(all.len(), 2);
                match &all[0] {
                    ConditionNode::Any { any } => assert_eq!(any.len(), 2),
                    other => panic!("expected Any at index 0, got {:?}", other),
                }
                match &all[1] {
                    ConditionNode::Predicate { field, op, value } => {
                        assert_eq!(field, "confidence");
                        assert_eq!(op, ">=");
                        assert_eq!(value.as_f64().unwrap(), 0.8);
                    }
                    other => panic!("expected Predicate at index 1, got {:?}", other),
                }
            }
            other => panic!("expected All, got {:?}", other),
        }
        // Idempotent round-trip: serialize, parse again, compare.
        let s1 = serde_json::to_string(&node).unwrap();
        let node2: ConditionNode = serde_json::from_str(&s1).unwrap();
        let s2 = serde_json::to_string(&node2).unwrap();
        assert_eq!(s1, s2, "round-trip must be idempotent");
    }

    // =========================================================================
    // W1: FileRule v2 new-fields round-trip
    // =========================================================================

    #[test]
    fn file_rule_with_all_v2_fields_round_trips_through_save_load() {
        use crate::types::ConditionNode;
        let dir = unique_tmp("v2fields");
        let path = dir.join("rules.json");

        let mut rule = sample_rule("tax_w2");
        rule.order = 5;
        rule.stop_processing = true;
        rule.copy_to = vec!["archive".to_string(), "backup".to_string()];
        rule.conditions = Some(ConditionNode::All {
            all: vec![ConditionNode::Predicate {
                field: "year".to_string(),
                op: "equals".to_string(),
                value: serde_json::Value::String("2024".to_string()),
            }],
        });
        rule.exceptions = Some(ConditionNode::Predicate {
            field: "issuer".to_string(),
            op: "equals".to_string(),
            value: serde_json::Value::String("unknown".to_string()),
        });

        let mut file = RulesFile::default();
        file.rules.push(rule.clone());
        save(&path, &file).expect("save");

        let loaded = load(&path).expect("load");
        assert_eq!(loaded.schema_version, CURRENT_SCHEMA_VERSION);
        let r = &loaded.rules[0];
        assert_eq!(r.order, 5);
        assert!(r.stop_processing);
        assert_eq!(r.copy_to, vec!["archive", "backup"]);
        assert!(r.conditions.is_some(), "conditions must survive round-trip");
        assert!(r.exceptions.is_some(), "exceptions must survive round-trip");

        fs::remove_dir_all(&dir).ok();
    }

    // =========================================================================
    // W1: schema_version 1 compat — new fields default when absent
    // =========================================================================

    #[test]
    fn v1_rules_file_loads_cleanly_with_new_fields_defaulted() {
        // A literal v1 JSON without any of the new fields.
        let json = r#"{
            "schema_version": 1,
            "default_category": "memories",
            "confidence_threshold": 0.6,
            "rename_pattern": "{date}_{sender}_{description}",
            "rules": [
                {
                    "label": "tax_w2",
                    "name": "W-2",
                    "instruction": "W-2 wage statements.",
                    "signals": ["wages", "employer"],
                    "subfolder": "taxes",
                    "rename_pattern": "",
                    "confidence_threshold": 0.7,
                    "encrypt": false,
                    "enabled": true,
                    "is_default": false
                }
            ]
        }"#;
        let file: RulesFile = serde_json::from_str(json).expect("v1 must parse");
        assert_eq!(file.rules.len(), 1);
        let r = &file.rules[0];
        assert_eq!(r.label, "tax_w2");
        // All new fields must default.
        assert!(r.conditions.is_none(), "conditions should default to None");
        assert!(r.exceptions.is_none(), "exceptions should default to None");
        assert_eq!(r.order, 0, "order should default to 0");
        assert!(!r.stop_processing, "stop_processing should default to false");
        assert!(r.copy_to.is_empty(), "copy_to should default to empty vec");
    }

    // =========================================================================
    // W1: FileRule ↔ Rule conversion preserves new fields
    // =========================================================================

    #[test]
    fn file_rule_to_rule_and_back_preserves_v2_fields() {
        use crate::types::ConditionNode;
        let mut fr = sample_rule("tax_w2");
        fr.order = 3;
        fr.stop_processing = true;
        fr.copy_to = vec!["dest_a".to_string()];
        fr.conditions = Some(ConditionNode::Any {
            any: vec![ConditionNode::Predicate {
                field: "extension".to_string(),
                op: "equals".to_string(),
                value: serde_json::Value::String(".pdf".to_string()),
            }],
        });
        fr.exceptions = None;

        let rule = fr.clone().into_rule();
        assert_eq!(rule.order, 3);
        assert!(rule.stop_processing);
        assert_eq!(rule.copy_to, vec!["dest_a"]);
        assert!(rule.conditions.is_some());
        assert!(rule.exceptions.is_none());

        // Round-trip back to FileRule.
        let fr2 = FileRule::from(rule);
        assert_eq!(fr2.order, fr.order);
        assert_eq!(fr2.stop_processing, fr.stop_processing);
        assert_eq!(fr2.copy_to, fr.copy_to);
        assert!(fr2.conditions.is_some());
    }

    // =========================================================================
    // W1: sender → issuer column migration idempotency
    // =========================================================================

    /// Build an in-memory DB that has the legacy `sender` column.
    fn legacy_documents_with_sender() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE project (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE documents (
                doc_id INTEGER PRIMARY KEY AUTOINCREMENT,
                original_filename TEXT NOT NULL,
                file_ext TEXT,
                category TEXT,
                confidence REAL,
                sender TEXT,
                description TEXT,
                doc_date TEXT,
                classified_at TEXT,
                sha256 TEXT UNIQUE,
                simhash TEXT,
                dhash TEXT,
                status TEXT DEFAULT 'classified',
                file_data BLOB,
                file_size INTEGER,
                compression TEXT DEFAULT 'zstd',
                encryption_iv BLOB,
                encryption_tag BLOB,
                source_path TEXT,
                display_name TEXT DEFAULT '',
                tags TEXT DEFAULT '[]',
                rule_snapshot TEXT DEFAULT ''
            );
            "#,
        )
        .unwrap();
        conn
    }

    /// Build an in-memory DB that already has `issuer` (already migrated).
    fn already_migrated_documents() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE project (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE documents (
                doc_id INTEGER PRIMARY KEY AUTOINCREMENT,
                original_filename TEXT NOT NULL,
                file_ext TEXT,
                category TEXT,
                confidence REAL,
                issuer TEXT,
                description TEXT,
                doc_date TEXT,
                classified_at TEXT,
                sha256 TEXT UNIQUE,
                simhash TEXT,
                dhash TEXT,
                status TEXT DEFAULT 'classified',
                file_data BLOB,
                file_size INTEGER,
                compression TEXT DEFAULT 'zstd',
                encryption_iv BLOB,
                encryption_tag BLOB,
                source_path TEXT,
                display_name TEXT DEFAULT '',
                tags TEXT DEFAULT '[]',
                rule_snapshot TEXT DEFAULT ''
            );
            "#,
        )
        .unwrap();
        conn
    }

    fn get_doc_columns(conn: &rusqlite::Connection) -> Vec<String> {
        conn.prepare("PRAGMA table_info(documents)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect()
    }

    fn apply_sender_issuer_migration(conn: &rusqlite::Connection) {
        let cols: Vec<String> = get_doc_columns(conn);
        if cols.contains(&"sender".to_string()) && !cols.contains(&"issuer".to_string()) {
            conn.execute("ALTER TABLE documents RENAME COLUMN sender TO issuer", [])
                .unwrap();
        }
    }

    #[test]
    fn sender_to_issuer_migration_renames_legacy_column() {
        let conn = legacy_documents_with_sender();
        assert!(get_doc_columns(&conn).contains(&"sender".to_string()));
        assert!(!get_doc_columns(&conn).contains(&"issuer".to_string()));

        apply_sender_issuer_migration(&conn);

        assert!(!get_doc_columns(&conn).contains(&"sender".to_string()),
            "sender column must be gone after migration");
        assert!(get_doc_columns(&conn).contains(&"issuer".to_string()),
            "issuer column must exist after migration");
    }

    #[test]
    fn sender_to_issuer_migration_is_idempotent_on_already_migrated_table() {
        let conn = already_migrated_documents();
        assert!(get_doc_columns(&conn).contains(&"issuer".to_string()));
        assert!(!get_doc_columns(&conn).contains(&"sender".to_string()));

        // Running migration again must not error.
        apply_sender_issuer_migration(&conn);

        // Column names unchanged.
        assert!(get_doc_columns(&conn).contains(&"issuer".to_string()));
        assert!(!get_doc_columns(&conn).contains(&"sender".to_string()));
    }

    // =========================================================================
    // W1 (DCR 019e33bf): new rule schema — stages/classify/keep_when round-trip
    // =========================================================================

    use crate::types::{Slot, SlotValues, Stage};

    /// Parse the DCR §"The rule schema" tax example verbatim and confirm every
    /// field survives a save→load round-trip.
    #[test]
    fn dcr_tax_example_round_trips_with_two_stages_and_filters() {
        let dir = unique_tmp("dcr_tax");
        let path = dir.join("rules.json");

        let json = r#"{
            "schema_version": 2,
            "default_category": "memories",
            "confidence_threshold": 0.6,
            "rename_pattern": "",
            "rules": [{
                "label": "tax_by_client",
                "name": "Per-client tax filings",
                "instruction": "Tax forms and statements received from clients.",
                "confidence_threshold": 0.6,
                "enabled": true,
                "is_default": false,
                "encrypt": false,
                "order": 10,
                "stop_processing": false,
                "stages": [
                    {
                        "ask": "Is this a tax-relevant document?",
                        "classify": {
                            "is_tax": {"description": "tax-relevant", "values": ["yes", "no"]}
                        },
                        "keep_when": "is_tax == 'yes'"
                    },
                    {
                        "ask": "Whose form is this, and what kind?",
                        "classify": {
                            "client": {"description": "the recipient's name", "values": "a person's name, or 'unknown'"},
                            "form":   {"description": "form type", "values": ["1099", "W-2", "1040", "K-1", "other"]},
                            "year":   {"description": "tax year", "values": "a 4-digit year, or 'unknown'"}
                        },
                        "keep_when": "client != 'unknown'"
                    }
                ],
                "subfolder": "{client}/{year}",
                "rename_pattern": "{form}.pdf",
                "copy_to": []
            }]
        }"#;

        let parsed: RulesFile = serde_json::from_str(json).expect("parse DCR tax example");
        save(&path, &parsed).expect("save");
        let loaded = load(&path).expect("load");
        let r = &loaded.rules[0];

        assert_eq!(r.label, "tax_by_client");
        assert_eq!(r.stages.len(), 2);

        // Stage 0 — closed-list slot + keep_when
        let s0 = &r.stages[0];
        assert_eq!(s0.ask, "Is this a tax-relevant document?");
        assert_eq!(s0.keep_when.as_deref(), Some("is_tax == 'yes'"));
        let is_tax = s0.classify.get("is_tax").expect("is_tax slot");
        match &is_tax.values {
            SlotValues::Closed(v) => assert_eq!(v, &vec!["yes".to_string(), "no".to_string()]),
            other => panic!("expected closed list, got {:?}", other),
        }

        // Stage 1 — mix of open and closed slots
        let s1 = &r.stages[1];
        assert_eq!(s1.classify.len(), 3);
        let client = s1.classify.get("client").expect("client slot");
        match &client.values {
            SlotValues::Open(s) => assert!(s.contains("person")),
            other => panic!("expected open slot, got {:?}", other),
        }
        let form = s1.classify.get("form").expect("form slot");
        match &form.values {
            SlotValues::Closed(v) => assert!(v.contains(&"W-2".to_string())),
            other => panic!("expected closed list, got {:?}", other),
        }

        fs::remove_dir_all(&dir).ok();
    }

    /// Persona-2 (Lawyer): multi-stage with filter on stage 1 then no filter.
    /// Confirms keep_when can be present on some stages and absent on others.
    #[test]
    fn dcr_lawyer_persona_two_stage_round_trips() {
        let dir = unique_tmp("dcr_lawyer");
        let path = dir.join("rules.json");

        let mut s0_classify = std::collections::BTreeMap::new();
        s0_classify.insert(
            "is_witness".to_string(),
            Slot {
                description: "witness-related document".to_string(),
                values: SlotValues::Closed(vec!["yes".to_string(), "no".to_string()]),
            },
        );
        let mut s1_classify = std::collections::BTreeMap::new();
        s1_classify.insert(
            "witness".to_string(),
            Slot {
                description: "witness name".to_string(),
                values: SlotValues::Open("a person's name, or 'unknown'".to_string()),
            },
        );
        s1_classify.insert(
            "case_id".to_string(),
            Slot {
                description: "case identifier".to_string(),
                values: SlotValues::Open("a case number, or 'unknown'".to_string()),
            },
        );

        let rule = FileRule {
            label: "witness_reports".to_string(),
            name: "Witness reports".to_string(),
            instruction: "Witness statements and deposition transcripts.".to_string(),
            signals: Vec::new(),
            subfolder: "cases/{case_id}".to_string(),
            rename_pattern: "{witness}.pdf".to_string(),
            confidence_threshold: 0.65,
            encrypt: true,
            enabled: true,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
            subtypes: Vec::new(),
            stages: vec![
                Stage {
                    ask: "Is this a witness-related document?".to_string(),
                    classify: s0_classify,
                    keep_when: Some("is_witness == 'yes'".to_string()),
                },
                Stage {
                    ask: "Who is the witness and which case?".to_string(),
                    classify: s1_classify,
                    keep_when: None,
                },
            ],
        };

        let mut file = RulesFile::default();
        file.rules.push(rule);
        save(&path, &file).expect("save");
        let loaded = load(&path).expect("load");
        let r = &loaded.rules[0];

        assert_eq!(r.stages.len(), 2);
        assert!(r.stages[0].keep_when.is_some(), "stage 0 must keep its filter");
        assert!(r.stages[1].keep_when.is_none(), "stage 1 must round-trip without filter");
        assert!(r.encrypt, "encrypt flag must survive");

        // keep_when=None serializes-out cleanly (not present in JSON).
        let raw = std::fs::read_to_string(&path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let stages = v["rules"][0]["stages"].as_array().unwrap();
        assert!(
            stages[1].get("keep_when").is_none(),
            "stage with no filter must omit keep_when key from on-disk JSON"
        );

        fs::remove_dir_all(&dir).ok();
    }

    /// Persona-3 (Citizen): single-stage with open-slot drawings extraction.
    #[test]
    fn dcr_citizen_drawings_single_stage_round_trips() {
        let dir = unique_tmp("dcr_citizen");
        let path = dir.join("rules.json");

        let mut classify = std::collections::BTreeMap::new();
        classify.insert(
            "subject".to_string(),
            Slot {
                description: "what the drawing shows".to_string(),
                values: SlotValues::Open("a 2-5 word phrase".to_string()),
            },
        );

        let rule = FileRule {
            label: "kids_drawings".to_string(),
            name: "Kids drawings".to_string(),
            instruction: "Drawings by my children — keep all of them.".to_string(),
            signals: Vec::new(),
            subfolder: "kids".to_string(),
            rename_pattern: "{subject}.png".to_string(),
            confidence_threshold: 0.5,
            encrypt: false,
            enabled: true,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
            subtypes: Vec::new(),
            stages: vec![Stage {
                ask: "What does this drawing show?".to_string(),
                classify,
                keep_when: None,
            }],
        };

        let mut file = RulesFile::default();
        file.rules.push(rule.clone());
        save(&path, &file).expect("save");
        let loaded = load(&path).expect("load");
        let r = &loaded.rules[0];

        assert_eq!(r.stages.len(), 1, "single-stage rules still wrap in a one-element array");
        let slot = r.stages[0].classify.get("subject").expect("subject slot");
        match &slot.values {
            SlotValues::Open(s) => assert_eq!(s, "a 2-5 word phrase"),
            other => panic!("expected open slot, got {:?}", other),
        }

        fs::remove_dir_all(&dir).ok();
    }

    /// Slot-name collision across stages: validate() must reject before insert.
    #[test]
    fn file_rule_validate_rejects_duplicate_slot_across_stages() {
        let mut s0 = std::collections::BTreeMap::new();
        s0.insert(
            "year".to_string(),
            Slot {
                description: "year".to_string(),
                values: SlotValues::Open("YYYY".to_string()),
            },
        );
        let mut s1 = std::collections::BTreeMap::new();
        s1.insert(
            "year".to_string(),
            Slot {
                description: "year again".to_string(),
                values: SlotValues::Open("YYYY".to_string()),
            },
        );

        let rule = FileRule {
            label: "bad".to_string(),
            name: "bad".to_string(),
            instruction: String::new(),
            signals: Vec::new(),
            subfolder: String::new(),
            rename_pattern: String::new(),
            confidence_threshold: 0.5,
            encrypt: false,
            enabled: true,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
            subtypes: Vec::new(),
            stages: vec![
                Stage {
                    ask: "First".to_string(),
                    classify: s0,
                    keep_when: None,
                },
                Stage {
                    ask: "Second".to_string(),
                    classify: s1,
                    keep_when: None,
                },
            ],
        };

        let err = rule.validate().expect_err("must reject duplicate slot");
        assert!(
            err.message.contains("'year'") && err.message.contains("stage 1"),
            "expected duplicate-slot error mentioning slot name and stage index, got: {}",
            err.message
        );
    }

    /// Single-stage rules in the new schema are always wrapped in a one-element
    /// `stages` array — there is no flat shortcut. Confirms the DCR design
    /// choice (single-stage rules always wrapped in `stages: [{...}]`).
    #[test]
    fn single_stage_rule_is_always_a_one_element_stages_array() {
        let json = r#"{
            "schema_version": 2,
            "default_category": "x",
            "confidence_threshold": 0.6,
            "rename_pattern": "",
            "rules": [{
                "label": "r",
                "stages": [{"ask": "Q?", "classify": {"x": {"description": "x", "values": ["a"]}}}]
            }]
        }"#;
        let f: RulesFile = serde_json::from_str(json).expect("parse");
        assert_eq!(f.rules[0].stages.len(), 1, "single-stage rule has stages.len() == 1");
    }
}
