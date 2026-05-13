//! Document CRUD: insert, query, extract, update, get, inventory.
//!
//! Ported from vault.py / experiment documents.rs. All functions take a vault
//! path as the first argument. Uses db.rs helpers for row extraction and
//! types.rs structs for return values.

use crate::db;
use crate::types::*;
use rusqlite::params;
use std::collections::HashMap;
use std::path::Path;

// ---------------------------------------------------------------------------
// insert_document
// ---------------------------------------------------------------------------

/// Read a file from disk, compress with zstd, compute SHA-256, and insert
/// into the documents and fingerprints tables.
///
/// Returns the new `doc_id` on success.
pub fn insert_document(
    path: &str,
    file_path: &str,
    category: &str,
    confidence: f64,
    sender: &str,
    description: &str,
    doc_date: &str,
    status: &str,
    sha256: &str,
    simhash: &str,
    dhash: &str,
    source_path: &str,
) -> VaultResult<i64> {
    let fp = Path::new(file_path);
    if !fp.exists() {
        return Err(VaultError::new(format!("File not found: {file_path}")));
    }

    // Read raw bytes
    let raw_data = std::fs::read(fp)?;
    let original_size = raw_data.len() as i64;

    // Compress with zstd
    let compressed = zstd::encode_all(raw_data.as_slice(), 3)
        .map_err(|e| VaultError::new(format!("Compression failed: {e}")))?;
    let compressed_size = compressed.len();

    // Compute SHA-256 if not provided
    let sha256_val = if sha256.is_empty() {
        use sha2::{Digest, Sha256};
        let hash = Sha256::digest(&raw_data);
        format!("{:x}", hash)
    } else {
        sha256.to_string()
    };

    // Extract filename and extension
    let original_filename = fp
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let file_ext = fp
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    let effective_source = if source_path.is_empty() {
        file_path
    } else {
        source_path
    };
    let effective_status = if status.is_empty() {
        "classified"
    } else {
        status
    };

    let now = now_iso();

    let conn = db::connect(path)?;

    // Insert document row
    let doc_id: i64 = match conn.execute(
        "INSERT INTO documents \
         (original_filename, file_ext, category, confidence, sender, \
          description, doc_date, classified_at, sha256, simhash, dhash, \
          status, file_data, file_size, compression, source_path) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'zstd', ?15)",
        params![
            original_filename,
            file_ext,
            category,
            confidence,
            sender,
            description,
            doc_date,
            now,
            sha256_val,
            simhash,
            dhash,
            effective_status,
            compressed,
            original_size,
            effective_source,
        ],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => {
            let msg = e.to_string();
            if msg.to_lowercase().contains("unique") || msg.to_lowercase().contains("sha256") {
                return Err(VaultError::new(format!(
                    "Duplicate document (SHA-256 already exists): {sha256_val}"
                )));
            }
            return Err(VaultError::new(format!("Failed to insert document: {e}")));
        }
    };

    // Insert fingerprints
    conn.execute(
        "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) \
         VALUES (?1, ?2, ?3, ?4)",
        params![sha256_val, simhash, dhash, doc_id],
    )?;

    // Log the insertion
    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            format!(
                "Imported {original_filename} ({original_size} bytes, \
                 compressed to {compressed_size} bytes)"
            ),
            doc_id,
        ],
    )?;

    Ok(doc_id)
}

// ---------------------------------------------------------------------------
// query_documents
// ---------------------------------------------------------------------------

