//! Transitory source-directory state for the Scansort plugin.
//!
//! Holds the incoming/source directory the user has pointed the plugin at.
//! State lives only in plugin-process memory — it is never persisted to disk
//! or written into a vault.
//!
//! Three MCP tools use this module:
//!   • minerva_scansort_set_source_dir
//!   • minerva_scansort_get_source_dir
//!   • minerva_scansort_list_source_files

use crate::fingerprints;
use crate::types::{compute_sha256, VaultResult};
use std::cell::RefCell;
use std::path::Path;

// ---------------------------------------------------------------------------
// Supported document extensions (case-insensitive match in list_files).
// ---------------------------------------------------------------------------

const SUPPORTED_EXTS: &[&str] = &[".pdf", ".docx", ".xlsx", ".xls"];

// ---------------------------------------------------------------------------
// Transitory state — thread-local (plugin is single-threaded stdio loop).
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
struct SourceState {
    dir: String,
    recursive: bool,
}

thread_local! {
    static STATE: RefCell<SourceState> = RefCell::new(SourceState::default());
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Set the source directory. Returns Err if the path is not an existing directory.
pub fn set_source_dir(path: &str, recursive: bool) -> VaultResult<()> {
    let p = Path::new(path);
    if !p.exists() {
        return Err(crate::types::VaultError::new(format!(
            "path does not exist: {path}"
        )));
    }
    if !p.is_dir() {
        return Err(crate::types::VaultError::new(format!(
            "path is not a directory: {path}"
        )));
    }
    STATE.with(|s| {
        *s.borrow_mut() = SourceState {
            dir: path.to_string(),
            recursive,
        };
    });
    Ok(())
}

/// Get the current source directory state. Returns (dir, recursive).
/// `dir` is an empty string when no directory has been set.
pub fn get_source_dir() -> (String, bool) {
    STATE.with(|s| {
        let st = s.borrow();
        (st.dir.clone(), st.recursive)
    })
}

/// A single file entry returned by list_source_files.
#[derive(Debug)]
pub struct SourceFile {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub in_vault: bool,
}

/// List supported document files under the stored source directory.
///
/// * Walks the directory (recursive per the stored flag).
/// * Filters to SUPPORTED_EXTS (case-insensitive).
/// * For each file: computes sha256, then checks vault membership when
///   `vault_path` is Some and non-empty.
pub fn list_source_files(vault_path: Option<&str>) -> VaultResult<Vec<SourceFile>> {
    let (dir, recursive) = get_source_dir();
    if dir.is_empty() {
        return Err(crate::types::VaultError::new("no source directory set"));
    }

    let mut files = Vec::new();
    collect_files(Path::new(&dir), recursive, vault_path, &mut files)?;
    files.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(files)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn is_supported(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_lowercase()))
        .unwrap_or_default();
    SUPPORTED_EXTS.contains(&ext.as_str())
}

