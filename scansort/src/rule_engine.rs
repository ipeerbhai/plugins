//! Phase-2 deterministic rule engine — W3.
//!
//! A pure function that takes the Phase-1 classification output (extracted facts
//! + per-rule semantic-match scores) plus file facts, walks the ordered rule set,
//! and returns which rules fired and what actions should be taken.
//!
//! Nothing in this module touches the filesystem, makes LLM calls, or has
//! side-effects.  Pure inputs → pure output.
//!
//! ## Rule walk algorithm
//!
//! Rules are evaluated in ascending `order` order, ties broken by list position.
//! For each enabled rule:
//!
//! 1. **Semantic gate** — the rule's `rule_signals` score must be ≥
//!    `confidence_threshold`. (Missing rule label → score 0.0.)
//! 2. **Conditions gate** — if `conditions` is `Some`, the `ConditionNode` tree
//!    must evaluate `true`. (`None` = pass.)
//! 3. **Exception gate** — if `exceptions` is `Some` and evaluates `true`,
//!    the rule is excepted (skipped even though gates 1+2 passed).
//! 4. If all gates pass → the rule **fires**.  Append to fired list.
//! 5. If the fired rule has `stop_processing = true` → halt.
//!
//! ## Condition evaluation
//!
//! | op       | string fields                          | numeric fields (`year`, `confidence`, `size`) / `amount` |
//! |----------|----------------------------------------|----------------------------------------------------------|
//! | equals   | case-insensitive exact match           | numeric equality (amount parsed leniently)               |
//! | contains | case-insensitive substring             | not a numeric concept → `false`                          |
//! | matches  | regex (case respects pattern flags)    | not a numeric concept → `false`                          |
//! | < > <= >=| lexicographic (documented; rarely used)| numeric comparison                                       |
//!
//! Unknown field names → predicate `false` (defensive; user-authored rules).
//! Invalid regex → predicate `false` (no panic).
//! Non-parseable `amount` for numeric op → `false`.

use crate::rules;
use crate::types::{Classification, ConditionNode, Rule, RuleSignal};
use regex::Regex;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Public output types
// ---------------------------------------------------------------------------

/// The resolved actions for a single fired rule.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FiredRuleAction {
    /// The rule's label — the classification category.
    pub category: String,
    /// Destination IDs this rule fans out to (from `copy_to`).
    pub copy_to: Vec<String>,
    /// Resolved subfolder (template tokens expanded with facts).
    pub resolved_subfolder: String,
    /// Resolved rename pattern (template tokens expanded with facts).
    pub resolved_rename_pattern: String,
    /// Whether the document should be encrypted (from the rule).
    pub encrypt: bool,
    /// The original rule for callers that need access to the full rule object.
    pub rule: Rule,
}

/// The outcome of running the rule walk over one document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleWalkOutcome {
    /// Fired rules in fire order.  Usually one entry; may be multiple when
    /// several rules fire before a `stop_processing` halts the walk.
    pub fired: Vec<FiredRuleAction>,
    /// True when at least one rule fired.
    pub matched: bool,
    /// The effective category: the first fired rule's label, or the fallback
    /// default category when no rule fired.
    pub effective_category: String,
    /// True when the walk was halted by a `stop_processing` flag.
    pub halted: bool,
}

// ---------------------------------------------------------------------------
// File facts (passed in by the caller — not from the LLM)
// ---------------------------------------------------------------------------

/// Facts derived from the source file, not from LLM classification.
#[derive(Debug, Clone, Default)]
pub struct FileFacts {
    pub filename: String,
    pub extension: String,
    pub size: i64,
}

// ---------------------------------------------------------------------------
// Fact lookup
// ---------------------------------------------------------------------------

/// All facts available to condition evaluation, unified into one flat map.
struct FactSet<'a> {
    classification: &'a Classification,
    file: &'a FileFacts,
}

impl<'a> FactSet<'a> {
    fn new(c: &'a Classification, f: &'a FileFacts) -> Self {
        FactSet { classification: c, file: f }
    }

    /// Get a fact value by field name.
    /// Returns None for unknown fields (predicate evaluates false).
    fn get(&self, field: &str) -> Option<FactValue> {
        let c = self.classification;
        let f = self.file;
        match field {
            // Phase-1 string facts
            "doc_date" => Some(FactValue::Str(c.doc_date.clone())),
            "issuer" => Some(FactValue::Str(c.issuer.clone())),
            "doc_type" => Some(FactValue::Str(c.doc_type.clone())),
            "amount" => Some(FactValue::Amount(c.amount.clone())),
            // Phase-1 numeric facts
            "year" => Some(FactValue::Int(c.year as i64)),
            "confidence" => Some(FactValue::Float(c.confidence)),
            // File facts
            "filename" => Some(FactValue::Str(f.filename.clone())),
            "extension" => Some(FactValue::Str(f.extension.clone())),
            "size" => Some(FactValue::Int(f.size)),
            _ => None,
        }
    }
}

/// Typed value variant for condition evaluation.
enum FactValue {
    Str(String),
    Int(i64),
    Float(f64),
    /// `amount` is stored as string but supports numeric coercion for ops like `>`.
    Amount(String),
}

// ---------------------------------------------------------------------------
// Condition evaluation
// ---------------------------------------------------------------------------

