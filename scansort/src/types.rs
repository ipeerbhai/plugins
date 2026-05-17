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
// ConditionNode — recursive condition tree for rule gates (W1 storage only)
// ---------------------------------------------------------------------------

/// A node in a deterministic condition tree.
///
/// Three JSON shapes are supported:
///
/// - `{"all": [<node>, ...]}` — all child nodes must be true
/// - `{"any": [<node>, ...]}` — at least one child node must be true
/// - `{"field": "<name>", "op": "<op>", "value": <scalar>}` — leaf predicate
///
/// Valid `op` values (stored as strings; evaluation is a later work-item):
///   `contains`, `equals`, `matches`, `<`, `>`, `<=`, `>=`
///
/// Valid `field` values (stored as strings; validation is a later work-item):
///   Phase-1 facts: `year`, `doc_date`, `issuer`, `amount`, `confidence`, `doc_type`
///   File facts: `filename`, `extension`, `size`
///
/// `value` accepts string or number via `serde_json::Value`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum ConditionNode {
    /// `{"all": [...]}` — all children must be true.
    All { all: Vec<ConditionNode> },
    /// `{"any": [...]}` — any child must be true.
    Any { any: Vec<ConditionNode> },
    /// `{"field": "...", "op": "...", "value": ...}` — leaf predicate.
    Predicate {
        field: String,
        op: String,
        value: serde_json::Value,
    },
}

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
    pub issuer: String,
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
    /// JSON snapshot of the rule that classified this document (empty if none).
    /// Populated by classify_document and persisted on insert (vault v1.1.0+).
    #[serde(default)]
    pub rule_snapshot: String,
}

// ---------------------------------------------------------------------------
// DocumentFilter — query filter parameters
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct DocumentFilter {
    pub category: Option<String>,
    pub issuer: Option<String>,
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
// Subtype — variant within a rule's category (B8 doc_type normalization)
//
// Deprecated by DCR 019e33bf — kept for the W1+W5 transition window so legacy
// library files still deserialize while W5's migration converts them to the
// new `stages` shape. W2 removes the field from `Rule`/`FileRule` and the
// engine; the type itself is retained as long as on-disk legacy files need it.
// ---------------------------------------------------------------------------

/// A document subtype within a rule. The `name` is the canonical token the
/// rename_pattern's `{doc_type}` resolves to; `also_known_as` lists aliases
/// the LLM might produce instead (used by the canonicalize strategy).
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Subtype {
    pub name: String,
    #[serde(default)]
    pub also_known_as: Vec<String>,
}

// ---------------------------------------------------------------------------
// SlotValues — closed taxonomy or open natural-language constraint
// (DCR 019e33bf — new rule schema)
// ---------------------------------------------------------------------------

/// What an extraction slot is allowed to produce.
///
/// - `Closed(["yes", "no"])`  — JSON array; the LLM must pick from the list.
/// - `Open("a 4-digit year")` — JSON string; natural-language constraint.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum SlotValues {
    Closed(Vec<String>),
    Open(String),
}

impl Default for SlotValues {
    fn default() -> Self {
        SlotValues::Closed(Vec::new())
    }
}

// ---------------------------------------------------------------------------
// Slot — one named extraction within a stage's `classify` map
// ---------------------------------------------------------------------------

/// A single extraction slot. `description` is the human/LLM-readable label;
/// `values` constrains what the LLM may return for this slot.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Slot {
    pub description: String,
    pub values: SlotValues,
}

// ---------------------------------------------------------------------------
// Stage — one LLM round (one `ask` + named slots) inside a rule's pipeline
// ---------------------------------------------------------------------------

