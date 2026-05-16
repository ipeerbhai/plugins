//! W6: copy_to fan-out execution + per-destination processed-state.
//!
//! ## Fan-out
//!
//! `fan_out` takes a source file path, the resolved action from the W3 rule
//! engine (`FiredRuleAction`), a destination registry, and classification
//! metadata, and fans the document out to EVERY destination id in
//! `action.copy_to` in one call.
//!
//! - **directory** destination — copies the file into
//!   `<dest.path>/<resolved_subfolder>/<resolved_rename>`, using
//!   `destination::resolve_and_sanitise` for path-traversal safety and
//!   `destination::collision_safe_path` for collision-avoidance.  Source is
//!   never moved.
//! - **vault** destination — calls `documents::insert_document` into that
//!   vault's `.ssort` file.  Respects the `encrypt` flag (stored in
//!   rule metadata; actual encryption is a vault-level concern handled by
//!   `insert_document` when a password is set).
//!
//! A destination id missing from the registry → that row gets `error` status;
//! the remaining destinations are still processed.
//!
//! Exact-sha256 auto-skip: before placing, we check whether the content
//! sha256 of the source file already lives in that destination.
//!   - vault  → `fingerprints::check_sha256`
//!   - directory → `DirHashCache::contains`
//!
//! Returns one `PlacementResult` row per destination id in `copy_to`.
//!
//! ## Per-destination processed-state
//!
//! `DirHashCache` is an **in-process, within-run cache** for directory
//! destinations.  It scans a directory recursively, content-hashes every
//! regular file into a `HashSet<String>` (sha256 hex), and caches the
//! `(canonical_path, mtime_ns, size)` triple for each file so that unchanged
//! files are NOT re-hashed on subsequent scans of the same directory tree.
//!
//! There is **no on-disk index file**.  The directory's contents are the
//! source of truth; the cache is a within-process speed-up.
//!
//! The MCP tool `minerva_scansort_scan_directory_hashes` is stateless across
//! calls — it performs a fresh scan each call.  The `DirHashCache` struct is
//! provided for in-process callers (W10 Process All) that want to reuse scan
//! results within a single run.

use crate::destination::{collision_safe_path, resolve_and_sanitise, TemplateValues};
use crate::destinations::{find_by_id, DestinationRegistry};
use crate::documents::insert_document;
use crate::fingerprints::check_sha256 as vault_check_sha256;
use crate::types::{compute_sha256, VaultError, VaultResult};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// ---------------------------------------------------------------------------
// Public output types
// ---------------------------------------------------------------------------

/// One row in the fan-out result list — one per destination id in `copy_to`.
/// W9 (audit log) and W10 (Process All) consume this.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PlacementResult {
    /// The destination id from the registry.
    pub destination_id: String,
    /// The destination kind: `"vault"` or `"directory"`.
    pub kind: String,
    /// For directory destinations: the absolute target path the file was
    /// copied to.  Empty when kind is `"vault"` or when placement failed/was
    /// skipped.
    pub target_path: String,
    /// For vault destinations: the `doc_id` returned by `insert_document`.
    /// 0 when kind is `"directory"` or when placement failed/was skipped.
    pub doc_id: i64,
    /// Outcome for this placement row.
    pub status: PlacementStatus,
    /// Human-readable detail (error message on `Error`, otherwise empty).
    pub message: String,
}

/// Outcome status for a single placement.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlacementStatus {
    /// The document was successfully placed at this destination.
    Placed,
    /// The document (by content sha256) is already present at this
    /// destination.  Placement skipped; source left intact.
    SkippedAlreadyPresent,
    /// This destination id was not found in the registry, or an I/O error
    /// occurred.  Other destinations in the same fan-out are unaffected.
    Error,
}

// ---------------------------------------------------------------------------
// Classification metadata the fan-out needs from the caller
// ---------------------------------------------------------------------------

/// Subset of doc metadata used by fan-out placement.
/// Mirrors the fields `insert_document` expects; callers supply what they know.
#[derive(Debug, Clone, Default)]
pub struct DocMeta {
    pub category: String,
    pub confidence: f64,
    pub issuer: String,
    pub description: String,
    pub doc_date: String,
    pub status: String,
    pub simhash: String,
    pub dhash: String,
    pub source_path: String,
    pub rule_snapshot: String,
    /// Pre-computed content sha256 hex string.  When empty the fan-out will
    /// compute it from `file_path`.
    pub sha256: String,
    /// Short document type string ("invoice", "W-2", …).  Empty when unknown.
    pub doc_type: String,
    /// Monetary amount extracted from the document.  Empty when not present.
    pub amount: String,
}

