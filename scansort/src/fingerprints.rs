//! Fingerprint deduplication: insert, check SHA-256, check SimHash.
//!
//! Ported from vault.py: insert_fingerprint, check_sha256, check_simhash.
//! All functions take a vault path as the first argument (stateless).

use crate::db;
use crate::types::*;
use rusqlite::params;

// ---------------------------------------------------------------------------
// insert_fingerprint
// ---------------------------------------------------------------------------

/// Insert or replace a fingerprint record for a document.
///
/// Used when ingesting documents or re-computing hashes.
// Used in T6 (document insertion path).
#[allow(dead_code)]
pub fn insert_fingerprint(
    path: &str,
    sha256: &str,
    simhash: &str,
    dhash: &str,
    doc_id: i64,
) -> VaultResult<()> {
    let conn = db::connect(path)?;
    conn.execute(
        "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) \
         VALUES (?1, ?2, ?3, ?4)",
        params![sha256, simhash, dhash, doc_id],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// check_sha256
// ---------------------------------------------------------------------------

/// Check if a SHA-256 hash exists in the fingerprints table.
///
/// Returns `Some(doc_id)` if found, `None` otherwise.
pub fn check_sha256(path: &str, sha256: &str) -> VaultResult<Option<i64>> {
    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT doc_id FROM fingerprints WHERE sha256 = ?",
    )?;

    let result = stmt.query_row(params![sha256], |row| row.get::<_, i64>(0));

    match result {
        Ok(doc_id) => Ok(Some(doc_id)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(VaultError::from(e)),
    }
}

// ---------------------------------------------------------------------------
// check_simhash
// ---------------------------------------------------------------------------

/// Check if a SimHash is within Hamming distance `threshold` of any
/// fingerprint in the vault.
///
/// Returns `Some((doc_id, distance))` for the closest match within threshold,
/// or `None` if no match is close enough.
///
/// A zero hash (`"0000000000000000"`) is treated as "no hash" and always
/// returns `None`.
// Used in T6 (document insertion path).
#[allow(dead_code)]
pub fn check_simhash(
    path: &str,
    simhash: &str,
    threshold: u32,
) -> VaultResult<Option<(i64, u32)>> {
    // Zero hash means "no meaningful content" — skip comparison
    if simhash == "0000000000000000" {
        return Ok(None);
    }

    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT simhash, doc_id FROM fingerprints",
    )?;

    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, i64>(1)?,
        ))
    })?;

    let mut best_distance: u32 = 65; // > 64 bits, impossible match
    let mut best_doc_id: Option<i64> = None;

    for row_result in rows {
        let (entry_hash_opt, doc_id) = row_result?;

        let entry_hash = match entry_hash_opt {
            Some(ref h) if !h.is_empty() && h != "0000000000000000" => h,
            _ => continue,
        };

        let dist = match hamming_distance_hex(simhash, entry_hash) {
            Ok(d) => d,
            Err(_) => continue, // skip malformed hashes
        };

        if dist < best_distance {
            best_distance = dist;
            best_doc_id = Some(doc_id);
        }
    }

    match best_doc_id {
        Some(doc_id) if best_distance <= threshold => Ok(Some((doc_id, best_distance))),
        _ => Ok(None),
    }
}
