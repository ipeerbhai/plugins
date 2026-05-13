//! Database schema creation and migration.
//!
//! Defines all 6 tables. Handles migration for older vaults missing new columns.

use crate::db;
use crate::types::{now_iso, VaultResult};
use rusqlite::Connection;

// ---------------------------------------------------------------------------
// Schema SQL
// ---------------------------------------------------------------------------

pub const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS project (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS rules (
    rule_id INTEGER PRIMARY KEY AUTOINCREMENT,
    label TEXT UNIQUE NOT NULL,
    name TEXT,
    instruction TEXT,
    signals TEXT,
    subfolder TEXT,
    rename_pattern TEXT DEFAULT '',
    confidence_threshold REAL DEFAULT 0.6,
    encrypt INTEGER DEFAULT 0,
    enabled INTEGER DEFAULT 1,
    is_default INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS documents (
    doc_id INTEGER PRIMARY KEY AUTOINCREMENT,
    original_filename TEXT NOT NULL,
    file_ext TEXT,
    category TEXT,
    confidence REAL,
    sender TEXT,
    description TEXT,
    doc_date TEXT,
    classified_at TEXT,
    sha256 TEXT UNIQUE,
    simhash TEXT,
    dhash TEXT,
    status TEXT DEFAULT 'classified',
    file_data BLOB,
    file_size INTEGER,
    compression TEXT DEFAULT 'zstd',
    encryption_iv BLOB,
    encryption_tag BLOB,
    source_path TEXT,
    display_name TEXT DEFAULT '',
    tags TEXT DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS fingerprints (
    sha256 TEXT PRIMARY KEY,
    simhash TEXT,
    dhash TEXT,
    doc_id INTEGER REFERENCES documents(doc_id)
);

CREATE TABLE IF NOT EXISTS log (
    log_id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    level TEXT,
    component TEXT,
    message TEXT,
    doc_id INTEGER REFERENCES documents(doc_id)
);

CREATE TABLE IF NOT EXISTS watch_folders (
    watch_id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL,
    category_filter TEXT,
    enabled INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS checklists (
    checklist_id INTEGER PRIMARY KEY AUTOINCREMENT,
    tax_year INTEGER NOT NULL,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    match_category TEXT,
    match_sender TEXT,
    match_pattern TEXT,
    enabled INTEGER DEFAULT 1,
    matched_doc_id INTEGER REFERENCES documents(doc_id),
    status TEXT DEFAULT 'pending'
);
"#;

// ---------------------------------------------------------------------------
// Migration
// ---------------------------------------------------------------------------

/// Apply schema migrations for older vaults that may be missing tables/columns.
pub fn migrate(conn: &Connection) -> VaultResult<()> {
    // Create checklists table if missing (added in later version)
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS checklists (
            checklist_id INTEGER PRIMARY KEY AUTOINCREMENT,
            tax_year INTEGER NOT NULL,
            type TEXT NOT NULL,
            name TEXT NOT NULL,
            match_category TEXT,
            match_sender TEXT,
            match_pattern TEXT,
            enabled INTEGER DEFAULT 1,
            matched_doc_id INTEGER REFERENCES documents(doc_id),
            status TEXT DEFAULT 'pending'
        );"
    )?;

    // Add display_name and tags columns if missing
    let cols: Vec<String> = conn
        .prepare("PRAGMA table_info(documents)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(|r| r.ok())
        .collect();

    if !cols.contains(&"display_name".to_string()) {
        conn.execute("ALTER TABLE documents ADD COLUMN display_name TEXT DEFAULT ''", [])?;
    }
    if !cols.contains(&"tags".to_string()) {
        conn.execute("ALTER TABLE documents ADD COLUMN tags TEXT DEFAULT '[]'", [])?;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Project defaults
// ---------------------------------------------------------------------------

/// Insert default project metadata entries for a new vault.
pub fn insert_project_defaults(conn: &Connection, name: &str) -> VaultResult<()> {
    let now = now_iso();

    let entries = [
        ("name", name.to_string()),
        ("version", "1.0.0".to_string()),
        ("created_at", now),
        (
            "format_description",
            "SQLite database. documents.file_data contains zstd-compressed original files. \
             Decompress with standard zstd tools. If encryption_iv is not NULL, file_data is \
             AES-256-GCM encrypted before compression. All metadata (category, sender, dates, \
             descriptions) is always plaintext and readable without decryption."
                .to_string(),
        ),
        ("readme", generate_readme(name)),
        (
            "extraction_guide",
            "To extract documents without ScanSort:\n\
             1. Open this file with any SQLite browser (e.g. DB Browser for SQLite).\n\
             2. Query: SELECT original_filename, file_data, compression FROM documents.\n\
             3. For each row, decompress file_data with zstd.\n\
             4. Save as original_filename."
                .to_string(),
        ),
        ("emergency_contact_name", String::new()),
        ("emergency_contact_email", String::new()),
        ("emergency_contact_phone", String::new()),
        (
            "software_url",
            "https://github.com/ipeerbhai/scansort".to_string(),
        ),
        ("password_hint", String::new()),
        (
            "table_documents",
            "Contains all classified documents. file_data is the compressed (and optionally \
             encrypted) original file. All other columns are plaintext metadata."
                .to_string(),
        ),
        (
            "table_rules",
            "Classification rules that determine how documents are categorized."
                .to_string(),
        ),
        (
            "table_fingerprints",
            "Deduplication hashes. sha256 for exact matches, simhash for text similarity, \
             dhash for visual similarity."
                .to_string(),
        ),
        (
            "table_log",
            "Activity log. Records all processing events, errors, and state changes."
                .to_string(),
        ),
        (
            "table_watch_folders",
            "Directories monitored for new files to classify and import.".to_string(),
        ),
    ];

    for (key, value) in &entries {
        db::set_project_key(conn, key, value)?;
    }

    Ok(())
}

/// Generate a basic README text for the vault.
fn generate_readme(name: &str) -> String {
    format!(
        "=== IMPORTANT: Document Archive ===\n\
         \n\
         Vault: {name}\n\
         \n\
         This .ssort file contains classified documents.\n\
         To access, install ScanSort or open with any SQLite browser.\n\
         See the 'extraction_guide' key in the project table for manual recovery.\n\
         \n\
         Software: https://github.com/ipeerbhai/scansort\n"
    )
}
