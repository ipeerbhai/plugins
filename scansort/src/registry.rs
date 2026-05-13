//! Cross-vault registry operations.
//!
//! Port of vault.py: registry_list, registry_add, registry_remove,
//! check_sha256_all_vaults.
//!
//! The registry is a JSON file at ~/.config/scansort/vault_registry.json,
//! NOT inside any vault. Format:
//! ```json
//! [{"path": "/abs/path.ssort", "name": "Vault Name", "added_at": "ISO8601"}]
//! ```

use crate::db;
use crate::types::*;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::path::Path;

// ---------------------------------------------------------------------------
// Registry entry struct
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RegistryEntry {
    path: String,
    name: String,
    added_at: String,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Default registry path: ~/.config/scansort/vault_registry.json
fn default_registry_path() -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    format!("{home}/.config/scansort/vault_registry.json")
}

/// Resolve registry path: use provided or default.
fn resolve_registry_path(registry_path: Option<&str>) -> String {
    match registry_path {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => std::env::var("SCANSORT_REGISTRY")
            .unwrap_or_else(|_| default_registry_path()),
    }
}

/// Read registry entries from file. Returns empty vec if file doesn't exist or is invalid.
fn read_registry(rpath: &str) -> Vec<RegistryEntry> {
    if !Path::new(rpath).exists() {
        return Vec::new();
    }
    match std::fs::read_to_string(rpath) {
        Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// Write registry entries to file. Creates parent directory if needed.
fn write_registry(rpath: &str, entries: &[RegistryEntry]) -> VaultResult<()> {
    if let Some(parent) = Path::new(rpath).parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let json = serde_json::to_string_pretty(entries)?;
    std::fs::write(rpath, json)?;
    Ok(())
}

/// Canonicalize a path for comparison. Falls back to the original string
/// when the path does not exist on disk.
fn abs_path(p: &str) -> String {
    std::fs::canonicalize(p)
        .map(|pb| pb.to_string_lossy().to_string())
        .unwrap_or_else(|_| {
            // Try to at least expand relative paths
            if Path::new(p).is_absolute() {
                p.to_string()
            } else {
                std::env::current_dir()
                    .map(|cwd| cwd.join(p).to_string_lossy().to_string())
                    .unwrap_or_else(|_| p.to_string())
            }
        })
}

/// Get vault name by reading the project table.
fn read_vault_name(vault_path: &str) -> String {
    if !Path::new(vault_path).exists() {
        return String::new();
    }
    db::connect_readonly(vault_path)
        .ok()
        .and_then(|conn| db::get_project_key(&conn, "name").ok().flatten())
        .unwrap_or_default()
}

/// Get vault doc count. Used by registry_list to enrich entries.
#[allow(dead_code)]
fn read_vault_doc_count(vault_path: &str) -> i64 {
    if !Path::new(vault_path).exists() {
        return -1;
    }
    match db::connect_readonly(vault_path) {
        Ok(conn) => conn
            .query_row("SELECT COUNT(*) FROM documents", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(-1),
        Err(_) => -1,
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// List all registered vaults with name and doc count.
///
/// For each entry, opens the vault briefly to read current name and document
/// count. Returns a JSON array of vault info objects.
pub fn registry_list(
    registry_path: Option<&str>,
) -> VaultResult<Vec<serde_json::Value>> {
    let rpath = resolve_registry_path(registry_path);
    let entries = read_registry(&rpath);

    let mut result = Vec::new();
    for entry in &entries {
        let path = &entry.path;
        let mut info = serde_json::json!({
            "path": path,
            "name": entry.name,
            "added_at": entry.added_at,
        });

        if Path::new(path).exists() {
            match db::connect_readonly(path) {
                Ok(conn) => {
                    let doc_count = conn
                        .query_row("SELECT COUNT(*) FROM documents", [], |row| {
                            row.get::<_, i64>(0)
                        })
                        .unwrap_or(0);
                    let name = db::get_project_key(&conn, "name")
                        .ok()
                        .flatten()
                        .unwrap_or_default();
                    info["doc_count"] = serde_json::json!(doc_count);
                    if !name.is_empty() {
                        info["name"] = serde_json::json!(name);
                    }
                }
                Err(_) => {
                    info["doc_count"] = serde_json::json!(-1);
                    info["error"] = serde_json::json!("Cannot open vault");
                }
            }
        } else {
            info["doc_count"] = serde_json::json!(-1);
            info["error"] = serde_json::json!("File not found");
        }

        result.push(info);
    }

    Ok(result)
}

/// Add a vault to the registry. Returns true if newly added, false if
/// already registered.
pub fn registry_add(
    vault_path: &str,
    registry_path: Option<&str>,
) -> VaultResult<bool> {
    let rpath = resolve_registry_path(registry_path);
    let mut entries = read_registry(&rpath);

    let target_abs = abs_path(vault_path);

    // Check for duplicates by absolute path
    for e in &entries {
        if abs_path(&e.path) == target_abs {
            return Ok(false); // already registered
        }
    }

    // Get vault name
    let vault_name = read_vault_name(vault_path);

    entries.push(RegistryEntry {
        path: target_abs,
        name: vault_name,
        added_at: now_iso(),
    });

    write_registry(&rpath, &entries)?;
    Ok(true)
}

/// Remove a vault from the registry. Returns true if the entry was present
/// and removed, false if it was not in the registry.
pub fn registry_remove(
    vault_path: &str,
    registry_path: Option<&str>,
) -> VaultResult<bool> {
    let rpath = resolve_registry_path(registry_path);
    if !Path::new(&rpath).exists() {
        return Ok(false);
    }

    let entries = read_registry(&rpath);
    let target_abs = abs_path(vault_path);

    let before_len = entries.len();
    let filtered: Vec<RegistryEntry> = entries
        .into_iter()
        .filter(|e| abs_path(&e.path) != target_abs)
        .collect();
    let removed = filtered.len() < before_len;

    write_registry(&rpath, &filtered)?;
    Ok(removed)
}

/// Check a SHA-256 hash against all registered vaults.
///
/// Short-circuits on the first match. Returns `Some((vault_path, vault_name, doc_id))`
/// if found, `None` otherwise.
pub fn check_sha256_all_vaults(
    sha256: &str,
    registry_path: Option<&str>,
    exclude_vault: Option<&str>,
) -> VaultResult<Option<(String, String, i64)>> {
    let rpath = resolve_registry_path(registry_path);
    let entries = read_registry(&rpath);

    let exclude_abs = exclude_vault.map(|p| abs_path(p));

    for entry in &entries {
        let path = &entry.path;

        if !Path::new(path).exists() {
            continue;
        }

        // Skip excluded vault
        if let Some(ref exclude) = exclude_abs {
            if abs_path(path) == *exclude {
                continue;
            }
        }

        // Open read-only and check fingerprints
        let conn = match db::connect_readonly(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let result = conn
            .prepare("SELECT doc_id FROM fingerprints WHERE sha256 = ?")
            .and_then(|mut stmt| stmt.query_row(params![sha256], |row| row.get::<_, i64>(0)));

        match result {
            Ok(doc_id) => {
                // Found! Get vault name
                let vault_name = db::get_project_key(&conn, "name")
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| {
                        Path::new(path)
                            .file_name()
                            .map(|n| n.to_string_lossy().to_string())
                            .unwrap_or_default()
                    });
                return Ok(Some((path.clone(), vault_name, doc_id)));
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => continue,
            Err(_) => continue,
        }
    }

    Ok(None)
}

// move_document_to_vault deferred to T6 (requires documents.rs port for insert/extract path)
