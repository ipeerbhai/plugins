//! Global rules library stored at the OS-specific app-data path.
//!
//! File location: `<OS-app-data>/Minerva/Scansort/library.rules.json`
//! Resolved via the `directories` crate using:
//!   qualifier = "" (empty), organization = "Minerva", application = "Scansort"
//!
//! Nine MCP tools in main.rs wrap the functions here:
//!   • minerva_scansort_library_insert_rule
//!   • minerva_scansort_library_list_rules
//!   • minerva_scansort_library_get_rule
//!   • minerva_scansort_library_update_rule
//!   • minerva_scansort_library_delete_rule
//!   • minerva_scansort_library_enable_rule
//!   • minerva_scansort_library_disable_rule
//!   • minerva_scansort_library_export_to_sidecar  (B5)
//!   • minerva_scansort_library_import_from_sidecar (B5)
//!
//! Design notes:
//!   - B7 cache: `CACHE` holds an `Option<CachedLibrary>` protected by a
//!     `Mutex` inside an `OnceLock`. Every read checks the file's mtime;
//!     on change (or empty cache) the file is reloaded. Every write updates
//!     the cache so in-process changes are immediately consistent.
//!   - Parent dirs are created on first save via `fs::create_dir_all`.
//!   - Test builds use a Mutex-guarded path override to isolate from the real
//!     OS data directory. Production builds always use `directories`.

use crate::rules_file::{self, FileRule, RulesFile};
use crate::types::{VaultError, VaultResult};
use directories::ProjectDirs;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

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
/// Also clears the B7 cache so the new path starts fresh.
#[cfg(test)]
pub fn set_library_path_for_test(path: PathBuf) {
    *TEST_PATH.lock().unwrap() = Some(path);
    // Clear the cache so the next read uses the new test path.
    *cache().lock().unwrap() = None;
}

/// Clear the test override, restoring normal `directories`-based resolution.
/// Also clears the B7 cache so no stale test data bleeds into later tests.
#[cfg(test)]
pub fn clear_library_path_for_test() {
    *TEST_PATH.lock().unwrap() = None;
    *cache().lock().unwrap() = None;
}

// ---------------------------------------------------------------------------
// B7: In-memory cache with mtime-based hot-reload
// ---------------------------------------------------------------------------

/// In-memory snapshot of the library file with the mtime at which it was read.
struct CachedLibrary {
    mtime: SystemTime,
    file: RulesFile,
}

/// Global cache — initialized once; the inner `Option` is `None` until the
/// first read, and is cleared whenever the path changes (test path override).
static CACHE: OnceLock<Mutex<Option<CachedLibrary>>> = OnceLock::new();

/// Accessor — always returns the same `Mutex<Option<CachedLibrary>>`.
fn cache() -> &'static Mutex<Option<CachedLibrary>> {
    CACHE.get_or_init(|| Mutex::new(None))
}

// ---------------------------------------------------------------------------
// Thin wrappers — load / save (B7-cached)
// ---------------------------------------------------------------------------

