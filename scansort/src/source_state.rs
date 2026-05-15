//! B4 — Source state manifest (.scansort-state.json).
//!
//! Tracks per-file processing outcomes keyed by sha256 hex, stored next to
//! the source directory as `<source_dir>/.scansort-state.json`.
//!
//! ## Atomicity
//!
//! Writes go via a temp file + rename to avoid corrupt manifests on crash.
//! The parent directory must already exist (it is the source directory).
//!
//! ## Escape hatch
//!
//! Hand-deleting `.scansort-state.json` forces full reprocess on next run.
//! A future tool `minerva_scansort_clear_source_state` can reset entries
//! selectively — that is out of scope for B4.

use crate::types::{VaultError, VaultResult, now_iso};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

pub const STATE_FILENAME: &str = ".scansort-state.json";

/// Entry for a single file processed by process().
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FileEntry {
    /// Relative path from the source directory root.
    pub relpath: String,
    /// `"moved"` | `"conflict"` | `"unprocessable"` | `"skipped_already_processed"`
    pub status: String,
    /// Human-readable reason for unprocessable / conflict. None for moved.
    pub reason: Option<String>,
    /// The rule label that fired (None when no rule matched).
    pub rule_label: Option<String>,
    /// Destination labels the file was sent to (empty for unprocessable).
    pub target_labels: Vec<String>,
    /// ISO 8601 UTC timestamp of the last process() run that touched this file.
    pub last_run_at: String,
}

/// Top-level manifest document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceState {
    pub version: i32,
    /// Key = sha256 hex of the file's content.
    pub files: HashMap<String, FileEntry>,
}