/// Evaluate a `ConditionNode` tree against the fact set.
///
/// Returns `false` on any structural/type mismatch — never panics.
fn eval_condition(node: &ConditionNode, facts: &FactSet<'_>) -> bool {
    match node {
        ConditionNode::All { all } => {
            if all.is_empty() {
                return true; // vacuously true
            }
            all.iter().all(|n| eval_condition(n, facts))
        }
        ConditionNode::Any { any } => {
            if any.is_empty() {
                return false; // vacuously false
            }
            any.iter().any(|n| eval_condition(n, facts))
        }
        ConditionNode::Predicate { field, op, value } => {
            eval_predicate(field, op, value, facts)
        }
    }
}

/// Evaluate a single leaf predicate.
fn eval_predicate(
    field: &str,
    op: &str,
    rule_value: &serde_json::Value,
    facts: &FactSet<'_>,
) -> bool {
    let fact = match facts.get(field) {
        Some(f) => f,
        None => return false, // unknown field → false
    };

    match fact {
        FactValue::Str(s) => eval_string_predicate(&s, op, rule_value),
        FactValue::Int(n) => eval_numeric_predicate(n as f64, op, rule_value),
        FactValue::Float(f) => eval_numeric_predicate(f, op, rule_value),
        FactValue::Amount(a) => eval_amount_predicate(&a, op, rule_value),
    }
}

/// String predicate evaluation.
///
/// - `equals`/`contains`: case-insensitive.
/// - `matches`: regex; respects the pattern's own flags.
/// - `<`/`>`/`<=`/`>=`: lexicographic (documented but rarely useful for strings).
fn eval_string_predicate(fact: &str, op: &str, rule_val: &serde_json::Value) -> bool {
    let rv_str = match rule_val.as_str() {
        Some(s) => s.to_string(),
        None => rule_val.to_string(), // coerce number to string if needed
    };

    match op {
        "equals" => fact.to_lowercase() == rv_str.to_lowercase(),
        "contains" => fact.to_lowercase().contains(&rv_str.to_lowercase()),
        "matches" => {
            match Regex::new(&rv_str) {
                Ok(re) => re.is_match(fact),
                Err(_) => false, // invalid regex → false, no panic
            }
        }
        "<" => fact < rv_str.as_str(),
        ">" => fact > rv_str.as_str(),
        "<=" => fact <= rv_str.as_str(),
        ">=" => fact >= rv_str.as_str(),
        _ => false, // unknown op → false
    }
}

/// Numeric predicate evaluation (for `year`, `confidence`, `size`).
///
/// `equals`, `<`, `>`, `<=`, `>=` all work numerically.
/// `contains`/`matches` → `false` (not meaningful for numbers).
fn eval_numeric_predicate(fact: f64, op: &str, rule_val: &serde_json::Value) -> bool {
    let rv: f64 = match rule_val.as_f64() {
        Some(v) => v,
        None => {
            // Try parsing a string-encoded number.
            match rule_val.as_str().and_then(|s| s.parse::<f64>().ok()) {
                Some(v) => v,
                None => return false,
            }
        }
    };

    match op {
        "equals" => (fact - rv).abs() < f64::EPSILON * 1024.0 || fact == rv,
        "<" => fact < rv,
        ">" => fact > rv,
        "<=" => fact <= rv,
        ">=" => fact >= rv,
        "contains" | "matches" => false, // not numeric concepts
        _ => false,
    }
}

/// Amount predicate evaluation.
///
/// `amount` is stored as a string (e.g. "1234.56").  For string ops (`equals`,
/// `contains`, `matches`) we treat it as a string (case-insensitive where
/// applicable).  For numeric ops (`<`, `>`, `<=`, `>=`) we parse it as f64;
/// if it cannot be parsed the predicate is `false`.
fn eval_amount_predicate(fact: &str, op: &str, rule_val: &serde_json::Value) -> bool {
    match op {
        "equals" | "contains" | "matches" => eval_string_predicate(fact, op, rule_val),
        "<" | ">" | "<=" | ">=" => {
            let fact_num = match parse_amount_f64(fact) {
                Some(n) => n,
                None => return false, // non-parseable amount → false
            };
            eval_numeric_predicate(fact_num, op, rule_val)
        }
        _ => false,
    }
}

/// Parse a monetary amount string to f64 leniently.
/// Accepts "1234.56", "$1,234.56", "1 234,56" etc.
fn parse_amount_f64(s: &str) -> Option<f64> {
    if s.is_empty() {
        return None;
    }
    // Strip common currency prefixes and thousands separators; keep digits, dot, minus.
    let cleaned: String = s
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.' || *c == '-')
        .collect();
    cleaned.parse::<f64>().ok()
}

// ---------------------------------------------------------------------------
// Template resolution helpers
// ---------------------------------------------------------------------------

