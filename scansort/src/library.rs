//! Global rules library stored at the OS-specific app-data path.
//!
//! File location: `<OS-app-data>/Minerva/Scansort/library.rules.json`
//! Resolved via the `directories` crate using:
//!   qualifier = "" (empty), organization = "Minerva", application = "Scansort"
//!
//! Seven MCP tools in main.rs wrap the functions here:
//!   • minerva_scansort_library_insert_rule
//!   • minerva_scansort_library_list_rules
//!   • minerva_scansort_library_get_rule
//!   • minerva_scansort_library_update_rule
//!   • minerva_scansort_library_delete_rule
//!   • minerva_scansort_library_enable_rule
//!   • minerva_scansort_library_disable_rule
//!
//! Design notes:
//!   - No caching: every call hits the file. (B7 adds caching/hot-reload.)
//!   - Parent dirs are created on first save via `fs::create_dir_all`.
//!   - Test builds use a Mutex-guarded path override to isolate from the real
//!     OS data directory. Production builds always use `directories`.

use crate::rules_file::{self, FileRule, RulesFile};
use crate::types::{VaultError, VaultResult};
use directories::ProjectDirs;
use std::fs;
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

/// Resolve the library path from OS app-data dirs.
///
/// Uses `ProjectDirs::from("", "Minerva", "Scansort")` — qualifier is empty,
/// organization is "Minerva", application is "Scansort".
///
/// Returns an error if `ProjectDirs::from` cannot determine the data dir
/// (e.g. HOME / USERPROFILE is unset).
pub fn library_path() -> VaultResult<PathBuf> {
    // In test builds, honour the override first.
    #[cfg(test)]
    {
        let guard = TEST_PATH.lock().unwrap();
        if let Some(ref p) = *guard {
            return Ok(p.clone());
        }
    }

    let proj = ProjectDirs::from("", "Minerva", "Scansort").ok_or_else(|| {
        VaultError::new(
            "cannot resolve user data dir — HOME/USERPROFILE may be unset".to_string(),
        )
    })?;
    Ok(proj.data_dir().join("library.rules.json"))
}

// ---------------------------------------------------------------------------
// Test-only path override
// ---------------------------------------------------------------------------

#[cfg(test)]
static TEST_PATH: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

/// Point the library at a tmpdir for testing. Must be cleared after use.
#[cfg(test)]
pub fn set_library_path_for_test(path: PathBuf) {
    *TEST_PATH.lock().unwrap() = Some(path);
}

/// Clear the test override, restoring normal `directories`-based resolution.
#[cfg(test)]
pub fn clear_library_path_for_test() {
    *TEST_PATH.lock().unwrap() = None;
}

// ---------------------------------------------------------------------------
// Thin wrappers — load / save
// ---------------------------------------------------------------------------

/// Load the library file, or return an empty default if it doesn't exist yet.
pub fn library_load() -> VaultResult<RulesFile> {
    let path = library_path()?;
    rules_file::load_or_init(&path)
}

/// Save the library file. Creates parent directories as needed.
pub fn library_save(file: &RulesFile) -> VaultResult<()> {
    let path = library_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    rules_file::save(&path, file)
}

// ---------------------------------------------------------------------------
// CRUD helpers
// ---------------------------------------------------------------------------

/// Upsert a rule by label into the library. Returns the resulting FileRule
/// (post-save, so the on-disk state is canonical).
pub fn library_insert(rule: FileRule) -> VaultResult<FileRule> {
    let mut file = library_load()?;
    rules_file::upsert(&mut file, rule.clone());
    library_save(&file)?;
    // Return the canonical stored rule (re-lookup to confirm).
    let label = &rule.label;
    file.rules
        .into_iter()
        .find(|r| &r.label == label)
        .ok_or_else(|| VaultError::new(format!("library upsert logic error: rule '{label}' missing after save")))
}

/// Remove a rule by label. Returns true if a rule was removed, false if not found.
pub fn library_delete(label: &str) -> VaultResult<bool> {
    let mut file = library_load()?;
    let removed = rules_file::remove(&mut file, label);
    if removed {
        library_save(&file)?;
    }
    Ok(removed)
}

/// Get a single rule by label. Returns None if not found.
pub fn library_get(label: &str) -> VaultResult<Option<FileRule>> {
    let file = library_load()?;
    Ok(rules_file::find_by_label(&file.rules, label).cloned())
}

/// List all rules in stable (insertion) order.
pub fn library_list() -> VaultResult<Vec<FileRule>> {
    let file = library_load()?;
    Ok(file.rules)
}

