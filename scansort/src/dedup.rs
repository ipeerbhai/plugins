//! W7: Three-layer deduplication query layer.
//!
//! Layer 1 (exact SHA-256) is already handled in `placement::fan_out` via
//! `fingerprints::check_sha256`.  This module provides the two remaining layers:
//!
//! ## Layer 2 — Near-duplicate detection
//!
//! `check_simhash` and `check_dhash` compare a candidate hash against every
//! hash stored in a vault's `fingerprints` table using Hamming distance.
//!
//! Default thresholds (from the experiment's config_defaults.json):
//!   - simhash: 3 bits
//!   - dhash:   0 bits  (disabled by default; set > 0 to enable image near-dup)
//!
//! A zero hash (`"0000000000000000"`) is treated as "no meaningful content"
//! and always returns `None` — callers that produce zero hashes for
//! unprocessable content must not flag those as duplicates.
//!
//! Returns ALL matches within the threshold (not just the closest), so the
//! caller can surface the full candidate set in the disposition UI.
//!
//! ## Layer 3 — Logical identity
//!
//! `check_logical_identity` answers: "has a document with the same
//! (rule_label, resolved_target_path) already been placed at this destination?"
//!
//! It is a pure in-memory function — it takes the history as a slice of
//! `(rule_label, target_path)` pairs and returns whether the candidate pair
//! already appears.  W10 (Process All) feeds the accumulated placement history;
//! W7 only provides the detection function.
//!
//! ## Disposition representation
//!
//! When either Layer 2 or Layer 3 flags a match the caller should present the
//! user with a `DedupDisposition` choice.  The chosen disposition is recorded
//! in the pipeline result so that W9 (audit log) and W10 (Process All) can
//! act on it:
//!
//! ```
//! DedupDisposition::KeepBoth   — place the incoming document alongside the existing one
//! DedupDisposition::Replace    — replace the existing document (W10 removes it first)
//! DedupDisposition::Skip       — skip this document (do not place)
//! DedupDisposition::Pending    — disposition not yet chosen (UI is still open)
//! ```
//!
//! HARD CONSTRAINT: **only the exact SHA-256 layer may auto-skip.**
//! Near-duplicate and logical-identity matches MUST NOT be auto-discarded or
//! silently renamed.  They must surface as an explicit user disposition prompt.

use crate::db;
use crate::types::*;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Default thresholds (from experiment config_defaults.json)
// ---------------------------------------------------------------------------

/// Default Hamming-distance threshold for text SimHash near-dup detection.
/// 3 bits → documents sharing ≥ 61/64 bits of their simhash are flagged.
pub const DEFAULT_SIMHASH_THRESHOLD: u32 = 3;

/// Default Hamming-distance threshold for perceptual dHash image near-dup.
/// 0 → disabled by default (set > 0 to enable image near-dup detection).
pub const DEFAULT_DHASH_THRESHOLD: u32 = 0;

// ---------------------------------------------------------------------------
// Disposition enum
// ---------------------------------------------------------------------------

/// User-chosen disposition for a near-duplicate or logical-identity match.
///
/// W9 (audit log) and W10 (Process All) consume this value.
/// `Pending` means the UI is still open — no action should be taken yet.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DedupDisposition {
    /// Place the incoming document alongside the existing one (keep both).
    KeepBoth,
    /// Replace the existing document at the destination with the incoming one.
    Replace,
    /// Skip the incoming document — do not place it anywhere.
    Skip,
    /// Disposition not yet chosen — UI is still open.
    Pending,
}

// ---------------------------------------------------------------------------
// Near-dup match record
// ---------------------------------------------------------------------------

/// One near-duplicate match returned by `check_simhash` or `check_dhash`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NearDupMatch {
    /// The existing document id that matched.
    pub doc_id: i64,
    /// The Hamming distance between the candidate and existing hashes.
    pub distance: u32,
    /// The existing hash value (for display in the disposition UI).
    pub existing_hash: String,
    /// Whether this match came from simhash or dhash.
    pub hash_kind: String,
}

// ---------------------------------------------------------------------------
// Layer 2: check_simhash
// ---------------------------------------------------------------------------

