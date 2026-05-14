//! W9: Append-only CSV audit log for Scansort filing operations.
//!
//! ## Purpose
//!
//! When the user enables the audit log in Settings, every placement and
//! reprocess-supersede event is written here as an append-only CSV row.
//! The file is intended for CPA/spreadsheet import — it is NEVER read back
//! by the plugin for any processing decision (dedup, processed-state, etc.).
//!
//! ## Toggle / split of responsibility
//!
//! The audit log is **opt-in** (disabled by default).  The Settings toggle
//! (`audit_log_enabled` / `audit_log_path`) lives entirely in GDScript
//! (`settings_dialog.gd` → `ScansortSettings`).  The MCP tool
//! `minerva_scansort_audit_append` simply writes the rows it receives —
//! it has no knowledge of whether the toggle is on or off.  The panel /
//! W10 Process All pipeline is responsible for reading the toggle from
//! Settings before deciding whether to call this tool.
//!
//! ## Robustness contract
//!
//! If the log path is unwritable (permissions, bad path, full disk), the
//! tool returns `{ok: false, error: "..."}` in the MCP envelope — it does
//! NOT panic and does NOT block placement.  W10 MUST treat audit failure
//! as non-fatal (log the error, continue placing documents).
//!
//! ## CSV format
//!
//! Header (written once, on file creation):
//!
//! ```text
//! timestamp,event,source_sha256,source_filename,rule_label,destination_id,destination_kind,resolved_path,disposition,detail
//! ```
//!
//! Columns:
//!
//! | Column            | Description |
//! |-------------------|-------------|
//! | `timestamp`       | ISO-8601 UTC (e.g. `2026-05-14T12:34:56Z`) |
//! | `event`           | `placement`, `skipped`, or `superseded` |
//! | `source_sha256`   | Hex SHA-256 of the source file content |
//! | `source_filename` | Original filename (basename only, CSV-escaped) |
//! | `rule_label`      | The classification rule label that fired |
//! | `destination_id`  | Destination registry id |
//! | `destination_kind`| `vault` or `directory` |
//! | `resolved_path`   | For directory dests: absolute target path; for vault: vault path |
//! | `disposition`     | `placed`, `skipped-already-present`, `kept-both`, `replaced`, `superseded`, or `error` |
//! | `detail`          | Human-readable detail (error message, doc_id, etc.) |
//!
//! All string fields are quoted and internal `"` characters are doubled
//! (standard RFC 4180 CSV escaping).  Newlines within field values are
//! replaced with a space to keep rows unambiguous.

use crate::types::VaultError;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::Path;

// ---------------------------------------------------------------------------
// CSV header
// ---------------------------------------------------------------------------

const CSV_HEADER: &str =
    "timestamp,event,source_sha256,source_filename,rule_label,destination_id,destination_kind,resolved_path,disposition,detail\n";

// ---------------------------------------------------------------------------
// Row type
// ---------------------------------------------------------------------------

/// A single audit log row.
///
/// Construct via [`AuditRow::placement`], [`AuditRow::skipped`], or
/// [`AuditRow::superseded`] rather than filling fields directly.
#[derive(Debug, Clone)]
pub struct AuditRow {
    /// ISO-8601 timestamp (caller provides; use [`crate::types::now_iso`]).
    pub timestamp: String,
    /// Event kind: `"placement"`, `"skipped"`, or `"superseded"`.
    pub event: String,
    /// Hex SHA-256 of the source file.
    pub source_sha256: String,
    /// Original source filename (basename).
    pub source_filename: String,
    /// Rule label that fired.
    pub rule_label: String,
    /// Destination registry id.
    pub destination_id: String,
    /// `"vault"` or `"directory"`.
    pub destination_kind: String,
    /// For directory: absolute target path; for vault: vault path.
    pub resolved_path: String,
    /// Disposition string.
    pub disposition: String,
    /// Human-readable detail (error msg, doc_id, etc.).
    pub detail: String,
}