/// Set `enabled` on a rule by label. Returns true if the rule existed and was
/// updated, false if not found.
pub fn library_set_enabled(label: &str, enabled: bool) -> VaultResult<bool> {
    let mut file = library_load()?;
    match rules_file::index_of(&file, label) {
        Some(i) => {
            file.rules[i].enabled = enabled;
            library_save(&file)?;
            Ok(true)
        }
        None => Ok(false),
    }
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
        std::env::temp_dir().join(format!("scansort-library-{prefix}-{pid}-{ts}-{n}"))
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
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
        }
    }

    /// All library tests run inside a single function to avoid Mutex contention
    /// from parallel test runners stomping on each other's TEST_PATH override.
    #[test]
    fn library_all_tests() {
        // Each sub-scenario gets a unique tmpdir + calls set_library_path_for_test
        // before use and clear_library_path_for_test after.

        // ----------------------------------------------------------------
        // 1. Auto-create on first insert (file doesn't exist yet).
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("autocreate");
            let path = dir.join("subdir").join("library.rules.json");
            set_library_path_for_test(path.clone());

            assert!(!path.exists(), "file must not exist before first insert");
            let inserted = library_insert(sample_rule("tax_w2")).expect("insert");
            assert!(path.exists(), "file must exist after first insert");
            assert_eq!(inserted.label, "tax_w2");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 2. Upsert by label: insert same label twice → second wins, count=1.
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("upsert");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("tax_w2")).expect("first insert");
            let mut updated = sample_rule("tax_w2");
            updated.instruction = "UPDATED".to_string();
            library_insert(updated).expect("second insert");

            let rules = library_list().expect("list");
            assert_eq!(rules.len(), 1, "count must stay at 1 after upsert");
            assert_eq!(rules[0].instruction, "UPDATED");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 3. List returns rules in stable (insertion) order.
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("list_order");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("aaa")).expect("insert aaa");
            library_insert(sample_rule("bbb")).expect("insert bbb");
            library_insert(sample_rule("ccc")).expect("insert ccc");

            let rules = library_list().expect("list");
            assert_eq!(rules.len(), 3);
            assert_eq!(rules[0].label, "aaa");
            assert_eq!(rules[1].label, "bbb");
            assert_eq!(rules[2].label, "ccc");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 4. Get returns the inserted rule.
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("get");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("receipt")).expect("insert");

            let found = library_get("receipt").expect("get").expect("found");
            assert_eq!(found.label, "receipt");
            assert_eq!(found.signals, vec!["alpha", "beta"]);

            let not_found = library_get("no_such_label").expect("get ok");
            assert!(not_found.is_none());

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 5. Delete removes rule; second delete returns false.
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("delete");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("school")).expect("insert");
            let deleted = library_delete("school").expect("delete");
            assert!(deleted, "first delete must return true");

            let rules = library_list().expect("list");
            assert!(rules.is_empty(), "rule must be gone");

            let deleted2 = library_delete("school").expect("second delete");
            assert!(!deleted2, "second delete must return false");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 6. Enable / disable flip the flag.
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("enable_disable");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("memo")).expect("insert");

            let r = library_get("memo").expect("get").expect("found");
            assert!(r.enabled, "starts enabled");

            let hit = library_set_enabled("memo", false).expect("disable");
            assert!(hit, "disable must return true when found");

            let r2 = library_get("memo").expect("get").expect("found");
            assert!(!r2.enabled, "must be disabled");

            let hit2 = library_set_enabled("memo", true).expect("enable");
            assert!(hit2, "re-enable must return true");

            let r3 = library_get("memo").expect("get").expect("found");
            assert!(r3.enabled, "must be re-enabled");

            // set_enabled on unknown label returns false without error.
            let miss = library_set_enabled("no_such", true).expect("ok");
            assert!(!miss, "unknown label must return false");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 7. copy_to: [label1, label2] round-trips (opaque strings accepted).
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("copy_to");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            let mut rule = sample_rule("invoice");
            rule.copy_to = vec!["archive".to_string(), "backup".to_string()];
            library_insert(rule).expect("insert");

            let r = library_get("invoice").expect("get").expect("found");
            assert_eq!(r.copy_to, vec!["archive", "backup"]);

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ----------------------------------------------------------------
        // 8. Multi-rule scenario: insert 3, delete middle, list returns 2.
        // ----------------------------------------------------------------
        {
            let dir = unique_tmp("multi");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("first")).expect("insert first");
            library_insert(sample_rule("second")).expect("insert second");
            library_insert(sample_rule("third")).expect("insert third");

            let rules = library_list().expect("list before delete");
            assert_eq!(rules.len(), 3);

            let removed = library_delete("second").expect("delete middle");
            assert!(removed);

            let rules2 = library_list().expect("list after delete");
            assert_eq!(rules2.len(), 2);
            assert_eq!(rules2[0].label, "first");
            assert_eq!(rules2[1].label, "third");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }
    }
}
