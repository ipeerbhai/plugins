//! Shared types used by scansort-plugin vault modules.
//!
//! Includes VaultError, VaultResult, VaultInfo, Document, Rule, Classification,
//! and utility functions needed by all vault modules.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct VaultError {
    pub message: String,
}

impl VaultError {
    pub fn new(msg: impl Into<String>) -> Self {
        Self {
            message: msg.into(),
        }
    }
}

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for VaultError {}

impl From<rusqlite::Error> for VaultError {
    fn from(e: rusqlite::Error) -> Self {
        VaultError::new(format!("Database error: {e}"))
    }
}

impl From<std::io::Error> for VaultError {
    fn from(e: std::io::Error) -> Self {
        VaultError::new(format!("IO error: {e}"))
    }
}

impl From<serde_json::Error> for VaultError {
    fn from(e: serde_json::Error) -> Self {
        VaultError::new(format!("JSON error: {e}"))
    }
}

pub type VaultResult<T> = Result<T, VaultError>;

// ---------------------------------------------------------------------------
// Document — returned by query/get/inventory
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Document {
    pub doc_id: i64,
    pub original_filename: String,
    pub display_name: String,
    pub file_ext: String,
    pub category: String,
    pub confidence: f64,
    pub sender: String,
    pub description: String,
    pub doc_date: String,
    pub classified_at: String,
    pub sha256: String,
    pub simhash: String,
    pub dhash: String,
    pub status: String,
    pub file_size: i64,
    pub compression: String,
    pub encrypted: bool,
    pub tags: Vec<String>,
    pub source_path: String,
}

// ---------------------------------------------------------------------------
// DocumentFilter — query filter parameters
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct DocumentFilter {
    pub category: Option<String>,
    pub sender: Option<String>,
    pub status: Option<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
    pub pattern: Option<String>,
    pub tag: Option<String>,
    pub doc_id: Option<i64>,
}

// ---------------------------------------------------------------------------
// VaultInfo — returned by open_vault
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultInfo {
    pub name: String,
    pub version: String,
    pub created_at: String,
    pub doc_count: i64,
    pub category_counts: HashMap<String, i64>,
    pub rule_count: i64,
    pub log_count: i64,
    pub total_file_size: i64,
    pub emergency_contact_name: String,
    pub emergency_contact_email: String,
    pub emergency_contact_phone: String,
    pub software_url: String,
    pub password_hint: String,
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/// Compute SHA-256 hash of a file.
pub fn compute_sha256(path: &Path) -> VaultResult<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Get current time as ISO8601 UTC string.
pub fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Compute Hamming distance between two 16-hex-digit SimHash strings.
///
/// Returns the number of differing bits (0–64).
pub fn hamming_distance_hex(a: &str, b: &str) -> VaultResult<u32> {
    let a_val = u64::from_str_radix(a, 16)
        .map_err(|e| VaultError::new(format!("Invalid hex hash a: {e}")))?;
    let b_val = u64::from_str_radix(b, 16)
        .map_err(|e| VaultError::new(format!("Invalid hex hash b: {e}")))?;
    Ok((a_val ^ b_val).count_ones())
}

// ---------------------------------------------------------------------------
// ChecklistItem — checklist entry stored in the checklists table (T7 R6+)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ChecklistItem {
    pub checklist_id: i64,
    pub tax_year: i32,
    pub item_type: String,
    pub name: String,
    pub match_category: Option<String>,
    pub match_sender: Option<String>,
    pub match_pattern: Option<String>,
    pub enabled: bool,
    pub matched_doc_id: Option<i64>,
    pub status: String,
}

// ---------------------------------------------------------------------------
// Rule — classification rule stored in the rules table (T6 R3+)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Rule {
    pub rule_id: i64,
    pub label: String,
    pub name: String,
    pub instruction: String,
    pub signals: Vec<String>,
    pub subfolder: String,
    pub rename_pattern: String,
    pub confidence_threshold: f64,
    pub encrypt: bool,
    pub enabled: bool,
    pub is_default: bool,
}

// ---------------------------------------------------------------------------
// Classification — result of classify_document (T6 R3+)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Classification {
    pub category: String,
    pub confidence: f64,
    pub sender: String,
    pub description: String,
    pub doc_date: String,
    pub tags: Vec<String>,
    pub raw_response: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<String>,
}

// ---------------------------------------------------------------------------
// R2: extract / render types
// ---------------------------------------------------------------------------

/// Result of a text extraction operation (R2+).
#[derive(Debug, Clone, Serialize, Default)]
pub struct ExtractionResult {
    pub success: bool,
    pub file_type: String,
    pub sha256: String,
    pub simhash: String,
    pub dhash: String,
    pub page_count: i32,
    pub pages: Vec<PageInfo>,
    pub full_text: String,
    pub char_count: i64,
    pub image_only_pages: Vec<i32>,
}

/// Per-page extraction info (R2+).
#[derive(Debug, Clone, Serialize, Default)]
pub struct PageInfo {
    pub page_num: i32,
    pub has_text: bool,
    pub text: String,
    pub char_count: i64,
}

/// Result of a page rendering operation (R2+).
#[derive(Debug, Clone, Serialize, Default)]
pub struct RenderResult {
    pub success: bool,
    pub pages: Vec<RenderedPage>,
    pub page_count: i32,
}

/// A single rendered page (base64-encoded PNG) (R2+).
#[derive(Debug, Clone, Serialize, Default)]
pub struct RenderedPage {
    pub page_num: i32,
    pub base64: String,
}

// ---------------------------------------------------------------------------
// R2: SimHash utility
// ---------------------------------------------------------------------------

/// Compute 64-bit SimHash from text using word 3-grams and MD5.
pub fn compute_simhash(text: &str) -> u64 {
    use md5::{Digest as Md5Digest, Md5};

    let normalized = normalize_text(text);
    if normalized.len() < 50 {
        return 0;
    }

    let words: Vec<&str> = normalized.split_whitespace().collect();
    if words.len() < 3 {
        return 0;
    }

    let mut v = [0i32; 64];

    for ngram in words.windows(3) {
        let gram = ngram.join(" ");
        let hash = Md5::digest(gram.as_bytes());
        let hash_val = u64::from_be_bytes(hash[..8].try_into().unwrap());

        for i in 0..64 {
            if hash_val & (1u64 << i) != 0 {
                v[i] += 1;
            } else {
                v[i] -= 1;
            }
        }
    }

    let mut fingerprint = 0u64;
    for i in 0..64 {
        if v[i] > 0 {
            fingerprint |= 1u64 << i;
        }
    }
    fingerprint
}

/// Normalize text for SimHash: lowercase, strip punctuation, collapse whitespace.
fn normalize_text(text: &str) -> String {
    let lower = text.to_lowercase();
    let cleaned: String = lower
        .chars()
        .map(|c| if c.is_alphanumeric() || c.is_whitespace() { c } else { ' ' })
        .collect();
    cleaned.split_whitespace().collect::<Vec<_>>().join(" ")
}
