//! Vault lifecycle: create, open, update project keys.
//!
//! Ported from vault.py: create_vault, open_vault, update_project_key.
//! All functions take a vault path as the first argument (stateless).

use crate::db;
use crate::schema;
use crate::types::*;
use std::path::Path;

// ---------------------------------------------------------------------------
// create_vault
// ---------------------------------------------------------------------------

/// Create a new .ssort vault at `path` with the given `name`.
///
/// Creates the parent directory if needed, initialises the schema, and
/// populates the project table with default metadata.
pub fn create_vault(path: &str, name: &str) -> VaultResult<()> {
    // Ensure parent directory exists
    if let Some(parent) = Path::new(path).parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            std::fs::create_dir_all(parent).map_err(|e| {
                VaultError::new(format!("Cannot create directory {}: {e}", parent.display()))
            })?;
        }
    }

    let conn = match db::connect_new(path) {
        Ok(c) => c,
        Err(e) => {
            // Clean up partial file on error
            let _ = std::fs::remove_file(path);
            return Err(e);
        }
    };

    // Apply full schema
    if let Err(e) = conn.execute_batch(schema::SCHEMA_SQL) {
        let _ = std::fs::remove_file(path);
        return Err(VaultError::new(format!("Schema creation failed: {e}")));
    }

    // Insert default project metadata
    if let Err(e) = schema::insert_project_defaults(&conn, name) {
        let _ = std::fs::remove_file(path);
        return Err(e);
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// open_vault
// ---------------------------------------------------------------------------

/// Open an existing vault, apply migrations, and return basic info.
///
/// Returns a `VaultInfo` with name, version, doc_count, category_counts, etc.
pub fn open_vault(path: &str) -> VaultResult<VaultInfo> {
    let conn = db::connect(path)?;

    // Apply schema migrations for older vaults
    schema::migrate(&conn)?;

    // Read project metadata
    let name = db::get_project_key(&conn, "name")?
        .unwrap_or_default();
    let version = db::get_project_key(&conn, "version")?
        .unwrap_or_default();
    let created_at = db::get_project_key(&conn, "created_at")?
        .unwrap_or_default();
    let emergency_contact_name = db::get_project_key(&conn, "emergency_contact_name")?
        .unwrap_or_default();
    let emergency_contact_email = db::get_project_key(&conn, "emergency_contact_email")?
        .unwrap_or_default();
    let emergency_contact_phone = db::get_project_key(&conn, "emergency_contact_phone")?
        .unwrap_or_default();
    let software_url = db::get_project_key(&conn, "software_url")?
        .unwrap_or_default();
    let password_hint = db::get_project_key(&conn, "password_hint")?
        .unwrap_or_default();

    // Document count
    let doc_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM documents", [], |row| row.get(0))
        .unwrap_or(0);

    // Category counts
    let mut cat_stmt = conn.prepare(
        "SELECT category, COUNT(*) AS cnt FROM documents GROUP BY category ORDER BY cnt DESC",
    )?;
    let category_counts: std::collections::HashMap<String, i64> = cat_stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?
                    .unwrap_or_default(),
                row.get::<_, i64>(1)?,
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();

    // Rule count
    let rule_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM rules", [], |row| row.get(0))
        .unwrap_or(0);

    // Log count
    let log_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM log", [], |row| row.get(0))
        .unwrap_or(0);

    // Total file size (uncompressed original sizes)
    let total_file_size: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(file_size), 0) FROM documents",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    Ok(VaultInfo {
        name,
        version,
        created_at,
        doc_count,
        category_counts,
        rule_count,
        log_count,
        total_file_size,
        emergency_contact_name,
        emergency_contact_email,
        emergency_contact_phone,
        software_url,
        password_hint,
    })
}

// ---------------------------------------------------------------------------
// update_project_key
// ---------------------------------------------------------------------------

/// Insert or replace a key-value pair in the project table.
pub fn update_project_key(path: &str, key: &str, value: &str) -> VaultResult<()> {
    if key.is_empty() {
        return Err(VaultError::new("Key is required"));
    }
    let conn = db::connect(path)?;
    db::set_project_key(&conn, key, value)?;
    Ok(())
}