/// Query documents with optional filters.
///
/// Supports filtering by category, sender, status, date range, text pattern,
/// tag, and specific doc_id.
pub fn query_documents(path: &str, filter: &DocumentFilter) -> VaultResult<Vec<Document>> {
    let conn = db::connect(path)?;

    let mut clauses: Vec<String> = Vec::new();
    let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(ref cat) = filter.category {
        clauses.push("category = ?".to_string());
        param_values.push(Box::new(cat.clone()));
    }

    if let Some(ref sender) = filter.sender {
        clauses.push("sender LIKE ?".to_string());
        param_values.push(Box::new(format!("%{sender}%")));
    }

    if let Some(ref status) = filter.status {
        clauses.push("status = ?".to_string());
        param_values.push(Box::new(status.clone()));
    }

    if let Some(ref date_from) = filter.date_from {
        clauses.push("doc_date >= ?".to_string());
        param_values.push(Box::new(date_from.clone()));
    }

    if let Some(ref date_to) = filter.date_to {
        clauses.push("doc_date <= ?".to_string());
        param_values.push(Box::new(date_to.clone()));
    }

    if let Some(ref pattern) = filter.pattern {
        let p = format!("%{pattern}%");
        clauses.push(
            "(description LIKE ? OR original_filename LIKE ? \
             OR display_name LIKE ? OR tags LIKE ? OR sender LIKE ?)"
                .to_string(),
        );
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p));
    }

    if let Some(ref tag) = filter.tag {
        clauses.push("tags LIKE ?".to_string());
        param_values.push(Box::new(format!("%\"{tag}\"%")));
    }

    if let Some(doc_id) = filter.doc_id {
        clauses.push("doc_id = ?".to_string());
        param_values.push(Box::new(doc_id));
    }

    let where_clause = if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    };

    let sql = format!(
        "SELECT doc_id, original_filename, file_ext, category, confidence, sender, \
         description, doc_date, classified_at, sha256, simhash, dhash, \
         status, file_size, compression, encryption_iv, source_path, \
         display_name, tags \
         FROM documents {where_clause} ORDER BY classified_at DESC"
    );

    let mut stmt = conn.prepare(&sql)?;
    let params_refs: Vec<&dyn rusqlite::types::ToSql> =
        param_values.iter().map(|p| p.as_ref()).collect();

    let rows = stmt.query_map(params_refs.as_slice(), |row| {
        let tags_raw = db::get_string(row, "tags");
        let tags = db::parse_json_array(&tags_raw);
        let display_name_raw = db::get_string(row, "display_name");
        let original_filename = db::get_string(row, "original_filename");
        let display_name = if display_name_raw.is_empty() {
            original_filename.clone()
        } else {
            display_name_raw
        };
        let encrypted = db::get_blob(row, "encryption_iv").is_some();

        Ok(Document {
            doc_id: db::get_i64(row, "doc_id"),
            original_filename,
            display_name,
            file_ext: db::get_string(row, "file_ext"),
            category: db::get_string(row, "category"),
            confidence: db::get_f64(row, "confidence"),
            sender: db::get_string(row, "sender"),
            description: db::get_string(row, "description"),
            doc_date: db::get_string(row, "doc_date"),
            classified_at: db::get_string(row, "classified_at"),
            sha256: db::get_string(row, "sha256"),
            simhash: db::get_string(row, "simhash"),
            dhash: db::get_string(row, "dhash"),
            status: db::get_string(row, "status"),
            file_size: db::get_i64(row, "file_size"),
            compression: db::get_string(row, "compression"),
            encrypted,
            tags,
            source_path: db::get_string(row, "source_path"),
        })
    })?;

    let mut docs = Vec::new();
    for row_result in rows {
        docs.push(row_result?);
    }

    Ok(docs)
}

// ---------------------------------------------------------------------------
// get_document
// ---------------------------------------------------------------------------

/// Get a single document's metadata by doc_id.
///
/// Returns the Document on success, or an error if not found.
pub fn get_document(path: &str, doc_id: i64) -> VaultResult<Document> {
    let filter = DocumentFilter {
        doc_id: Some(doc_id),
        ..Default::default()
    };
    let mut docs = query_documents(path, &filter)?;
    if docs.is_empty() {
        Err(VaultError::new(format!("Document not found: id={doc_id}")))
    } else {
        Ok(docs.remove(0))
    }
}

// ---------------------------------------------------------------------------
// extract_document
// ---------------------------------------------------------------------------

/// Extract a document from the vault to the filesystem.
///
/// Reads the file_data blob, decompresses zstd, and writes to `dest`.
/// If `dest` is a directory, the original filename is appended.
///
/// Returns the final output path on success.
pub fn extract_document(path: &str, doc_id: i64, dest: &str) -> VaultResult<String> {
    let conn = db::connect(path)?;

    let mut stmt = conn.prepare(
        "SELECT original_filename, file_data, compression, encryption_iv \
         FROM documents WHERE doc_id = ?",
    )?;

    let (original_filename, file_data, compression, has_encryption): (
        String,
        Option<Vec<u8>>,
        String,
        bool,
    ) = stmt
        .query_row(params![doc_id], |row| {
            Ok((
                db::get_string(row, "original_filename"),
                db::get_blob(row, "file_data"),
                db::get_string(row, "compression"),
                db::get_blob(row, "encryption_iv").is_some(),
            ))
        })
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                VaultError::new(format!("Document not found: id={doc_id}"))
            }
            other => VaultError::from(other),
        })?;

    // Reject encrypted documents until Phase D
    if has_encryption {
        return Err(VaultError::new(
            "Document is encrypted. Decryption is not yet implemented.",
        ));
    }

    let raw_blob = file_data.ok_or_else(|| VaultError::new("Document has no file data"))?;

    // Decompress
    let decompressed = if compression == "zstd" {
        zstd::decode_all(raw_blob.as_slice())
            .map_err(|e| VaultError::new(format!("Decompression failed: {e}")))?
    } else {
        raw_blob
    };

    // Resolve destination path
    let dest_path = Path::new(dest);
    let final_path = if dest_path.is_dir() {
        dest_path.join(&original_filename)
    } else {
        dest_path.to_path_buf()
    };

    // Create parent directories if needed
    if let Some(parent) = final_path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent)?;
        }
    }

    std::fs::write(&final_path, &decompressed)?;

    // Log extraction
    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            format!("Extracted to {}", final_path.display()),
            doc_id,
        ],
    )?;

    Ok(final_path.to_string_lossy().to_string())
}

