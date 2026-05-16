//! W8: reprocess a destination + set/clear the locked flag.
//!
//! ## Reprocess model
//!
//! The default Process All pipeline is strictly additive (dedup-skip).
//! Reprocess is a **separate, deliberately-destructive** path that clears a
//! destination's state so a clean re-run can re-populate it.
//!
//! Callers MUST gate this behind an explicit confirm dialog in the UI.
//! The backend also enforces the `locked` flag as a second line of defence.
//!
//! ### Per-destination semantics
//!
//! **Directory destination**: delete every *regular file* directly inside the
//! directory.  Sub-directories are NOT removed (they may contain user data
//! unrelated to scansort).  The folder itself stays.  Clearing only the
//! immediate regular files is the minimal-destructive choice: scansort places
//! files at the top level of the destination (or in category subfolders); those
//! files are what gets re-created on re-run.
//!
//! **Vault destination**: delete ALL rows from the `documents` and
//! `fingerprints` tables.  This is the correct "invalidate" semantic because
//! the entire vault was built by previous process runs and must be re-derived.
//! Partial deletes (e.g., only rows matching a source_path) could leave stale
//! fingerprints and cause incorrect dedup-skips on re-run.
//!
//! ### Path sanity-check for directory destinations
//!
//! Refused if the destination directory path:
//!   - is empty or "/",
//!   - is a single component (e.g. "/home", "/tmp"),
//!   - equals the user's $HOME,
//!   - equals an OS root that is hard-coded as unsafe.
//!
//! The exact rule: the canonicalised path must have ≥ 3 components and must
//! not be one of: `/`, `/home`, `/tmp`, `/var`, `/etc`, `/usr`, `/bin`, `/root`.

use crate::db;
use crate::destinations;
use crate::types::{VaultError, VaultResult};
use rusqlite::params;
use std::fs;
use std::path::Path;

// ---------------------------------------------------------------------------
// Dangerous path prefixes / exact matches
// ---------------------------------------------------------------------------

/// Exact paths that are always refused for clearing.
const DANGEROUS_EXACT: &[&str] = &[
    "/",
    "/home",
    "/tmp",
    "/var",
    "/etc",
    "/usr",
    "/bin",
    "/root",
    "/sbin",
    "/lib",
    "/lib64",
    "/boot",
    "/dev",
    "/sys",
    "/proc",
    "/opt",
    "/mnt",
    "/media",
    "/srv",
];

/// Minimum number of path components required.  Enforces that the path is
/// at least three levels deep (e.g. `/home/user/docs`).
const MIN_COMPONENT_DEPTH: usize = 3;