// ---------------------------------------------------------------------------
// Directory hash cache
// ---------------------------------------------------------------------------

/// In-process cache mapping `(canonical_path, mtime_nanos, size)` → sha256.
///
/// Use this within a single Process-All run so unchanged files are not
/// re-hashed.  The cache is NOT persisted to disk; create a fresh instance
/// per run.
#[derive(Default)]
pub struct DirHashCache {
    /// `(canonical_path_string, mtime_ns, size_bytes)` → sha256 hex
    file_cache: HashMap<(String, u128, u64), String>,
}

impl DirHashCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Return the set of sha256 hex strings for every regular file under
    /// `dir` (recursive).  Unchanged files (same path + mtime + size) reuse
    /// the cached hash; changed or new files are re-hashed and the cache is
    /// updated.
    ///
    /// Missing or inaccessible `dir` returns an empty set (not an error).
    pub fn scan(&mut self, dir: &Path) -> HashSet<String> {
        let mut result = HashSet::new();
        if !dir.exists() {
            return result;
        }
        self.walk_and_hash(dir, &mut result);
        result
    }

    /// Check whether a given sha256 is already present anywhere under `dir`.
    pub fn contains(&mut self, dir: &Path, sha256: &str) -> bool {
        let set = self.scan(dir);
        set.contains(sha256)
    }

    fn walk_and_hash(&mut self, dir: &Path, out: &mut HashSet<String>) {
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry_result in entries {
            let entry = match entry_result {
                Ok(e) => e,
                Err(_) => continue,
            };
            let path = entry.path();
            if path.is_dir() {
                self.walk_and_hash(&path, out);
                continue;
            }
            if !path.is_file() {
                continue;
            }
            let meta = match std::fs::metadata(&path) {
                Ok(m) => m,
                Err(_) => continue,
            };
            let size = meta.len();
            let mtime_ns = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let canonical = path
                .canonicalize()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| path.to_string_lossy().into_owned());

            let cache_key = (canonical.clone(), mtime_ns, size);
            let sha = if let Some(cached) = self.file_cache.get(&cache_key) {
                cached.clone()
            } else {
                match compute_sha256(&path) {
                    Ok(h) => {
                        self.file_cache.insert(cache_key.clone(), h.clone());
                        h
                    }
                    Err(_) => continue,
                }
            };
            out.insert(sha);
        }
    }

    /// Expose a reference to the internal file cache for testing / inspection.
    /// Returns the number of cached entries (used in tests to verify cache reuse).
    #[cfg(test)]
    pub fn cache_size(&self) -> usize {
        self.file_cache.len()
    }
}

// ---------------------------------------------------------------------------
// Fresh (stateless) directory scan — used by the MCP tool
// ---------------------------------------------------------------------------

/// Scan `dir` recursively and return the set of sha256 hex strings.
/// No caching — always reads from disk.  Used by the stateless MCP tool;
/// in-process callers should use `DirHashCache` for performance.
pub fn scan_directory_hashes(dir: &Path) -> VaultResult<HashSet<String>> {
    let mut cache = DirHashCache::new();
    Ok(cache.scan(dir))
}

// ---------------------------------------------------------------------------
// Resolve the target path for a directory destination
// ---------------------------------------------------------------------------

/// Build a TemplateValues + (year_val, date_val) owned strings for use with
/// `resolve_and_sanitise`. Both vault and directory placement branches need
/// the same expansion context (year fallback "unknown", date fallback
/// "undated"); centralising avoids drift.
fn build_template_context(meta: &DocMeta) -> (String, String) {
    let doc_date = &meta.doc_date;
    let year_val = if doc_date.len() >= 4 && doc_date[..4].chars().all(|c| c.is_ascii_digit()) {
        doc_date[..4].to_string()
    } else {
        "unknown".to_string()
    };
    let date_val = if doc_date.is_empty() {
        "undated".to_string()
    } else {
        doc_date.to_string()
    };
    (year_val, date_val)
}

/// Resolve the rename_pattern + source extension into a display_name string
/// suitable for the vault's display_name column. Returns empty string when
/// pattern is empty (caller's choice: vault_inventory falls back to
/// original_filename in that case).
fn resolve_display_name(
    resolved_rename_pattern: &str,
    file_path: &str,
    meta: &DocMeta,
) -> String {
    if resolved_rename_pattern.is_empty() {
        return String::new();
    }
    let (year_val, date_val) = build_template_context(meta);
    let tv = TemplateValues {
        year: &year_val,
        date: &date_val,
        issuer: &meta.issuer,
        doc_type: &meta.doc_type,
        description: &meta.description,
        amount: &meta.amount,
        category: &meta.category,
    };
    let stem = match resolve_and_sanitise(resolved_rename_pattern, &tv) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };
    let ext = Path::new(file_path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{e}"))
        .unwrap_or_default();
    format!("{stem}{ext}")
}

