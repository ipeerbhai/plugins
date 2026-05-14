//! Document CRUD: insert, query, extract, update, get, inventory.
//!
//! Ported from vault.py / experiment documents.rs. All functions take a vault
//! path as the first argument. Uses db.rs helpers for row extraction and
//! types.rs structs for return values.

use crate::crypto;
use crate::db;
use crate::types::*;
use rusqlite::params;
use std::collections::HashMap;
use std::path::Path;

// ---------------------------------------------------------------------------
// insert_document
// ---------------------------------------------------------------------------

/// Read a file from disk, compress with zstd, optionally encrypt with
/// AES-256-GCM, and insert into the documents and fingerprints tables.
///
/// `password` controls encryption: if non-empty the vault must already have a
/// password set (via `crypto::set_password`); the same KDF + salt stored in
/// the vault's project table is used to derive the key.  Ordering mirrors the
/// Python reference implementation: **compress → encrypt → store**.
///
/// Returns the new `doc_id` on success.
pub fn insert_document(
    path: &str,
    file_path: &str,
    category: &str,
    confidence: f64,
    issuer: &str,
    description: &str,
    doc_date: &str,
    status: &str,
    sha256: &str,
    simhash: &str,
    dhash: &str,
    source_path: &str,
    rule_snapshot: &str,
    password: &str,
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

    // Optionally encrypt the compressed bytes (compress → encrypt, same as Python).
    let (stored_data, enc_iv, enc_tag): (Vec<u8>, Option<Vec<u8>>, Option<Vec<u8>>) =
        if !password.is_empty() {
            let key = crypto::vault_key(path, password)?;
            let (ct, iv, tag) = crypto::encrypt_bytes(&key, &compressed)?;
            (ct, Some(iv), Some(tag))
        } else {
            (compressed, None, None)
        };

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
         (original_filename, file_ext, category, confidence, issuer, \
          description, doc_date, classified_at, sha256, simhash, dhash, \
          status, file_data, file_size, compression, encryption_iv, encryption_tag, \
          source_path, rule_snapshot) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'zstd', \
                 ?15, ?16, ?17, ?18)",
        params![
            original_filename,
            file_ext,
            category,
            confidence,
            issuer,
            description,
            doc_date,
            now,
            sha256_val,
            simhash,
            dhash,
            effective_status,
            stored_data,
            original_size,
            enc_iv,
            enc_tag,
            effective_source,
            rule_snapshot,
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

    if let Some(ref issuer) = filter.issuer {
        clauses.push("issuer LIKE ?".to_string());
        param_values.push(Box::new(format!("%{issuer}%")));
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
             OR display_name LIKE ? OR tags LIKE ? OR issuer LIKE ?)"
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
        "SELECT doc_id, original_filename, file_ext, category, confidence, issuer, \
         description, doc_date, classified_at, sha256, simhash, dhash, \
         status, file_size, compression, encryption_iv, source_path, \
         display_name, tags, rule_snapshot \
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
            issuer: db::get_string(row, "issuer"),
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
            rule_snapshot: db::get_string(row, "rule_snapshot"),
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
/// Reads the file_data blob, decrypts if the document is encrypted (requires
/// `password`), decompresses zstd, and writes to `dest`.  If `dest` is a
/// directory the original filename is appended.
///
/// Ordering mirrors the Python reference implementation (and the inverse of
/// `insert_document`): stored blob = encrypt(compress(raw)), so extract does
/// **decrypt → decompress → write**.
///
/// * Plaintext doc + any password: works (password ignored).
/// * Encrypted doc + correct password: decrypts and extracts.
/// * Encrypted doc + empty password: returns a clear "password required" error.
/// * Encrypted doc + wrong password: returns a clear "incorrect password" error,
///   never panics (GCM tag mismatch is caught).
///
/// Returns the final output path on success.
pub fn extract_document(path: &str, doc_id: i64, dest: &str, password: &str) -> VaultResult<String> {
    let conn = db::connect(path)?;

    let mut stmt = conn.prepare(
        "SELECT original_filename, file_data, compression, encryption_iv, encryption_tag \
         FROM documents WHERE doc_id = ?",
    )?;

    let (original_filename, file_data, compression, enc_iv, enc_tag): (
        String,
        Option<Vec<u8>>,
        String,
        Option<Vec<u8>>,
        Option<Vec<u8>>,
    ) = stmt
        .query_row(params![doc_id], |row| {
            Ok((
                db::get_string(row, "original_filename"),
                db::get_blob(row, "file_data"),
                db::get_string(row, "compression"),
                db::get_blob(row, "encryption_iv"),
                db::get_blob(row, "encryption_tag"),
            ))
        })
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                VaultError::new(format!("Document not found: id={doc_id}"))
            }
            other => VaultError::from(other),
        })?;

    let raw_blob = file_data.ok_or_else(|| VaultError::new("Document has no file data"))?;

    // Decrypt if the document was stored encrypted (compression then encryption).
    let decompressable: Vec<u8> = if let (Some(iv), Some(tag)) = (enc_iv, enc_tag) {
        // Document is encrypted — password is required.
        if password.is_empty() {
            return Err(VaultError::new(
                "Document is encrypted — a vault password is required to open it.",
            ));
        }
        // Derive the vault key using the same KDF + salt used at insert time.
        let key = crypto::vault_key(path, password).map_err(|e| {
            VaultError::new(format!("Failed to derive vault key: {}", e.message))
        })?;
        // Decrypt.  GCM tag mismatch means wrong password.
        crypto::decrypt_bytes(&key, &raw_blob, &iv, &tag).map_err(|_| {
            VaultError::new(
                "Incorrect vault password — could not decrypt the document.",
            )
        })?
    } else {
        // Plaintext document — use blob as-is.
        raw_blob
    };

    // Decompress
    let decompressed = if compression == "zstd" {
        zstd::decode_all(decompressable.as_slice())
            .map_err(|e| VaultError::new(format!("Decompression failed: {e}")))?
    } else {
        decompressable
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
// set_document_encrypted — toggle a document's at-rest encryption in place
// ---------------------------------------------------------------------------

/// Toggle whether a document's stored blob is encrypted, in place.
///
/// The stored blob is always `compress(raw)`; an *encrypted* document
/// additionally has that compressed blob AES-256-GCM encrypted
/// (`encrypt(compress(raw))`) with `encryption_iv` / `encryption_tag` set.
/// Encryption state is identified by iv/tag presence — the same convention
/// `extract_document` and `query_documents` use.
///
/// * `encrypt == true` on a plaintext doc  → `encrypt(compress(raw))`, sets iv/tag.
/// * `encrypt == false` on an encrypted doc → decrypts back to `compress(raw)`,
///   clears iv/tag.
/// * Already in the requested state → no-op (`Ok`).
/// * A state change requires a non-empty `password`; a wrong password on
///   decrypt returns a clear error and never panics (GCM tag mismatch).
pub fn set_document_encrypted(
    path: &str,
    doc_id: i64,
    encrypt: bool,
    password: &str,
) -> VaultResult<()> {
    let conn = db::connect(path)?;

    let (file_data, enc_iv, enc_tag): (Option<Vec<u8>>, Option<Vec<u8>>, Option<Vec<u8>>) = conn
        .prepare(
            "SELECT file_data, encryption_iv, encryption_tag FROM documents WHERE doc_id = ?",
        )?
        .query_row(params![doc_id], |row| {
            Ok((
                db::get_blob(row, "file_data"),
                db::get_blob(row, "encryption_iv"),
                db::get_blob(row, "encryption_tag"),
            ))
        })
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                VaultError::new(format!("Document not found: id={doc_id}"))
            }
            other => VaultError::from(other),
        })?;

    let blob = file_data.ok_or_else(|| VaultError::new("Document has no file data"))?;
    let currently_encrypted = enc_iv.is_some() && enc_tag.is_some();

    // Already in the requested state — nothing to do.
    if currently_encrypted == encrypt {
        return Ok(());
    }

    if password.is_empty() {
        return Err(VaultError::new(
            "A vault password is required to change a document's encryption.",
        ));
    }
    let key = crypto::vault_key(path, password).map_err(|e| {
        VaultError::new(format!("Failed to derive vault key: {}", e.message))
    })?;

    let (new_blob, new_iv, new_tag): (Vec<u8>, Option<Vec<u8>>, Option<Vec<u8>>) = if encrypt {
        // Plaintext → encrypted: encrypt the (already compressed) blob.
        let (ct, iv, tag) = crypto::encrypt_bytes(&key, &blob)?;
        (ct, Some(iv), Some(tag))
    } else {
        // Encrypted → plaintext: decrypt back to the compressed blob.
        let iv = enc_iv.unwrap();
        let tag = enc_tag.unwrap();
        let compressed = crypto::decrypt_bytes(&key, &blob, &iv, &tag).map_err(|_| {
            VaultError::new("Incorrect vault password — could not decrypt the document.")
        })?;
        (compressed, None, None)
    };

    conn.execute(
        "UPDATE documents SET file_data = ?1, encryption_iv = ?2, encryption_tag = ?3 \
         WHERE doc_id = ?4",
        params![new_blob, new_iv, new_tag, doc_id],
    )?;

    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            if encrypt {
                "Document encrypted at rest"
            } else {
                "Document decrypted at rest"
            },
            doc_id,
        ],
    )?;

    Ok(())
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
        "SELECT doc_id, original_filename, file_ext, category, confidence, issuer, \
         description, doc_date, classified_at, sha256, simhash, dhash, \
         status, file_size, compression, encryption_iv, source_path, \
         display_name, tags, rule_snapshot \
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
            issuer: db::get_string(row, "issuer"),
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
            rule_snapshot: db::get_string(row, "rule_snapshot"),
        })
    })?;

    let mut docs = Vec::new();
    for row_result in rows {
        docs.push(row_result?);
    }

    Ok(docs)
}