/// Check a candidate SimHash against every stored SimHash in a vault.
///
/// Returns all `NearDupMatch` entries whose Hamming distance ≤ `threshold`.
/// A zero hash (`"0000000000000000"`) always returns an empty Vec.
///
/// The panel calls this with the threshold from Settings; if the result is
/// non-empty the user MUST be shown a disposition prompt (keep-both / replace /
/// skip) — the caller MUST NOT auto-skip.
pub fn check_simhash(
    path: &str,
    simhash: &str,
    threshold: u32,
) -> VaultResult<Vec<NearDupMatch>> {
    // Zero hash means "no meaningful content" — skip comparison
    if simhash == "0000000000000000" {
        return Ok(vec![]);
    }

    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT simhash, doc_id FROM fingerprints",
    )?;

    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<i64>>(1)?,
        ))
    })?;

    let mut matches = Vec::new();

    for row_result in rows {
        let (entry_hash_opt, doc_id_opt) = row_result?;

        let entry_hash = match entry_hash_opt {
            Some(ref h) if !h.is_empty() && h != "0000000000000000" => h.clone(),
            _ => continue,
        };

        let dist = match hamming_distance_hex(simhash, &entry_hash) {
            Ok(d) => d,
            Err(_) => continue, // skip malformed hashes
        };

        if dist <= threshold {
            matches.push(NearDupMatch {
                doc_id: doc_id_opt.unwrap_or(0),
                distance: dist,
                existing_hash: entry_hash,
                hash_kind: "simhash".to_string(),
            });
        }
    }

    Ok(matches)
}

// ---------------------------------------------------------------------------
// Layer 2: check_dhash
// ---------------------------------------------------------------------------

/// Check a candidate perceptual image hash (dHash) against every stored dHash.
///
/// Same semantics as `check_simhash` but for the `dhash` column.
/// A zero hash always returns an empty Vec.
///
/// The panel calls this with the dhash threshold from Settings; non-empty
/// results MUST surface a disposition prompt — never auto-skipped.
pub fn check_dhash(
    path: &str,
    dhash: &str,
    threshold: u32,
) -> VaultResult<Vec<NearDupMatch>> {
    // Zero hash means "no meaningful content" — skip comparison
    if dhash == "0000000000000000" {
        return Ok(vec![]);
    }

    let conn = db::connect(path)?;
    let mut stmt = conn.prepare(
        "SELECT dhash, doc_id FROM fingerprints",
    )?;

    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<i64>>(1)?,
        ))
    })?;

    let mut matches = Vec::new();

    for row_result in rows {
        let (entry_hash_opt, doc_id_opt) = row_result?;

        let entry_hash = match entry_hash_opt {
            Some(ref h) if !h.is_empty() && h != "0000000000000000" => h.clone(),
            _ => continue,
        };

        let dist = match hamming_distance_hex(dhash, &entry_hash) {
            Ok(d) => d,
            Err(_) => continue, // skip malformed hashes
        };

        if dist <= threshold {
            matches.push(NearDupMatch {
                doc_id: doc_id_opt.unwrap_or(0),
                distance: dist,
                existing_hash: entry_hash,
                hash_kind: "dhash".to_string(),
            });
        }
    }

    Ok(matches)
}

// ---------------------------------------------------------------------------
// Layer 3: logical identity check
// ---------------------------------------------------------------------------