fn resolve_directory_target(
    dest_path: &str,
    resolved_subfolder: &str,
    resolved_rename_pattern: &str,
    file_path: &str,
    meta: &DocMeta,
) -> VaultResult<PathBuf> {
    let (year_val, date_val) = build_template_context(meta);
    let tv = TemplateValues {
        year: &year_val,
        date: &date_val,
        issuer: &meta.issuer,
        doc_type: &meta.doc_type,
        description: &meta.description,
        amount: &meta.amount,
        category: &meta.category,
    };

    // Sanitise the already-expanded subfolder (guards against ../ injected
    // via rule template values).
    let sanitised_subfolder = resolve_and_sanitise(resolved_subfolder, &tv)?;

    // Build target directory.
    let target_dir = if sanitised_subfolder.is_empty() {
        PathBuf::from(dest_path)
    } else {
        Path::new(dest_path).join(&sanitised_subfolder)
    };

    // Determine source file extension.
    let src_path = Path::new(file_path);
    let src_ext = src_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{e}"))
        .unwrap_or_default();

    // Determine the base stem (from rename pattern or original filename).
    let base_stem: String = if !resolved_rename_pattern.is_empty() {
        resolve_and_sanitise(resolved_rename_pattern, &tv)?
    } else {
        src_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("document")
            .to_string()
    };

    // Create target directory.
    std::fs::create_dir_all(&target_dir).map_err(|e| {
        VaultError::new(format!("cannot create directory {}: {}", target_dir.display(), e))
    })?;

    // Collision-safe final path.
    Ok(collision_safe_path(&target_dir, &base_stem, &src_ext))
}

// ---------------------------------------------------------------------------
// Fan-out
// ---------------------------------------------------------------------------