/// Expand `{year}`, `{date}`, `{issuer}`, `{sender}` tokens in `pattern`
/// using the classification facts.  Returns the expanded string.
///
/// Token-expansion only — NOT sanitised. The engine stays pure and free of
/// vault I/O coupling; path-traversal sanitisation is the placement layer's
/// job (W10 / destination.rs), applied when the resolved string is used.
pub fn resolve_template(pattern: &str, classification: &Classification) -> String {
    if pattern.is_empty() {
        return String::new();
    }
    let year_val = if classification.year > 0 {
        classification.year.to_string()
    } else {
        // Fall back to parsing from doc_date if year is 0.
        if classification.doc_date.len() >= 4 {
            classification.doc_date[..4].to_string()
        } else {
            "unknown".to_string()
        }
    };
    let date_val = if classification.doc_date.is_empty() {
        "undated".to_string()
    } else {
        classification.doc_date.clone()
    };
    let issuer = &classification.issuer;

    // Mirror token expansion inline — rule_engine stays pure, no vault I/O coupling.
    // Empty-value fallback: substitute "unknown" for any empty field.
    let year_v = if year_val.is_empty() { "unknown".to_string() } else { year_val };
    let date_v = if date_val.is_empty() { "unknown".to_string() } else { date_val };
    let issuer_v = if issuer.is_empty() { "unknown" } else { issuer };
    let doc_type_v = if classification.doc_type.is_empty() { "unknown" } else { &classification.doc_type };
    // Description: cap at 60 chars before empty fallback.
    // Use chars().take() to avoid panicking on multi-byte codepoint boundaries.
    let desc_capped: String = classification.description.chars().take(60).collect();
    let description_v: &str = if desc_capped.is_empty() { "unknown" } else { &desc_capped };
    let amount_v = if classification.amount.is_empty() { "unknown" } else { &classification.amount };
    let category_v = if classification.category.is_empty() { "unknown" } else { &classification.category };

    pattern
        .replace("{year}", &year_v)
        .replace("{date}", &date_v)
        .replace("{issuer}", issuer_v)
        .replace("{sender}", issuer_v) // backward-compat alias
        .replace("{doc_type}", doc_type_v)
        .replace("{description}", description_v)
        .replace("{amount}", amount_v)
        .replace("{category}", category_v)
}

// ---------------------------------------------------------------------------
// Semantic score lookup
// ---------------------------------------------------------------------------

/// Look up a rule's semantic score from the classification's `rule_signals`.
/// Returns 0.0 when the label is not present.
fn rule_score(rule_label: &str, signals: &[RuleSignal]) -> f64 {
    signals
        .iter()
        .find(|s| s.label == rule_label)
        .map(|s| s.score)
        .unwrap_or(0.0)
}

// ---------------------------------------------------------------------------
// Main rule walk
// ---------------------------------------------------------------------------

