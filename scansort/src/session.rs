//! In-process session state for the Scansort plugin.
//!
//! Tracks three sets of labeled, opened handles — vaults, directories, and
//! sources — that the panel registers as the user interacts with the UI.
//!
//! State is **volatile**: it lives only in plugin-process memory and is never
//! persisted to disk or written into a vault.
//!
//! Rules:
//!   - Labels are unique within each set.
//!   - `add_*` errors on duplicate label.
//!   - `remove_*` errors on unknown label.
//!   - `state()` returns labels only — NO paths are ever exposed through this
//!     accessor; callers that need the path should use their own bookkeeping.
//!
//! Seven MCP tools wrap this module:
//!   • minerva_scansort_session_open_vault
//!   • minerva_scansort_session_close_vault
//!   • minerva_scansort_session_open_directory
//!   • minerva_scansort_session_close_directory
//!   • minerva_scansort_session_open_source
//!   • minerva_scansort_session_close_source
//!   • minerva_scansort_session_state

use crate::types::{VaultError, VaultResult};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

// ---------------------------------------------------------------------------
// Public data types
// ---------------------------------------------------------------------------

/// A single labeled entry in the session.
#[derive(Debug, Clone)]
pub struct SessionEntry {
    pub label: String,
    pub path: PathBuf,
}

/// A snapshot of the session that contains **labels only** — no paths.
/// Returned by `state()` and serialised into the MCP response.
#[derive(Debug, Clone)]
pub struct SessionState {
    pub vaults: Vec<String>,
    pub dirs: Vec<String>,
    pub sources: Vec<String>,
}

// ---------------------------------------------------------------------------
// Internal session struct
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
struct Session {
    open_vaults: Vec<SessionEntry>,
    open_dirs: Vec<SessionEntry>,
    open_sources: Vec<SessionEntry>,
}

impl Session {
    fn add(set: &mut Vec<SessionEntry>, label: &str, path: PathBuf) -> VaultResult<()> {
        if set.iter().any(|e| e.label == label) {
            return Err(VaultError::new(format!(
                "session label already open: {label}"
            )));
        }
        set.push(SessionEntry {
            label: label.to_string(),
            path,
        });
        Ok(())
    }