// ---------------------------------------------------------------------------
// update_document
// ---------------------------------------------------------------------------

/// Update document fields by doc_id.
///
/// Allowed fields: status, category, display_name, description, tags.
/// Tags should be provided as a JSON array value (e.g. `["tax", "2024"]`).
pub fn update_document(
    path: &str,
    doc_id: i64,
    updates: &HashMap<String, serde_json::Value>,
) -> VaultResult<()> {
    const ALLOWED: &[&str] = &["status", "category", "display_name", "description", "tags"];

    let mut set_parts: Vec<String> = Vec::new();
    let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    for key in ALLOWED {
        if let Some(val) = updates.get(*key) {
            set_parts.push(format!("{key} = ?"));
            if *key == "tags" {
                // Accept array → serialise to JSON string; accept string as-is
                match val {
                    serde_json::Value::Array(arr) => {
                        let strings: Vec<String> = arr
                            .iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect();
                        values.push(Box::new(db::to_json_array(&strings)));
                    }
                    serde_json::Value::String(s) => {
                        values.push(Box::new(s.clone()));
                    }
                    _ => {
                        values.push(Box::new(val.to_string()));
                    }
                }
            } else {
                // All other fields stored as text
                let text = match val {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                values.push(Box::new(text));
            }
        }
    }

    if set_parts.is_empty() {
        return Err(VaultError::new("No valid fields to update"));
    }

    let sql = format!(
        "UPDATE documents SET {} WHERE doc_id = ?",
        set_parts.join(", ")
    );
    values.push(Box::new(doc_id));

    let conn = db::connect(path)?;
    let params_refs: Vec<&dyn rusqlite::types::ToSql> =
        values.iter().map(|p| p.as_ref()).collect();

    let rows_changed = conn.execute(&sql, params_refs.as_slice())?;
    if rows_changed == 0 {
        return Err(VaultError::new(format!("Document not found: id={doc_id}")));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// vault_inventory
// ---------------------------------------------------------------------------

/// List all documents with metadata (no file_data blob).
///
/// Returns every document's metadata fields for display/export purposes.
pub fn vault_inventory(path: &str) -> VaultResult<Vec<Document>> {
    let conn = db::connect(path)?;

    let mut stmt = conn.prepare(
        "SELECT doc_id, original_filename, file_ext, category, confidence, sender, \
         description, doc_date, classified_at, sha256, simhash, dhash, \
         status, file_size, compression, encryption_iv, source_path, \
         display_name, tags \
         FROM documents ORDER BY doc_id",
    )?;

    let rows = stmt.query_map([], |row| {
        let tags_raw = db::get_string(row, "tags");
        let tags = db::parse_json_array(&tags_raw);
        let display_name_raw = db::get_string(row, "display_name");
        let original_filename = db::get_string(row, "original_filename");
        let display_name = if display_name_raw.is_empty() {
            original_filename.clone()
        } else {
            display_name_raw
        };
        let encrypted = db::get_blob(row, "encryption_iv").is_some();

        Ok(Document {
            doc_id: db::get_i64(row, "doc_id"),
            original_filename,
            display_name,
            file_ext: db::get_string(row, "file_ext"),
            category: db::get_string(row, "category"),
            confidence: db::get_f64(row, "confidence"),
            sender: db::get_string(row, "sender"),
            description: db::get_string(row, "description"),
            doc_date: db::get_string(row, "doc_date"),
            classified_at: db::get_string(row, "classified_at"),
            sha256: db::get_string(row, "sha256"),
            simhash: db::get_string(row, "simhash"),
            dhash: db::get_string(row, "dhash"),
            status: db::get_string(row, "status"),
            file_size: db::get_i64(row, "file_size"),
            compression: db::get_string(row, "compression"),
            encrypted,
            tags,
            source_path: db::get_string(row, "source_path"),
        })
    })?;

    let mut docs = Vec::new();
    for row_result in rows {
        docs.push(row_result?);
    }

    Ok(docs)
}