/// One stage of a rule's classification pipeline.
///
/// Serializes as `{"ask": "...", "classify": {...}, "keep_when": "..."}`.
/// `classify` slot names are unique per rule (validated across all stages by
/// `Rule::validate`); `BTreeMap` gives stable alphabetical key ordering on
/// serialization so on-disk JSON round-trips deterministically.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Stage {
    pub ask: String,
    pub classify: std::collections::BTreeMap<String, Slot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep_when: Option<String>,
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
    /// Deterministic gate evaluated before LLM-based classification applies this rule.
    /// W1 stores this only; evaluation is a later work-item.
    #[serde(default)]
    pub conditions: Option<ConditionNode>,
    /// When this evaluates true, the rule match is negated.
    /// W1 stores this only; evaluation is a later work-item.
    #[serde(default)]
    pub exceptions: Option<ConditionNode>,
    /// Explicit ordering key — lower values sort first. Default 0.
    #[serde(default)]
    pub order: i64,
    /// When true, stop evaluating subsequent rules after this one matches.
    #[serde(default)]
    pub stop_processing: bool,
    /// Additional destination IDs to copy the document to.
    /// W1 stores as opaque strings; resolution is a later work-item.
    #[serde(default)]
    pub copy_to: Vec<String>,
    /// Document subtypes within this rule (B8 doc_type normalization).
    /// Used by the enum strategy (prompt augmentation) and canonicalize
    /// strategy (post-LLM alias→name mapping).
    ///
    /// Deprecated by DCR 019e33bf (W1). Kept on the struct for the W1+W5
    /// transition window so legacy `library.rules.json` files still deserialize
    /// before W5's migration rewrites them into `stages`. W2 removes this field
    /// and the engine code that reads it.
    #[serde(default)]
    pub subtypes: Vec<Subtype>,
    /// W1 (DCR 019e33bf): per-rule classification pipeline. Each stage is one
    /// LLM round. Slot names are unique across all stages (enforced by
    /// `validate`). Empty until W2 wires the engine to read it; legacy rules
    /// have this populated by W5 migration on first load.
    #[serde(default)]
    pub stages: Vec<Stage>,
}

impl Rule {
    /// Reject duplicate `classify` slot names across stages (DCR 019e33bf
    /// invariant). Called from `library_insert` callers; returns the first
    /// offending slot name in its error message.
    pub fn validate(&self) -> VaultResult<()> {
        let mut seen: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        for (i, stage) in self.stages.iter().enumerate() {
            for slot_name in stage.classify.keys() {
                if let Some(prev) = seen.get(slot_name) {
                    return Err(VaultError::new(format!(
                        "slot name '{}' is declared in stage {} but already declared in stage {}; \
                         classify slot names must be unique across all stages of a rule",
                        slot_name, i, prev
                    )));
                }
                seen.insert(slot_name.clone(), i);
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Classification — result of classify_document (T6 R3+, extended W2)
// ---------------------------------------------------------------------------

/// Per-rule semantic-match signal returned by Phase 1 classification.
///
/// `label` matches a rule's `.label` field.
/// `score` is 0.0–1.0 — how well the document matches that rule's
/// instruction/signals as judged by the LLM. W3's deterministic rule walk
/// will threshold these scores and apply conditions/exceptions.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RuleSignal {
    pub label: String,
    pub score: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Classification {
    // ── legacy fields (unchanged) ──────────────────────────────────────────
    pub category: String,
    pub confidence: f64,
    pub issuer: String,
    pub description: String,
    pub doc_date: String,
    pub tags: Vec<String>,
    pub raw_response: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<String>,
    // ── W2 additions ───────────────────────────────────────────────────────
    /// Short free-text document type ("W-2", "invoice", "bank statement", …).
    #[serde(default)]
    pub doc_type: String,
    /// Monetary amount extracted from the document (empty when not present).
    #[serde(default)]
    pub amount: String,
    /// Calendar year extracted from doc_date (0 when not parseable).
    #[serde(default)]
    pub year: i32,
    /// Per-rule semantic-match scores.  One entry per *enabled* rule in the
    /// rule set.  W3 consumes these to threshold, apply conditions, and pick
    /// which rules fire.  Missing rules default to 0.0.
    #[serde(default)]
    pub rule_signals: Vec<RuleSignal>,
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
