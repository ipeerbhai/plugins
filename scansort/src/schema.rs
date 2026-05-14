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
    issuer TEXT,
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
    tags TEXT DEFAULT '[]',
    rule_snapshot TEXT DEFAULT ''
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
    if !cols.contains(&"rule_snapshot".to_string()) {
        conn.execute(
            "ALTER TABLE documents ADD COLUMN rule_snapshot TEXT DEFAULT ''",
            [],
        )?;
    }

    // Rename sender → issuer (idempotent: only runs when the legacy column name
    // is still present, i.e. the column is named "sender" not yet "issuer").
    // Re-read cols in case ADD COLUMN above changed the set.
    let cols_now: Vec<String> = conn
        .prepare("PRAGMA table_info(documents)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(|r| r.ok())
        .collect();
    if cols_now.contains(&"sender".to_string()) && !cols_now.contains(&"issuer".to_string()) {
        conn.execute("ALTER TABLE documents RENAME COLUMN sender TO issuer", [])?;
    }

    // Version bump: 1.0.0 → 1.1.0 marks rules storage as external. The legacy
    // `rules` table is left in place as a historical artifact (deprecated, never
    // written by new classifies). Full migration of embedded rules into a user-
    // level file is a separate UX-driven step (planned for R5 of the DCR).
    let current_version = db::get_project_key(conn, "version")?
        .unwrap_or_default();
    if current_version != "1.1.0" {
        db::set_project_key(conn, "version", "1.1.0")?;
        db::set_project_key(conn, "rules_storage", "external")?;
        db::set_project_key(conn, "rules_migrated_at", &now_iso())?;
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
        ("version", "1.1.0".to_string()),
        ("rules_storage", "external".to_string()),
        ("created_at", now.clone()),
        ("rules_migrated_at", now),
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    /// Apply the pre-1.1.0 schema (no rule_snapshot column) and stamp version=1.0.0.
    /// Mirrors what an on-disk legacy vault looks like.
    fn legacy_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        // Note: documents table here lacks rule_snapshot. Other tables match
        // the current schema since prior migrations have already landed.
        conn.execute_batch(
            r#"
            CREATE TABLE project (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE rules (
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
            CREATE TABLE documents (
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
            "#,
        )
        .unwrap();
        conn.execute(
            "INSERT INTO project (key, value) VALUES ('version', '1.0.0')",
            [],
        )
        .unwrap();
        conn
    }

    fn doc_columns(conn: &Connection) -> Vec<String> {
        conn.prepare("PRAGMA table_info(documents)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect()
    }

    #[test]
    fn migrate_adds_rule_snapshot_column_to_legacy_documents() {
        let conn = legacy_conn();
        assert!(!doc_columns(&conn).contains(&"rule_snapshot".to_string()));
        migrate(&conn).expect("migrate");
        assert!(doc_columns(&conn).contains(&"rule_snapshot".to_string()));
    }

    #[test]
    fn migrate_bumps_version_to_1_1_0() {
        let conn = legacy_conn();
        migrate(&conn).expect("migrate");
        let v = db::get_project_key(&conn, "version").unwrap();
        assert_eq!(v.as_deref(), Some("1.1.0"));
    }

    #[test]
    fn migrate_stamps_rules_storage_external() {
        let conn = legacy_conn();
        migrate(&conn).expect("migrate");
        let v = db::get_project_key(&conn, "rules_storage").unwrap();
        assert_eq!(v.as_deref(), Some("external"));
    }

    #[test]
    fn migrate_stamps_rules_migrated_at_timestamp() {
        let conn = legacy_conn();
        migrate(&conn).expect("migrate");
        let ts = db::get_project_key(&conn, "rules_migrated_at")
            .unwrap()
            .expect("should be set");
        assert!(!ts.is_empty(), "rules_migrated_at must be non-empty");
        // ISO 8601 starts with the year.
        assert!(
            ts.starts_with("20") || ts.starts_with("21"),
            "expected ISO timestamp, got: {ts}"
        );
    }

    #[test]
    fn migrate_is_idempotent_on_already_migrated_vault() {
        let conn = legacy_conn();
        migrate(&conn).expect("first migrate");
        let first_ts = db::get_project_key(&conn, "rules_migrated_at")
            .unwrap()
            .unwrap();

        // Second migrate should be a no-op (version already 1.1.0).
        migrate(&conn).expect("second migrate");
        let second_ts = db::get_project_key(&conn, "rules_migrated_at")
            .unwrap()
            .unwrap();
        assert_eq!(
            first_ts, second_ts,
            "rules_migrated_at must not be overwritten by re-migration"
        );

        // Re-adding the column would error if not guarded — re-run confirms guard works.
        assert!(doc_columns(&conn).contains(&"rule_snapshot".to_string()));
    }

    #[test]
    fn fresh_vault_starts_at_1_1_0_with_external_rules_storage() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        insert_project_defaults(&conn, "Fresh Vault").expect("defaults");

        let v = db::get_project_key(&conn, "version").unwrap();
        assert_eq!(v.as_deref(), Some("1.1.0"));
        let rs = db::get_project_key(&conn, "rules_storage").unwrap();
        assert_eq!(rs.as_deref(), Some("external"));
        // Schema includes rule_snapshot directly — no migration needed for fresh vaults.
        assert!(doc_columns(&conn).contains(&"rule_snapshot".to_string()));
    }

    #[test]
    fn legacy_rules_table_is_preserved_after_migration() {
        let conn = legacy_conn();
        // Populate a row in the legacy rules table before migrate.
        conn.execute(
            "INSERT INTO rules (label, name, instruction, signals, subfolder, \
             rename_pattern, confidence_threshold, encrypt, enabled, is_default) \
             VALUES ('legacy_cat', 'Legacy', 'instr', '[]', 'sub', '', 0.6, 0, 1, 0)",
            [],
        )
        .unwrap();

        migrate(&conn).expect("migrate");

        // Row must still be readable after migration — promise of self-describing vault.
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM rules WHERE label = 'legacy_cat'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "legacy rules row must survive migration");
    }
}
