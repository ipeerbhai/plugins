//! Checklist CRUD and run operations for tax year tracking.
//!
//! Port of the experiment's checklists.rs (ccsandbox/experiments/scansort/rust/src/checklists.rs).
//! Checklists track expected documents per tax year and can auto-match documents
//! already in the vault.
//!
//! Changes from experiment:
//!   - No godot::* references (plugin is stdio JSON-RPC, not GDExtension).
//!   - Password parameter plumbed through for API consistency (not used for
//!     encryption in this table — checklists are always plaintext metadata).

use crate::db;
use crate::schema;
use crate::types::*;
use rusqlite::params;
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Public API — CRUD
// ---------------------------------------------------------------------------

/// Add an `auto_upload` or `expected_doc` checklist item.
///
/// Returns the new `checklist_id`.
pub fn add_checklist_item(
    path: &str,
    _password: &str,
    tax_year: i32,
    item_type: &str,
    name: &str,
    match_category: Option<&str>,
    match_sender: Option<&str>,
    match_pattern: Option<&str>,
) -> VaultResult<i64> {
    if item_type != "auto_upload" && item_type != "expected_doc" {
        return Err(VaultError::new(format!(
            "Invalid checklist type: {item_type}. Must be 'auto_upload' or 'expected_doc'"
        )));
    }
    if name.is_empty() {
        return Err(VaultError::new("Checklist item must have a name"));
    }

    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    conn.execute(
        "INSERT INTO checklists \
         (tax_year, type, name, match_category, match_sender, \
          match_pattern, enabled, status) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, 'pending')",
        params![
            tax_year,
            item_type,
            name,
            match_category,
            match_sender,
            match_pattern,
        ],
    )?;

    let checklist_id = conn.last_insert_rowid();
    Ok(checklist_id)
}

/// List checklist items, optionally filtered by tax_year and/or type.
pub fn list_checklist_items(
    path: &str,
    _password: &str,
    tax_year: Option<i32>,
    item_type: Option<&str>,
) -> VaultResult<Vec<ChecklistItem>> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    let mut clauses: Vec<String> = Vec::new();
    let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(year) = tax_year {
        clauses.push("c.tax_year = ?".to_string());
        param_values.push(Box::new(year));
    }
    if let Some(t) = item_type {
        clauses.push("c.type = ?".to_string());
        param_values.push(Box::new(t.to_string()));
    }

    let where_clause = if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    };

    let sql = format!(
        "SELECT c.checklist_id, c.tax_year, c.type, c.name, \
         c.match_category, c.match_sender, c.match_pattern, \
         c.enabled, c.matched_doc_id, c.status \
         FROM checklists c \
         {where_clause} \
         ORDER BY c.type, c.checklist_id"
    );

    let param_refs: Vec<&dyn rusqlite::types::ToSql> =
        param_values.iter().map(|p| p.as_ref()).collect();

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt
        .query_map(param_refs.as_slice(), |row| {
            Ok(ChecklistItem {
                checklist_id: row.get("checklist_id")?,
                tax_year: row.get("tax_year")?,
                item_type: db::get_string(row, "type"),
                name: db::get_string(row, "name"),
                match_category: row.get::<_, Option<String>>("match_category")?,
                match_sender: row.get::<_, Option<String>>("match_sender")?,
                match_pattern: row.get::<_, Option<String>>("match_pattern")?,
                enabled: db::get_bool(row, "enabled"),
                matched_doc_id: row.get::<_, Option<i64>>("matched_doc_id")?,
                status: db::get_string(row, "status"),
            })
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(VaultError::from)?;

    Ok(rows)
}

/// Get a single checklist item by ID.
pub fn get_checklist_item(
    path: &str,
    _password: &str,
    checklist_id: i64,
) -> VaultResult<ChecklistItem> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    let result = conn.prepare(
        "SELECT checklist_id, tax_year, type, name, \
         match_category, match_sender, match_pattern, \
         enabled, matched_doc_id, status \
         FROM checklists WHERE checklist_id = ?",
    )?.query_row(params![checklist_id], |row| {
        Ok(ChecklistItem {
            checklist_id: row.get("checklist_id")?,
            tax_year: row.get("tax_year")?,
            item_type: db::get_string(row, "type"),
            name: db::get_string(row, "name"),
            match_category: row.get::<_, Option<String>>("match_category")?,
            match_sender: row.get::<_, Option<String>>("match_sender")?,
            match_pattern: row.get::<_, Option<String>>("match_pattern")?,
            enabled: db::get_bool(row, "enabled"),
            matched_doc_id: row.get::<_, Option<i64>>("matched_doc_id")?,
            status: db::get_string(row, "status"),
        })
    });

    match result {
        Ok(item) => Ok(item),
        Err(rusqlite::Error::QueryReturnedNoRows) => Err(VaultError::new(format!(
            "Checklist item not found: id={checklist_id}"
        ))),
        Err(e) => Err(VaultError::from(e)),
    }
}