// ===========================================================================
// Tests (W5f) — encrypted-document round-trip via insert_document /
// extract_document.
// ===========================================================================
#[cfg(test)]
mod tests {
    use crate::crypto;
    use crate::documents::{extract_document, insert_document, set_document_encrypted};
    use crate::vault_lifecycle;
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
        std::env::temp_dir().join(format!("scansort-documents-{prefix}-{pid}-{ts}-{n}"))
    }

    /// Build a vault + a source file, returning (dir, vault_path, src_file).
    fn setup(prefix: &str, body: &[u8]) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        let dir = unique_tmp(prefix);
        std::fs::create_dir_all(&dir).unwrap();
        let vault_path = dir.join("archive.ssort");
        vault_lifecycle::create_vault(vault_path.to_str().unwrap(), "TestArchive")
            .expect("create vault");
        let src_file = dir.join("sample.txt");
        std::fs::write(&src_file, body).unwrap();
        (dir, vault_path, src_file)
    }

    fn insert(
        vault_path: &std::path::Path,
        src_file: &std::path::Path,
        password: &str,
    ) -> i64 {
        insert_document(
            vault_path.to_str().unwrap(),
            src_file.to_str().unwrap(),
            "test",
            0.9,
            "tester",
            "test doc",
            "2024-01-01",
            "classified",
            "",
            "0000000000000000",
            "0000000000000000",
            "",
            "",
            password,
        )
        .expect("insert_document")
    }

    // -----------------------------------------------------------------------
    // 1. Encrypted doc + correct password → round-trips, bytes match.
    // -----------------------------------------------------------------------
    #[test]
    fn encrypted_doc_correct_password_round_trips() {
        let body = b"top secret contents for the encrypted round trip test";
        let (dir, vault_path, src_file) = setup("enc-ok", body);
        let pw = "correct horse battery staple";

        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);
        assert!(doc_id > 0);

        let out = dir.join("extracted.txt");
        let out_path = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            pw,
        )
        .expect("extract_document with correct password");

        let got = std::fs::read(&out_path).expect("read extracted file");
        assert_eq!(got.as_slice(), body, "decrypted bytes must match original");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 2. Encrypted doc + wrong password → clear error, no panic.
    // -----------------------------------------------------------------------
    #[test]
    fn encrypted_doc_wrong_password_clear_error() {
        let body = b"contents guarded by a password";
        let (dir, vault_path, src_file) = setup("enc-wrong", body);
        let pw = "the real password";

        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);

        let out = dir.join("extracted.txt");
        let res = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            "the WRONG password",
        );
        assert!(res.is_err(), "wrong password must return Err, not panic");
        let msg = res.unwrap_err().message.to_lowercase();
        assert!(
            msg.contains("password") || msg.contains("decrypt"),
            "error should mention password/decrypt, got: {msg}"
        );
        assert!(!out.exists(), "no output file should be written on failure");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 3. Encrypted doc + empty password → "password required" error.
    // -----------------------------------------------------------------------
    #[test]
    fn encrypted_doc_empty_password_required_error() {
        let body = b"contents that need a password to read";
        let (dir, vault_path, src_file) = setup("enc-empty", body);
        let pw = "a vault password";

        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);

        let out = dir.join("extracted.txt");
        let res = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            "",
        );
        assert!(res.is_err(), "empty password on encrypted doc must return Err");
        let msg = res.unwrap_err().message.to_lowercase();
        assert!(
            msg.contains("password") && msg.contains("required"),
            "error should say a password is required, got: {msg}"
        );
        assert!(!out.exists(), "no output file should be written on failure");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 4. Plaintext doc still extracts (password ignored).
    // -----------------------------------------------------------------------
    #[test]
    fn plaintext_doc_still_extracts() {
        let body = b"ordinary unencrypted document body";
        let (dir, vault_path, src_file) = setup("plain", body);

        // No set_password, no password passed to insert → stored compressed-only.
        let doc_id = insert(&vault_path, &src_file, "");
        assert!(doc_id > 0);

        // Extract with empty password works.
        let out = dir.join("extracted-empty.txt");
        let out_path = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            "",
        )
        .expect("extract plaintext doc with empty password");
        assert_eq!(
            std::fs::read(&out_path).unwrap().as_slice(),
            body,
            "plaintext extract must match original"
        );

        // Extract with a non-empty password also works (password ignored).
        let out2 = dir.join("extracted-pw.txt");
        let out_path2 = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out2.to_str().unwrap(),
            "irrelevant password",
        )
        .expect("extract plaintext doc with a password (ignored)");
        assert_eq!(
            std::fs::read(&out_path2).unwrap().as_slice(),
            body,
            "plaintext extract must match original even when a password is supplied"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 5. W5h: set_document_encrypted toggles encryption in place, round-trips.
    // -----------------------------------------------------------------------
    #[test]
    fn set_document_encrypted_round_trips_plaintext_to_encrypted_and_back() {
        let body = b"a document that starts plaintext and gets encrypted in place";
        let (dir, vault_path, src_file) = setup("setenc-rt", body);
        let pw = "vault password for in-place encryption";
        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");

        // Insert as PLAINTEXT (no password to insert).
        let doc_id = insert(&vault_path, &src_file, "");

        // Encrypt in place.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, true, pw)
            .expect("encrypt in place");
        // Now it must require the password to extract...
        let no_pw = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            dir.join("x1.txt").to_str().unwrap(),
            "",
        );
        assert!(no_pw.is_err(), "encrypted doc must need a password");
        // ...and decrypt correctly with it.
        let out = dir.join("enc-extract.txt");
        extract_document(vault_path.to_str().unwrap(), doc_id, out.to_str().unwrap(), pw)
            .expect("extract after in-place encrypt");
        assert_eq!(std::fs::read(&out).unwrap().as_slice(), body);

        // Decrypt in place — now it extracts with an empty password again.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, false, pw)
            .expect("decrypt in place");
        let out2 = dir.join("dec-extract.txt");
        extract_document(vault_path.to_str().unwrap(), doc_id, out2.to_str().unwrap(), "")
            .expect("extract after in-place decrypt");
        assert_eq!(std::fs::read(&out2).unwrap().as_slice(), body);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn set_document_encrypted_is_idempotent_and_guards_password() {
        let body = b"idempotency + password-guard checks";
        let (dir, vault_path, src_file) = setup("setenc-guard", body);
        let pw = "the vault password";
        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, "");

        // Already plaintext → encrypt:false is a no-op, even with empty password.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, false, "")
            .expect("no-op when already in the requested state");

        // Plaintext → encrypt:true with EMPTY password → clear error.
        let err = set_document_encrypted(vault_path.to_str().unwrap(), doc_id, true, "")
            .expect_err("a state change needs a password");
        assert!(err.message.to_lowercase().contains("password"));

        // Encrypt for real, then decrypt with the WRONG password → clear error, no panic.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, true, pw)
            .expect("encrypt");
        let werr = set_document_encrypted(vault_path.to_str().unwrap(), doc_id, false, "wrong pw")
            .expect_err("wrong password must error");
        assert!(
            werr.message.to_lowercase().contains("password")
                || werr.message.to_lowercase().contains("decrypt"),
            "got: {}",
            werr.message
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
