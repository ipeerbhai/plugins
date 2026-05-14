//! Persisted destination settings for the Scansort plugin.
//!
//! A vault's "destination" controls where classified documents land:
//!   • `vault_only`     — store only inside the .ssort vault (default)
//!   • `disk_only`      — copy to a disk root path, no vault entry
//!   • `vault_and_disk` — copy to both
//!
//! Unlike source state, destination IS persisted in the vault's `project`
//! key-value table so it survives process restarts.
//!
//! Three MCP tools use this module:
//!   • minerva_scansort_set_destination
//!   • minerva_scansort_get_destination
//!   • minerva_scansort_place_on_disk

use crate::db;
use crate::types::{VaultError, VaultResult};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const KEY_MODE: &str = "destination_mode";
const KEY_DISK_ROOT: &str = "destination_disk_root";
const VALID_MODES: &[&str] = &["vault_only", "disk_only", "vault_and_disk"];
const DEFAULT_MODE: &str = "vault_only";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Persist the destination mode (and optional disk root) into the vault's
/// `project` table.
///
/// * `mode` must be one of `vault_only`, `disk_only`, `vault_and_disk`.
/// * For `disk_only` / `vault_and_disk`, `disk_root` must be `Some(non-empty)`.
/// * For `vault_only`, `disk_root` is ignored and stored as `""`.
pub fn set_destination(vault_path: &str, mode: &str, disk_root: Option<&str>) -> VaultResult<()> {
    if !VALID_MODES.contains(&mode) {
        return Err(VaultError::new(format!(
            "invalid destination mode {:?}; must be one of: {}",
            mode,
            VALID_MODES.join(", ")
        )));
    }

    let root_value = if mode == "vault_only" {
        // disk_root is irrelevant for vault_only
        "".to_string()
    } else {
        let root = disk_root.unwrap_or("").trim();
        if root.is_empty() {
            return Err(VaultError::new(format!(
                "disk_root is required (non-empty) for destination mode {:?}",
                mode
            )));
        }
        root.to_string()
    };

    let conn = db::connect(vault_path)?;
    db::set_project_key(&conn, KEY_MODE, mode)?;
    db::set_project_key(&conn, KEY_DISK_ROOT, &root_value)?;
    Ok(())
}

/// Read the destination settings from the vault's `project` table.
///
/// Defaults when unset: `mode = "vault_only"`, `disk_root = ""`.
pub fn get_destination(vault_path: &str) -> VaultResult<(String, String)> {
    let conn = db::connect(vault_path)?;
    let mode = db::get_project_key(&conn, KEY_MODE)?
        .unwrap_or_else(|| DEFAULT_MODE.to_string());
    let disk_root = db::get_project_key(&conn, KEY_DISK_ROOT)?
        .unwrap_or_default();
    Ok((mode, disk_root))
}

/// Copy `file_path` to its resolved on-disk location under `disk_root`.
///
/// * `subfolder`      — path component appended to `disk_root`; may contain
///                      `{year}` and `{date}` templates.
/// * `doc_date`       — ISO-ish `YYYY-MM-DD` string used to resolve templates.
/// * `rename_pattern` — optional base-name template (extension preserved);
///                      when `None` or empty the original filename is kept.
///
/// Template values:
///   `{year}` → 4-digit year from `doc_date`, or `"unknown"` if unparseable / empty.
///   `{date}` → `doc_date` as-is, or `"undated"` if empty.
///
/// The resolved subfolder components are sanitised (no `/` or `..` allowed in
/// template-expanded values).
///
/// Target is created (with parents) if missing. Collisions are resolved by
/// appending ` (1)`, ` (2)`, … before the extension.
///
/// Returns the absolute path of the placed file.
pub fn place_on_disk(
    vault_path: &str,
    file_path: &str,
    subfolder: &str,
    doc_date: &str,
    rename_pattern: Option<&str>,
) -> VaultResult<PathBuf> {
    place_on_disk_with_issuer(vault_path, file_path, subfolder, doc_date, rename_pattern, "")
}