impl Default for SourceState {
    fn default() -> Self {
        Self {
            version: 1,
            files: HashMap::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

/// Load `<source_dir>/.scansort-state.json`, or return an empty default if
/// the file does not exist.  Existing files are parsed and validated.
pub fn load_or_init(source_dir: &Path) -> SourceState {
    let path = source_dir.join(STATE_FILENAME);
    if !path.exists() {
        return SourceState::default();
    }
    match fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_else(|_| {
            log::warn!(
                "source_state: could not parse {}, starting fresh",
                path.display()
            );
            SourceState::default()
        }),
        Err(e) => {
            log::warn!(
                "source_state: could not read {}: {e}, starting fresh",
                path.display()
            );
            SourceState::default()
        }
    }
}

/// Atomically write `<source_dir>/.scansort-state.json`.
///
/// Uses a sibling temp file + rename for crash safety.  The source_dir must
/// already exist (it is the directory we just processed).
pub fn save(source_dir: &Path, state: &SourceState) -> VaultResult<()> {
    let path = source_dir.join(STATE_FILENAME);
    let text = serde_json::to_string_pretty(state)?;

    // Write to a temp file next to the target, then rename.
    let tmp_path = source_dir.join(".scansort-state.json.tmp");
    fs::write(&tmp_path, &text).map_err(|e| {
        VaultError::new(format!(
            "source_state: cannot write tmp file {}: {e}",
            tmp_path.display()
        ))
    })?;
    fs::rename(&tmp_path, &path).map_err(|e| {
        VaultError::new(format!(
            "source_state: cannot rename tmp→final {}: {e}",
            path.display()
        ))
    })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Mutation helpers
// ---------------------------------------------------------------------------

/// Insert or replace the entry for `sha256` in `state`.
pub fn upsert(state: &mut SourceState, sha256: &str, entry: FileEntry) {
    state.files.insert(sha256.to_string(), entry);
}

/// Build a `FileEntry` with `last_run_at` set to now.
pub fn make_entry(
    relpath: String,
    status: &str,
    reason: Option<String>,
    rule_label: Option<String>,
    target_labels: Vec<String>,
) -> FileEntry {
    FileEntry {
        relpath,
        status: status.to_string(),
        reason,
        rule_label,
        target_labels,
        last_run_at: now_iso(),
    }
}

// ---------------------------------------------------------------------------
// Skip logic
// ---------------------------------------------------------------------------

/// Returns true iff:
///   1. `sha256` has an entry in `state` with `status == "moved"`, AND
///   2. ALL of that entry's `target_labels` are present in
///      `current_session_labels`.
///
/// This means a previously-moved file is skipped only when every destination
/// it was sent to is still open.  If any destination has been closed/removed
/// the file is re-evaluated (not re-moved, but the process() logic will
/// check deeper and may record a conflict or unprocessable).
///
/// Files with `status != "moved"` (e.g. "unprocessable") are also skipped
/// on re-run — the caller decides what to do with "skipped_already_processed"
/// entries for non-moved statuses.  See the `unprocessable` note in B4 spec.
pub fn should_skip(
    state: &SourceState,
    sha256: &str,
    current_session_labels: &HashSet<String>,
) -> bool {
    match state.files.get(sha256) {
        None => false,
        Some(entry) => {
            if entry.status == "moved" {
                // All destinations must still be open.
                entry
                    .target_labels
                    .iter()
                    .all(|lbl| current_session_labels.contains(lbl))
            } else {
                // unprocessable / conflict entries are also skipped on re-run.
                // (The user must delete the manifest or clear the entry to
                // force re-classification.)
                true
            }
        }
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
        std::env::temp_dir()
            .join(format!("scansort-srcstate-{prefix}-{pid}-{ts}-{n}"))
    }

    fn session_labels(labels: &[&str]) -> HashSet<String> {
        labels.iter().map(|s| s.to_string()).collect()
    }

    // -----------------------------------------------------------------------
    // Round-trip: empty state
    // -----------------------------------------------------------------------
    #[test]
    fn round_trip_empty_state() {
        let dir = unique_tmp("empty");
        fs::create_dir_all(&dir).unwrap();

        let state = SourceState::default();
        save(&dir, &state).expect("save empty");

        let loaded = load_or_init(&dir);
        assert_eq!(loaded.version, 1);
        assert!(loaded.files.is_empty());

        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Round-trip: single entry keyed by sha256
    // -----------------------------------------------------------------------
    #[test]
    fn round_trip_single_entry() {
        let dir = unique_tmp("single");
        fs::create_dir_all(&dir).unwrap();

        let sha = "abc123def456";
        let mut state = SourceState::default();
        upsert(
            &mut state,
            sha,
            make_entry(
                "docs/invoice.pdf".to_string(),
                "moved",
                None,
                Some("invoice".to_string()),
                vec!["archive-vault".to_string()],
            ),
        );
        save(&dir, &state).expect("save single");

        let loaded = load_or_init(&dir);
        assert_eq!(loaded.files.len(), 1);
        let entry = loaded.files.get(sha).expect("entry must exist");
        assert_eq!(entry.relpath, "docs/invoice.pdf");
        assert_eq!(entry.status, "moved");
        assert!(entry.reason.is_none());
        assert_eq!(entry.rule_label, Some("invoice".to_string()));
        assert_eq!(entry.target_labels, vec!["archive-vault"]);
        assert!(!entry.last_run_at.is_empty());

        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Round-trip: multiple entries with different statuses
    // -----------------------------------------------------------------------
    #[test]
    fn round_trip_multi_entry() {
        let dir = unique_tmp("multi");
        fs::create_dir_all(&dir).unwrap();

        let mut state = SourceState::default();
        upsert(&mut state, "sha_a", make_entry("a.pdf".to_string(), "moved", None, Some("tax".to_string()), vec!["vault-a".to_string()]));
        upsert(&mut state, "sha_b", make_entry("b.pdf".to_string(), "unprocessable", Some("no_rule_match".to_string()), None, vec![]));
        upsert(&mut state, "sha_c", make_entry("c.pdf".to_string(), "conflict", Some("sha256_present".to_string()), Some("tax".to_string()), vec!["vault-a".to_string()]));

        save(&dir, &state).expect("save multi");
        let loaded = load_or_init(&dir);
        assert_eq!(loaded.files.len(), 3);
        assert_eq!(loaded.files["sha_a"].status, "moved");
        assert_eq!(loaded.files["sha_b"].status, "unprocessable");
        assert_eq!(loaded.files["sha_c"].status, "conflict");

        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // sha256 keying: upsert overwrites existing entry for same key
    // -----------------------------------------------------------------------
    #[test]
    fn upsert_overwrites_existing_entry() {
        let mut state = SourceState::default();
        let sha = "deadbeef";
        upsert(&mut state, sha, make_entry("foo.pdf".to_string(), "moved", None, None, vec![]));
        upsert(&mut state, sha, make_entry("foo.pdf".to_string(), "conflict", Some("dup".to_string()), None, vec![]));
        assert_eq!(state.files.len(), 1);
        assert_eq!(state.files[sha].status, "conflict");
    }

    // -----------------------------------------------------------------------
    // Atomic write: load_or_init returns empty default for missing file
    // -----------------------------------------------------------------------
    #[test]
    fn load_or_init_returns_empty_for_missing_file() {
        let dir = unique_tmp("missing");
        fs::create_dir_all(&dir).unwrap();
        // No .scansort-state.json written.
        let state = load_or_init(&dir);
        assert_eq!(state.version, 1);
        assert!(state.files.is_empty());
        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Atomic write: temp file is cleaned up (rename succeeds)
    // -----------------------------------------------------------------------
    #[test]
    fn atomic_write_no_leftover_tmp() {
        let dir = unique_tmp("atomic");
        fs::create_dir_all(&dir).unwrap();

        let mut state = SourceState::default();
        upsert(&mut state, "x", make_entry("x.pdf".to_string(), "moved", None, None, vec![]));
        save(&dir, &state).expect("save");

        // Tmp file must not exist after successful write.
        let tmp = dir.join(".scansort-state.json.tmp");
        assert!(!tmp.exists(), "tmp file must be cleaned up after rename");

        // Final file must exist.
        assert!(dir.join(STATE_FILENAME).exists());

        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // should_skip: moved file with all destinations still open → true
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_moved_all_dests_open() {
        let mut state = SourceState::default();
        upsert(
            &mut state,
            "sha1",
            make_entry(
                "file.pdf".to_string(),
                "moved",
                None,
                Some("rule_a".to_string()),
                vec!["dest-a".to_string(), "dest-b".to_string()],
            ),
        );
        let open = session_labels(&["dest-a", "dest-b", "dest-c"]);
        assert!(should_skip(&state, "sha1", &open), "all dests open → should skip");
    }

    // -----------------------------------------------------------------------
    // should_skip: moved file with one destination now closed → false
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_moved_one_dest_closed() {
        let mut state = SourceState::default();
        upsert(
            &mut state,
            "sha2",
            make_entry(
                "file.pdf".to_string(),
                "moved",
                None,
                None,
                vec!["dest-a".to_string(), "dest-b".to_string()],
            ),
        );
        // dest-b is no longer open.
        let open = session_labels(&["dest-a", "dest-c"]);
        assert!(!should_skip(&state, "sha2", &open), "one dest closed → do not skip");
    }

    // -----------------------------------------------------------------------
    // should_skip: unprocessable entry → true (don't re-classify)
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_unprocessable() {
        let mut state = SourceState::default();
        upsert(
            &mut state,
            "sha3",
            make_entry("file.pdf".to_string(), "unprocessable", Some("no_rule_match".to_string()), None, vec![]),
        );
        let open = session_labels(&["anything"]);
        assert!(should_skip(&state, "sha3", &open), "unprocessable → skip");
    }

    // -----------------------------------------------------------------------
    // should_skip: missing sha256 → false
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_missing_sha() {
        let state = SourceState::default();
        let open = session_labels(&["dest-a"]);
        assert!(!should_skip(&state, "no_such_sha", &open), "missing sha → do not skip");
    }

    // -----------------------------------------------------------------------
    // should_skip: moved file with empty target_labels + open session → true
    // (vacuously — no labels to check)
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_moved_empty_targets_vacuously_true() {
        let mut state = SourceState::default();
        upsert(
            &mut state,
            "sha4",
            make_entry("file.pdf".to_string(), "moved", None, None, vec![]),
        );
        let open = session_labels(&["anything"]);
        // Vacuously all() on empty vec → true.
        assert!(should_skip(&state, "sha4", &open));
    }

    // -----------------------------------------------------------------------
    // conflict status → skip on re-run
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_conflict() {
        let mut state = SourceState::default();
        upsert(
            &mut state,
            "sha5",
            make_entry("dup.pdf".to_string(), "conflict", Some("sha256_present".to_string()), None, vec!["vault-a".to_string()]),
        );
        let open = session_labels(&["vault-a"]);
        assert!(should_skip(&state, "sha5", &open), "conflict → skip");
    }
}