/// Check whether the candidate `(rule_label, resolved_target_path)` pair
/// already exists in the provided placement history.
///
/// This is a pure in-memory function — it takes the accumulated history as a
/// slice of `(rule_label, target_path)` tuples and returns `true` if the
/// candidate pair is already present.
///
/// W10 (Process All) accumulates the history across documents in a run and
/// passes it here for each new candidate.  W7 only provides the detection
/// function; it does not manage the history itself.
///
/// A match means: a document filed under the SAME rule AND with the SAME
/// resolved output path is already known to this run.  This catches the case
/// where two source documents with different content would both resolve to
/// the same target path under the same rule — the second one MUST be surfaced
/// for user review, not silently overwritten or (1)-renamed.
pub fn check_logical_identity(
    rule_label: &str,
    resolved_target_path: &str,
    history: &[(String, String)],
) -> bool {
    history.iter().any(|(hist_label, hist_path)| {
        hist_label == rule_label && hist_path == resolved_target_path
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault_lifecycle;
    use crate::db;
    use rusqlite::params;
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
        std::env::temp_dir().join(format!("scansort-dedup-{prefix}-{pid}-{ts}-{n}"))
    }

    fn make_vault(path: &std::path::Path) {
        vault_lifecycle::create_vault(path.to_str().unwrap(), "test-dedup").unwrap();
    }

    /// Insert directly into fingerprints with NULL doc_id (FK constraints are ON
    /// so we cannot use arbitrary integer doc_ids without a matching documents row;
    /// NULL is valid and appropriate for test fixtures that just need a hash stored).
    fn insert_fp(vault_path: &str, sha256: &str, simhash: &str, dhash: &str) {
        let conn = db::connect(vault_path).unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) \
             VALUES (?1, ?2, ?3, NULL)",
            params![sha256, simhash, dhash],
        ).unwrap();
    }

    // -----------------------------------------------------------------------
    // 1. check_simhash: zero hash always returns empty.
    // -----------------------------------------------------------------------
    #[test]
    fn check_simhash_zero_hash_returns_empty() {
        let vault = unique_tmp("simhash-zero");
        make_vault(&vault);

        // Even if there are stored hashes, zero-query → empty.
        insert_fp(vault.to_str().unwrap(), "aabbccdd00000001", "1111111111111111", "0000000000000000");

        let result = check_simhash(vault.to_str().unwrap(), "0000000000000000", 10).unwrap();
        assert!(result.is_empty(), "zero hash must return empty Vec");

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 2. check_simhash: finds exact match (distance = 0) within threshold.
    //    doc_id is NULL when inserted directly; we assert None (0) in NearDupMatch.
    // -----------------------------------------------------------------------
    #[test]
    fn check_simhash_finds_exact_match() {
        let vault = unique_tmp("simhash-exact");
        make_vault(&vault);

        let hash = "abcdef1234567890";
        insert_fp(vault.to_str().unwrap(), "sha256a", hash, "0000000000000000");

        let result = check_simhash(vault.to_str().unwrap(), hash, DEFAULT_SIMHASH_THRESHOLD).unwrap();
        assert_eq!(result.len(), 1, "exact match must be found");
        assert_eq!(result[0].distance, 0);
        assert_eq!(result[0].hash_kind, "simhash");

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 3. check_simhash: no match when distance > threshold.
    // -----------------------------------------------------------------------
    #[test]
    fn check_simhash_no_match_above_threshold() {
        let vault = unique_tmp("simhash-miss");
        make_vault(&vault);

        // Two hashes that differ by many bits.
        insert_fp(vault.to_str().unwrap(), "sha256b", "ffffffffffffffff", "0000000000000000");

        // Query with a very different hash and a small threshold.
        let result = check_simhash(vault.to_str().unwrap(), "0000000000000001", 2).unwrap();
        assert!(result.is_empty(), "no match expected above threshold");

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 4. check_simhash: returns multiple matches when multiple are within threshold.
    // -----------------------------------------------------------------------
    #[test]
    fn check_simhash_returns_all_matches_within_threshold() {
        let vault = unique_tmp("simhash-multi");
        make_vault(&vault);

        let base = "abcdef1234567890";
        // Insert two rows with the same simhash but different sha256 keys.
        insert_fp(vault.to_str().unwrap(), "sha256c1", base, "0000000000000000");
        insert_fp(vault.to_str().unwrap(), "sha256c2", base, "0000000000000000");

        let result = check_simhash(vault.to_str().unwrap(), base, DEFAULT_SIMHASH_THRESHOLD).unwrap();
        assert_eq!(result.len(), 2, "both rows must be returned");

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 5. check_dhash: zero hash always returns empty.
    // -----------------------------------------------------------------------
    #[test]
    fn check_dhash_zero_hash_returns_empty() {
        let vault = unique_tmp("dhash-zero");
        make_vault(&vault);
        insert_fp(vault.to_str().unwrap(), "sha256d0", "0000000000000000", "1111111111111111");

        let result = check_dhash(vault.to_str().unwrap(), "0000000000000000", 10).unwrap();
        assert!(result.is_empty(), "zero dhash must return empty Vec");

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 6. check_dhash: finds exact match.
    // -----------------------------------------------------------------------
    #[test]
    fn check_dhash_finds_exact_match() {
        let vault = unique_tmp("dhash-exact");
        make_vault(&vault);

        let dhash = "fedcba9876543210";
        insert_fp(vault.to_str().unwrap(), "sha256e", "0000000000000000", dhash);

        let result = check_dhash(vault.to_str().unwrap(), dhash, 1).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].distance, 0);
        assert_eq!(result[0].hash_kind, "dhash");

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 7. check_dhash: default threshold 0 — only exact (distance-0) matches.
    //    Vault contains dhash_a. Query for dhash_b (1 bit away from dhash_a).
    //    threshold=0: must not match (distance 1 > 0).
    //    threshold=1: must match.
    // -----------------------------------------------------------------------
    #[test]
    fn check_dhash_default_threshold_zero_only_exact() {
        let vault = unique_tmp("dhash-threshold0");
        make_vault(&vault);

        let dhash_a = "1111111111111111"; // stored in vault
        let dhash_b = "1111111111111110"; // 1 bit away from dhash_a — NOT stored
        insert_fp(vault.to_str().unwrap(), "sha256f1", "0000000000000000", dhash_a);

        // Query for dhash_b at threshold=0 → must NOT find dhash_a (distance is 1, not 0).
        let result = check_dhash(vault.to_str().unwrap(), dhash_b, DEFAULT_DHASH_THRESHOLD).unwrap();
        assert!(result.is_empty(), "threshold 0 must not match dhash 1 bit away");

        // Query for dhash_b at threshold=1 → must find dhash_a (distance 1 ≤ 1).
        let result2 = check_dhash(vault.to_str().unwrap(), dhash_b, 1).unwrap();
        assert!(!result2.is_empty(), "threshold 1 must find dhash 1 bit away");
        assert_eq!(result2[0].distance, 1);

        std::fs::remove_file(&vault).ok();
    }

    // -----------------------------------------------------------------------
    // 8. check_logical_identity: detects existing (rule, path) pair.
    // -----------------------------------------------------------------------
    #[test]
    fn check_logical_identity_detects_existing_pair() {
        let history: Vec<(String, String)> = vec![
            ("invoices".to_string(), "/archive/2024/acme/invoice.pdf".to_string()),
            ("contracts".to_string(), "/archive/legal/contract.pdf".to_string()),
        ];

        assert!(
            check_logical_identity("invoices", "/archive/2024/acme/invoice.pdf", &history),
            "exact match must be found"
        );
    }

    // -----------------------------------------------------------------------
    // 9. check_logical_identity: same path, different rule → no match.
    // -----------------------------------------------------------------------
    #[test]
    fn check_logical_identity_different_rule_no_match() {
        let history: Vec<(String, String)> = vec![
            ("invoices".to_string(), "/archive/2024/acme/invoice.pdf".to_string()),
        ];

        assert!(
            !check_logical_identity("receipts", "/archive/2024/acme/invoice.pdf", &history),
            "different rule_label must not match"
        );
    }

    // -----------------------------------------------------------------------
    // 10. check_logical_identity: same rule, different path → no match.
    // -----------------------------------------------------------------------
    #[test]
    fn check_logical_identity_different_path_no_match() {
        let history: Vec<(String, String)> = vec![
            ("invoices".to_string(), "/archive/2024/acme/invoice.pdf".to_string()),
        ];

        assert!(
            !check_logical_identity("invoices", "/archive/2024/acme/invoice_v2.pdf", &history),
            "different path must not match"
        );
    }

    // -----------------------------------------------------------------------
    // 11. check_logical_identity: empty history → never matches.
    // -----------------------------------------------------------------------
    #[test]
    fn check_logical_identity_empty_history_no_match() {
        let history: Vec<(String, String)> = vec![];
        assert!(
            !check_logical_identity("invoices", "/archive/invoice.pdf", &history),
            "empty history must not match"
        );
    }

    // -----------------------------------------------------------------------
    // 12. DedupDisposition serialises to snake_case strings.
    // -----------------------------------------------------------------------
    #[test]
    fn dedup_disposition_serialises_correctly() {
        let s = serde_json::to_string(&DedupDisposition::KeepBoth).unwrap();
        assert_eq!(s, "\"keep_both\"");

        let s = serde_json::to_string(&DedupDisposition::Replace).unwrap();
        assert_eq!(s, "\"replace\"");

        let s = serde_json::to_string(&DedupDisposition::Skip).unwrap();
        assert_eq!(s, "\"skip\"");

        let s = serde_json::to_string(&DedupDisposition::Pending).unwrap();
        assert_eq!(s, "\"pending\"");
    }

    // -----------------------------------------------------------------------
    // 13. DedupDisposition round-trips through JSON.
    // -----------------------------------------------------------------------
    #[test]
    fn dedup_disposition_round_trips() {
        for d in [DedupDisposition::KeepBoth, DedupDisposition::Replace, DedupDisposition::Skip, DedupDisposition::Pending] {
            let json = serde_json::to_string(&d).unwrap();
            let back: DedupDisposition = serde_json::from_str(&json).unwrap();
            assert_eq!(d, back);
        }
    }
}
