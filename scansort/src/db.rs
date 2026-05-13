//! Database connection management and shared helpers.
//!
//! Provides WAL-mode connections, transaction helpers, and row→struct converters.
//! All domain modules import from here for consistent DB access patterns.

use crate::types::{VaultError, VaultResult};
use rusqlite::{Connection, OpenFlags, Row};
use std::path::Path;

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

/// Open an existing vault database with WAL journal mode.
pub fn connect(path: &str) -> VaultResult<Connection> {
    if !Path::new(path).exists() {
        return Err(VaultError::new(format!("Vault not found: {path}")));
    }
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    Ok(conn)
}

/// Create a new vault database file.
pub fn connect_new(path: &str) -> VaultResult<Connection> {
    if Path::new(path).exists() {
        return Err(VaultError::new(format!("Vault already exists: {path}")));
    }
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    Ok(conn)
}

/// Open a vault read-only (for cross-vault queries).
pub fn connect_readonly(path: &str) -> VaultResult<Connection> {
    if !Path::new(path).exists() {
        return Err(VaultError::new(format!("Vault not found: {path}")));
    }
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    Ok(conn)
}

// ---------------------------------------------------------------------------
// Result helpers — match Python's _ok() / _error() pattern
// ---------------------------------------------------------------------------

/// Build a success result as a serde_json::Value.
pub fn ok_result() -> serde_json::Value {
    serde_json::json!({"success": true})
}

/// Build a success result with additional fields.
pub fn ok_with(fields: serde_json::Value) -> serde_json::Value {
    let mut val = fields;
    if let Some(obj) = val.as_object_mut() {
        obj.insert("success".to_string(), serde_json::Value::Bool(true));
    }
    val
}

/// Build an error result.
pub fn err_result(msg: &str) -> serde_json::Value {
    serde_json::json!({"success": false, "error": msg})
}

// ---------------------------------------------------------------------------
// Row extraction helpers
// ---------------------------------------------------------------------------

/// Extract an optional string column, returning empty string for NULL.
pub fn get_string(row: &Row, idx: &str) -> String {
    row.get::<_, Option<String>>(idx).unwrap_or(None).unwrap_or_default()
}

/// Extract an optional i64 column, returning 0 for NULL.
pub fn get_i64(row: &Row, idx: &str) -> i64 {
    row.get::<_, Option<i64>>(idx).unwrap_or(None).unwrap_or(0)
}

/// Extract an optional f64 column, returning 0.0 for NULL.
pub fn get_f64(row: &Row, idx: &str) -> f64 {
    row.get::<_, Option<f64>>(idx).unwrap_or(None).unwrap_or(0.0)
}

/// Extract an optional bool column (stored as INTEGER), returning false for NULL.
pub fn get_bool(row: &Row, idx: &str) -> bool {
    row.get::<_, Option<i64>>(idx).unwrap_or(None).unwrap_or(0) != 0
}

/// Extract an optional blob column, returning None for NULL.
pub fn get_blob(row: &Row, idx: &str) -> Option<Vec<u8>> {
    row.get::<_, Option<Vec<u8>>>(idx).unwrap_or(None)
}

/// Parse a JSON array string into Vec<String>, returning empty vec on failure.
pub fn parse_json_array(json_str: &str) -> Vec<String> {
    serde_json::from_str::<Vec<String>>(json_str).unwrap_or_default()
}

/// Serialize a Vec<String> to a JSON array string.
pub fn to_json_array(items: &[String]) -> String {
    serde_json::to_string(items).unwrap_or_else(|_| "[]".to_string())
}

// ---------------------------------------------------------------------------
// Project table helpers
// ---------------------------------------------------------------------------

/// Get a value from the project key-value table.
pub fn get_project_key(conn: &Connection, key: &str) -> VaultResult<Option<String>> {
    let mut stmt = conn.prepare("SELECT value FROM project WHERE key = ?")?;
    let result = stmt.query_row([key], |row| row.get::<_, String>(0));
    match result {
        Ok(val) => Ok(Some(val)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(VaultError::from(e)),
    }
}

/// Set a value in the project key-value table.
pub fn set_project_key(conn: &Connection, key: &str, value: &str) -> VaultResult<()> {
    conn.execute(
        "INSERT OR REPLACE INTO project (key, value) VALUES (?, ?)",
        rusqlite::params![key, value],
    )?;
    Ok(())
}