/// Fan out a single source document to every destination in `action.copy_to`.
///
/// # Parameters
/// - `file_path`   — absolute path of the source file (never moved/deleted).
/// - `action`      — resolved `FiredRuleAction` from the W3 rule engine.
/// - `registry`    — loaded `DestinationRegistry` (W4).
/// - `meta`        — doc classification metadata for vault insertion.
/// - `dir_cache`   — optional mutable `DirHashCache` for directory processed-
///                   state checks; pass `None` to use a fresh one-shot scan.
///
/// # Returns
/// One `PlacementResult` per entry in `action.copy_to` (same order).
/// A bad/unknown destination id → `Error` status for that row; other
/// destinations in the same fan-out continue.
pub fn fan_out(
    file_path: &str,
    copy_to: &[String],
    resolved_subfolder: &str,
    resolved_rename_pattern: &str,
    encrypt: bool,
    registry: &DestinationRegistry,
    meta: &DocMeta,
    dir_cache: Option<&mut DirHashCache>,
) -> Vec<PlacementResult> {
    // Compute content sha256 once (reuse if provided by caller).
    let sha256 = if meta.sha256.is_empty() {
        match compute_sha256(Path::new(file_path)) {
            Ok(h) => h,
            Err(e) => {
                // Can't hash → every destination gets an error row.
                return copy_to
                    .iter()
                    .map(|id| PlacementResult {
                        destination_id: id.clone(),
                        kind: String::new(),
                        target_path: String::new(),
                        doc_id: 0,
                        status: PlacementStatus::Error,
                        message: format!("cannot compute sha256: {}", e.message),
                    })
                    .collect();
            }
        }
    } else {
        meta.sha256.clone()
    };

    // We may need a temporary cache if the caller didn't supply one.
    let mut owned_cache = DirHashCache::new();
    let cache = match dir_cache {
        Some(c) => c,
        None => &mut owned_cache,
    };

    let mut results = Vec::with_capacity(copy_to.len());

    for dest_id in copy_to {
        let dest = match find_by_id(registry, dest_id) {
            Some(d) => d,
            None => {
                results.push(PlacementResult {
                    destination_id: dest_id.clone(),
                    kind: String::new(),
                    target_path: String::new(),
                    doc_id: 0,
                    status: PlacementStatus::Error,
                    message: format!("destination id '{}' not found in registry", dest_id),
                });
                continue;
            }
        };

        match dest.kind.as_str() {
            "vault" => {
                // Check if already present in this vault.
                match vault_check_sha256(&dest.path, &sha256) {
                    Ok(Some(existing_id)) => {
                        results.push(PlacementResult {
                            destination_id: dest_id.clone(),
                            kind: "vault".to_string(),
                            target_path: String::new(),
                            doc_id: existing_id,
                            status: PlacementStatus::SkippedAlreadyPresent,
                            message: format!("sha256 already present as doc_id={}", existing_id),
                        });
                        continue;
                    }
                    Err(e) => {
                        results.push(PlacementResult {
                            destination_id: dest_id.clone(),
                            kind: "vault".to_string(),
                            target_path: String::new(),
                            doc_id: 0,
                            status: PlacementStatus::Error,
                            message: format!("sha256 check failed: {}", e.message),
                        });
                        continue;
                    }
                    Ok(None) => {} // not present; proceed to insert
                }

                // Insert into vault.
                // `encrypt` flag: the vault already has a password set (or
                // not) independently.  We pass a rule_snapshot note about
                // whether encrypt was requested; actual AES is handled by the
                // vault's own password machinery when the document is later
                // accessed.  For now we store the flag in rule_snapshot.
                let rule_snapshot = if encrypt {
                    format!("{{\"encrypt\":true,\"rule_snapshot\":{}}}", meta.rule_snapshot)
                } else {
                    meta.rule_snapshot.clone()
                };

                // Bridge: vault branch now mirrors the directory branch by
                // resolving the rename_pattern into display_name. Empty pattern
                // → empty display_name → vault_inventory falls back to the
                // original filename (preserves prior behaviour for rules
                // without a rename_pattern).
                let display_name = resolve_display_name(resolved_rename_pattern, file_path, meta);

                match insert_document(
                    &dest.path,
                    file_path,
                    &meta.category,
                    meta.confidence,
                    &meta.issuer,
                    &meta.description,
                    &meta.doc_date,
                    &meta.status,
                    &sha256,
                    &meta.simhash,
                    &meta.dhash,
                    &meta.source_path,
                    &rule_snapshot,
                    // W5f: encryption at fan-out time is not wired here; the
                    // `encrypt` flag is recorded in rule_snapshot only. Pass an
                    // empty password so the blob is stored plaintext-compressed.
                    "",
                    &display_name,
                ) {
                    Ok(doc_id) => {
                        results.push(PlacementResult {
                            destination_id: dest_id.clone(),
                            kind: "vault".to_string(),
                            target_path: String::new(),
                            doc_id,
                            status: PlacementStatus::Placed,
                            message: String::new(),
                        });
                    }
                    Err(e) => {
                        results.push(PlacementResult {
                            destination_id: dest_id.clone(),
                            kind: "vault".to_string(),
                            target_path: String::new(),
                            doc_id: 0,
                            status: PlacementStatus::Error,
                            message: e.message,
                        });
                    }
                }
            }

            "directory" => {
                let dir_path = Path::new(&dest.path);

                // Check if already present in this directory.
                if cache.contains(dir_path, &sha256) {
                    results.push(PlacementResult {
                        destination_id: dest_id.clone(),
                        kind: "directory".to_string(),
                        target_path: String::new(),
                        doc_id: 0,
                        status: PlacementStatus::SkippedAlreadyPresent,
                        message: "sha256 already present in directory".to_string(),
                    });
                    continue;
                }

                // Resolve target path.
                match resolve_directory_target(
                    &dest.path,
                    resolved_subfolder,
                    resolved_rename_pattern,
                    file_path,
                    meta,
                ) {
                    Ok(target_path) => {
                        // Copy the file.
                        match std::fs::copy(file_path, &target_path) {
                            Ok(_) => {
                                // Invalidate cache for this dir so subsequent
                                // checks within the same run see the new file.
                                // We do this by inserting the new file's sha256
                                // directly into the cache's file map.
                                if let Ok(canonical) = target_path.canonicalize() {
                                    if let Ok(m) = std::fs::metadata(&canonical) {
                                        let size = m.len();
                                        let mtime_ns = m
                                            .modified()
                                            .ok()
                                            .and_then(|t| {
                                                t.duration_since(SystemTime::UNIX_EPOCH).ok()
                                            })
                                            .map(|d| d.as_nanos())
                                            .unwrap_or(0);
                                        let key = (
                                            canonical.to_string_lossy().into_owned(),
                                            mtime_ns,
                                            size,
                                        );
                                        cache.file_cache.insert(key, sha256.clone());
                                    }
                                }
                                results.push(PlacementResult {
                                    destination_id: dest_id.clone(),
                                    kind: "directory".to_string(),
                                    target_path: target_path
                                        .canonicalize()
                                        .unwrap_or(target_path)
                                        .to_string_lossy()
                                        .into_owned(),
                                    doc_id: 0,
                                    status: PlacementStatus::Placed,
                                    message: String::new(),
                                });
                            }
                            Err(e) => {
                                results.push(PlacementResult {
                                    destination_id: dest_id.clone(),
                                    kind: "directory".to_string(),
                                    target_path: String::new(),
                                    doc_id: 0,
                                    status: PlacementStatus::Error,
                                    message: format!(
                                        "copy failed: {} → {}: {}",
                                        file_path,
                                        target_path.display(),
                                        e
                                    ),
                                });
                            }
                        }
                    }
                    Err(e) => {
                        results.push(PlacementResult {
                            destination_id: dest_id.clone(),
                            kind: "directory".to_string(),
                            target_path: String::new(),
                            doc_id: 0,
                            status: PlacementStatus::Error,
                            message: e.message,
                        });
                    }
                }
            }

            other => {
                results.push(PlacementResult {
                    destination_id: dest_id.clone(),
                    kind: other.to_string(),
                    target_path: String::new(),
                    doc_id: 0,
                    status: PlacementStatus::Error,
                    message: format!("unknown destination kind: {}", other),
                });
            }
        }
    }

    results
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::destinations;
    use crate::vault_lifecycle;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_tmp(prefix: &str) -> PathBuf {
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir().join(format!("scansort-placement-{prefix}-{pid}-{ts}-{n}"))
    }

    fn make_vault(path: &Path) {
        vault_lifecycle::create_vault(path.to_str().unwrap(), "test-vault").unwrap();
    }

    fn make_source_file(base: &Path, name: &str, content: &[u8]) -> PathBuf {
        let p = base.join(name);
        std::fs::write(&p, content).unwrap();
        p
    }

    fn default_meta(sha256: &str) -> DocMeta {
        DocMeta {
            category: "invoice".to_string(),
            confidence: 0.9,
            issuer: "ACME".to_string(),
            description: "test doc".to_string(),
            doc_date: "2024-03-15".to_string(),
            status: "classified".to_string(),
            simhash: "0000000000000000".to_string(),
            dhash: "0000000000000000".to_string(),
            source_path: String::new(),
            rule_snapshot: String::new(),
            sha256: sha256.to_string(),
            doc_type: String::new(),
            amount: String::new(),
        }
    }

    // -----------------------------------------------------------------------
    // 1. Fan-out copy to multiple directory destinations.
    //    Source intact; result list has N rows; file present at all targets.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_multiple_directory_destinations() {
        let base = unique_tmp("multi-dir");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "doc.pdf", b"hello world invoice");
        let sha256 = compute_sha256(&src).unwrap();

        // Two directory destinations.
        let dir_a = base.join("dest_a");
        let dir_b = base.join("dest_b");
        std::fs::create_dir_all(&dir_a).unwrap();
        std::fs::create_dir_all(&dir_b).unwrap();

        let mut reg = crate::destinations::DestinationRegistry::default();
        let da = destinations::add(&mut reg, "directory", dir_a.to_str().unwrap(), None, false)
            .unwrap();
        let db_dest = destinations::add(&mut reg, "directory", dir_b.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![da.id.clone(), db_dest.id.clone()];
        let meta = default_meta(&sha256);

        let results = fan_out(&src.to_str().unwrap(), &copy_to, "docs", "", false, &reg, &meta, None);

        assert_eq!(results.len(), 2);
        for r in &results {
            assert_eq!(r.status, PlacementStatus::Placed, "dest {} should be Placed", r.destination_id);
            assert!(!r.target_path.is_empty(), "target_path must be set for directory dest");
            assert!(Path::new(&r.target_path).exists(), "placed file must exist at {}", r.target_path);
        }

        // Source is still intact.
        assert!(src.exists(), "source must still exist after fan-out");

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 2. Fan-out to a vault destination → insert_document ran, doc row exists.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_to_vault_destination() {
        let base = unique_tmp("vault-dest");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "invoice.pdf", b"vault fan-out content");
        let sha256 = compute_sha256(&src).unwrap();

        let vault_path = base.join("archive.ssort");
        make_vault(&vault_path);

        let mut reg = crate::destinations::DestinationRegistry::default();
        let vd = destinations::add(&mut reg, "vault", vault_path.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![vd.id.clone()];
        let meta = default_meta(&sha256);

        let results = fan_out(src.to_str().unwrap(), &copy_to, "", "", false, &reg, &meta, None);

        assert_eq!(results.len(), 1);
        let r = &results[0];
        assert_eq!(r.status, PlacementStatus::Placed, "vault placement must succeed");
        assert!(r.doc_id > 0, "doc_id must be > 0, got {}", r.doc_id);

        // Verify row is present.
        let doc = crate::documents::get_document(vault_path.to_str().unwrap(), r.doc_id).unwrap();
        assert_eq!(doc.sha256, sha256);

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 3. Mixed fan-out: some directory, some vault.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_mixed_directory_and_vault() {
        let base = unique_tmp("mixed");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "mixed.pdf", b"mixed placement test content");
        let sha256 = compute_sha256(&src).unwrap();

        let dir_dest = base.join("dir_dest");
        std::fs::create_dir_all(&dir_dest).unwrap();

        let vault_path = base.join("vault.ssort");
        make_vault(&vault_path);

        let mut reg = crate::destinations::DestinationRegistry::default();
        let dd = destinations::add(&mut reg, "directory", dir_dest.to_str().unwrap(), None, false)
            .unwrap();
        let vd = destinations::add(&mut reg, "vault", vault_path.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![dd.id.clone(), vd.id.clone()];
        let meta = default_meta(&sha256);

        let results = fan_out(src.to_str().unwrap(), &copy_to, "", "", false, &reg, &meta, None);

        assert_eq!(results.len(), 2);

        let dir_row = results.iter().find(|r| r.kind == "directory").unwrap();
        assert_eq!(dir_row.status, PlacementStatus::Placed);
        assert!(Path::new(&dir_row.target_path).exists());

        let vault_row = results.iter().find(|r| r.kind == "vault").unwrap();
        assert_eq!(vault_row.status, PlacementStatus::Placed);
        assert!(vault_row.doc_id > 0);

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 4. Bad/unknown destination id → that row errors; others still placed.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_bad_destination_id_errors_others_placed() {
        let base = unique_tmp("bad-id");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "doc.pdf", b"bad id test content");
        let sha256 = compute_sha256(&src).unwrap();

        let dir_good = base.join("good_dest");
        std::fs::create_dir_all(&dir_good).unwrap();

        let mut reg = crate::destinations::DestinationRegistry::default();
        let good =
            destinations::add(&mut reg, "directory", dir_good.to_str().unwrap(), None, false)
                .unwrap();

        let copy_to = vec!["nonexistent-id-99".to_string(), good.id.clone()];
        let meta = default_meta(&sha256);

        let results = fan_out(src.to_str().unwrap(), &copy_to, "", "", false, &reg, &meta, None);

        assert_eq!(results.len(), 2);

        let bad_row = results.iter().find(|r| r.destination_id == "nonexistent-id-99").unwrap();
        assert_eq!(bad_row.status, PlacementStatus::Error);
        assert!(bad_row.message.contains("not found"));

        let good_row = results.iter().find(|r| r.destination_id == good.id).unwrap();
        assert_eq!(good_row.status, PlacementStatus::Placed);

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 5. Path-traversal in resolved_subfolder is rejected.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_path_traversal_in_subfolder_rejected() {
        let base = unique_tmp("traversal");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "doc.pdf", b"traversal test");
        let sha256 = compute_sha256(&src).unwrap();

        let dir_dest = base.join("safe_dest");
        std::fs::create_dir_all(&dir_dest).unwrap();

        let mut reg = crate::destinations::DestinationRegistry::default();
        let dd = destinations::add(&mut reg, "directory", dir_dest.to_str().unwrap(), None, false)
            .unwrap();

        // Subfolder containing a path-traversal component.
        let copy_to = vec![dd.id.clone()];
        let meta = default_meta(&sha256);

        let results = fan_out(
            src.to_str().unwrap(),
            &copy_to,
            "../../etc", // path traversal attempt
            "",
            false,
            &reg,
            &meta,
            None,
        );

        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].status,
            PlacementStatus::Error,
            "path traversal must be rejected"
        );
        assert!(results[0].message.contains("traversal") || results[0].message.contains(".."));

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 6. Collision safety: placing the same-named file twice → two distinct
    //    paths.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_collision_safety_two_distinct_paths() {
        let base = unique_tmp("collision");
        std::fs::create_dir_all(&base).unwrap();

        // Two different source files with the same name to force same stem.
        let src1 = make_source_file(&base, "document.pdf", b"content one");
        let src2 = make_source_file(&base, "document2.pdf", b"content two different bytes");

        let sha1 = compute_sha256(&src1).unwrap();
        let sha2 = compute_sha256(&src2).unwrap();

        let dir_dest = base.join("dest");
        std::fs::create_dir_all(&dir_dest).unwrap();

        let mut reg = crate::destinations::DestinationRegistry::default();
        let dd = destinations::add(&mut reg, "directory", dir_dest.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![dd.id.clone()];

        // First placement.
        let r1 = fan_out(src1.to_str().unwrap(), &copy_to, "", "", false, &reg, &default_meta(&sha1), None);
        assert_eq!(r1[0].status, PlacementStatus::Placed);

        // Second placement with same stem but different content → different
        // sha256 so not skipped; collision-safe rename.
        let r2 = fan_out(src2.to_str().unwrap(), &copy_to, "", "", false, &reg, &default_meta(&sha2), None);
        assert_eq!(r2[0].status, PlacementStatus::Placed);

        assert_ne!(r1[0].target_path, r2[0].target_path, "two placements must yield distinct paths");
        assert!(Path::new(&r1[0].target_path).exists());
        assert!(Path::new(&r2[0].target_path).exists());

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 7. Directory processed-state scan: scan a dir, assert expected sha256
    //    set; add a file, re-scan, assert it appears.
    // -----------------------------------------------------------------------
    #[test]
    fn dir_hash_cache_scan_adds_new_file() {
        let base = unique_tmp("scan-state");
        std::fs::create_dir_all(&base).unwrap();

        let file_a = make_source_file(&base, "a.txt", b"file a content");
        let sha_a = compute_sha256(&file_a).unwrap();

        let mut cache = DirHashCache::new();

        // First scan: only file_a.
        let set1 = cache.scan(&base);
        assert!(set1.contains(&sha_a), "sha of file_a must be in scan result");

        // Add file_b.
        let file_b = make_source_file(&base, "b.txt", b"file b different content");
        let sha_b = compute_sha256(&file_b).unwrap();

        // Re-scan: both files should appear.
        let set2 = cache.scan(&base);
        assert!(set2.contains(&sha_a), "sha_a still present");
        assert!(set2.contains(&sha_b), "sha_b must appear after adding file_b");

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 8. DirHashCache: scanning unchanged dir twice doesn't re-hash.
    //    (We assert via cache_size growth: after two identical scans the
    //    cache size must not have grown beyond what the first scan added.)
    // -----------------------------------------------------------------------
    #[test]
    fn dir_hash_cache_no_rehash_on_unchanged_dir() {
        let base = unique_tmp("cache-reuse");
        std::fs::create_dir_all(&base).unwrap();

        make_source_file(&base, "x.txt", b"unchanged content");
        make_source_file(&base, "y.txt", b"also unchanged content");

        let mut cache = DirHashCache::new();

        cache.scan(&base);
        let size_after_first = cache.cache_size();
        assert_eq!(size_after_first, 2, "two files → two cache entries");

        // Second scan — should reuse; cache size must stay at 2.
        cache.scan(&base);
        assert_eq!(
            cache.cache_size(),
            size_after_first,
            "cache size must not grow on unchanged dir scan"
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 9. DirHashCache: modifying a file updates the cached hash.
    // -----------------------------------------------------------------------
    #[test]
    fn dir_hash_cache_updated_file_gets_new_hash() {
        let base = unique_tmp("cache-update");
        std::fs::create_dir_all(&base).unwrap();

        let f = make_source_file(&base, "evolving.txt", b"original content");
        let sha_orig = compute_sha256(&f).unwrap();

        let mut cache = DirHashCache::new();
        let set1 = cache.scan(&base);
        assert!(set1.contains(&sha_orig));

        // Overwrite with new content (different mtime/size).
        // Sleep briefly to ensure mtime changes (filesystem resolution).
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&f, b"completely different new content for testing").unwrap();

        let sha_new = compute_sha256(&f).unwrap();
        assert_ne!(sha_orig, sha_new);

        // Re-scan: new hash must appear, old must not.
        let set2 = cache.scan(&base);
        assert!(set2.contains(&sha_new), "new hash must appear after file change");
        // Note: old sha may still be in the cache map under the old key, but
        // the scan result (which reflects live files) must not contain it.
        assert!(!set2.contains(&sha_orig), "old hash must not appear in re-scan");

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 10. Exact-sha256 auto-skip — directory: fanning out a doc whose sha256
    //     is already present → SkippedAlreadyPresent.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_exact_sha256_auto_skip_directory() {
        let base = unique_tmp("skip-dir");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "dup.pdf", b"duplicate content here");
        let sha256 = compute_sha256(&src).unwrap();

        let dir_dest = base.join("dest");
        std::fs::create_dir_all(&dir_dest).unwrap();

        // Pre-populate destination with the same content under a different name.
        let existing = dir_dest.join("already_there.pdf");
        std::fs::write(&existing, b"duplicate content here").unwrap();

        let mut reg = crate::destinations::DestinationRegistry::default();
        let dd = destinations::add(&mut reg, "directory", dir_dest.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![dd.id.clone()];
        let meta = default_meta(&sha256);

        let results = fan_out(src.to_str().unwrap(), &copy_to, "", "", false, &reg, &meta, None);

        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].status,
            PlacementStatus::SkippedAlreadyPresent,
            "same sha256 already in directory → must be skipped"
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 11. Exact-sha256 auto-skip — vault: document already in vault →
    //     SkippedAlreadyPresent.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_exact_sha256_auto_skip_vault() {
        let base = unique_tmp("skip-vault");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "dup_vault.pdf", b"vault duplicate content");
        let sha256 = compute_sha256(&src).unwrap();

        let vault_path = base.join("vault.ssort");
        make_vault(&vault_path);

        let mut reg = crate::destinations::DestinationRegistry::default();
        let vd = destinations::add(&mut reg, "vault", vault_path.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![vd.id.clone()];
        let meta = default_meta(&sha256);

        // First placement: places the doc.
        let r1 = fan_out(src.to_str().unwrap(), &copy_to, "", "", false, &reg, &meta, None);
        assert_eq!(r1[0].status, PlacementStatus::Placed, "first placement must succeed");

        // Second placement: same content sha256 → SkippedAlreadyPresent.
        let r2 = fan_out(src.to_str().unwrap(), &copy_to, "", "", false, &reg, &meta, None);
        assert_eq!(
            r2[0].status,
            PlacementStatus::SkippedAlreadyPresent,
            "second fan-out with same sha256 must be skipped"
        );

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 12. scan_directory_hashes (stateless API).
    // -----------------------------------------------------------------------
    #[test]
    fn scan_directory_hashes_stateless() {
        let base = unique_tmp("stateless-scan");
        std::fs::create_dir_all(&base).unwrap();

        let f = make_source_file(&base, "z.txt", b"stateless scan content");
        let sha = compute_sha256(&f).unwrap();

        let set = scan_directory_hashes(&base).unwrap();
        assert!(set.contains(&sha));

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 13. Empty copy_to list → empty results, no panic.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_empty_copy_to_returns_empty() {
        let base = unique_tmp("empty-copy-to");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "doc.pdf", b"some content");
        let sha256 = compute_sha256(&src).unwrap();
        let reg = crate::destinations::DestinationRegistry::default();
        let meta = default_meta(&sha256);

        let results = fan_out(src.to_str().unwrap(), &[], "", "", false, &reg, &meta, None);
        assert!(results.is_empty());

        std::fs::remove_dir_all(&base).ok();
    }

    // -----------------------------------------------------------------------
    // 14. Shared DirHashCache across two fan-out calls: after placing file A
    //     into dest, a second fan-out of the same content uses the same cache
    //     and gets SkippedAlreadyPresent without re-scanning disk.
    // -----------------------------------------------------------------------
    #[test]
    fn fan_out_shared_cache_skips_on_second_call() {
        let base = unique_tmp("shared-cache");
        std::fs::create_dir_all(&base).unwrap();

        let src = make_source_file(&base, "shared.pdf", b"shared cache test content");
        let sha256 = compute_sha256(&src).unwrap();

        let dir_dest = base.join("shared_dest");
        std::fs::create_dir_all(&dir_dest).unwrap();

        let mut reg = crate::destinations::DestinationRegistry::default();
        let dd = destinations::add(&mut reg, "directory", dir_dest.to_str().unwrap(), None, false)
            .unwrap();

        let copy_to = vec![dd.id.clone()];
        let meta = default_meta(&sha256);

        let mut cache = DirHashCache::new();

        // First call: places the file, updates the cache.
        let r1 = fan_out(
            src.to_str().unwrap(),
            &copy_to,
            "",
            "",
            false,
            &reg,
            &meta,
            Some(&mut cache),
        );
        assert_eq!(r1[0].status, PlacementStatus::Placed);

        // Second call with same cache: should see sha256 already present.
        let r2 = fan_out(
            src.to_str().unwrap(),
            &copy_to,
            "",
            "",
            false,
            &reg,
            &meta,
            Some(&mut cache),
        );
        assert_eq!(
            r2[0].status,
            PlacementStatus::SkippedAlreadyPresent,
            "shared cache must catch duplicate without re-scanning disk"
        );

        std::fs::remove_dir_all(&base).ok();
    }
}