fn collect_files(
    dir: &Path,
    recursive: bool,
    vault_path: Option<&str>,
    out: &mut Vec<SourceFile>,
) -> VaultResult<()> {
    let entries = std::fs::read_dir(dir).map_err(|e| {
        crate::types::VaultError::new(format!(
            "cannot read directory {}: {}",
            dir.display(),
            e
        ))
    })?;

    for entry_result in entries {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        if path.is_dir() {
            if recursive {
                collect_files(&path, recursive, vault_path, out)?;
            }
            continue;
        }
        if !is_supported(&path) {
            continue;
        }

        let abs_path = path
            .canonicalize()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());

        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();

        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);

        let sha256 = compute_sha256(&path).unwrap_or_default();

        let in_vault = match vault_path {
            Some(vp) if !vp.is_empty() && !sha256.is_empty() => {
                fingerprints::check_sha256(vp, &sha256)
                    .map(|opt| opt.is_some())
                    .unwrap_or(false)
            }
            _ => false,
        };

        out.push(SourceFile {
            path: abs_path,
            name,
            size,
            sha256,
            in_vault,
        });
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
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
        std::env::temp_dir().join(format!("scansort-source-{prefix}-{pid}-{ts}-{n}"))
    }

    /// Seed a real on-disk SQLite vault with the minimal schema needed by
    /// fingerprints::check_sha256, and insert one fingerprint row.
    fn seed_vault(vault_path: &Path, sha256: &str, doc_id: i64) {
        let conn = Connection::open(vault_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS fingerprints (
                sha256 TEXT PRIMARY KEY,
                simhash TEXT,
                dhash TEXT,
                doc_id INTEGER
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) VALUES (?1, '', '', ?2)",
            rusqlite::params![sha256, doc_id],
        )
        .unwrap();
    }

    // (a) set→get round-trip
    #[test]
    fn set_get_round_trip() {
        let dir = unique_tmp("rtrip");
        std::fs::create_dir_all(&dir).unwrap();
        let path_str = dir.to_str().unwrap();

        set_source_dir(path_str, true).expect("set_source_dir");
        let (got_dir, got_recursive) = get_source_dir();
        assert_eq!(got_dir, path_str);
        assert!(got_recursive);

        set_source_dir(path_str, false).expect("set non-recursive");
        let (_, got_r2) = get_source_dir();
        assert!(!got_r2);

        std::fs::remove_dir_all(&dir).ok();
    }

    // set_source_dir rejects non-existent path
    #[test]
    fn set_rejects_nonexistent_path() {
        let result = set_source_dir("/tmp/__does_not_exist_scansort_test__", false);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("does not exist"));
    }

    // set_source_dir rejects a file (not a directory)
    #[test]
    fn set_rejects_file_path() {
        let dir = unique_tmp("notadir");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("file.txt");
        std::fs::write(&file, b"x").unwrap();
        let result = set_source_dir(file.to_str().unwrap(), false);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not a directory"));
        std::fs::remove_dir_all(&dir).ok();
    }

    // (b) list_source_files filters out unsupported extensions
    #[test]
    fn list_filters_unsupported_extensions() {
        let dir = unique_tmp("filter");
        std::fs::create_dir_all(&dir).unwrap();

        // Supported files
        std::fs::write(dir.join("doc.pdf"), b"fake pdf").unwrap();
        std::fs::write(dir.join("report.docx"), b"fake docx").unwrap();
        std::fs::write(dir.join("sheet.xlsx"), b"fake xlsx").unwrap();
        std::fs::write(dir.join("old.xls"), b"fake xls").unwrap();
        // Unsupported
        std::fs::write(dir.join("image.png"), b"fake png").unwrap();
        std::fs::write(dir.join("notes.txt"), b"text").unwrap();
        std::fs::write(dir.join("data.csv"), b"csv").unwrap();

        set_source_dir(dir.to_str().unwrap(), false).unwrap();
        let files = list_source_files(None).expect("list");

        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert!(names.contains(&"doc.pdf"), "pdf should be included");
        assert!(names.contains(&"report.docx"), "docx should be included");
        assert!(names.contains(&"sheet.xlsx"), "xlsx should be included");
        assert!(names.contains(&"old.xls"), "xls should be included");
        assert!(!names.contains(&"image.png"), "png should be excluded");
        assert!(!names.contains(&"notes.txt"), "txt should be excluded");
        assert!(!names.contains(&"data.csv"), "csv should be excluded");
        assert_eq!(files.len(), 4);

        std::fs::remove_dir_all(&dir).ok();
    }

    // (c) list respects the recursive flag
    #[test]
    fn list_respects_recursive_flag() {
        let dir = unique_tmp("recursive");
        let sub = dir.join("subdir");
        std::fs::create_dir_all(&sub).unwrap();

        std::fs::write(dir.join("top.pdf"), b"top level").unwrap();
        std::fs::write(sub.join("nested.pdf"), b"nested").unwrap();

        // Non-recursive: only top.pdf
        set_source_dir(dir.to_str().unwrap(), false).unwrap();
        let files_flat = list_source_files(None).expect("list flat");
        let names_flat: Vec<&str> = files_flat.iter().map(|f| f.name.as_str()).collect();
        assert!(names_flat.contains(&"top.pdf"));
        assert!(!names_flat.contains(&"nested.pdf"), "nested.pdf must NOT appear in non-recursive");
        assert_eq!(files_flat.len(), 1);

        // Recursive: both
        set_source_dir(dir.to_str().unwrap(), true).unwrap();
        let files_rec = list_source_files(None).expect("list recursive");
        let names_rec: Vec<&str> = files_rec.iter().map(|f| f.name.as_str()).collect();
        assert!(names_rec.contains(&"top.pdf"));
        assert!(names_rec.contains(&"nested.pdf"), "nested.pdf must appear in recursive");
        assert_eq!(files_rec.len(), 2);

        std::fs::remove_dir_all(&dir).ok();
    }

    // (d) in_vault true/false correctness against a real fingerprints row
    #[test]
    fn in_vault_flag_correctness() {
        let base = unique_tmp("invault");
        let src_dir = base.join("source");
        let vault_path = base.join("test.ssort");
        std::fs::create_dir_all(&src_dir).unwrap();

        // Write two real files so compute_sha256 works.
        let known_file = src_dir.join("known.pdf");
        let unknown_file = src_dir.join("unknown.pdf");
        std::fs::write(&known_file, b"known file content").unwrap();
        std::fs::write(&unknown_file, b"unknown file content").unwrap();

        // Compute the SHA-256 of the known file so we can seed the vault.
        let known_sha = compute_sha256(&known_file).unwrap();

        // Seed a real vault DB with known_sha.
        seed_vault(&vault_path, &known_sha, 42);

        // List files with vault_path set.
        set_source_dir(src_dir.to_str().unwrap(), false).unwrap();
        let files = list_source_files(Some(vault_path.to_str().unwrap())).expect("list");

        let known_entry = files.iter().find(|f| f.name == "known.pdf").unwrap();
        let unknown_entry = files.iter().find(|f| f.name == "unknown.pdf").unwrap();

        assert!(known_entry.in_vault, "known.pdf sha256 is in vault — must be in_vault=true");
        assert!(!unknown_entry.in_vault, "unknown.pdf sha256 not in vault — must be in_vault=false");

        std::fs::remove_dir_all(&base).ok();
    }

    // list_source_files returns error when no source dir is set
    #[test]
    fn list_returns_error_when_no_dir_set() {
        // Reset state.
        STATE.with(|s| *s.borrow_mut() = SourceState::default());
        let result = list_source_files(None);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("no source directory set"));
    }

    // in_vault is false for all when vault_path is None
    #[test]
    fn in_vault_false_when_no_vault_path() {
        let dir = unique_tmp("novault");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("doc.pdf"), b"content").unwrap();

        set_source_dir(dir.to_str().unwrap(), false).unwrap();
        let files = list_source_files(None).expect("list");

        assert_eq!(files.len(), 1);
        assert!(!files[0].in_vault);

        std::fs::remove_dir_all(&dir).ok();
    }

    // Extension matching is case-insensitive
    #[test]
    fn extension_matching_is_case_insensitive() {
        let dir = unique_tmp("caseext");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("UPPER.PDF"), b"pdf content").unwrap();
        std::fs::write(dir.join("Mixed.Docx"), b"docx content").unwrap();

        set_source_dir(dir.to_str().unwrap(), false).unwrap();
        let files = list_source_files(None).expect("list");

        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert!(names.contains(&"UPPER.PDF") || names.contains(&"upper.pdf"),
            "uppercase .PDF should be included");
        assert_eq!(files.len(), 2);

        std::fs::remove_dir_all(&dir).ok();
    }
}
