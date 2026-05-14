//! Destination registry — W4.
//!
//! A *destination* is a filing target: either a `.ssort` vault file or a
//! plain directory.  The registry holds all destinations declared for the
//! current filing session; it is NOT per-vault and spans vaults.
//!
//! Persistence pattern mirrors `rules_file.rs`:
//!   - Top-level struct with `schema_version`.
//!   - `load` / `save` / `load_or_init` trio.
//!   - Parent-dir creation on save.
//!   - Helpful error messages.
//!
//! MCP tools (`destination_add` / `destination_list` / `destination_remove`)
//! live in `main.rs` and call this module.

use crate::types::{VaultError, VaultResult};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub const CURRENT_SCHEMA_VERSION: i64 = 1;

// ---------------------------------------------------------------------------
// Valid kinds
// ---------------------------------------------------------------------------

const KIND_VAULT: &str = "vault";
const KIND_DIRECTORY: &str = "directory";

fn is_valid_kind(kind: &str) -> bool {
    kind == KIND_VAULT || kind == KIND_DIRECTORY
}

// ---------------------------------------------------------------------------
// Destination — a single filing target.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Destination {
    /// Stable, unique ID within the registry. Generated on `add`; callers
    /// never supply it. Format: a short slug derived from the path's file
    /// stem plus a decimal counter suffix (e.g. `taxes-1`).
    pub id: String,
    /// `"vault"` (a `.ssort` vault file) or `"directory"` (a plain directory).
    pub kind: String,
    /// Absolute path to the vault file or directory.
    pub path: String,
    /// Human-readable label for display. Defaults to the file/dir name of
    /// `path` when not provided by the caller.
    pub label: String,
    /// The "locked / final" flag.  W8 will use it to refuse reprocessing;
    /// W4 just stores it.
    pub locked: bool,
}

// ---------------------------------------------------------------------------
// DestinationRegistry — top-level JSON document.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DestinationRegistry {
    pub schema_version: i64,
    pub destinations: Vec<Destination>,
}

