//! External rules-file storage.
//!
//! The rules file is a plaintext JSON document that lives either next to the
//! vault (sibling override: `<stem>.rules.json`) or at a user-level path
//! provided by the host. Schema mirrors the experiment's
//! `user://scansort_rules.json` format so files port forward.

use crate::db;
use crate::types::{now_iso, Rule, VaultError, VaultResult};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const CURRENT_SCHEMA_VERSION: i64 = 1;
pub const DEFAULT_CATEGORY: &str = "memories";
pub const DEFAULT_CONFIDENCE_THRESHOLD: f64 = 0.6;
pub const DEFAULT_RENAME_PATTERN: &str = "{date}_{sender}_{description}";

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
    #[serde(default)]
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
        }
    }
}

impl FileRule {
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
}