/// Extended variant of `place_on_disk` that also accepts an `issuer` value for
/// template expansion (`{issuer}` / `{sender}` tokens in `rename_pattern`).
pub fn place_on_disk_with_issuer(
    vault_path: &str,
    file_path: &str,
    subfolder: &str,
    doc_date: &str,
    rename_pattern: Option<&str>,
    issuer: &str,
) -> VaultResult<PathBuf> {
    // Resolve disk_root.
    let (_, disk_root) = get_destination(vault_path)?;
    if disk_root.is_empty() {
        return Err(VaultError::new(
            "disk_root is not configured; cannot place file on disk (destination mode may be vault_only)".to_string(),
        ));
    }

    // Template values.
    let year_val = parse_year(doc_date);
    let date_val = if doc_date.is_empty() {
        "undated".to_string()
    } else {
        doc_date.to_string()
    };

    // Resolve and sanitise subfolder.
    let resolved_subfolder = resolve_and_sanitise(subfolder, &year_val, &date_val, issuer)?;

    // Build target directory.
    let target_dir = if resolved_subfolder.is_empty() {
        PathBuf::from(&disk_root)
    } else {
        Path::new(&disk_root).join(&resolved_subfolder)
    };

    // Create target directory (and parents) if missing.
    std::fs::create_dir_all(&target_dir).map_err(|e| {
        VaultError::new(format!(
            "cannot create directory {}: {}",
            target_dir.display(),
            e
        ))
    })?;

    // Determine the source file's extension.
    let src_path = Path::new(file_path);
    let src_ext = src_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{e}"))
        .unwrap_or_default();

    // Determine the base name (without extension).
    let base_stem: String = match rename_pattern.filter(|p| !p.is_empty()) {
        Some(pattern) => resolve_and_sanitise(pattern, &year_val, &date_val, issuer)?,
        None => src_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("document")
            .to_string(),
    };

    // Collision-safe target path.
    let target_path = collision_safe_path(&target_dir, &base_stem, &src_ext);

    // Copy the file.
    std::fs::copy(file_path, &target_path).map_err(|e| {
        VaultError::new(format!(
            "failed to copy {} → {}: {}",
            file_path,
            target_path.display(),
            e
        ))
    })?;

    // Return absolute path.
    target_path.canonicalize().or(Ok(target_path)).map_err(|e: std::io::Error| {
        VaultError::new(format!("canonicalize error: {e}"))
    })
}

/// List every regular file under the vault's configured disk_root, recursively.
/// Returns Vec of (absolute_path, file_name, rel_path_from_disk_root, size_bytes).
/// Returns an empty Vec (Ok) when disk_root is unset/empty or does not exist —
/// this is not an error (vault_only vaults have no disk tree).
pub fn list_disk_files(vault_path: &str) -> VaultResult<Vec<(String, String, String, u64)>> {
    let (_, disk_root) = get_destination(vault_path)?;
    if disk_root.is_empty() {
        return Ok(vec![]);
    }
    let root_path = Path::new(&disk_root);
    if !root_path.exists() {
        return Ok(vec![]);
    }

    let mut results: Vec<(String, String, String, u64)> = Vec::new();
    collect_disk_files(root_path, root_path, &mut results)?;
    results.sort_by(|a, b| a.2.cmp(&b.2));
    Ok(results)
}