impl Default for DestinationRegistry {
    fn default() -> Self {
        Self {
            schema_version: CURRENT_SCHEMA_VERSION,
            destinations: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

/// Read and parse a destination registry from disk.
pub fn load(path: &Path) -> VaultResult<DestinationRegistry> {
    let text = fs::read_to_string(path).map_err(|e| {
        VaultError::new(format!(
            "Cannot read destination registry {}: {}",
            path.display(),
            e
        ))
    })?;
    let reg: DestinationRegistry = serde_json::from_str(&text).map_err(|e| {
        VaultError::new(format!(
            "Invalid destination registry JSON at {}: {}",
            path.display(),
            e
        ))
    })?;
    if reg.schema_version > CURRENT_SCHEMA_VERSION {
        return Err(VaultError::new(format!(
            "Destination registry schema_version {} is newer than supported version {}",
            reg.schema_version, CURRENT_SCHEMA_VERSION
        )));
    }
    Ok(reg)
}

/// Write the registry to disk as pretty-printed UTF-8 JSON.
/// Creates parent directories as needed.
pub fn save(path: &Path, reg: &DestinationRegistry) -> VaultResult<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    let text = serde_json::to_string_pretty(reg)?;
    fs::write(path, text)?;
    Ok(())
}

/// Load an existing registry, or return an empty default if the file does
/// not exist.  Existing files still validate normally.
pub fn load_or_init(path: &Path) -> VaultResult<DestinationRegistry> {
    if path.exists() {
        load(path)
    } else {
        Ok(DestinationRegistry::default())
    }
}

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

/// Derive a short slug from an arbitrary path string.
/// Takes the file stem of the last component (or a fallback), strips
/// non-alphanumeric characters except hyphens, lower-cases, and truncates.
fn path_slug(path: &str) -> String {
    let p = Path::new(path);
    let stem = p
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("dest");
    let slug: String = stem
        .chars()
        .map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(24)
        .collect();
    if slug.is_empty() { "dest".to_string() } else { slug }
}

/// Generate a unique ID for a new destination.
/// Format: `<slug>-<n>` where n is chosen so that the id is not already
/// present in `reg`.
fn generate_id(reg: &DestinationRegistry, path: &str) -> String {
    let slug = path_slug(path);
    // Find the lowest counter that doesn't collide with an existing id.
    let mut n: u64 = 1;
    loop {
        let candidate = format!("{slug}-{n}");
        if !reg.destinations.iter().any(|d| d.id == candidate) {
            return candidate;
        }
        n += 1;
    }
}

// ---------------------------------------------------------------------------
// CRUD helpers — used by MCP tool handlers
// ---------------------------------------------------------------------------

/// Add a destination to the registry.
///
/// Validates `kind` (must be `"vault"` or `"directory"`).
/// Rejects a duplicate `path` — if the same path is already registered this
/// returns an error (rather than silently returning the existing entry).
/// The `label` defaults to the file/dir name of `path` when empty.
/// Returns a reference to the newly created `Destination`.
pub fn add(
    reg: &mut DestinationRegistry,
    kind: &str,
    path: &str,
    label: Option<&str>,
    locked: bool,
) -> VaultResult<Destination> {
    if !is_valid_kind(kind) {
        return Err(VaultError::new(format!(
            "Invalid destination kind '{}'. Must be 'vault' or 'directory'.",
            kind
        )));
    }
    if path.is_empty() {
        return Err(VaultError::new("path is required".to_string()));
    }
    // Reject duplicate paths (case-sensitive exact match).
    if reg.destinations.iter().any(|d| d.path == path) {
        return Err(VaultError::new(format!(
            "Destination path '{}' is already registered.",
            path
        )));
    }
    let id = generate_id(reg, path);
    let effective_label = match label {
        Some(l) if !l.is_empty() => l.to_string(),
        _ => {
            // Derive from path's file name.
            Path::new(path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(path)
                .to_string()
        }
    };
    let dest = Destination {
        id,
        kind: kind.to_string(),
        path: path.to_string(),
        label: effective_label,
        locked,
    };
    reg.destinations.push(dest.clone());
    Ok(dest)
}

/// List all destinations (returns a slice).
pub fn list(reg: &DestinationRegistry) -> &[Destination] {
    &reg.destinations
}

/// Remove a destination by `id`.
/// Returns `true` if a destination was removed, `false` if no match.
pub fn remove(reg: &mut DestinationRegistry, id: &str) -> bool {
    let before = reg.destinations.len();
    reg.destinations.retain(|d| d.id != id);
    reg.destinations.len() < before
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
            .join(format!("scansort-destinations-{prefix}-{pid}-{ts}-{n}"))
    }

    // -----------------------------------------------------------------------
    // 1. add then list returns the destination with generated non-empty id,
    //    correct kind / path / label / locked.
    // -----------------------------------------------------------------------
    #[test]
    fn add_then_list_returns_correct_destination() {
        let mut reg = DestinationRegistry::default();
        let dest = add(
            &mut reg,
            "vault",
            "/tmp/archives/taxes_2024.ssort",
            Some("Taxes 2024"),
            false,
        )
        .expect("add");

        assert!(!dest.id.is_empty(), "generated id must be non-empty");
        assert_eq!(dest.kind, "vault");
        assert_eq!(dest.path, "/tmp/archives/taxes_2024.ssort");
        assert_eq!(dest.label, "Taxes 2024");
        assert!(!dest.locked);

        let all = list(&reg);
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].id, dest.id);
    }

    // -----------------------------------------------------------------------
    // 2. add rejects an invalid kind.
    // -----------------------------------------------------------------------
    #[test]
    fn add_rejects_invalid_kind() {
        let mut reg = DestinationRegistry::default();
        let err = add(&mut reg, "bucket", "/tmp/foo", None, false)
            .expect_err("should reject invalid kind");
        assert!(err.to_string().contains("Invalid destination kind"));
        assert!(reg.destinations.is_empty());
    }

    // -----------------------------------------------------------------------
    // 3. add rejects a duplicate path (same path already registered).
    // -----------------------------------------------------------------------
    #[test]
    fn add_rejects_duplicate_path() {
        let mut reg = DestinationRegistry::default();
        add(&mut reg, "directory", "/mnt/output", None, false).expect("first add");
        let err = add(&mut reg, "directory", "/mnt/output", Some("Duplicate"), false)
            .expect_err("second add must fail");
        assert!(err.to_string().contains("already registered"));
        // Still only one entry.
        assert_eq!(reg.destinations.len(), 1);
    }

    // -----------------------------------------------------------------------
    // 4. remove by id returns true and drops the entry;
    //    remove of unknown id returns false.
    // -----------------------------------------------------------------------
    #[test]
    fn remove_by_id_drops_entry_and_unknown_id_returns_false() {
        let mut reg = DestinationRegistry::default();
        let d = add(&mut reg, "vault", "/tmp/a.ssort", None, false).expect("add");
        let id = d.id.clone();

        assert!(remove(&mut reg, &id), "remove known id must return true");
        assert!(reg.destinations.is_empty());

        assert!(!remove(&mut reg, &id), "remove unknown id must return false");
        assert!(!remove(&mut reg, "nonexistent-99"), "remove of totally unknown id is false");
    }