    fn remove(set: &mut Vec<SessionEntry>, label: &str) -> VaultResult<()> {
        let pos = set.iter().position(|e| e.label == label).ok_or_else(|| {
            VaultError::new(format!("session label not found: {label}"))
        })?;
        set.remove(pos);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Global in-process state
// ---------------------------------------------------------------------------

static SESSION: OnceLock<Mutex<Session>> = OnceLock::new();

fn with_session<F, T>(f: F) -> T
where
    F: FnOnce(&mut Session) -> T,
{
    let m = SESSION.get_or_init(|| Mutex::new(Session::default()));
    let mut guard = m.lock().unwrap_or_else(|p| p.into_inner());
    f(&mut guard)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Register an opened vault in the session.
/// Returns `Err` if `label` is already present.
pub fn add_vault(label: &str, path: PathBuf) -> VaultResult<()> {
    with_session(|s| Session::add(&mut s.open_vaults, label, path))
}

/// Deregister a vault from the session.
/// Returns `Err` if `label` is not present.
pub fn remove_vault(label: &str) -> VaultResult<()> {
    with_session(|s| Session::remove(&mut s.open_vaults, label))
}

/// Register an opened directory in the session.
/// Returns `Err` if `label` is already present.
pub fn add_dir(label: &str, path: PathBuf) -> VaultResult<()> {
    with_session(|s| Session::add(&mut s.open_dirs, label, path))
}

/// Deregister a directory from the session.
/// Returns `Err` if `label` is not present.
pub fn remove_dir(label: &str) -> VaultResult<()> {
    with_session(|s| Session::remove(&mut s.open_dirs, label))
}

/// Register an opened source directory in the session.
/// Returns `Err` if `label` is already present.
pub fn add_source(label: &str, path: PathBuf) -> VaultResult<()> {
    with_session(|s| Session::add(&mut s.open_sources, label, path))
}

/// Deregister a source directory from the session.
/// Returns `Err` if `label` is not present.
pub fn remove_source(label: &str) -> VaultResult<()> {
    with_session(|s| Session::remove(&mut s.open_sources, label))
}

/// Return a snapshot of session labels.  **No paths are included.**
pub fn state() -> SessionState {
    with_session(|s| SessionState {
        vaults: s.open_vaults.iter().map(|e| e.label.clone()).collect(),
        dirs: s.open_dirs.iter().map(|e| e.label.clone()).collect(),
        sources: s.open_sources.iter().map(|e| e.label.clone()).collect(),
    })
}

// ---------------------------------------------------------------------------
// B3 helpers — label resolution for the process() pipeline
// ---------------------------------------------------------------------------

/// The kind of a resolved destination entry.
#[derive(Debug, Clone, PartialEq)]
pub enum EntryKind {
    Vault,
    Directory,
    Source,
}

/// Resolve a destination label to its `(label, path, kind)` triple.
///
/// Searches open_vaults first, then open_dirs.  Source directories are NOT
/// valid placement destinations, so they are excluded from the search.
///
/// Returns `None` when the label is not open as a vault or directory.
pub fn resolve_label(label: &str) -> Option<(String, PathBuf, EntryKind)> {
    with_session(|s| {
        // Check vaults first.
        if let Some(e) = s.open_vaults.iter().find(|e| e.label == label) {
            return Some((e.label.clone(), e.path.clone(), EntryKind::Vault));
        }
        // Then check directories.
        if let Some(e) = s.open_dirs.iter().find(|e| e.label == label) {
            return Some((e.label.clone(), e.path.clone(), EntryKind::Directory));
        }
        None
    })
}

/// Return all open sources as `(label, path)` pairs, sorted by label.
///
/// Used by process() to iterate source directories in deterministic order.
pub fn open_sources_sorted() -> Vec<(String, PathBuf)> {
    with_session(|s| {
        let mut pairs: Vec<(String, PathBuf)> = s
            .open_sources
            .iter()
            .map(|e| (e.label.clone(), e.path.clone()))
            .collect();
        pairs.sort_by(|a, b| a.0.cmp(&b.0));
        pairs
    })
}

/// Return the set of all currently-open destination labels (vaults + dirs).
///
/// Used by should_skip to test whether all previously-recorded target labels
/// are still open.
pub fn open_destination_labels() -> std::collections::HashSet<String> {
    with_session(|s| {
        let mut set = std::collections::HashSet::new();
        for e in &s.open_vaults {
            set.insert(e.label.clone());
        }
        for e in &s.open_dirs {
            set.insert(e.label.clone());
        }
        set
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Each test gets its own isolated Session — we don't touch the global
    /// singleton so parallel tests can't interfere.
    fn fresh() -> Session {
        Session::default()
    }

    // Helper: add_vault on a local session.
    fn av(s: &mut Session, label: &str) -> VaultResult<()> {
        Session::add(&mut s.open_vaults, label, PathBuf::from(format!("/fake/{label}.ssort")))
    }
    fn rv(s: &mut Session, label: &str) -> VaultResult<()> {
        Session::remove(&mut s.open_vaults, label)
    }
    fn ad(s: &mut Session, label: &str) -> VaultResult<()> {
        Session::add(&mut s.open_dirs, label, PathBuf::from(format!("/fake/dir/{label}")))
    }
    fn rd(s: &mut Session, label: &str) -> VaultResult<()> {
        Session::remove(&mut s.open_dirs, label)
    }
    fn as_(s: &mut Session, label: &str) -> VaultResult<()> {
        Session::add(&mut s.open_sources, label, PathBuf::from(format!("/fake/src/{label}")))
    }
    fn rs(s: &mut Session, label: &str) -> VaultResult<()> {
        Session::remove(&mut s.open_sources, label)
    }

    fn state_of(s: &Session) -> SessionState {
        SessionState {
            vaults: s.open_vaults.iter().map(|e| e.label.clone()).collect(),
            dirs: s.open_dirs.iter().map(|e| e.label.clone()).collect(),
            sources: s.open_sources.iter().map(|e| e.label.clone()).collect(),
        }
    }

    // (a) 0/0/0 → state shape: all lists empty
    #[test]
    fn empty_state_shape() {
        let s = fresh();
        let st = state_of(&s);
        assert!(st.vaults.is_empty(), "vaults must be empty");
        assert!(st.dirs.is_empty(), "dirs must be empty");
        assert!(st.sources.is_empty(), "sources must be empty");
    }

    // (b) 1/0/0 — one vault, state correct
    #[test]
    fn one_vault_state_correct() {
        let mut s = fresh();
        av(&mut s, "MyVault").unwrap();
        let st = state_of(&s);
        assert_eq!(st.vaults, vec!["MyVault"]);
        assert!(st.dirs.is_empty());
        assert!(st.sources.is_empty());
    }

    // (c) 0/0/1 — one source, state correct
    #[test]
    fn one_source_state_correct() {
        let mut s = fresh();
        as_(&mut s, "Inbox").unwrap();
        let st = state_of(&s);
        assert!(st.vaults.is_empty());
        assert!(st.dirs.is_empty());
        assert_eq!(st.sources, vec!["Inbox"]);
    }

    // (d) 3+5 cardinality — add 3 vaults + 5 dirs, state reflects all
    #[test]
    fn three_vaults_five_dirs_cardinality() {
        let mut s = fresh();
        for i in 1..=3 {
            av(&mut s, &format!("Vault{i}")).unwrap();
        }
        for i in 1..=5 {
            ad(&mut s, &format!("Dir{i}")).unwrap();
        }
        let st = state_of(&s);
        assert_eq!(st.vaults.len(), 3, "expected 3 vaults");
        assert_eq!(st.dirs.len(), 5, "expected 5 dirs");
        assert!(st.sources.is_empty());
        assert!(st.vaults.contains(&"Vault1".to_string()));
        assert!(st.vaults.contains(&"Vault3".to_string()));
        assert!(st.dirs.contains(&"Dir1".to_string()));
        assert!(st.dirs.contains(&"Dir5".to_string()));
    }

    // (e) duplicate label → error
    #[test]
    fn duplicate_vault_label_errors() {
        let mut s = fresh();
        av(&mut s, "AlreadyOpen").unwrap();
        let err = av(&mut s, "AlreadyOpen").unwrap_err();
        assert!(err.message.contains("already open"), "unexpected: {}", err.message);
    }

    // (f) close on unknown label → error
    #[test]
    fn close_unknown_vault_errors() {
        let mut s = fresh();
        let err = rv(&mut s, "DoesNotExist").unwrap_err();
        assert!(err.message.contains("not found"), "unexpected: {}", err.message);
    }

    // same tests for dirs
    #[test]
    fn duplicate_dir_label_errors() {
        let mut s = fresh();
        ad(&mut s, "MyDir").unwrap();
        let err = ad(&mut s, "MyDir").unwrap_err();
        assert!(err.message.contains("already open"), "unexpected: {}", err.message);
    }

    #[test]
    fn close_unknown_dir_errors() {
        let mut s = fresh();
        let err = rd(&mut s, "Ghost").unwrap_err();
        assert!(err.message.contains("not found"), "unexpected: {}", err.message);
    }

    // same tests for sources
    #[test]
    fn duplicate_source_label_errors() {
        let mut s = fresh();
        as_(&mut s, "Downloads").unwrap();
        let err = as_(&mut s, "Downloads").unwrap_err();
        assert!(err.message.contains("already open"), "unexpected: {}", err.message);
    }

    #[test]
    fn close_unknown_source_errors() {
        let mut s = fresh();
        let err = rs(&mut s, "Phantom").unwrap_err();
        assert!(err.message.contains("not found"), "unexpected: {}", err.message);
    }

    // (g) Regression: session_state never includes path strings.
    // Serialize SessionState as JSON and verify no path separator characters.
    #[test]
    fn state_never_includes_paths() {
        let mut s = fresh();
        av(&mut s, "TaxVault2024").unwrap();
        ad(&mut s, "Archive2024").unwrap();
        as_(&mut s, "Downloads").unwrap();
        let st = state_of(&s);

        // Manually serialize the labels into a JSON-like string.
        // We only serialise what state() returns (labels), so we verify
        // no path separators slip through.
        let json = serde_json::json!({
            "vaults":  st.vaults,
            "dirs":    st.dirs,
            "sources": st.sources,
        });
        let serialized = serde_json::to_string(&json).unwrap();

        assert!(
            !serialized.contains('/') && !serialized.contains('\\'),
            "state JSON must not contain path separators — found: {serialized}"
        );
    }

    // (h) remove then re-add with same label succeeds.
    #[test]
    fn remove_then_readd_succeeds() {
        let mut s = fresh();
        av(&mut s, "Temp").unwrap();
        rv(&mut s, "Temp").unwrap();
        // After removal the label slot is free — should succeed.
        av(&mut s, "Temp").unwrap();
        let st = state_of(&s);
        assert_eq!(st.vaults, vec!["Temp"]);
    }

    // (i) sources have independent label namespace from vaults/dirs.
    #[test]
    fn same_label_across_kinds_is_allowed() {
        let mut s = fresh();
        // "Work" as a vault, dir, and source simultaneously — all distinct sets.
        av(&mut s, "Work").unwrap();
        ad(&mut s, "Work").unwrap();
        as_(&mut s, "Work").unwrap();
        let st = state_of(&s);
        assert_eq!(st.vaults.len(), 1);
        assert_eq!(st.dirs.len(), 1);
        assert_eq!(st.sources.len(), 1);
    }
}