/// Update a checklist item by ID.
///
/// Supported fields in `updates`: name, match_category, match_sender,
/// match_pattern, status, type, tax_year, enabled, matched_doc_id.
pub fn update_checklist_item(
    path: &str,
    _password: &str,
    checklist_id: i64,
    updates: &HashMap<String, serde_json::Value>,
) -> VaultResult<()> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    // Check existence
    let exists: bool = conn
        .prepare("SELECT 1 FROM checklists WHERE checklist_id = ?")?
        .exists(params![checklist_id])?;
    if !exists {
        return Err(VaultError::new(format!(
            "Checklist item not found: id={checklist_id}"
        )));
    }

    let mut set_clauses: Vec<String> = Vec::new();
    let mut update_params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    // String fields
    let string_fields = [
        "name",
        "match_category",
        "match_sender",
        "match_pattern",
        "status",
        "type",
    ];
    for field in &string_fields {
        if let Some(val) = updates.get(*field) {
            set_clauses.push(format!("{field} = ?"));
            let text = match val {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Null => String::new(),
                other => other.to_string(),
            };
            update_params.push(Box::new(text));
        }
    }

    // tax_year (integer)
    if let Some(val) = updates.get("tax_year") {
        set_clauses.push("tax_year = ?".to_string());
        let year = val.as_i64().unwrap_or(0) as i32;
        update_params.push(Box::new(year));
    }

    // enabled (boolean -> integer)
    if let Some(val) = updates.get("enabled") {
        set_clauses.push("enabled = ?".to_string());
        let enabled = val.as_bool().unwrap_or(true) as i64;
        update_params.push(Box::new(enabled));
    }

    // matched_doc_id (nullable integer)
    if let Some(val) = updates.get("matched_doc_id") {
        set_clauses.push("matched_doc_id = ?".to_string());
        if val.is_null() {
            update_params.push(Box::new(None::<i64>));
        } else {
            update_params.push(Box::new(val.as_i64()));
        }
    }

    if set_clauses.is_empty() {
        return Err(VaultError::new("No valid fields to update"));
    }

    update_params.push(Box::new(checklist_id));
    let sql = format!(
        "UPDATE checklists SET {} WHERE checklist_id = ?",
        set_clauses.join(", ")
    );
    let param_refs: Vec<&dyn rusqlite::types::ToSql> =
        update_params.iter().map(|p| p.as_ref()).collect();
    conn.execute(&sql, param_refs.as_slice())?;

    Ok(())
}

/// Delete a checklist item by ID.
pub fn delete_checklist_item(path: &str, _password: &str, checklist_id: i64) -> VaultResult<()> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    let rows_changed = conn.execute(
        "DELETE FROM checklists WHERE checklist_id = ?",
        params![checklist_id],
    )?;

    if rows_changed == 0 {
        return Err(VaultError::new(format!(
            "Checklist item not found: id={checklist_id}"
        )));
    }

    Ok(())
}