/// Recursive helper for list_disk_files.
fn collect_disk_files(
    root: &Path,
    dir: &Path,
    out: &mut Vec<(String, String, String, u64)>,
) -> VaultResult<()> {
    let entries = std::fs::read_dir(dir).map_err(|e| {
        VaultError::new(format!("cannot read directory {}: {}", dir.display(), e))
    })?;
    for entry_result in entries {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        if path.is_dir() {
            collect_disk_files(root, &path, out)?;
            continue;
        }
        if !path.is_file() {
            continue;
        }
        let abs_path = path
            .canonicalize()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();
        let rel_path = path
            .strip_prefix(root)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| file_name.clone());
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        out.push((abs_path, file_name, rel_path, size));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Parse the 4-digit year from an ISO-ish `YYYY-MM-DD` string.
/// Returns `"unknown"` on empty input or parse failure.
fn parse_year(doc_date: &str) -> String {
    if doc_date.is_empty() {
        return "unknown".to_string();
    }
    // Expect at least 4 chars; take the first 4 and check they're ASCII digits.
    let prefix: &str = doc_date.get(..4).unwrap_or("");
    if prefix.len() == 4 && prefix.chars().all(|c| c.is_ascii_digit()) {
        prefix.to_string()
    } else {
        "unknown".to_string()
    }
}

/// Apply `{year}` / `{date}` / `{issuer}` templates to `s`, then sanitise each
/// `/`-delimited path component so no component is `..` or contains a literal `/`.
///
/// `{sender}` is accepted as a backward-compat alias for `{issuer}`.
///
/// We split on `/`, resolve templates in each component, reject traversal, and
/// rejoin with the OS separator.
fn resolve_and_sanitise(s: &str, year: &str, date: &str, issuer: &str) -> VaultResult<String> {
    let replaced = s
        .replace("{year}", year)
        .replace("{date}", date)
        .replace("{issuer}", issuer)
        .replace("{sender}", issuer); // backward-compat alias

    // Validate each path component.
    let mut parts: Vec<String> = Vec::new();
    for component in replaced.split('/') {
        // Skip empty components (leading / trailing slash, double slash).
        if component.is_empty() {
            continue;
        }
        if component == ".." {
            return Err(VaultError::new(format!(
                "path traversal detected in template result: {:?}",
                replaced
            )));
        }
        // A component must not itself contain a path separator (shouldn't
        // happen after splitting, but guard anyway for non-Unix separators).
        if component.contains(std::path::MAIN_SEPARATOR) {
            return Err(VaultError::new(format!(
                "resolved template contains path separator: {:?}",
                component
            )));
        }
        parts.push(component.to_string());
    }

    Ok(parts.join(std::path::MAIN_SEPARATOR_STR))
}

/// Find a collision-safe path in `dir` for `<stem><ext>`.
/// If `<stem><ext>` is free, returns it. Otherwise tries
/// `<stem> (1)<ext>`, `<stem> (2)<ext>`, … until a free slot is found.
fn collision_safe_path(dir: &Path, stem: &str, ext: &str) -> PathBuf {
    let first = dir.join(format!("{stem}{ext}"));
    if !first.exists() {
        return first;
    }
    let mut n: u32 = 1;
    loop {
        let candidate = dir.join(format!("{stem} ({n}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
        n += 1;
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

    fn unique_tmp(prefix: &str) -> std::path::PathBuf {
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir().join(format!("scansort-dest-{prefix}-{pid}-{ts}-{n}"))
    }

    /// Create a minimal vault with the `project` table (and fingerprints table
    /// so db::connect doesn't trip over schema checks).
    fn make_vault(path: &std::path::Path) {
        crate::vault_lifecycle::create_vault(path.to_str().unwrap(), "test-vault").unwrap();
    }

    // (a) set→get round-trip for each mode.
    #[test]
    fn set_get_vault_only() {
        let base = unique_tmp("rtrip-vo");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        set_destination(vp, "vault_only", None).expect("set vault_only");
        let (mode, root) = get_destination(vp).expect("get");
        assert_eq!(mode, "vault_only");
        assert_eq!(root, "");

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn set_get_disk_only() {
        let base = unique_tmp("rtrip-do");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();
        let disk = base.join("disk");

        set_destination(vp, "disk_only", Some(disk.to_str().unwrap())).expect("set disk_only");
        let (mode, root) = get_destination(vp).expect("get");
        assert_eq!(mode, "disk_only");
        assert_eq!(root, disk.to_str().unwrap());

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn set_get_vault_and_disk() {
        let base = unique_tmp("rtrip-vd");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();
        let disk = base.join("disk");

        set_destination(vp, "vault_and_disk", Some(disk.to_str().unwrap()))
            .expect("set vault_and_disk");
        let (mode, root) = get_destination(vp).expect("get");
        assert_eq!(mode, "vault_and_disk");
        assert_eq!(root, disk.to_str().unwrap());

        std::fs::remove_dir_all(&base).ok();
    }

    // (b) get_destination returns vault_only/"" defaults on a fresh vault.
    #[test]
    fn get_defaults_on_fresh_vault() {
        let base = unique_tmp("defaults");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let (mode, root) = get_destination(vp).expect("get");
        assert_eq!(mode, "vault_only");
        assert_eq!(root, "");

        std::fs::remove_dir_all(&base).ok();
    }

    // (c) mode validation rejects a bogus mode.
    #[test]
    fn rejects_bogus_mode() {
        let base = unique_tmp("badmode");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let err = set_destination(vp, "nowhere", None).unwrap_err();
        assert!(
            err.message.contains("invalid destination mode"),
            "error was: {}",
            err.message
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // (d) disk_only/vault_and_disk without disk_root is rejected.
    #[test]
    fn rejects_disk_only_without_disk_root() {
        let base = unique_tmp("nodisk-do");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let err = set_destination(vp, "disk_only", None).unwrap_err();
        assert!(
            err.message.contains("disk_root is required"),
            "error was: {}",
            err.message
        );

        let err2 = set_destination(vp, "disk_only", Some("")).unwrap_err();
        assert!(
            err2.message.contains("disk_root is required"),
            "error was: {}",
            err2.message
        );

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn rejects_vault_and_disk_without_disk_root() {
        let base = unique_tmp("nodisk-vd");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let err = set_destination(vp, "vault_and_disk", Some("  ")).unwrap_err();
        assert!(
            err.message.contains("disk_root is required"),
            "error was: {}",
            err.message
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // (e) place_on_disk resolves {year}/{date} in the subfolder.
    #[test]
    fn place_resolves_templates_in_subfolder() {
        let base = unique_tmp("tmpl");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let disk = base.join("disk");
        set_destination(vp, "disk_only", Some(disk.to_str().unwrap())).unwrap();

        // Source file.
        let src = base.join("invoice.pdf");
        std::fs::write(&src, b"pdf content").unwrap();

        let placed = place_on_disk(
            vp,
            src.to_str().unwrap(),
            "{year}/{date}",
            "2024-03-15",
            None,
        )
        .expect("place_on_disk");

        // Must land under disk/2024/2024-03-15/
        let placed_str = placed.to_string_lossy();
        assert!(
            placed_str.contains("2024"),
            "year not in path: {placed_str}"
        );
        assert!(
            placed_str.contains("2024-03-15"),
            "date not in path: {placed_str}"
        );
        assert!(placed.exists(), "placed file must exist");

        std::fs::remove_dir_all(&base).ok();
    }

    // (f) collision safety — placing the same file twice yields two distinct files.
    #[test]
    fn place_collision_safety() {
        let base = unique_tmp("coll");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let disk = base.join("disk");
        set_destination(vp, "disk_only", Some(disk.to_str().unwrap())).unwrap();

        let src = base.join("report.pdf");
        std::fs::write(&src, b"report content").unwrap();

        let p1 = place_on_disk(vp, src.to_str().unwrap(), "docs", "2024-01-01", None)
            .expect("first place");
        let p2 = place_on_disk(vp, src.to_str().unwrap(), "docs", "2024-01-01", None)
            .expect("second place");

        assert_ne!(p1, p2, "two placements must have distinct paths");
        assert!(p1.exists());
        assert!(p2.exists());

        // Second file should contain " (1)" in its name.
        let name2 = p2.file_name().unwrap().to_string_lossy();
        assert!(
            name2.contains("(1)"),
            "second file should have (1) suffix, got: {name2}"
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // (g) place_on_disk creates missing intermediate directories.
    #[test]
    fn place_creates_intermediate_dirs() {
        let base = unique_tmp("mkdir");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let disk = base.join("output"); // does NOT exist yet
        set_destination(vp, "disk_only", Some(disk.to_str().unwrap())).unwrap();

        let src = base.join("doc.pdf");
        std::fs::write(&src, b"doc").unwrap();

        let placed = place_on_disk(
            vp,
            src.to_str().unwrap(),
            "a/b/c",
            "2023-06-01",
            None,
        )
        .expect("place_on_disk with deep subfolder");

        assert!(placed.exists(), "placed file must exist");
        assert!(
            placed.to_string_lossy().contains("a"),
            "path should contain subfolder a"
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // (h) place_on_disk with rename_pattern renames while preserving extension.
    #[test]
    fn place_rename_pattern_preserves_extension() {
        let base = unique_tmp("rename");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();

        let disk = base.join("disk");
        set_destination(vp, "disk_only", Some(disk.to_str().unwrap())).unwrap();

        let src = base.join("ugly_scan_001.pdf");
        std::fs::write(&src, b"scan content").unwrap();

        let placed = place_on_disk(
            vp,
            src.to_str().unwrap(),
            "invoices",
            "2025-11-20",
            Some("invoice-{date}"),
        )
        .expect("place with rename");

        let name = placed.file_name().unwrap().to_string_lossy();
        assert_eq!(name, "invoice-2025-11-20.pdf", "expected renamed file, got: {name}");
        assert!(placed.exists());

        std::fs::remove_dir_all(&base).ok();
    }

    // place_on_disk returns error when disk_root is empty (vault_only mode).
    #[test]
    fn place_errors_on_vault_only() {
        let base = unique_tmp("vo-place");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();
        // Default is vault_only — no need to set.

        let src = base.join("doc.pdf");
        std::fs::write(&src, b"x").unwrap();

        let err = place_on_disk(vp, src.to_str().unwrap(), "sub", "2024-01-01", None)
            .unwrap_err();
        assert!(
            err.message.contains("disk_root is not configured"),
            "error was: {}",
            err.message
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // (i) list_disk_files returns empty on a vault_only vault (no disk_root configured).
    #[test]
    fn list_disk_files_empty_on_vault_only() {
        let base = unique_tmp("ldf-vo");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();
        // Default mode is vault_only — no disk_root.
        let files = list_disk_files(vp).expect("list_disk_files");
        assert!(files.is_empty(), "vault_only should yield empty list");
        std::fs::remove_dir_all(&base).ok();
    }

    // (j) list_disk_files returns correct entries after placing files in nested subdirs.
    #[test]
    fn list_disk_files_after_placing_files() {
        let base = unique_tmp("ldf-files");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();
        let disk = base.join("disk");
        std::fs::create_dir_all(&disk).unwrap();

        set_destination(vp, "disk_only", Some(disk.to_str().unwrap())).unwrap();

        // Place two files in different nested subdirs.
        let sub1 = disk.join("invoices").join("2024");
        let sub2 = disk.join("receipts");
        std::fs::create_dir_all(&sub1).unwrap();
        std::fs::create_dir_all(&sub2).unwrap();
        std::fs::write(sub1.join("invoice_a.pdf"), b"invoice a").unwrap();
        std::fs::write(sub2.join("receipt_b.pdf"), b"receipt b").unwrap();

        let files = list_disk_files(vp).expect("list_disk_files");
        assert_eq!(files.len(), 2, "expected 2 files, got {}", files.len());

        // Check rel_paths sort correctly (invoices/2024/invoice_a.pdf < receipts/receipt_b.pdf).
        let rel_paths: Vec<&str> = files.iter().map(|f| f.2.as_str()).collect();
        assert!(
            rel_paths.iter().any(|r| r.contains("invoice_a.pdf")),
            "invoice_a.pdf rel_path missing: {rel_paths:?}"
        );
        assert!(
            rel_paths.iter().any(|r| r.contains("receipt_b.pdf")),
            "receipt_b.pdf rel_path missing: {rel_paths:?}"
        );
        // Verify sizes.
        for (_, name, _, size) in &files {
            assert!(*size > 0, "size should be > 0 for {name}");
        }

        std::fs::remove_dir_all(&base).ok();
    }

    // (k) list_disk_files returns empty when disk_root points to a non-existent dir.
    #[test]
    fn list_disk_files_empty_when_disk_root_missing() {
        let base = unique_tmp("ldf-nodir");
        std::fs::create_dir_all(&base).unwrap();
        let vault = base.join("v.ssort");
        make_vault(&vault);
        let vp = vault.to_str().unwrap();
        // Point disk_root at a directory that does not exist.
        let nonexistent = base.join("does_not_exist");
        set_destination(vp, "disk_only", Some(nonexistent.to_str().unwrap())).unwrap();

        let files = list_disk_files(vp).expect("list_disk_files should return Ok([])");
        assert!(files.is_empty(), "non-existent disk_root should yield empty list");
        std::fs::remove_dir_all(&base).ok();
    }

    // parse_year helper: graceful fallback for bad/empty input.
    #[test]
    fn parse_year_fallback() {
        assert_eq!(parse_year("2024-03-15"), "2024");
        assert_eq!(parse_year(""), "unknown");
        assert_eq!(parse_year("not-a-date"), "unknown");
        assert_eq!(parse_year("20"), "unknown"); // too short
    }
}