/// Return an error if `path` is considered too dangerous to empty.
fn check_directory_safety(path: &str) -> VaultResult<()> {
    if path.is_empty() {
        return Err(VaultError::new(
            "Reprocess refused: directory path is empty.".to_string(),
        ));
    }

    let p = Path::new(path);

    // Reject any `..` (parent-dir) component. Canonicalization in
    // reprocess_directory resolves these anyway, but a `..` in the raw path
    // (e.g. "/a/b/../../etc") can defeat the depth heuristic, so reject it
    // outright — defense in depth for any direct caller of this function.
    if p.components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(VaultError::new(format!(
            "Reprocess refused: directory path '{}' contains a '..' traversal component.",
            path,
        )));
    }

    // Count only Normal (non-root, non-separator) path components.
    // e.g. "/" → 0, "/home" → 1, "/home/user" → 2, "/home/user/docs" → 3.
    // We require ≥ MIN_COMPONENT_DEPTH meaningful components so that
    // overly short paths like "/" "/home" "/home/user" are refused.
    let normal_count = p
        .components()
        .filter(|c| matches!(c, std::path::Component::Normal(_)))
        .count();
    if normal_count < MIN_COMPONENT_DEPTH {
        return Err(VaultError::new(format!(
            "Reprocess refused: directory '{}' is too shallow (< {} path components). \
             Specify a deeper path to avoid accidental data loss.",
            path, MIN_COMPONENT_DEPTH,
        )));
    }

    // Check home directory via environment variable.
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() && path == home.as_str() {
            return Err(VaultError::new(format!(
                "Reprocess refused: '{}' is your home directory.",
                path
            )));
        }
    }

    // Exact-match against the known-dangerous set.
    for &dangerous in DANGEROUS_EXACT {
        if path == dangerous {
            return Err(VaultError::new(format!(
                "Reprocess refused: '{}' is a system-critical path.",
                path
            )));
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Outcome of a `reprocess_destination` call.
#[derive(Debug)]
pub struct ReprocessResult {
    /// Destination id that was reprocessed.
    pub destination_id: String,
    /// `"vault"` or `"directory"`.
    pub kind: String,
    /// Human-readable summary of what was cleared.
    pub summary: String,
    /// Number of items removed (files deleted, or document rows deleted).
    pub cleared_count: usize,
}

/// Reprocess a destination: clear its state so a fresh Process All re-run
/// re-populates it from scratch.
///
/// - Looks up `destination_id` in the registry at `registry_path`.
/// - If the destination is `locked`, returns an error — does NOT clear.
/// - For `directory` kind: deletes regular files in the directory (with
///   safety-check on the path).
/// - For `vault` kind: deletes all rows from `documents` and `fingerprints`.
/// - Default Process All is UNAFFECTED — this is a separate code path.
pub fn reprocess_destination(
    registry_path: &Path,
    destination_id: &str,
) -> VaultResult<ReprocessResult> {
    let reg = destinations::load_or_init(registry_path)?;
    let dest = destinations::find_by_id(&reg, destination_id).ok_or_else(|| {
        VaultError::new(format!("Destination not found: '{}'", destination_id))
    })?;

    if dest.locked {
        return Err(VaultError::new(format!(
            "Destination '{}' ({}) is locked/final. Unlock it before reprocessing.",
            dest.label, dest.id,
        )));
    }

    match dest.kind.as_str() {
        "directory" => reprocess_directory(&dest.path, destination_id, &dest.label),
        "vault" => reprocess_vault(&dest.path, destination_id, &dest.label),
        other => Err(VaultError::new(format!(
            "Unknown destination kind '{}' for '{}'",
            other, destination_id,
        ))),
    }
}

/// Clear all regular files from a directory destination.
fn reprocess_directory(
    dir_path: &str,
    destination_id: &str,
    label: &str,
) -> VaultResult<ReprocessResult> {
    // First-pass check on the raw input (rejects empty / `..` / shallow).
    check_directory_safety(dir_path)?;

    let raw = Path::new(dir_path);
    if !raw.exists() {
        return Err(VaultError::new(format!(
            "Directory destination '{}' does not exist: {}",
            label, dir_path,
        )));
    }

    // Canonicalize to resolve symlinks and any residual `.`/`..` so the
    // safety check operates on the REAL target — a symlinked destination
    // dir pointing at a shallow/system path cannot bypass the depth guard.
    let dir = raw.canonicalize().map_err(|e| {
        VaultError::new(format!(
            "Cannot canonicalize directory '{}': {}",
            dir_path, e,
        ))
    })?;
    if !dir.is_dir() {
        return Err(VaultError::new(format!(
            "Path '{}' is not a directory (destination: {})",
            dir_path, label,
        )));
    }
    // Re-run the safety check against the resolved canonical path.
    check_directory_safety(&dir.to_string_lossy())?;

    let mut deleted: Vec<String> = Vec::new();
    let mut errors: Vec<String> = Vec::new();

    let entries = fs::read_dir(&dir).map_err(|e| {
        VaultError::new(format!(
            "Cannot read directory '{}': {}",
            dir.display(), e,
        ))
    })?;

    for entry_result in entries {
        let entry = match entry_result {
            Ok(e) => e,
            Err(e) => {
                errors.push(format!("read_dir entry error: {}", e));
                continue;
            }
        };
        let entry_path = entry.path();
        if entry_path.is_file() {
            match fs::remove_file(&entry_path) {
                Ok(()) => deleted.push(entry_path.to_string_lossy().to_string()),
                Err(e) => errors.push(format!(
                    "failed to delete {}: {}",
                    entry_path.display(),
                    e,
                )),
            }
        }
        // Subdirectories are intentionally left untouched.
    }

    if !errors.is_empty() {
        return Err(VaultError::new(format!(
            "Reprocess directory '{}' encountered {} error(s): {}",
            dir_path,
            errors.len(),
            errors.join("; "),
        )));
    }

    let count = deleted.len();
    Ok(ReprocessResult {
        destination_id: destination_id.to_string(),
        kind: "directory".to_string(),
        summary: format!(
            "Cleared {} regular file(s) from directory '{}'",
            count, dir_path,
        ),
        cleared_count: count,
    })
}

/// Delete all documents and fingerprints rows from a vault destination.
fn reprocess_vault(
    vault_path: &str,
    destination_id: &str,
    label: &str,
) -> VaultResult<ReprocessResult> {
    let mut conn = db::connect(vault_path)?;

    // Temporarily disable FK enforcement so we can delete in one pass.
    // All referencing tables (fingerprints, log, dupes) will have their
    // doc_id become dangling — they are audit/helper tables and empty is
    // the correct post-reprocess state for fingerprints.  log rows are
    // historical audit; leaving them intact with NULL-able doc_id FK is safe.
    // The pragma must be set OUTSIDE a transaction (SQLite ignores it inside
    // one), so toggle it around the transaction below.
    conn.pragma_update(None, "foreign_keys", "OFF")?;

    // Delete in a transaction so a mid-way failure rolls back rather than
    // leaving the vault half-cleared.
    let (fp_deleted, doc_deleted) = {
        let tx = conn.transaction()?;
        // Delete referencing tables first, then documents.
        let fp_deleted = tx.execute("DELETE FROM fingerprints", [])?;
        let doc_deleted = tx.execute("DELETE FROM documents", [])?;
        // dupes table (if it exists) holds matched_doc_id references — clear
        // it too; ignore the error when the table is absent.
        let _ = tx.execute("DELETE FROM dupes", []);
        tx.commit()?;
        (fp_deleted, doc_deleted)
    };

    // Re-enable FK enforcement.
    conn.pragma_update(None, "foreign_keys", "ON")?;

    // Log the reprocess event (FK back on, doc_id=NULL is fine for log rows).
    let now = crate::types::now_iso();
    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'reprocess', ?2, NULL)",
        params![
            now,
            format!(
                "Reprocess: deleted {} document(s) and {} fingerprint(s)",
                doc_deleted, fp_deleted,
            ),
        ],
    )?;

    let count = doc_deleted;
    Ok(ReprocessResult {
        destination_id: destination_id.to_string(),
        kind: "vault".to_string(),
        summary: format!(
            "Deleted {} document row(s) and {} fingerprint row(s) from vault '{}' ({})",
            doc_deleted, fp_deleted, label, vault_path,
        ),
        cleared_count: count,
    })
}

