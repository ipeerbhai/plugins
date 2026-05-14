//! External rules-file storage.
//!
//! The rules file is a plaintext JSON document that lives either next to the
//! vault (sibling override: `<stem>.rules.json`) or at a user-level path
//! provided by the host. Schema mirrors the experiment's
//! `user://scansort_rules.json` format so files port forward.

use crate::types::{Rule, VaultError, VaultResult};
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