/// Load the library file with mtime-based hot-reload caching.
///
/// Algorithm:
/// 1. stat(library_path). On IO error (file missing) → return `RulesFile::default()`,
///    clear cache, log a one-time warning.
/// 2. Compare file mtime to cache mtime.
///    - Cache empty OR mtime changed → reload from disk, update cache.
///    - mtime unchanged → return cached clone.
/// 3. On disk-parse failure (corrupt JSON mid-write) → keep cached value,
///    log warning, return cached clone. Next read retries.
pub fn library_load() -> VaultResult<RulesFile> {
    let path = library_path()?;

    // Stat the file first.
    let meta = match fs::metadata(&path) {
        Ok(m) => m,
        Err(_) => {
            // File missing (or unreadable). Return default; clear cache.
            static WARNED: std::sync::atomic::AtomicBool =
                std::sync::atomic::AtomicBool::new(false);
            if !WARNED.swap(true, std::sync::atomic::Ordering::Relaxed) {
                log::warn!(
                    "library_load: file not found at {}; returning empty defaults",
                    path.display()
                );
            }
            *cache().lock().unwrap() = None;
            return Ok(RulesFile::default());
        }
    };

    let file_mtime = match meta.modified() {
        Ok(t) => t,
        Err(_) => {
            // Platform doesn't support mtime — fall through to always-reload.
            SystemTime::UNIX_EPOCH
        }
    };

    let mut guard = cache().lock().unwrap();

    // Cache hit when mtime matches.
    if let Some(ref cached) = *guard {
        if cached.mtime == file_mtime {
            return Ok(cached.file.clone());
        }
    }

    // Cache miss — reload from disk.
    match rules_file::load_or_init(&path) {
        Ok(mut file) => {
            // W5 — DCR 019e33bf: detect legacy markers (`signals`/`subtypes`/
            // built-in template tokens with no `stages`) and rewrite each
            // rule into the new shape, then persist the migrated file so the
            // next read is a no-op.
            let any_legacy = file.rules.iter().any(crate::migrate::is_legacy);
            if any_legacy {
                let mut changed = 0usize;
                for rule in &mut file.rules {
                    if crate::migrate::migrate_rule(rule) {
                        changed += 1;
                    }
                }
                if changed > 0 {
                    log::info!(
                        "library_load: migrated {} of {} rules to new schema; rewriting {}",
                        changed,
                        file.rules.len(),
                        path.display()
                    );
                    if let Err(e) = rules_file::save(&path, &file) {
                        log::warn!(
                            "library_load: migration succeeded in memory but write-back failed: {}; \
                             returning migrated copy without persisting",
                            e.message
                        );
                    }
                }
            }

            // Re-stat after possible write-back so the cached mtime matches disk.
            let cached_mtime = if any_legacy {
                fs::metadata(&path)
                    .and_then(|m| m.modified())
                    .unwrap_or(file_mtime)
            } else {
                file_mtime
            };

            *guard = Some(CachedLibrary {
                mtime: cached_mtime,
                file: file.clone(),
            });
            Ok(file)
        }
        Err(e) => {
            // Corrupt JSON mid-write: keep the prior cached value if any.
            if let Some(ref cached) = *guard {
                log::warn!(
                    "library_load: disk read failed ({}); returning stale cached value",
                    e.message
                );
                return Ok(cached.file.clone());
            }
            Err(e)
        }
    }
}