// ---------------------------------------------------------------------------
// set_destination_locked — toggle the locked / final flag.
// ---------------------------------------------------------------------------

/// Set the `locked` flag on a destination in the registry.
///
/// Loads the registry, mutates the matching destination's `locked` field,
/// and saves back.  Returns the updated `Destination` on success.
pub fn set_destination_locked(
    registry_path: &Path,
    destination_id: &str,
    locked: bool,
) -> VaultResult<destinations::Destination> {
    let mut reg = destinations::load_or_init(registry_path)?;

    let dest = reg
        .destinations
        .iter_mut()
        .find(|d| d.id == destination_id)
        .ok_or_else(|| {
            VaultError::new(format!("Destination not found: '{}'", destination_id))
        })?;

    dest.locked = locked;
    let updated = dest.clone();

    destinations::save(registry_path, &reg)?;
    Ok(updated)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::destinations;
    use crate::vault_lifecycle;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_tmp(prefix: &str) -> std::path::PathBuf {
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir()
            .join(format!("scansort-reprocess-{prefix}-{pid}-{ts}-{n}"))
    }

    // -----------------------------------------------------------------------
    // 1. reprocess_destination errors on locked destination.
    // -----------------------------------------------------------------------
    #[test]
    fn reprocess_locked_destination_returns_error() {
        let dir = unique_tmp("locked");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        let dest_dir = dir.join("output");
        std::fs::create_dir_all(&dest_dir).unwrap();

        let mut reg = destinations::DestinationRegistry::default();
        let dest = destinations::add(
            &mut reg,
            "directory",
            dest_dir.to_str().unwrap(),
            Some("Locked Output"),
            true, // locked = true
        )
        .expect("add");
        destinations::save(&reg_path, &reg).expect("save");

        let err = reprocess_destination(&reg_path, &dest.id)
            .expect_err("should refuse locked destination");
        assert!(
            err.to_string().contains("locked") || err.to_string().contains("Locked"),
            "error should mention 'locked': {}",
            err
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 2. reprocess_destination errors on unknown destination id.
    // -----------------------------------------------------------------------
    #[test]
    fn reprocess_unknown_destination_returns_error() {
        let dir = unique_tmp("unknown");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        let reg = destinations::DestinationRegistry::default();
        destinations::save(&reg_path, &reg).expect("save");

        let err = reprocess_destination(&reg_path, "nonexistent-99")
            .expect_err("should fail for unknown id");
        assert!(err.to_string().contains("not found") || err.to_string().contains("Destination"));
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 3. reprocess directory: clears regular files, leaves subdirs.
    // -----------------------------------------------------------------------
    #[test]
    fn reprocess_directory_clears_files_leaves_subdirs() {
        let dir = unique_tmp("dir-clear");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        // Create a destination directory with a path deep enough to pass sanity check.
        let dest_dir = dir.join("some/deep/output");
        std::fs::create_dir_all(&dest_dir).unwrap();

        // Place some regular files.
        std::fs::write(dest_dir.join("doc1.pdf"), b"data1").unwrap();
        std::fs::write(dest_dir.join("doc2.txt"), b"data2").unwrap();
        // Place a subdirectory.
        let subdir = dest_dir.join("subdir");
        std::fs::create_dir_all(&subdir).unwrap();
        std::fs::write(subdir.join("nested.pdf"), b"nested").unwrap();

        let mut reg = destinations::DestinationRegistry::default();
        let dest = destinations::add(
            &mut reg,
            "directory",
            dest_dir.to_str().unwrap(),
            Some("Deep Output"),
            false, // not locked
        )
        .expect("add");
        destinations::save(&reg_path, &reg).expect("save");

        let result = reprocess_destination(&reg_path, &dest.id)
            .expect("reprocess should succeed");
        assert_eq!(result.kind, "directory");
        assert_eq!(result.cleared_count, 2, "should have deleted 2 regular files");
        // Regular files gone.
        assert!(!dest_dir.join("doc1.pdf").exists(), "doc1.pdf should be deleted");
        assert!(!dest_dir.join("doc2.txt").exists(), "doc2.txt should be deleted");
        // Subdir still present.
        assert!(subdir.exists(), "subdirectory should survive");
        assert!(subdir.join("nested.pdf").exists(), "file inside subdir should survive");
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 4. reprocess vault: deletes all documents and fingerprints rows.
    // -----------------------------------------------------------------------
    #[test]
    fn reprocess_vault_deletes_all_documents() {
        let dir = unique_tmp("vault-clear");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        let vault_path = dir.join("archive.ssort");

        // Create and populate a real vault.
        vault_lifecycle::create_vault(vault_path.to_str().unwrap(), "TestArchive")
            .expect("create vault");

        // Insert a document (we need a real file on disk).
        let src_file = dir.join("sample.txt");
        std::fs::write(&src_file, b"hello world").unwrap();
        let doc_id = crate::documents::insert_document(
            vault_path.to_str().unwrap(),
            src_file.to_str().unwrap(),
            "test",
            0.9,
            "tester",
            "test doc",
            "2024-01-01",
            "classified",
            "",
            "0000000000000000",
            "0000000000000000",
            "",
            "",
            "",
            "",
        )
        .expect("insert_document");
        assert!(doc_id > 0);

        let mut reg = destinations::DestinationRegistry::default();
        let dest = destinations::add(
            &mut reg,
            "vault",
            vault_path.to_str().unwrap(),
            Some("Test Archive"),
            false,
        )
        .expect("add");
        destinations::save(&reg_path, &reg).expect("save");

        let result = reprocess_destination(&reg_path, &dest.id)
            .expect("reprocess should succeed");
        assert_eq!(result.kind, "vault");
        assert_eq!(result.cleared_count, 1, "should have deleted 1 document");

        // Verify documents table is now empty.
        let inventory =
            crate::documents::vault_inventory(vault_path.to_str().unwrap())
                .expect("inventory");
        assert!(inventory.is_empty(), "vault documents should be empty after reprocess");
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 5. Path sanity-check refuses dangerous paths.
    // -----------------------------------------------------------------------
    #[test]
    fn path_sanity_check_refuses_root() {
        let err = check_directory_safety("/").expect_err("should refuse /");
        assert!(err.to_string().contains("system-critical") || err.to_string().contains("shallow"));
    }

    #[test]
    fn path_sanity_check_refuses_single_component() {
        let err = check_directory_safety("/home").expect_err("should refuse /home");
        assert!(
            err.to_string().contains("system-critical")
                || err.to_string().contains("shallow")
                || err.to_string().contains("Refused"),
            "got: {}",
            err,
        );
    }

    #[test]
    fn path_sanity_check_refuses_two_components() {
        // /home/user has only 2 meaningful path components — refused.
        let err = check_directory_safety("/home/user").expect_err("should refuse /home/user");
        assert!(
            err.to_string().contains("shallow") || err.to_string().contains("Refused"),
            "got: {}",
            err,
        );
    }

    #[test]
    fn path_sanity_check_accepts_deep_path() {
        // Three components is the minimum; /tmp/test/output passes.
        check_directory_safety("/tmp/test/output").expect("three-component path should be accepted");
    }

    #[test]
    fn path_sanity_check_refuses_empty() {
        let err = check_directory_safety("").expect_err("should refuse empty path");
        assert!(err.to_string().contains("empty"));
    }

    #[test]
    fn path_sanity_check_refuses_parent_dir_traversal() {
        // "/a/b/../../etc" has 3 Normal components (a, b, etc) and would pass
        // the depth heuristic — the `..` rejection must catch it.
        let err = check_directory_safety("/a/b/../../etc")
            .expect_err("should refuse path with '..' traversal");
        assert!(
            err.to_string().contains(".."),
            "error should mention '..': {}",
            err,
        );
        // A relative traversal too.
        assert!(check_directory_safety("foo/../../bar/baz").is_err());
    }

    #[test]
    fn reprocess_directory_resolves_symlink_before_safety_check() {
        // A symlinked destination dir pointing at a shallow path must be
        // refused — canonicalization resolves the link before the depth check.
        let dir = unique_tmp("symlink-escape");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        // Target is a 1-component-deep dir; the link sits deep enough to pass
        // a naive string check.
        let shallow_target = std::env::temp_dir().join(format!(
            "scansort-shallow-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&shallow_target).ok();
        let link_parent = dir.join("a/b");
        std::fs::create_dir_all(&link_parent).unwrap();
        let link = link_parent.join("link");
        #[cfg(unix)]
        {
            let _ = std::os::unix::fs::symlink(&shallow_target, &link);
            let mut reg = destinations::DestinationRegistry::default();
            let dest = destinations::add(
                &mut reg,
                "directory",
                link.to_str().unwrap(),
                Some("Symlinked"),
                false,
            )
            .expect("add");
            destinations::save(&reg_path, &reg).expect("save");
            // shallow_target has only 2 components (temp dir + name) → refused
            // once canonicalized.
            let result = reprocess_destination(&reg_path, &dest.id);
            assert!(
                result.is_err(),
                "reprocess via symlink to a shallow dir must be refused, got: {:?}",
                result,
            );
        }
        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&shallow_target).ok();
    }

    // -----------------------------------------------------------------------
    // 6. set_destination_locked round-trip.
    // -----------------------------------------------------------------------
    #[test]
    fn set_destination_locked_round_trip() {
        let dir = unique_tmp("locked-rt");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");

        let mut reg = destinations::DestinationRegistry::default();
        let dest = destinations::add(
            &mut reg,
            "vault",
            "/tmp/fake.ssort",
            Some("Test Vault"),
            false, // starts unlocked
        )
        .expect("add");
        destinations::save(&reg_path, &reg).expect("save");

        // Lock it.
        let updated = set_destination_locked(&reg_path, &dest.id, true)
            .expect("set locked");
        assert!(updated.locked, "should now be locked");

        // Verify persisted.
        let reloaded = destinations::load(&reg_path).expect("reload");
        let found = destinations::find_by_id(&reloaded, &dest.id).expect("find");
        assert!(found.locked, "locked flag should be persisted");

        // Unlock it.
        let updated2 = set_destination_locked(&reg_path, &dest.id, false)
            .expect("set unlocked");
        assert!(!updated2.locked, "should now be unlocked");

        let reloaded2 = destinations::load(&reg_path).expect("reload2");
        let found2 = destinations::find_by_id(&reloaded2, &dest.id).expect("find2");
        assert!(!found2.locked, "unlocked should be persisted");

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 7. set_destination_locked errors on unknown id.
    // -----------------------------------------------------------------------
    #[test]
    fn set_destination_locked_unknown_id_returns_error() {
        let dir = unique_tmp("locked-unk");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        let reg = destinations::DestinationRegistry::default();
        destinations::save(&reg_path, &reg).expect("save");

        let err = set_destination_locked(&reg_path, "no-such-id", true)
            .expect_err("should fail");
        assert!(err.to_string().contains("not found") || err.to_string().contains("Destination"));
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 8. After reprocess, locked check still works (lock prevents re-run).
    // -----------------------------------------------------------------------
    #[test]
    fn lock_prevents_reprocess_after_unlock_run_relock() {
        let dir = unique_tmp("lock-cycle");
        std::fs::create_dir_all(&dir).unwrap();
        let reg_path = dir.join("dest_registry.json");
        let dest_dir = dir.join("files/output/here");
        std::fs::create_dir_all(&dest_dir).unwrap();

        let mut reg = destinations::DestinationRegistry::default();
        let dest = destinations::add(
            &mut reg,
            "directory",
            dest_dir.to_str().unwrap(),
            Some("Cycle Test"),
            false,
        )
        .expect("add");
        destinations::save(&reg_path, &reg).expect("save");

        // First reprocess should work (unlocked).
        let r1 = reprocess_destination(&reg_path, &dest.id);
        assert!(r1.is_ok(), "first reprocess should succeed: {:?}", r1);

        // Now lock the destination.
        set_destination_locked(&reg_path, &dest.id, true).expect("lock");

        // Second reprocess should be refused.
        let r2 = reprocess_destination(&reg_path, &dest.id)
            .expect_err("should be refused after locking");
        assert!(r2.to_string().contains("locked") || r2.to_string().contains("Locked"));
        std::fs::remove_dir_all(&dir).ok();
    }
}