/// Run the deterministic Phase-2 rule walk.
///
/// # Parameters
///
/// - `classification` — Phase-1 output (facts + per-rule scores).
/// - `file_facts` — facts derived from the source file (filename, extension, size).
/// - `rules` — the enabled rules to consider (typically from `RulesFile::to_rules()`).
///   Disabled rules are skipped automatically.
///
/// # Returns
///
/// A `RuleWalkOutcome` capturing which rules fired and the resolved actions.
pub fn run(
    classification: &Classification,
    file_facts: &FileFacts,
    rules: &[Rule],
) -> RuleWalkOutcome {
    // Sort rules by (order, list_index) ascending.
    let mut indexed: Vec<(usize, &Rule)> = rules
        .iter()
        .enumerate()
        .filter(|(_, r)| r.enabled)
        .collect();
    indexed.sort_by_key(|(idx, r)| (r.order, *idx as i64));

    let facts = FactSet::new(classification, file_facts);
    let mut fired: Vec<FiredRuleAction> = Vec::new();
    let mut halted = false;

    for (_, rule) in &indexed {
        // Gate 1: semantic score ≥ threshold.
        let score = rule_score(&rule.label, &classification.rule_signals);
        if score < rule.confidence_threshold {
            continue;
        }

        // Gate 2: conditions (None = pass).
        if let Some(ref cond) = rule.conditions {
            if !eval_condition(cond, &facts) {
                continue;
            }
        }

        // Gate 3: exceptions (None = no exception; Some(true) = skip this rule).
        if let Some(ref exc) = rule.exceptions {
            if eval_condition(exc, &facts) {
                continue; // excepted — do NOT fire
            }
        }

        // The rule fires.
        let resolved_subfolder = resolve_template(&rule.subfolder, classification);
        let resolved_rename_pattern = resolve_template(&rule.rename_pattern, classification);

        fired.push(FiredRuleAction {
            category: rule.label.clone(),
            copy_to: rule.copy_to.clone(),
            resolved_subfolder,
            resolved_rename_pattern,
            encrypt: rule.encrypt,
            rule: (*rule).clone(),
        });

        if rule.stop_processing {
            halted = true;
            break;
        }
    }

    let effective_category = if let Some(first) = fired.first() {
        first.category.clone()
    } else {
        rules::default_category(rules).to_string()
    };

    RuleWalkOutcome {
        matched: !fired.is_empty(),
        effective_category,
        halted,
        fired,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Classification, ConditionNode, Rule, RuleSignal};

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    fn make_classification(
        year: i32,
        doc_date: &str,
        issuer: &str,
        amount: &str,
        doc_type: &str,
        confidence: f64,
        signals: Vec<(&str, f64)>,
    ) -> Classification {
        Classification {
            category: String::new(),
            confidence,
            issuer: issuer.to_string(),
            description: String::new(),
            doc_date: doc_date.to_string(),
            tags: vec![],
            raw_response: String::new(),
            fallback_reason: None,
            doc_type: doc_type.to_string(),
            amount: amount.to_string(),
            year,
            rule_signals: signals
                .into_iter()
                .map(|(l, s)| RuleSignal { label: l.to_string(), score: s })
                .collect(),
        }
    }

    fn make_rule(
        label: &str,
        order: i64,
        threshold: f64,
        stop: bool,
        copy_to: Vec<&str>,
        subfolder: &str,
        rename_pattern: &str,
        conditions: Option<ConditionNode>,
        exceptions: Option<ConditionNode>,
    ) -> Rule {
        Rule {
            rule_id: 0,
            label: label.to_string(),
            name: label.to_string(),
            instruction: String::new(),
            signals: vec![],
            subfolder: subfolder.to_string(),
            rename_pattern: rename_pattern.to_string(),
            confidence_threshold: threshold,
            encrypt: false,
            enabled: true,
            is_default: label == "memories",
            conditions,
            exceptions,
            order,
            stop_processing: stop,
            copy_to: copy_to.into_iter().map(String::from).collect(),
        }
    }

    fn default_file_facts() -> FileFacts {
        FileFacts {
            filename: "invoice_2024.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 12345,
        }
    }

    fn pred(field: &str, op: &str, value: serde_json::Value) -> ConditionNode {
        ConditionNode::Predicate {
            field: field.to_string(),
            op: op.to_string(),
            value,
        }
    }

    fn all_of(nodes: Vec<ConditionNode>) -> ConditionNode {
        ConditionNode::All { all: nodes }
    }

    fn any_of(nodes: Vec<ConditionNode>) -> ConditionNode {
        ConditionNode::Any { any: nodes }
    }

    // =========================================================================
    // Operator tests — string fields
    // =========================================================================

    #[test]
    fn string_equals_case_insensitive() {
        let c = make_classification(2024, "2024-01-15", "ACME Corp", "", "invoice", 0.9,
            vec![("invoice", 0.9)]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        // issuer exact match, different case
        assert!(eval_predicate("issuer", "equals",
            &serde_json::json!("acme corp"), &fs));
        assert!(eval_predicate("issuer", "equals",
            &serde_json::json!("ACME CORP"), &fs));
        // mismatch
        assert!(!eval_predicate("issuer", "equals",
            &serde_json::json!("other"), &fs));
    }

    #[test]
    fn string_contains_case_insensitive() {
        let c = make_classification(2024, "2024-01-15", "ACME Corporation", "", "", 0.9,
            vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("issuer", "contains",
            &serde_json::json!("acme"), &fs));
        assert!(eval_predicate("issuer", "contains",
            &serde_json::json!("CORP"), &fs));
        assert!(!eval_predicate("issuer", "contains",
            &serde_json::json!("walmart"), &fs));
    }

    #[test]
    fn string_matches_regex() {
        let c = make_classification(2024, "2024-03-15", "", "", "W-2", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        // Pattern matching doc_type
        assert!(eval_predicate("doc_type", "matches",
            &serde_json::json!("^W-[0-9]+$"), &fs));
        assert!(!eval_predicate("doc_type", "matches",
            &serde_json::json!("^invoice$"), &fs));
    }

    #[test]
    fn invalid_regex_returns_false_no_panic() {
        let c = make_classification(2024, "", "", "", "test", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        // Invalid regex pattern — must return false, not panic.
        assert!(!eval_predicate("doc_type", "matches",
            &serde_json::json!("[[[invalid regex"), &fs));
    }

    #[test]
    fn string_lexicographic_comparisons() {
        let c = make_classification(2024, "2024-03-15", "", "", "", 0.9, vec![]);
        let f = FileFacts { filename: "banana.pdf".to_string(), extension: "pdf".to_string(), size: 0 };
        let fs = FactSet::new(&c, &f);

        // "banana" > "apple" lexicographically
        assert!(eval_predicate("filename", ">",
            &serde_json::json!("apple.pdf"), &fs));
        assert!(!eval_predicate("filename", "<",
            &serde_json::json!("apple.pdf"), &fs));
        assert!(eval_predicate("filename", ">=",
            &serde_json::json!("banana.pdf"), &fs));
        assert!(eval_predicate("filename", "<=",
            &serde_json::json!("cherry.pdf"), &fs));
    }

    // =========================================================================
    // Operator tests — numeric fields (year, confidence, size)
    // =========================================================================

    #[test]
    fn numeric_year_comparisons() {
        let c = make_classification(2024, "2024-01-01", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("year", "equals", &serde_json::json!(2024), &fs));
        assert!(!eval_predicate("year", "equals", &serde_json::json!(2023), &fs));
        assert!(eval_predicate("year", ">", &serde_json::json!(2020), &fs));
        assert!(eval_predicate("year", "<", &serde_json::json!(2025), &fs));
        assert!(eval_predicate("year", ">=", &serde_json::json!(2024), &fs));
        assert!(eval_predicate("year", "<=", &serde_json::json!(2024), &fs));
        assert!(!eval_predicate("year", ">", &serde_json::json!(2024), &fs));
    }

    #[test]
    fn numeric_confidence_comparisons() {
        let c = make_classification(2024, "", "", "", "", 0.85, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("confidence", ">=", &serde_json::json!(0.8), &fs));
        assert!(eval_predicate("confidence", "<", &serde_json::json!(0.9), &fs));
        assert!(!eval_predicate("confidence", "contains", &serde_json::json!("0.85"), &fs));
        assert!(!eval_predicate("confidence", "matches", &serde_json::json!("0.8"), &fs));
    }

    #[test]
    fn numeric_size_comparisons() {
        let c = make_classification(0, "", "", "", "", 0.5, vec![]);
        let f = FileFacts { filename: "doc.pdf".to_string(), extension: "pdf".to_string(), size: 50000 };
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("size", ">", &serde_json::json!(10000), &fs));
        assert!(eval_predicate("size", "<=", &serde_json::json!(50000), &fs));
        assert!(!eval_predicate("size", ">", &serde_json::json!(50000), &fs));
    }

    #[test]
    fn numeric_value_as_string_in_json() {
        // JSON rule_value is a quoted string like "2024" — should still work.
        let c = make_classification(2024, "2024-01-01", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("year", "equals", &serde_json::json!("2024"), &fs));
        assert!(eval_predicate("year", ">", &serde_json::json!("2020"), &fs));
    }

    // =========================================================================
    // Amount field tests
    // =========================================================================

    #[test]
    fn amount_string_ops_work() {
        let c = make_classification(2024, "", "", "1234.56", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("amount", "equals", &serde_json::json!("1234.56"), &fs));
        assert!(eval_predicate("amount", "contains", &serde_json::json!("1234"), &fs));
        assert!(eval_predicate("amount", "matches", &serde_json::json!(r"\d+\.\d+"), &fs));
    }

    #[test]
    fn amount_numeric_comparison() {
        let c = make_classification(2024, "", "", "1234.56", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(eval_predicate("amount", ">", &serde_json::json!(1000.0), &fs));
        assert!(eval_predicate("amount", "<", &serde_json::json!(2000.0), &fs));
        assert!(eval_predicate("amount", ">=", &serde_json::json!(1234.56), &fs));
        assert!(!eval_predicate("amount", ">", &serde_json::json!(5000.0), &fs));
    }

    #[test]
    fn amount_non_parseable_numeric_op_is_false() {
        let c = make_classification(2024, "", "", "N/A", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        // "N/A" cannot be parsed as f64 — numeric ops → false.
        assert!(!eval_predicate("amount", ">", &serde_json::json!(0.0), &fs));
        assert!(!eval_predicate("amount", "<", &serde_json::json!(999999.0), &fs));
    }

    #[test]
    fn empty_amount_numeric_op_is_false() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(!eval_predicate("amount", ">", &serde_json::json!(0.0), &fs));
    }

    // =========================================================================
    // Unknown field / unknown op
    // =========================================================================

    #[test]
    fn unknown_field_returns_false_no_panic() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(!eval_predicate("no_such_field", "equals",
            &serde_json::json!("x"), &fs));
        assert!(!eval_predicate("totally_made_up", ">",
            &serde_json::json!(0), &fs));
    }

    #[test]
    fn unknown_op_returns_false() {
        let c = make_classification(2024, "", "ACME", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        assert!(!eval_predicate("issuer", "startswith",
            &serde_json::json!("ACME"), &fs));
    }

    // =========================================================================
    // ConditionNode tree tests
    // =========================================================================

    #[test]
    fn all_empty_is_true() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        let node = all_of(vec![]);
        assert!(eval_condition(&node, &fs));
    }

    #[test]
    fn any_empty_is_false() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        let node = any_of(vec![]);
        assert!(!eval_condition(&node, &fs));
    }

    #[test]
    fn all_requires_all_children_true() {
        let c = make_classification(2024, "2024-01-15", "ACME", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        let node = all_of(vec![
            pred("year", "equals", serde_json::json!(2024)),
            pred("issuer", "contains", serde_json::json!("acme")),
        ]);
        assert!(eval_condition(&node, &fs));

        let node_fail = all_of(vec![
            pred("year", "equals", serde_json::json!(2024)),
            pred("issuer", "equals", serde_json::json!("other")), // fails
        ]);
        assert!(!eval_condition(&node_fail, &fs));
    }

    #[test]
    fn any_requires_at_least_one_child_true() {
        let c = make_classification(2024, "", "ACME", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        // First child fails, second succeeds.
        let node = any_of(vec![
            pred("issuer", "equals", serde_json::json!("other")),
            pred("issuer", "equals", serde_json::json!("acme")),
        ]);
        assert!(eval_condition(&node, &fs));

        // All children fail.
        let node_fail = any_of(vec![
            pred("issuer", "equals", serde_json::json!("other")),
            pred("issuer", "equals", serde_json::json!("third")),
        ]);
        assert!(!eval_condition(&node_fail, &fs));
    }

    #[test]
    fn nested_all_any_predicate() {
        // {all: [{any: [year=2023, year=2024]}, {issuer contains "acme"}]}
        let c = make_classification(2024, "", "ACME Corp", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let fs = FactSet::new(&c, &f);

        let node = all_of(vec![
            any_of(vec![
                pred("year", "equals", serde_json::json!(2023)),
                pred("year", "equals", serde_json::json!(2024)),
            ]),
            pred("issuer", "contains", serde_json::json!("acme")),
        ]);
        assert!(eval_condition(&node, &fs));

        // year=2022 makes the any fail → all fails.
        let c2 = make_classification(2022, "", "ACME Corp", "", "", 0.9, vec![]);
        let fs2 = FactSet::new(&c2, &f);
        assert!(!eval_condition(&node, &fs2));
    }

    // =========================================================================
    // Rule walk: semantic gate
    // =========================================================================

    #[test]
    fn score_below_threshold_rule_does_not_fire() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("invoice", 0.4)]); // 0.4 < 0.6 threshold
        let f = default_file_facts();
        let rule = make_rule("invoice", 0, 0.6, false, vec![], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert!(!outcome.matched);
        assert!(outcome.fired.is_empty());
    }

    #[test]
    fn score_at_threshold_fires() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("invoice", 0.6)]); // exactly at threshold
        let f = default_file_facts();
        let rule = make_rule("invoice", 0, 0.6, false, vec![], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched);
        assert_eq!(outcome.fired.len(), 1);
        assert_eq!(outcome.fired[0].category, "invoice");
    }

    #[test]
    fn score_above_threshold_fires() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("invoice", 0.95)]);
        let f = default_file_facts();
        let rule = make_rule("invoice", 0, 0.6, false, vec![], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched);
    }

    #[test]
    fn missing_signal_label_treated_as_zero_score() {
        // rule label "tax" has no matching entry in rule_signals → score 0.0.
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("invoice", 0.9)]); // no "tax" signal
        let f = default_file_facts();
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert!(!outcome.matched, "missing signal = 0.0 < 0.6 threshold");
    }

    // =========================================================================
    // Rule walk: conditions gate
    // =========================================================================

    #[test]
    fn conditions_pass_rule_fires() {
        let c = make_classification(2024, "2024-03-01", "IRS", "", "W-2", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        let cond = pred("year", "equals", serde_json::json!(2024));
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", Some(cond), None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched);
    }

    #[test]
    fn conditions_fail_rule_does_not_fire() {
        let c = make_classification(2023, "2023-03-01", "IRS", "", "W-2", 0.9,
            vec![("tax", 0.95)]);
        let f = default_file_facts();
        // Condition requires year=2024 but it's 2023.
        let cond = pred("year", "equals", serde_json::json!(2024));
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", Some(cond), None);

        let outcome = run(&c, &f, &[rule]);
        assert!(!outcome.matched);
    }

    #[test]
    fn none_conditions_always_pass() {
        let c = make_classification(2020, "", "", "", "", 0.9,
            vec![("memories", 0.9)]);
        let f = default_file_facts();
        let rule = make_rule("memories", 0, 0.6, false, vec![], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched);
    }

    // =========================================================================
    // Rule walk: exceptions gate
    // =========================================================================

    #[test]
    fn exceptions_match_rule_does_not_fire() {
        // Score passes, conditions pass, but exception matches → skip.
        let c = make_classification(2024, "", "unknown", "", "", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        let exc = pred("issuer", "equals", serde_json::json!("unknown"));
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", None, Some(exc));

        let outcome = run(&c, &f, &[rule]);
        assert!(!outcome.matched, "exception matched → rule must not fire");
    }

    #[test]
    fn exceptions_no_match_rule_fires() {
        let c = make_classification(2024, "", "IRS", "", "", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        // Exception is "issuer = unknown" but issuer is "IRS" → no exception.
        let exc = pred("issuer", "equals", serde_json::json!("unknown"));
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", None, Some(exc));

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched, "exception did not match → rule should fire");
    }

    #[test]
    fn exceptions_with_conditions_both_must_pass_for_fire() {
        // Conditions pass, exception also matches → net result: no fire.
        let c = make_classification(2024, "", "unknown_issuer", "0.00", "", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        let cond = pred("year", "equals", serde_json::json!(2024));
        let exc = pred("issuer", "contains", serde_json::json!("unknown"));
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", Some(cond), Some(exc));

        let outcome = run(&c, &f, &[rule]);
        assert!(!outcome.matched);
    }

    // =========================================================================
    // Rule walk: order sorting
    // =========================================================================

    #[test]
    fn rules_fire_in_order_ascending() {
        // Two rules; order=5 should fire before order=10.
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("a", 0.9), ("b", 0.9)]);
        let f = default_file_facts();

        // Deliberately put high-order rule first in the slice.
        let rules = vec![
            make_rule("b", 10, 0.6, false, vec![], "", "", None, None),
            make_rule("a", 5, 0.6, false, vec![], "", "", None, None),
        ];

        let outcome = run(&c, &f, &rules);
        assert_eq!(outcome.fired.len(), 2);
        assert_eq!(outcome.fired[0].category, "a", "order=5 must fire first");
        assert_eq!(outcome.fired[1].category, "b", "order=10 must fire second");
    }

    #[test]
    fn ties_broken_by_list_position() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("alpha", 0.9), ("beta", 0.9)]);
        let f = default_file_facts();

        // Both have order=0; list position breaks the tie.
        let rules = vec![
            make_rule("alpha", 0, 0.6, false, vec![], "", "", None, None),
            make_rule("beta", 0, 0.6, false, vec![], "", "", None, None),
        ];

        let outcome = run(&c, &f, &rules);
        assert_eq!(outcome.fired[0].category, "alpha");
        assert_eq!(outcome.fired[1].category, "beta");
    }

    // =========================================================================
    // Rule walk: stop_processing
    // =========================================================================

    #[test]
    fn stop_processing_halts_walk_after_first_fire() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("first", 0.9), ("second", 0.9)]);
        let f = default_file_facts();

        let rules = vec![
            make_rule("first", 1, 0.6, true,  vec![], "", "", None, None), // stop=true
            make_rule("second", 2, 0.6, false, vec![], "", "", None, None),
        ];

        let outcome = run(&c, &f, &rules);
        assert_eq!(outcome.fired.len(), 1, "walk must stop after first rule fires with stop=true");
        assert_eq!(outcome.fired[0].category, "first");
        assert!(outcome.halted);
    }

    #[test]
    fn stop_processing_not_triggered_when_rule_does_not_fire() {
        // Rule with stop=true doesn't fire (score below threshold).
        // Next rule should still be evaluated.
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("stopper", 0.3), ("follower", 0.9)]);
        let f = default_file_facts();

        let rules = vec![
            make_rule("stopper", 1, 0.6, true,  vec![], "", "", None, None), // won't fire
            make_rule("follower", 2, 0.6, false, vec![], "", "", None, None),
        ];

        let outcome = run(&c, &f, &rules);
        assert_eq!(outcome.fired.len(), 1);
        assert_eq!(outcome.fired[0].category, "follower");
        assert!(!outcome.halted);
    }

    #[test]
    fn multiple_rules_fire_when_no_stop() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("r1", 0.9), ("r2", 0.9), ("r3", 0.9)]);
        let f = default_file_facts();

        let rules = vec![
            make_rule("r1", 1, 0.6, false, vec![], "", "", None, None),
            make_rule("r2", 2, 0.6, false, vec![], "", "", None, None),
            make_rule("r3", 3, 0.6, false, vec![], "", "", None, None),
        ];

        let outcome = run(&c, &f, &rules);
        assert_eq!(outcome.fired.len(), 3);
        assert!(!outcome.halted);
    }

    // =========================================================================
    // Rule walk: fan-out (copy_to)
    // =========================================================================

    #[test]
    fn copy_to_multi_element_yields_all_destinations() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        let rule = make_rule("tax", 0, 0.6, false,
            vec!["dest_a", "dest_b", "dest_c"], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert_eq!(outcome.fired[0].copy_to, vec!["dest_a", "dest_b", "dest_c"]);
    }

    #[test]
    fn empty_copy_to_yields_empty_destinations() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        let rule = make_rule("tax", 0, 0.6, false, vec![], "", "", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.fired[0].copy_to.is_empty());
    }

    // =========================================================================
    // Template resolution
    // =========================================================================

    #[test]
    fn template_year_resolved() {
        let c = make_classification(2024, "2024-03-15", "ACME", "", "", 0.9, vec![]);
        let result = resolve_template("{year}/taxes", &c);
        assert_eq!(result, "2024/taxes");
    }

    #[test]
    fn template_date_resolved() {
        let c = make_classification(2024, "2024-03-15", "ACME", "", "", 0.9, vec![]);
        let result = resolve_template("{date}_doc", &c);
        assert_eq!(result, "2024-03-15_doc");
    }

    #[test]
    fn template_issuer_resolved() {
        let c = make_classification(2024, "", "ACME Corp", "", "", 0.9, vec![]);
        let result = resolve_template("{issuer}_report", &c);
        assert_eq!(result, "ACME Corp_report");
    }

    #[test]
    fn template_sender_alias_resolved() {
        let c = make_classification(2024, "", "Bank of Test", "", "", 0.9, vec![]);
        let result = resolve_template("{sender}", &c);
        assert_eq!(result, "Bank of Test");
    }

    #[test]
    fn template_multiple_tokens() {
        let c = make_classification(2024, "2024-07-04", "IRS", "", "", 0.9, vec![]);
        let result = resolve_template("{year}/{issuer}/{date}", &c);
        assert_eq!(result, "2024/IRS/2024-07-04");
    }

    #[test]
    fn template_empty_pattern_returns_empty() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        assert_eq!(resolve_template("", &c), "");
    }

    #[test]
    fn template_unknown_token_passes_through() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        let result = resolve_template("{unknown_token}/path", &c);
        assert_eq!(result, "{unknown_token}/path");
    }

    #[test]
    fn template_year_zero_falls_back_to_doc_date_prefix() {
        // year=0 (not parseable), but doc_date starts with a year.
        let c = make_classification(0, "2022-06-01", "", "", "", 0.9, vec![]);
        let result = resolve_template("{year}", &c);
        assert_eq!(result, "2022");
    }

    #[test]
    fn template_in_fired_action() {
        let c = make_classification(2024, "2024-03-15", "IRS", "", "", 0.9,
            vec![("tax", 0.9)]);
        let f = default_file_facts();
        let rule = make_rule("tax", 0, 0.6, false, vec![],
            "{year}/taxes", "{date}_{issuer}", None, None);

        let outcome = run(&c, &f, &[rule]);
        assert_eq!(outcome.fired[0].resolved_subfolder, "2024/taxes");
        assert_eq!(outcome.fired[0].resolved_rename_pattern, "2024-03-15_IRS");
    }

    #[test]
    fn resolve_template_expands_doc_type_and_description() {
        let long_desc = "A long description ".repeat(6); // 114 chars — over the 60-char cap
        let c = Classification {
            doc_type: "1099".to_string(),
            description: long_desc.clone(),
            issuer: "Payer".to_string(),
            doc_date: "2024-01-01".to_string(),
            year: 2024,
            ..Classification::default()
        };
        let result = resolve_template("{doc_type}_{description}", &c);
        // doc_type must appear.
        assert!(result.contains("1099"), "doc_type missing: {result}");
        // description must be capped at 60 chars.
        let desc_part = result.strip_prefix("1099_").unwrap_or(&result);
        assert_eq!(
            desc_part.len(),
            60,
            "description should be capped at 60 chars, got: {desc_part:?}"
        );
    }

    // =========================================================================
    // Rule walk: no-rule-fires fallback
    // =========================================================================

    #[test]
    fn no_rule_fires_returns_default_category() {
        // All rules have score below threshold.
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("invoice", 0.1)]);
        let f = default_file_facts();

        let default_rule = Rule {
            rule_id: 0,
            label: "memories".to_string(),
            name: "Memories".to_string(),
            instruction: String::new(),
            signals: vec![],
            subfolder: String::new(),
            rename_pattern: String::new(),
            confidence_threshold: 0.6,
            encrypt: false,
            enabled: true,
            is_default: true,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: vec![],
        };
        let invoice_rule = make_rule("invoice", 1, 0.6, false, vec![], "", "", None, None);
        let rules = vec![invoice_rule, default_rule];

        let outcome = run(&c, &f, &rules);
        // Neither rule fires (both below threshold: invoice=0.1 < 0.6, memories missing → 0.0 < 0.6).
        // Fallback should be the first is_default rule.
        assert!(!outcome.matched);
        assert_eq!(outcome.effective_category, "memories");
    }

    #[test]
    fn no_rules_at_all_falls_back_to_unclassified() {
        let c = make_classification(2024, "", "", "", "", 0.9, vec![]);
        let f = default_file_facts();
        let outcome = run(&c, &f, &[]);
        assert!(!outcome.matched);
        assert_eq!(outcome.effective_category, "unclassified");
    }

    // =========================================================================
    // Disabled rules are skipped
    // =========================================================================

    #[test]
    fn disabled_rules_are_not_evaluated() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("disabled_rule", 0.99)]);
        let f = default_file_facts();

        let mut rule = make_rule("disabled_rule", 0, 0.5, false, vec![], "", "", None, None);
        rule.enabled = false;

        let outcome = run(&c, &f, &[rule]);
        assert!(!outcome.matched, "disabled rule must not fire regardless of score");
    }

    // =========================================================================
    // File facts in condition
    // =========================================================================

    #[test]
    fn condition_on_extension_works() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("pdf_rule", 0.9)]);
        let f = FileFacts {
            filename: "report.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 1000,
        };
        let cond = pred("extension", "equals", serde_json::json!("pdf"));
        let rule = make_rule("pdf_rule", 0, 0.6, false, vec![], "", "", Some(cond), None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched);
    }

    #[test]
    fn condition_on_file_size_works() {
        let c = make_classification(2024, "", "", "", "", 0.9,
            vec![("large_doc", 0.9)]);
        let f = FileFacts {
            filename: "big.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 5_000_000,
        };
        let cond = pred("size", ">", serde_json::json!(1_000_000));
        let rule = make_rule("large_doc", 0, 0.6, false, vec![], "", "", Some(cond), None);

        let outcome = run(&c, &f, &[rule]);
        assert!(outcome.matched);
    }

    // =========================================================================
    // Integration: full realistic scenario
    // =========================================================================

    #[test]
    fn integration_w2_with_conditions_and_stop() {
        // Scenario: classify a W-2 with multiple rules.
        // Rule "tax_w2" should fire (score=0.92, year=2024, doc_type=W-2).
        // Rule "invoice" would also score above threshold but has wrong doc_type.
        // Rule "memories" is the default fallback.
        let c = make_classification(
            2024, "2024-03-01", "Employer Corp", "45000.00", "W-2", 0.92,
            vec![("tax_w2", 0.92), ("invoice", 0.1), ("memories", 0.0)],
        );
        let f = FileFacts {
            filename: "w2_2024.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 98000,
        };

        let tax_cond = all_of(vec![
            any_of(vec![
                pred("doc_type", "equals", serde_json::json!("W-2")),
                pred("doc_type", "equals", serde_json::json!("1099")),
            ]),
            pred("year", ">=", serde_json::json!(2020)),
        ]);
        let invoice_cond = pred("doc_type", "equals", serde_json::json!("invoice"));

        let rules = vec![
            make_rule("tax_w2", 1, 0.6, true, vec!["archive_vault"],
                "{year}/taxes", "{date}_{issuer}_w2", Some(tax_cond), None),
            make_rule("invoice", 2, 0.6, false, vec![], "{year}/invoices", "", Some(invoice_cond), None),
            make_rule("memories", 99, 0.6, false, vec![], "", "", None, None),
        ];

        let outcome = run(&c, &f, &rules);

        assert!(outcome.matched);
        assert_eq!(outcome.fired.len(), 1, "stop_processing should halt after tax_w2");
        assert_eq!(outcome.fired[0].category, "tax_w2");
        assert_eq!(outcome.fired[0].copy_to, vec!["archive_vault"]);
        assert_eq!(outcome.fired[0].resolved_subfolder, "2024/taxes");
        assert_eq!(outcome.fired[0].resolved_rename_pattern, "2024-03-01_Employer Corp_w2");
        assert!(outcome.halted);
        assert_eq!(outcome.effective_category, "tax_w2");
    }

    #[test]
    fn integration_no_match_falls_back_to_default() {
        let c = make_classification(2024, "2024-01-01", "Random Co", "", "unknown", 0.5,
            vec![("tax_w2", 0.1), ("invoice", 0.05)]);
        let f = default_file_facts();

        let rules = vec![
            make_rule("tax_w2", 1, 0.7, false, vec![], "", "", None, None),
            make_rule("invoice", 2, 0.7, false, vec![], "", "", None, None),
            Rule {
                rule_id: 0,
                label: "memories".to_string(),
                name: "memories".to_string(),
                instruction: String::new(),
                signals: vec![],
                subfolder: String::new(),
                rename_pattern: String::new(),
                confidence_threshold: 0.0, // always fires when reached
                encrypt: false,
                enabled: true,
                is_default: true,
                conditions: None,
                exceptions: None,
                order: 99,
                stop_processing: false,
                copy_to: vec![],
            },
        ];

        let outcome = run(&c, &f, &rules);
        // tax_w2 and invoice don't fire (scores too low).
        // memories has threshold 0.0 but its signal is missing from rule_signals
        // → treated as score 0.0 ≥ 0.0 → FIRES.
        assert!(outcome.matched);
        assert_eq!(outcome.effective_category, "memories");
    }
}