/// Save the library file and update the in-memory cache so subsequent reads
/// see the new content without a disk round-trip.
pub fn library_save(file: &RulesFile) -> VaultResult<()> {
    let path = library_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    rules_file::save(&path, file)?;
    // Update cache with the freshly written mtime.
    if let Ok(meta) = fs::metadata(&path) {
        if let Ok(mtime) = meta.modified() {
            *cache().lock().unwrap() = Some(CachedLibrary {
                mtime,
                file: file.clone(),
            });
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// B5: Sidecar export / import helpers
// ---------------------------------------------------------------------------

/// Export the global library to the per-vault sidecar path
/// (`<vault-stem>.rules.json` next to the vault).
///
/// `vault_path` must be a valid path to the vault file (existence not
/// required — only the path shape is used for `sibling_path`).
/// Returns `(sidecar_path, count)` on success.
pub fn library_export_to_sidecar(vault_path: &std::path::Path) -> VaultResult<(PathBuf, usize)> {
    let lib = library_load()?;
    let count = lib.rules.len();
    let sidecar = rules_file::sibling_path(vault_path);
    // Write directly — sidecar is NOT cached through the library cache.
    rules_file::save(&sidecar, &lib)?;
    Ok((sidecar, count))
}

/// Import rules from the per-vault sidecar into the global library.
///
/// Each rule in the sidecar is upserted (last-write-wins). Returns
/// `(sidecar_path, imported, conflicts, total_after)` where `conflicts` is
/// the number of rules whose label already existed in the library with
/// *different* content before the import.
pub fn library_import_from_sidecar(
    vault_path: &std::path::Path,
) -> VaultResult<(PathBuf, usize, usize, usize)> {
    let sidecar = rules_file::sibling_path(vault_path);
    if !sidecar.exists() {
        return Err(VaultError::new(format!(
            "sidecar not found at {}",
            sidecar.display()
        )));
    }
    let sidecar_file = rules_file::load(&sidecar)?;
    let imported = sidecar_file.rules.len();

    // Load the current library to check for conflicts before overwriting.
    let current = library_load()?;

    let mut conflicts: usize = 0;
    for incoming in &sidecar_file.rules {
        if let Some(existing) = rules_file::find_by_label(&current.rules, &incoming.label) {
            // Conflict = same label, different content (compare by serialization).
            let ex_json = serde_json::to_string(existing).unwrap_or_default();
            let in_json = serde_json::to_string(incoming).unwrap_or_default();
            if ex_json != in_json {
                conflicts += 1;
            }
        }
        // Upsert into the library (last-write-wins).
        library_insert(incoming.clone())?;
    }

    let total_after = library_list()?.len();
    Ok((sidecar, imported, conflicts, total_after))
}

// ---------------------------------------------------------------------------
// CRUD helpers
// ---------------------------------------------------------------------------

/// Upsert a rule by label into the library. Returns the resulting FileRule
/// (post-save, so the on-disk state is canonical).
pub fn library_insert(rule: FileRule) -> VaultResult<FileRule> {
    // W1 (DCR 019e33bf): reject duplicate classify slot names across stages
    // at insert time so the on-disk library never contains a malformed rule.
    rule.validate()?;
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

/// W3 (DCR 019e33bf): reorder rules by reassigning each rule's `order` field
/// to its index in the supplied array. Spaces values with a gap of 10 to
/// leave room for future single-rule inserts without re-walking the whole
/// library.
///
/// `order` must contain exactly the set of labels currently in the library —
/// no extras, no missing, no duplicates. Returns the resulting
/// `[(label, order), ...]` pairs in their new order on success.
pub fn library_reorder(order: &[String]) -> VaultResult<Vec<(String, i64)>> {
    let mut file = library_load()?;

    let existing: std::collections::HashSet<&str> =
        file.rules.iter().map(|r| r.label.as_str()).collect();
    let input_set: std::collections::HashSet<&str> = order.iter().map(String::as_str).collect();

    if input_set.len() != order.len() {
        return Err(VaultError::new(
            "order array contains duplicate labels".to_string(),
        ));
    }

    let missing: Vec<&str> = existing.difference(&input_set).copied().collect();
    let extra: Vec<&str> = input_set.difference(&existing).copied().collect();

    if !missing.is_empty() || !extra.is_empty() {
        let mut msg = String::from(
            "order array must contain exactly the set of labels currently in the library",
        );
        if !missing.is_empty() {
            let mut m: Vec<&str> = missing;
            m.sort();
            msg.push_str(&format!("; missing labels: {}", m.join(", ")));
        }
        if !extra.is_empty() {
            let mut e: Vec<&str> = extra;
            e.sort();
            msg.push_str(&format!("; unknown labels: {}", e.join(", ")));
        }
        return Err(VaultError::new(msg));
    }

    let mut new_order: Vec<(String, i64)> = Vec::with_capacity(order.len());
    for (i, label) in order.iter().enumerate() {
        let assigned = (i as i64) * 10;
        if let Some(idx) = rules_file::index_of(&file, label) {
            file.rules[idx].order = assigned;
        }
        new_order.push((label.clone(), assigned));
    }
    library_save(&file)?;
    Ok(new_order)
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
        // Migration-neutral fixture for library CRUD tests: no signals/subtypes
        // and no built-in tokens in templates, so library_load does NOT rewrite
        // the file. W5 has its own legacy-shape fixtures in `w5_migration_subtests`.
        FileRule {
            label: label.to_string(),
            name: format!("Rule {label}"),
            instruction: format!("Match {label} documents."),
            signals: Vec::new(),
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
            subtypes: Vec::new(),
            stages: Vec::new(),
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
            assert_eq!(found.instruction, "Match receipt documents.");

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

        // B7 and B5 sub-tests — called here so they share the same
        // serialized execution context as the existing 8 scenarios above.
        b7_cache_subtests();
        b5_sidecar_subtests();
        w5_migration_subtests();
    }

    // ----------------------------------------------------------------
    // B7: Cache hot-reload tests — run inside library_all_tests to avoid
    // Mutex / CACHE contention with parallel test runners.
    // Call this from library_all_tests, not as a standalone #[test].
    // ----------------------------------------------------------------
    fn b7_cache_subtests() {
        // B7-1: Write via library_insert → subsequent library_list returns
        // correct, consistent data (cache populated after write).
        {
            let dir = unique_tmp("b7_cache_hit");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("alpha")).expect("insert");

            let r1 = library_list().expect("list 1");
            assert_eq!(r1.len(), 1);
            assert_eq!(r1[0].label, "alpha");

            // Second list — cache hit, same data.
            let r2 = library_list().expect("list 2");
            assert_eq!(r2.len(), 1);
            assert_eq!(r2[0].label, "alpha");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // B7-2: Out-of-band file change is auto-detected via mtime delta.
        // The cache is warm after the first list; we sleep past mtime granularity
        // before the OOB write so the next library_list() observes a different
        // mtime and reloads from disk WITHOUT any manual cache reset.
        {
            let dir = unique_tmp("b7_oob_reload");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            // Populate cache via an insert.
            library_insert(sample_rule("beta")).expect("insert beta");
            let r1 = library_list().expect("list before oob write");
            assert_eq!(r1.len(), 1);

            // Sleep past mtime granularity so the OOB write produces a strictly
            // newer mtime than the cached value. ext4/HFS+/NTFS all resolve at
            // ≤ 10 ms; 100 ms is a comfortable margin.
            std::thread::sleep(std::time::Duration::from_millis(100));

            // Write new content out-of-band (simulates hand-edit).
            let mut new_file = crate::rules_file::RulesFile::default();
            new_file.rules.push(sample_rule("beta"));
            new_file.rules.push(sample_rule("gamma_oob"));
            let text = serde_json::to_string_pretty(&new_file).unwrap();
            fs::write(&path, &text).expect("oob write");

            // NO cache reset. library_list() must auto-detect mtime delta
            // and reload from disk — this is the whole point of B7.
            let r2 = library_list().expect("list after oob write");
            assert_eq!(r2.len(), 2, "mtime auto-reload must pick up gamma_oob");
            let labels: Vec<&str> = r2.iter().map(|r| r.label.as_str()).collect();
            assert!(labels.contains(&"gamma_oob"), "gamma_oob must appear after auto-reload");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // B7-3: Delete the file between calls → next read returns empty, no panic.
        // No manual cache reset — the stat-on-read path must observe the missing
        // file and fall back to RulesFile::default().
        {
            let dir = unique_tmp("b7_file_deleted");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("delta")).expect("insert");
            let r1 = library_list().expect("list before delete");
            assert_eq!(r1.len(), 1);

            // Delete the file out-of-band — no cache reset.
            fs::remove_file(&path).expect("remove file");

            // Next read should observe missing file via stat error,
            // return RulesFile::default() (empty), and not panic.
            let r2 = library_list().expect("list after file deleted");
            assert!(r2.is_empty(), "missing-file path must return empty without panic");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // B7-4: Corrupt JSON with a warm cache → library_load() detects the
        // mtime delta, attempts to parse, fails, and returns the prior cached
        // value. Deterministic via explicit sleep past mtime granularity.
        {
            let dir = unique_tmp("b7_corrupt");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("epsilon")).expect("insert");
            let r1 = library_list().expect("list before corrupt");
            assert_eq!(r1.len(), 1);
            assert_eq!(r1[0].label, "epsilon");

            // Sleep past mtime granularity so the corrupt write is a true delta.
            std::thread::sleep(std::time::Duration::from_millis(100));

            // Write corrupt JSON — different mtime, unparseable content.
            fs::write(&path, b"not valid json").expect("write corrupt");

            // The cache is warm with "epsilon". stat sees a newer mtime,
            // load_or_init fails on parse, and the B7 fallback returns the
            // prior cached clone. Result must contain exactly "epsilon".
            let r2 = library_list().expect("stale cache must be returned on corrupt parse");
            assert_eq!(r2.len(), 1, "stale-cache fallback must return prior content");
            assert_eq!(r2[0].label, "epsilon", "corrupt parse must not leak partial data");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }
    }

    // ----------------------------------------------------------------
    // B5: Sidecar export / import tests — run inside library_all_tests.
    // ----------------------------------------------------------------
    fn b5_sidecar_subtests() {
        // B5-1: Export library to sidecar — sidecar file created at sibling path.
        {
            let dir = unique_tmp("b5_export");
            let lib_path = dir.join("library.rules.json");
            set_library_path_for_test(lib_path.clone());

            library_insert(sample_rule("zeta")).expect("insert zeta");
            library_insert(sample_rule("eta")).expect("insert eta");

            let vault_path = dir.join("taxes.ssort");
            let (sidecar, count) = library_export_to_sidecar(&vault_path).expect("export");
            assert_eq!(count, 2);
            let expected_sidecar = dir.join("taxes.rules.json");
            assert_eq!(sidecar, expected_sidecar);
            assert!(sidecar.exists(), "sidecar file must be written");

            let loaded = crate::rules_file::load(&sidecar).expect("load sidecar");
            assert_eq!(loaded.rules.len(), 2);
            let labels: Vec<&str> = loaded.rules.iter().map(|r| r.label.as_str()).collect();
            assert!(labels.contains(&"zeta"));
            assert!(labels.contains(&"eta"));

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // B5-2: Import from sidecar → rules upserted into library.
        {
            let dir = unique_tmp("b5_import");
            let lib_path = dir.join("library.rules.json");
            set_library_path_for_test(lib_path.clone());

            // Pre-populate library with one rule.
            library_insert(sample_rule("theta")).expect("insert theta");

            // Write a sidecar with two rules (one overlap with existing).
            let vault_path = dir.join("docs.ssort");
            let sidecar = crate::rules_file::sibling_path(&vault_path);
            let mut sidecar_file = crate::rules_file::RulesFile::default();
            sidecar_file.rules.push(sample_rule("theta")); // overlap, same content → no conflict
            sidecar_file.rules.push(sample_rule("iota"));  // new
            crate::rules_file::save(&sidecar, &sidecar_file).expect("write sidecar");

            let (_, imported, conflicts, total_after) =
                library_import_from_sidecar(&vault_path).expect("import");
            assert_eq!(imported, 2, "2 rules in sidecar");
            assert_eq!(conflicts, 0, "theta content identical — no conflict");
            assert_eq!(total_after, 2, "library should have theta + iota");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // B5-3: Import from sidecar with conflicting rule → conflict counted, last-write-wins.
        {
            let dir = unique_tmp("b5_import_conflict");
            let lib_path = dir.join("library.rules.json");
            set_library_path_for_test(lib_path.clone());

            let mut existing = sample_rule("kappa");
            existing.instruction = "Original instruction".to_string();
            library_insert(existing).expect("insert kappa");

            let vault_path = dir.join("vault.ssort");
            let sidecar = crate::rules_file::sibling_path(&vault_path);
            let mut sidecar_file = crate::rules_file::RulesFile::default();
            let mut incoming = sample_rule("kappa");
            incoming.instruction = "DIFFERENT instruction from sidecar".to_string();
            sidecar_file.rules.push(incoming);
            crate::rules_file::save(&sidecar, &sidecar_file).expect("write sidecar");

            let (_, imported, conflicts, total_after) =
                library_import_from_sidecar(&vault_path).expect("import");
            assert_eq!(imported, 1);
            assert_eq!(conflicts, 1, "one conflict: kappa instruction differs");
            assert_eq!(total_after, 1, "still one rule");

            // Last-write-wins: library should have the sidecar's instruction.
            let rule = library_get("kappa").expect("get").expect("found");
            assert_eq!(rule.instruction, "DIFFERENT instruction from sidecar");

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // B5-4: Import from sidecar when sidecar doesn't exist → error.
        {
            let dir = unique_tmp("b5_import_missing");
            let lib_path = dir.join("library.rules.json");
            set_library_path_for_test(lib_path.clone());

            let vault_path = dir.join("nonexistent.ssort");
            let err = library_import_from_sidecar(&vault_path).expect_err("must error");
            assert!(
                err.message.contains("sidecar not found"),
                "unexpected error: {}",
                err.message
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }
    }

    // ----------------------------------------------------------------
    // W5: Schema migration on library load — DCR 019e33bf
    // Each sub-test plants a legacy library file on disk, calls
    // library_load(), and confirms (a) the in-memory result is migrated,
    // (b) the on-disk file is rewritten, (c) a second load is a no-op.
    // ----------------------------------------------------------------
    fn w5_migration_subtests() {
        use crate::types::SlotValues;

        // Helper — write raw JSON to the test library path.
        fn plant(path: &PathBuf, body: &str) {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(path, body).unwrap();
        }

        // W5-1: signals + rename_pattern with built-in tokens → migrated to
        // stages + signals-suffixed instruction. On-disk file rewritten.
        {
            let dir = unique_tmp("w5_signals_builtins");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            plant(&path, r#"{
                "schema_version": 2,
                "default_category": "memories",
                "confidence_threshold": 0.6,
                "rename_pattern": "",
                "rules": [{
                    "label": "tax",
                    "name": "Tax docs",
                    "instruction": "Tax forms and statements.",
                    "signals": ["W-2", "1099", "withholding"],
                    "subfolder": "tax/{year}",
                    "rename_pattern": "{date}_{sender}_{description}.pdf",
                    "confidence_threshold": 0.7,
                    "encrypt": false,
                    "enabled": true,
                    "is_default": false
                }]
            }"#);

            let rules = library_list().expect("list triggers migration");
            assert_eq!(rules.len(), 1);
            let r = &rules[0];
            assert!(r.signals.is_empty(), "signals must be cleared in memory");
            assert!(
                r.instruction.contains("typical signals include W-2, 1099, withholding"),
                "instruction should carry signals; got: {}",
                r.instruction
            );
            assert_eq!(r.stages.len(), 1, "built-in tokens fold into stages[0]");
            let classify = &r.stages[0].classify;
            for tok in ["date", "sender", "description", "year"] {
                assert!(classify.contains_key(tok), "expected slot '{tok}'");
            }
            for tok in ["amount", "category", "doc_type", "issuer"] {
                assert!(!classify.contains_key(tok), "unreferenced slot '{tok}' must not be injected");
            }

            // On-disk file must be rewritten — signals key gone.
            let raw = fs::read_to_string(&path).unwrap();
            assert!(!raw.contains("\"signals\""), "on-disk file must not retain signals key after migration");
            assert!(raw.contains("\"stages\""), "on-disk file must contain stages after migration");

            // Idempotent — second load must not rewrite.
            let mtime_after_first = fs::metadata(&path).unwrap().modified().unwrap();
            std::thread::sleep(std::time::Duration::from_millis(150));
            // Clear cache so library_load goes back to disk.
            *cache().lock().unwrap() = None;
            let _ = library_load().expect("idempotent reload");
            let mtime_after_second = fs::metadata(&path).unwrap().modified().unwrap();
            assert_eq!(
                mtime_after_first, mtime_after_second,
                "migrated file must not be rewritten on second load"
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W5-2: subtypes-only → injected doc_type slot with closed list.
        {
            let dir = unique_tmp("w5_subtypes");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            plant(&path, r#"{
                "schema_version": 2,
                "default_category": "memories",
                "confidence_threshold": 0.6,
                "rename_pattern": "",
                "rules": [{
                    "label": "form_types",
                    "subfolder": "forms",
                    "rename_pattern": "form.pdf",
                    "subtypes": [
                        {"name": "W-2", "also_known_as": ["w2"]},
                        {"name": "1099", "also_known_as": []}
                    ]
                }]
            }"#);

            let r = &library_list().expect("list")[0];
            assert!(r.subtypes.is_empty());
            assert_eq!(r.stages.len(), 1);
            let slot = r.stages[0].classify.get("doc_type").expect("doc_type slot");
            match &slot.values {
                SlotValues::Closed(v) => {
                    assert_eq!(v, &vec!["W-2".to_string(), "1099".to_string()]);
                }
                other => panic!("expected closed list, got {:?}", other),
            }

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W5-3: combined signals + subtypes + built-ins — single stage,
        // doc_type from subtypes plus extra slots from templates.
        {
            let dir = unique_tmp("w5_combined");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            plant(&path, r#"{
                "schema_version": 2,
                "default_category": "memories",
                "confidence_threshold": 0.6,
                "rename_pattern": "",
                "rules": [{
                    "label": "tax",
                    "instruction": "Tax materials.",
                    "signals": ["wages"],
                    "subtypes": [{"name": "W-2", "also_known_as": []}],
                    "subfolder": "tax/{year}",
                    "rename_pattern": "{date}.pdf"
                }]
            }"#);

            let r = &library_list().expect("list")[0];
            assert!(r.signals.is_empty());
            assert!(r.subtypes.is_empty());
            assert_eq!(r.stages.len(), 1, "combined migration folds into one stage");
            let classify = &r.stages[0].classify;
            assert!(classify.contains_key("doc_type"));
            assert!(classify.contains_key("year"));
            assert!(classify.contains_key("date"));
            assert!(r.instruction.contains("typical signals include wages"));

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W5-4: already-new-shape rule is untouched on load.
        {
            let dir = unique_tmp("w5_already_new");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            plant(&path, r#"{
                "schema_version": 2,
                "default_category": "memories",
                "confidence_threshold": 0.6,
                "rename_pattern": "",
                "rules": [{
                    "label": "modern",
                    "instruction": "Already migrated.",
                    "subfolder": "modern",
                    "rename_pattern": "file.pdf",
                    "stages": [{
                        "ask": "Is this relevant?",
                        "classify": {"yes": {"description": "yes/no", "values": ["yes", "no"]}},
                        "keep_when": "yes == 'yes'"
                    }]
                }]
            }"#);

            let mtime_before = fs::metadata(&path).unwrap().modified().unwrap();
            std::thread::sleep(std::time::Duration::from_millis(150));
            let _ = library_list().expect("list");
            let mtime_after = fs::metadata(&path).unwrap().modified().unwrap();
            assert_eq!(
                mtime_before, mtime_after,
                "new-shape file must not be rewritten by migration probe"
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // ------------------------------------------------------------------
        // W3 (DCR 019e33bf): library_reorder rule reordering
        // ------------------------------------------------------------------

        // W3-1: happy path — 3 rules reordered, order field persisted to disk.
        {
            let dir = unique_tmp("w3_happy");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("aaa")).expect("insert");
            library_insert(sample_rule("bbb")).expect("insert");
            library_insert(sample_rule("ccc")).expect("insert");

            let new_order: Vec<String> =
                vec!["ccc".to_string(), "aaa".to_string(), "bbb".to_string()];
            let result = library_reorder(&new_order).expect("reorder");
            assert_eq!(result.len(), 3);
            assert_eq!(result[0], ("ccc".to_string(), 0));
            assert_eq!(result[1], ("aaa".to_string(), 10));
            assert_eq!(result[2], ("bbb".to_string(), 20));

            // Confirm persisted to disk (re-read from file).
            *cache().lock().unwrap() = None;
            let rules = library_list().expect("list after reorder");
            let by_label: std::collections::HashMap<&str, i64> =
                rules.iter().map(|r| (r.label.as_str(), r.order)).collect();
            assert_eq!(by_label["ccc"], 0);
            assert_eq!(by_label["aaa"], 10);
            assert_eq!(by_label["bbb"], 20);

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W3-2: rejection — missing label.
        {
            let dir = unique_tmp("w3_missing");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("alpha")).expect("insert");
            library_insert(sample_rule("beta")).expect("insert");

            let err = library_reorder(&[String::from("alpha")]).expect_err("missing must reject");
            assert!(
                err.message.contains("missing labels: beta"),
                "expected missing-label error, got: {}",
                err.message
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W3-3: rejection — unknown extra label.
        {
            let dir = unique_tmp("w3_extra");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("alpha")).expect("insert");

            let err = library_reorder(&[String::from("alpha"), String::from("ghost")])
                .expect_err("extra must reject");
            assert!(
                err.message.contains("unknown labels: ghost"),
                "expected unknown-label error, got: {}",
                err.message
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W3-4: rejection — duplicate input.
        {
            let dir = unique_tmp("w3_dup");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("alpha")).expect("insert");
            library_insert(sample_rule("beta")).expect("insert");

            let err =
                library_reorder(&["alpha".into(), "alpha".into()]).expect_err("dup must reject");
            assert!(
                err.message.contains("duplicate"),
                "expected duplicate-label error, got: {}",
                err.message
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }

        // W3-5: empty input on non-empty library — treated as missing every label.
        {
            let dir = unique_tmp("w3_empty");
            let path = dir.join("library.rules.json");
            set_library_path_for_test(path.clone());

            library_insert(sample_rule("solo")).expect("insert");
            let err = library_reorder(&[]).expect_err("empty on non-empty must reject");
            assert!(
                err.message.contains("missing labels: solo"),
                "expected missing-label error, got: {}",
                err.message
            );

            clear_library_path_for_test();
            fs::remove_dir_all(&dir).ok();
        }
    }
}