impl AuditRow {
    /// Build a row for a successful `placed` event from a `PlacementResult`.
    ///
    /// - `source_sha256`   — content hash of the source file.
    /// - `source_filename` — basename of the source file.
    /// - `rule_label`      — rule that fired for this document.
    /// - `placement`       — per-destination `PlacementResult` from W6.
    /// - `vault_path`      — vault path (used as `resolved_path` for vault dests).
    /// - `timestamp`       — ISO-8601 string; call `types::now_iso()` at the call site.
    pub fn from_placement(
        source_sha256: &str,
        source_filename: &str,
        rule_label: &str,
        destination_id: &str,
        destination_kind: &str,
        target_path: &str,   // resolved path for dir; vault_path for vault
        status_str: &str,    // "placed", "skipped-already-present", "error"
        detail: &str,
        timestamp: &str,
    ) -> Self {
        let event = match status_str {
            "placed" => "placement",
            "skipped-already-present" => "skipped",
            _ => "placement", // error rows still logged as placement events
        };
        let disposition = status_str;
        AuditRow {
            timestamp: timestamp.to_string(),
            event: event.to_string(),
            source_sha256: source_sha256.to_string(),
            source_filename: source_filename.to_string(),
            rule_label: rule_label.to_string(),
            destination_id: destination_id.to_string(),
            destination_kind: destination_kind.to_string(),
            resolved_path: target_path.to_string(),
            disposition: disposition.to_string(),
            detail: detail.to_string(),
        }
    }

    /// Build `superseded` rows for a reprocess event.
    ///
    /// A reprocess clears a destination's prior placements; this function
    /// produces one `superseded` row documenting the clearing event.
    /// Individual prior-placement sha256 values are not available at clear
    /// time, so `source_sha256` is left as `"(cleared)"`.
    ///
    /// - `destination_id`   — destination that was reprocessed.
    /// - `destination_kind` — `"vault"` or `"directory"`.
    /// - `destination_path` — path of the destination.
    /// - `cleared_count`    — number of documents/files cleared.
    /// - `timestamp`        — ISO-8601 string.
    pub fn from_reprocess(
        destination_id: &str,
        destination_kind: &str,
        destination_path: &str,
        cleared_count: usize,
        timestamp: &str,
    ) -> Self {
        AuditRow {
            timestamp: timestamp.to_string(),
            event: "superseded".to_string(),
            source_sha256: "(cleared)".to_string(),
            source_filename: "(cleared)".to_string(),
            rule_label: String::new(),
            destination_id: destination_id.to_string(),
            destination_kind: destination_kind.to_string(),
            resolved_path: destination_path.to_string(),
            disposition: "superseded".to_string(),
            detail: format!("reprocess cleared {} item(s)", cleared_count),
        }
    }

    /// Serialise this row to a single CSV line (no trailing newline).
    ///
    /// All fields are quoted; internal `"` are doubled; newlines in values
    /// are replaced with a space to keep each row on one line.
    pub fn to_csv_line(&self) -> String {
        let fields = [
            self.timestamp.as_str(),
            self.event.as_str(),
            self.source_sha256.as_str(),
            self.source_filename.as_str(),
            self.rule_label.as_str(),
            self.destination_id.as_str(),
            self.destination_kind.as_str(),
            self.resolved_path.as_str(),
            self.disposition.as_str(),
            self.detail.as_str(),
        ];
        fields
            .iter()
            .map(|f| csv_quote(f))
            .collect::<Vec<_>>()
            .join(",")
    }
}

// ---------------------------------------------------------------------------
// CSV quoting (RFC 4180)
// ---------------------------------------------------------------------------

/// Quote a single CSV field value.
///
/// Always wraps in `"..."`.  Internal `"` are doubled.  Embedded newlines
/// (`\n`, `\r`) are replaced with a space so each logical row stays on
/// one physical line — this is important for CPA spreadsheet import.
fn csv_quote(value: &str) -> String {
    // Replace newlines with space, then double any embedded quotes.
    let cleaned = value.replace('\n', " ").replace('\r', " ");
    let escaped = cleaned.replace('"', "\"\"");
    format!("\"{}\"", escaped)
}

// ---------------------------------------------------------------------------
// Append to log file
// ---------------------------------------------------------------------------