/// Toggle the enabled state of a checklist item.
pub fn toggle_checklist_enabled(
    path: &str,
    _password: &str,
    checklist_id: i64,
    enabled: bool,
) -> VaultResult<()> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    let rows_changed = conn.execute(
        "UPDATE checklists SET enabled = ? WHERE checklist_id = ?",
        params![enabled as i64, checklist_id],
    )?;

    if rows_changed == 0 {
        return Err(VaultError::new(format!(
            "Checklist item not found: id={checklist_id}"
        )));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Public API — run and copy
// ---------------------------------------------------------------------------

/// Run all checklist rules for a tax year against documents in the vault.
///
/// For each `expected_doc`: searches documents matching the criteria,
/// sets status to `found` or `missing`, and records the `matched_doc_id`.
///
/// For each `auto_upload`: finds matching docs and sets their status to
/// `'uploaded'` in the documents table.
///
/// Returns `{ok, expected: {found, missing, items}, auto_uploaded}`.
pub fn run_checklist(path: &str, _password: &str, tax_year: i32) -> VaultResult<serde_json::Value> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    // Fetch all enabled checklist items for this year
    let mut stmt = conn.prepare(
        "SELECT checklist_id, type, name, match_category, \
         match_sender, match_pattern \
         FROM checklists \
         WHERE tax_year = ? AND enabled = 1",
    )?;

    struct CheckItem {
        checklist_id: i64,
        item_type: String,
        name: String,
        match_category: Option<String>,
        match_sender: Option<String>,
        match_pattern: Option<String>,
    }

    let items: Vec<CheckItem> = stmt
        .query_map(params![tax_year], |row| {
            Ok(CheckItem {
                checklist_id: row.get("checklist_id")?,
                item_type: db::get_string(row, "type"),
                name: db::get_string(row, "name"),
                match_category: row.get::<_, Option<String>>("match_category")?,
                match_sender: row.get::<_, Option<String>>("match_sender")?,
                match_pattern: row.get::<_, Option<String>>("match_pattern")?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    let mut expected_found: i64 = 0;
    let mut expected_missing: i64 = 0;
    let mut expected_items: Vec<serde_json::Value> = Vec::new();
    let mut auto_uploaded: i64 = 0;

    for item in &items {
        // Build query to find matching documents
        let mut clauses: Vec<String> = Vec::new();
        let mut match_params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref cat) = item.match_category {
            if !cat.is_empty() {
                clauses.push("category = ?".to_string());
                match_params.push(Box::new(cat.clone()));
            }
        }
        if let Some(ref sender) = item.match_sender {
            if !sender.is_empty() {
                clauses.push("sender LIKE ?".to_string());
                match_params.push(Box::new(format!("%{sender}%")));
            }
        }
        if let Some(ref pattern) = item.match_pattern {
            if !pattern.is_empty() {
                clauses.push("description LIKE ?".to_string());
                match_params.push(Box::new(format!("%{pattern}%")));
            }
        }

        let where_clause = if clauses.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", clauses.join(" AND "))
        };

        let match_sql = format!(
            "SELECT doc_id, original_filename \
             FROM documents {where_clause} \
             ORDER BY classified_at DESC LIMIT 1"
        );

        let match_param_refs: Vec<&dyn rusqlite::types::ToSql> =
            match_params.iter().map(|p| p.as_ref()).collect();

        let mut match_stmt = conn.prepare(&match_sql)?;
        let match_result: Option<(i64, String)> = match_stmt
            .query_row(match_param_refs.as_slice(), |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                ))
            })
            .ok();

        if item.item_type == "expected_doc" {
            if let Some((doc_id, filename)) = match_result {
                conn.execute(
                    "UPDATE checklists SET status = 'found', matched_doc_id = ? \
                     WHERE checklist_id = ?",
                    params![doc_id, item.checklist_id],
                )?;
                expected_found += 1;
                expected_items.push(serde_json::json!({
                    "checklist_id": item.checklist_id,
                    "name": item.name,
                    "status": "found",
                    "matched_doc_id": doc_id,
                    "matched_filename": filename,
                }));
            } else {
                conn.execute(
                    "UPDATE checklists SET status = 'missing', matched_doc_id = NULL \
                     WHERE checklist_id = ?",
                    params![item.checklist_id],
                )?;
                expected_missing += 1;
                expected_items.push(serde_json::json!({
                    "checklist_id": item.checklist_id,
                    "name": item.name,
                    "status": "missing",
                    "matched_doc_id": null,
                    "matched_filename": null,
                }));
            }
        } else if item.item_type == "auto_upload" {
            if let Some((doc_id, _)) = match_result {
                // Set the matched document's status to 'uploaded'
                conn.execute(
                    "UPDATE documents SET status = 'uploaded' WHERE doc_id = ?",
                    params![doc_id],
                )?;
                conn.execute(
                    "UPDATE checklists SET status = 'found', matched_doc_id = ? \
                     WHERE checklist_id = ?",
                    params![doc_id, item.checklist_id],
                )?;
                auto_uploaded += 1;
            } else {
                conn.execute(
                    "UPDATE checklists SET status = 'pending', matched_doc_id = NULL \
                     WHERE checklist_id = ?",
                    params![item.checklist_id],
                )?;
            }
        }
    }

    Ok(serde_json::json!({
        "ok": true,
        "expected": {
            "found": expected_found,
            "missing": expected_missing,
            "items": expected_items,
        },
        "auto_uploaded": auto_uploaded,
    }))
}

/// Copy all checklist items from one tax year to another (for next tax season).
///
/// Duplicates items with the new `tax_year`, resets status to `'pending'`,
/// and clears `matched_doc_id`.
///
/// Returns the number of items copied.
pub fn copy_checklist_year(
    path: &str,
    _password: &str,
    from_year: i32,
    to_year: i32,
) -> VaultResult<i64> {
    let conn = db::connect(path)?;
    schema::migrate(&conn)?;

    let mut stmt = conn.prepare(
        "SELECT type, name, match_category, match_sender, \
         match_pattern, enabled \
         FROM checklists WHERE tax_year = ?",
    )?;

    struct CopyItem {
        item_type: String,
        name: String,
        match_category: Option<String>,
        match_sender: Option<String>,
        match_pattern: Option<String>,
        enabled: i64,
    }

    let items: Vec<CopyItem> = stmt
        .query_map(params![from_year], |row| {
            Ok(CopyItem {
                item_type: db::get_string(row, "type"),
                name: db::get_string(row, "name"),
                match_category: row.get::<_, Option<String>>("match_category")?,
                match_sender: row.get::<_, Option<String>>("match_sender")?,
                match_pattern: row.get::<_, Option<String>>("match_pattern")?,
                enabled: row.get::<_, Option<i64>>("enabled")?.unwrap_or(1),
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    let mut copied: i64 = 0;

    for item in &items {
        conn.execute(
            "INSERT INTO checklists \
             (tax_year, type, name, match_category, match_sender, \
              match_pattern, enabled, status) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending')",
            params![
                to_year,
                item.item_type,
                item.name,
                item.match_category,
                item.match_sender,
                item.match_pattern,
                item.enabled,
            ],
        )?;
        copied += 1;
    }

    Ok(copied)
}