    // -----------------------------------------------------------------------
    // 5. save→load round-trips a registry with ≥2 destinations including
    //    a locked: true one.
    // -----------------------------------------------------------------------
    #[test]
    fn save_load_round_trip_preserves_two_destinations_with_locked() {
        let dir = unique_tmp("roundtrip");
        let path = dir.join("dest_registry.json");

        let mut reg = DestinationRegistry::default();
        let d1 = add(&mut reg, "vault", "/home/user/personal.ssort", Some("Personal"), false)
            .expect("add vault");
        let d2 = add(&mut reg, "directory", "/mnt/archive", Some("NAS Archive"), true)
            .expect("add directory");

        save(&path, &reg).expect("save");
        let loaded = load(&path).expect("load");

        assert_eq!(loaded.schema_version, CURRENT_SCHEMA_VERSION);
        assert_eq!(loaded.destinations.len(), 2);

        let l1 = &loaded.destinations[0];
        assert_eq!(l1.id, d1.id);
        assert_eq!(l1.kind, "vault");
        assert_eq!(l1.path, "/home/user/personal.ssort");
        assert_eq!(l1.label, "Personal");
        assert!(!l1.locked);

        let l2 = &loaded.destinations[1];
        assert_eq!(l2.id, d2.id);
        assert_eq!(l2.kind, "directory");
        assert_eq!(l2.path, "/mnt/archive");
        assert_eq!(l2.label, "NAS Archive");
        assert!(l2.locked, "locked flag must survive round-trip");

        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 6. load_or_init returns an empty default (schema_version 1) for a
    //    missing path.
    // -----------------------------------------------------------------------
    #[test]
    fn load_or_init_returns_empty_default_for_missing_path() {
        let path = unique_tmp("missing").join("dest_registry.json");
        let reg = load_or_init(&path).expect("should succeed with default");
        assert_eq!(reg.schema_version, CURRENT_SCHEMA_VERSION);
        assert!(reg.destinations.is_empty());
    }

    // -----------------------------------------------------------------------
    // Additional: load_or_init returns existing file when present.
    // -----------------------------------------------------------------------
    #[test]
    fn load_or_init_returns_existing_for_existing_path() {
        let dir = unique_tmp("existing");
        let path = dir.join("dest_registry.json");
        let mut reg = DestinationRegistry::default();
        add(&mut reg, "vault", "/tmp/x.ssort", None, false).expect("add");
        save(&path, &reg).expect("save");

        let loaded = load_or_init(&path).expect("load_or_init");
        assert_eq!(loaded.destinations.len(), 1);
        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Additional: save creates parent directories.
    // -----------------------------------------------------------------------
    #[test]
    fn save_creates_parent_directories() {
        let dir = unique_tmp("nested");
        let path = dir.join("a/b/c/dest_registry.json");
        let reg = DestinationRegistry::default();
        save(&path, &reg).expect("save with nested dirs");
        assert!(path.exists());
        fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Additional: label defaults to path's file name when not provided.
    // -----------------------------------------------------------------------
    #[test]
    fn add_derives_label_from_path_when_label_is_none() {
        let mut reg = DestinationRegistry::default();
        let d = add(&mut reg, "vault", "/home/user/taxes_2024.ssort", None, false)
            .expect("add");
        assert_eq!(d.label, "taxes_2024.ssort");
    }

    // -----------------------------------------------------------------------
    // Additional: generated IDs are unique across multiple adds.
    // -----------------------------------------------------------------------
    #[test]
    fn generated_ids_are_unique() {
        let mut reg = DestinationRegistry::default();
        let d1 = add(&mut reg, "vault", "/tmp/a.ssort", None, false).expect("add a");
        let d2 = add(&mut reg, "vault", "/tmp/b.ssort", None, false).expect("add b");
        let d3 = add(&mut reg, "directory", "/tmp/out", None, false).expect("add dir");
        assert_ne!(d1.id, d2.id);
        assert_ne!(d1.id, d3.id);
        assert_ne!(d2.id, d3.id);
    }

    // -----------------------------------------------------------------------
    // Additional: both valid kinds are accepted.
    // -----------------------------------------------------------------------
    #[test]
    fn add_accepts_both_valid_kinds() {
        let mut reg = DestinationRegistry::default();
        add(&mut reg, "vault", "/tmp/v.ssort", None, false).expect("vault kind");
        add(&mut reg, "directory", "/tmp/d", None, false).expect("directory kind");
        assert_eq!(reg.destinations.len(), 2);
    }
}