/// Append one or more audit rows to the CSV log at `log_path`.
///
/// - If the file does not exist, it is created and the header row is written.
/// - If the file already exists, rows are appended (file is NEVER truncated).
/// - Returns `Err` (not a panic) if the file cannot be opened/written.
///   Callers MUST treat this as non-fatal.
pub fn append_rows(log_path: &Path, rows: &[AuditRow]) -> Result<(), VaultError> {
    if rows.is_empty() {
        return Ok(());
    }

    let needs_header = !log_path.exists();

    // Ensure parent directory exists.
    if let Some(parent) = log_path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            std::fs::create_dir_all(parent).map_err(|e| {
                VaultError::new(format!(
                    "audit log: cannot create parent directory '{}': {}",
                    parent.display(),
                    e
                ))
            })?;
        }
    }

    let file: File = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot open '{}' for append: {}",
                log_path.display(),
                e
            ))
        })?;

    let mut writer = BufWriter::new(file);

    if needs_header {
        writer.write_all(CSV_HEADER.as_bytes()).map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot write header to '{}': {}",
                log_path.display(),
                e
            ))
        })?;
    }

    for row in rows {
        let line = row.to_csv_line();
        writer.write_all(line.as_bytes()).map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot write row to '{}': {}",
                log_path.display(),
                e
            ))
        })?;
        writer.write_all(b"\n").map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot write newline to '{}': {}",
                log_path.display(),
                e
            ))
        })?;
    }

    writer.flush().map_err(|e| {
        VaultError::new(format!(
            "audit log: cannot flush '{}': {}",
            log_path.display(),
            e
        ))
    })?;

    Ok(())
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
            .join(format!("scansort-audit-{prefix}-{pid}-{ts}-{n}"))
    }

    fn read_file(p: &Path) -> String {
        std::fs::read_to_string(p).unwrap_or_default()
    }

    // -----------------------------------------------------------------------
    // 1. First append creates file with header row.
    // -----------------------------------------------------------------------
    #[test]
    fn first_append_writes_header() {
        let dir = unique_tmp("header");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "abc123", "invoice.pdf", "Invoice", "dest1", "vault",
            "/archive.ssort", "placed", "doc_id=42",
            "2026-05-14T12:00:00Z",
        );

        append_rows(&log, &[row]).expect("append should succeed");

        let contents = read_file(&log);
        assert!(
            contents.starts_with("timestamp,event,"),
            "first line must be the header: {:?}",
            contents.lines().next()
        );

        // Should have header + 1 data row.
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(lines.len(), 2, "expected header + 1 data row");
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 2. Subsequent appends do NOT add another header.
    // -----------------------------------------------------------------------
    #[test]
    fn subsequent_appends_do_not_truncate_or_add_header() {
        let dir = unique_tmp("no-trunc");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row1 = AuditRow::from_placement(
            "sha1", "a.pdf", "Invoice", "d1", "directory",
            "/dest/a.pdf", "placed", "",
            "2026-05-14T10:00:00Z",
        );
        let row2 = AuditRow::from_placement(
            "sha2", "b.pdf", "Contract", "d2", "vault",
            "/vault.ssort", "placed", "doc_id=7",
            "2026-05-14T10:01:00Z",
        );

        append_rows(&log, &[row1]).expect("first append");
        append_rows(&log, &[row2]).expect("second append");

        let contents = read_file(&log);
        let lines: Vec<&str> = contents.lines().collect();

        // header + row1 + row2 = 3 lines
        assert_eq!(lines.len(), 3, "expected header + 2 data rows, got:\n{}", contents);

        // Only one header.
        let header_count = lines.iter().filter(|l| l.starts_with("timestamp,event")).count();
        assert_eq!(header_count, 1, "header must appear exactly once");

        // Both rows present.
        assert!(contents.contains("sha1"), "row1 missing");
        assert!(contents.contains("sha2"), "row2 missing");

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 3. CSV escaping: commas in a filename don't corrupt the row.
    // -----------------------------------------------------------------------
    #[test]
    fn csv_escaping_comma_in_filename() {
        let dir = unique_tmp("csv-comma");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "deadbeef", "invoice, 2026.pdf", "Invoice", "d1", "directory",
            "/dest/invoice.pdf", "placed", "",
            "2026-05-14T10:00:00Z",
        );
        append_rows(&log, &[row]).expect("append");

        let contents = read_file(&log);
        // The filename field with a comma must be quoted.
        assert!(
            contents.contains("\"invoice, 2026.pdf\""),
            "comma-containing filename must be quoted in CSV: {}",
            contents
        );
        // The row must parse into exactly 10 fields (not more).
        let data_line = contents.lines().nth(1).expect("data line");
        let field_count = count_csv_fields(data_line);
        assert_eq!(field_count, 10, "CSV row must have exactly 10 fields: {}", data_line);

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 4. CSV escaping: double-quote in a filename.
    // -----------------------------------------------------------------------
    #[test]
    fn csv_escaping_quote_in_filename() {
        let dir = unique_tmp("csv-quote");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "deadbeef", "invoice \"final\".pdf", "Invoice", "d1", "vault",
            "/vault.ssort", "placed", "",
            "2026-05-14T10:00:00Z",
        );
        append_rows(&log, &[row]).expect("append");

        let contents = read_file(&log);
        // Internal quotes are doubled: " → ""
        assert!(
            contents.contains("\"invoice \"\"final\"\".pdf\""),
            "double-quote must be escaped as \"\" in CSV: {}",
            contents
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 5. CSV escaping: newline in a filename does not produce extra rows.
    // -----------------------------------------------------------------------
    #[test]
    fn csv_escaping_newline_in_filename() {
        let dir = unique_tmp("csv-newline");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "deadbeef", "invoice\npart2.pdf", "Invoice", "d1", "vault",
            "/vault.ssort", "placed", "",
            "2026-05-14T10:00:00Z",
        );
        append_rows(&log, &[row]).expect("append");

        let contents = read_file(&log);
        // Must still be exactly 2 lines (header + 1 data row).
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(
            lines.len(), 2,
            "newline in filename must not produce extra rows: {:?}",
            lines
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 6. from_placement → row construction: event and disposition fields.
    // -----------------------------------------------------------------------
    #[test]
    fn placement_row_event_and_disposition() {
        let placed = AuditRow::from_placement(
            "sha", "doc.pdf", "Contract", "d1", "vault",
            "/v.ssort", "placed", "doc_id=3",
            "2026-05-14T00:00:00Z",
        );
        assert_eq!(placed.event, "placement");
        assert_eq!(placed.disposition, "placed");

        let skipped = AuditRow::from_placement(
            "sha", "doc.pdf", "Contract", "d1", "vault",
            "/v.ssort", "skipped-already-present", "",
            "2026-05-14T00:00:00Z",
        );
        assert_eq!(skipped.event, "skipped");
        assert_eq!(skipped.disposition, "skipped-already-present");
    }

    // -----------------------------------------------------------------------
    // 7. from_reprocess → superseded row construction.
    // -----------------------------------------------------------------------
    #[test]
    fn reprocess_row_superseded() {
        let row = AuditRow::from_reprocess(
            "dest_99", "directory", "/docs/output", 5,
            "2026-05-14T09:00:00Z",
        );
        assert_eq!(row.event, "superseded");
        assert_eq!(row.disposition, "superseded");
        assert!(row.detail.contains("5"), "detail should mention cleared count");
    }

    // -----------------------------------------------------------------------
    // 8. Unwritable path returns an error (not a panic).
    // -----------------------------------------------------------------------
    #[test]
    fn unwritable_path_returns_error_not_panic() {
        // Use a path under a non-existent parent with no write permission.
        // We simulate this by pointing at /proc/scansort-audit-test (never
        // writable from user space on Linux).
        let log = std::path::Path::new("/proc/scansort-audit-test-w9/audit.csv");
        let row = AuditRow::from_placement(
            "sha", "doc.pdf", "Invoice", "d1", "vault",
            "/v.ssort", "placed", "",
            "2026-05-14T00:00:00Z",
        );
        let result = append_rows(log, &[row]);
        assert!(
            result.is_err(),
            "append to unwritable path must return Err, not panic"
        );
        // Error message must be informative (not empty).
        let msg = result.unwrap_err().message;
        assert!(!msg.is_empty(), "error message must not be empty");
    }

    // -----------------------------------------------------------------------
    // 9. Batch append: multiple rows in one call.
    // -----------------------------------------------------------------------
    #[test]
    fn batch_append_writes_all_rows() {
        let dir = unique_tmp("batch");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let rows: Vec<AuditRow> = (0..5u64).map(|i| {
            AuditRow::from_placement(
                &format!("sha{i}"),
                &format!("doc{i}.pdf"),
                "Invoice",
                &format!("dest{i}"),
                "directory",
                &format!("/dest{i}/doc{i}.pdf"),
                "placed",
                "",
                "2026-05-14T00:00:00Z",
            )
        }).collect();

        append_rows(&log, &rows).expect("batch append");

        let contents = read_file(&log);
        let lines: Vec<&str> = contents.lines().collect();
        // header + 5 rows
        assert_eq!(lines.len(), 6, "expected 6 lines (header + 5 rows): {}", contents);

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 10. Empty batch is a no-op (file not created).
    // -----------------------------------------------------------------------
    #[test]
    fn empty_batch_is_noop() {
        let dir = unique_tmp("empty-batch");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        append_rows(&log, &[]).expect("empty batch should not error");
        assert!(!log.exists(), "empty batch must not create the log file");

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Helper: naively count CSV fields in a line by counting commas outside
    // of quoted strings. Handles the RFC 4180 subset we produce.
    // -----------------------------------------------------------------------
    fn count_csv_fields(line: &str) -> usize {
        let mut count = 1;
        let mut in_quotes = false;
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '"' => {
                    if in_quotes {
                        // Check for doubled quote (escaped).
                        if chars.peek() == Some(&'"') {
                            chars.next(); // consume second "
                        } else {
                            in_quotes = false;
                        }
                    } else {
                        in_quotes = true;
                    }
                }
                ',' if !in_quotes => {
                    count += 1;
                }
                _ => {}
            }
        }
        count
    }
}
