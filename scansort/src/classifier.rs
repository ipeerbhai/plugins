//! Document classification prompt builder and response parser.
//!
//! GDScript→Rust port of classifier.gd (115 lines).
//! Uses rules::build_prompt_context for the system prompt.
//! All message construction returns serde_json::Value (OpenAI format).

use crate::rules;
use crate::types::{Classification, RuleSignal, Rule};
use serde_json::{json, Value};

// ---------------------------------------------------------------------------
// Message builders
// ---------------------------------------------------------------------------

/// Build OpenAI-format messages for text-mode classification.
pub fn build_messages(document_text: &str, max_chars: usize, rules: &[Rule]) -> Vec<Value> {
    let system_prompt = rules::build_prompt_context(rules);

    let truncated = if document_text.len() > max_chars {
        let mut s = document_text[..max_chars].to_string();
        s.push_str(&format!("\n\n[... truncated at {} chars]", max_chars));
        s
    } else {
        document_text.to_string()
    };

    vec![
        json!({"role": "system", "content": system_prompt}),
        json!({"role": "user", "content": format!("Classify this document:\n\n{}", truncated)}),
    ]
}

/// Build OpenAI-format multimodal messages for vision-mode classification.
///
/// `page_images` elements must have `page_num: i32` and `base64: String` keys.
pub fn build_vision_messages(page_images: &[Value], rules: &[Rule]) -> Vec<Value> {
    let system_prompt = rules::build_prompt_context(rules);

    let mut user_content: Vec<Value> = vec![
        json!({"type": "text", "text": "Classify this scanned document from the page image(s):"}),
    ];

    for page in page_images {
        let b64 = page.get("base64").and_then(|v| v.as_str()).unwrap_or("");
        user_content.push(json!({
            "type": "image_url",
            "image_url": {"url": format!("data:image/png;base64,{}", b64)},
        }));
    }

    vec![
        json!({"role": "system", "content": system_prompt}),
        json!({"role": "user", "content": user_content}),
    ]
}

// ---------------------------------------------------------------------------
// Response parser
// ---------------------------------------------------------------------------

/// Parse an LLM response text into a Classification result.
///
/// Handles raw JSON, markdown-fenced JSON (```json...```), and prose with
/// embedded JSON (simple brace-search fallback). Falls back to the default
/// category when parsing or validation fails.
pub fn parse_response(response_text: &str, rules: &[Rule]) -> Classification {
    let cleaned = strip_markdown_fences(response_text.trim());

    // Primary: try direct parse
    let parsed_opt: Option<serde_json::Map<String, Value>> =
        serde_json::from_str(&cleaned).ok().and_then(|v: Value| {
            if let Value::Object(m) = v {
                Some(m)
            } else {
                None
            }
        });

    // Fallback: find first '{' and last '}' and try parsing that substring.
    let parsed_opt = parsed_opt.or_else(|| {
        if let (Some(start), Some(end)) = (
            response_text.find('{'),
            response_text.rfind('}'),
        ) {
            if end > start {
                let substr = &response_text[start..=end];
                serde_json::from_str(substr).ok().and_then(|v: Value| {
                    if let Value::Object(m) = v {
                        Some(m)
                    } else {
                        None
                    }
                })
            } else {
                None
            }
        } else {
            None
        }
    });

    let parsed = match parsed_opt {
        Some(m) => m,
        None => {
            return fallback_result(response_text, "Failed to parse response as JSON", rules);
        }
    };

    // ── legacy `category` field ────────────────────────────────────────────
    // The LLM may still emit `category` from older prompts; accept it if
    // present and valid, but it is no longer required.
    let category_raw = parsed
        .get("category")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_lowercase();

    // If the LLM emitted an explicit category, validate it; otherwise derive
    // the best category from rule_signals (highest-scoring enabled rule).
    let category: String = if !category_raw.is_empty() {
        if rules::is_valid_label(rules, &category_raw) {
            category_raw
        } else {
            // Invalid label — derive from rule_signals below (handled after we
            // parse rule_signals) or fall back to default.
            String::new()
        }
    } else {
        String::new()
    };

    // ── confidence ─────────────────────────────────────────────────────────
    let confidence = parsed
        .get("confidence")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0)
        .clamp(0.0, 1.0);

    // ── issuer: accept "issuer" (W1+) or legacy "sender" ──────────────────
    let issuer = parsed
        .get("issuer")
        .or_else(|| parsed.get("sender"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // ── description ────────────────────────────────────────────────────────
    let description = parsed
        .get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // ── doc_date: accept "doc_date" (W2) or legacy "date" ─────────────────
    let doc_date = parsed
        .get("doc_date")
        .or_else(|| parsed.get("date"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    // ── year: derive from doc_date if not explicitly provided ─────────────
    let year: i32 = parsed
        .get("year")
        .and_then(|v| v.as_i64())
        .map(|y| y as i32)
        .unwrap_or_else(|| {
            // Try to parse YYYY from the first 4 chars of doc_date.
            if doc_date.len() >= 4 {
                doc_date[..4].parse::<i32>().unwrap_or(0)
            } else {
                0
            }
        });

    // ── tags ───────────────────────────────────────────────────────────────
    let tags: Vec<String> = parsed
        .get("tags")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|t| t.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    // ── doc_type (W2) ──────────────────────────────────────────────────────
    let doc_type = parsed
        .get("doc_type")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // ── amount (W2) ────────────────────────────────────────────────────────
    let amount = parsed
        .get("amount")
        .and_then(|v| {
            // Accept string or number.
            if let Some(s) = v.as_str() {
                Some(s.to_string())
            } else if let Some(n) = v.as_f64() {
                Some(format!("{n}"))
            } else {
                None
            }
        })
        .unwrap_or_default();

    // ── rule_signals (W2) ─────────────────────────────────────────────────
    // Build a score map from the LLM response, then ensure every enabled rule
    // has an entry (default 0.0 for missing ones).
    let llm_scores: std::collections::HashMap<String, f64> = parsed
        .get("rule_signals")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|entry| {
                    let label = entry.get("label")?.as_str()?.to_string();
                    let score = entry
                        .get("score")
                        .and_then(|s| s.as_f64())
                        .unwrap_or(0.0)
                        .clamp(0.0, 1.0);
                    Some((label, score))
                })
                .collect()
        })
        .unwrap_or_default();

    let rule_signals: Vec<RuleSignal> = rules
        .iter()
        .filter(|r| r.enabled)
        .map(|r| RuleSignal {
            label: r.label.clone(),
            score: llm_scores.get(&r.label).copied().unwrap_or(0.0),
        })
        .collect();

    // ── derive category from rule_signals when not explicit ───────────────
    let category = if !category.is_empty() {
        category
    } else {
        // Best-scoring enabled rule wins; fall back to default if all 0.
        rule_signals
            .iter()
            .max_by(|a, b| a.score.partial_cmp(&b.score).unwrap_or(std::cmp::Ordering::Equal))
            .filter(|sig| sig.score > 0.0)
            .map(|sig| sig.label.clone())
            .unwrap_or_else(|| rules::default_category(rules).to_string())
    };

    Classification {
        category,
        confidence,
        issuer,
        description,
        doc_date,
        tags,
        raw_response: response_text.to_string(),
        fallback_reason: None,
        doc_type,
        amount,
        year,
        rule_signals,
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fallback_result(raw: &str, reason: &str, rules: &[Rule]) -> Classification {
    // Emit 0.0 for every enabled rule so W3 still gets a well-formed envelope.
    let rule_signals: Vec<RuleSignal> = rules
        .iter()
        .filter(|r| r.enabled)
        .map(|r| RuleSignal {
            label: r.label.clone(),
            score: 0.0,
        })
        .collect();

    Classification {
        category: rules::default_category(rules).to_string(),
        confidence: 0.0,
        issuer: String::new(),
        description: String::new(),
        doc_date: String::new(),
        tags: Vec::new(),
        raw_response: raw.to_string(),
        fallback_reason: Some(reason.to_string()),
        doc_type: String::new(),
        amount: String::new(),
        year: 0,
        rule_signals,
    }
}

/// Remove ```json ... ``` or ``` ... ``` fences from a string.
pub fn strip_markdown_fences(text: &str) -> String {
    let mut s = text.to_string();

    if s.starts_with("```json") {
        s = s[7..].to_string();
    } else if s.starts_with("```") {
        s = s[3..].to_string();
    }

    if s.ends_with("```") {
        let new_len = s.len() - 3;
        s.truncate(new_len);
    }

    s.trim().to_string()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Rule;

    fn make_rule(label: &str, instruction: &str, enabled: bool) -> Rule {
        Rule {
            label: label.to_string(),
            instruction: instruction.to_string(),
            enabled,
            ..Default::default()
        }
    }

    fn two_rules() -> Vec<Rule> {
        vec![
            make_rule("tax", "Tax documents such as W-2, 1099, or tax returns.", true),
            make_rule("invoice", "Invoices, bills, and payment requests.", true),
        ]
    }

    // ── Test 1: well-formed LLM response — all fields populated ───────────

    #[test]
    fn parse_full_response_all_fields() {
        let rules = two_rules();
        let json = r#"{
            "doc_date": "2024-04-15",
            "issuer": "ACME Corp",
            "amount": "1234.56",
            "doc_type": "invoice",
            "description": "Invoice from ACME Corp for services rendered.",
            "tags": ["invoice", "payment"],
            "confidence": 0.95,
            "rule_signals": [
                {"label": "tax",     "score": 0.05},
                {"label": "invoice", "score": 0.92}
            ]
        }"#;

        let c = parse_response(json, &rules);
        assert_eq!(c.doc_date, "2024-04-15");
        assert_eq!(c.year, 2024);
        assert_eq!(c.issuer, "ACME Corp");
        assert_eq!(c.amount, "1234.56");
        assert_eq!(c.doc_type, "invoice");
        assert!(!c.description.is_empty());
        assert_eq!(c.tags, vec!["invoice", "payment"]);
        assert!((c.confidence - 0.95).abs() < 1e-9);
        assert_eq!(c.rule_signals.len(), 2);

        let tax_sig = c.rule_signals.iter().find(|s| s.label == "tax").unwrap();
        let inv_sig = c.rule_signals.iter().find(|s| s.label == "invoice").unwrap();
        assert!((tax_sig.score - 0.05).abs() < 1e-9);
        assert!((inv_sig.score - 0.92).abs() < 1e-9);

        // Category derived from highest-scoring rule (no explicit `category` key).
        assert_eq!(c.category, "invoice");
        assert!(c.fallback_reason.is_none());
    }

    // ── Test 2: tolerance — missing rule scores default to 0.0 ────────────

    #[test]
    fn parse_response_missing_rule_scores_default_zero() {
        let rules = two_rules();
        // LLM only scored one of the two rules.
        let json = r#"{
            "doc_date": "2023-01-31",
            "issuer": "IRS",
            "doc_type": "W-2",
            "description": "W-2 wage and tax statement.",
            "confidence": 0.88,
            "rule_signals": [
                {"label": "tax", "score": 0.91}
            ]
        }"#;

        let c = parse_response(json, &rules);
        assert_eq!(c.rule_signals.len(), 2, "must have one entry per enabled rule");

        let tax_sig = c.rule_signals.iter().find(|s| s.label == "tax").unwrap();
        let inv_sig = c.rule_signals.iter().find(|s| s.label == "invoice").unwrap();
        assert!((tax_sig.score - 0.91).abs() < 1e-9);
        assert!((inv_sig.score - 0.0).abs() < 1e-9, "missing rule defaults to 0.0");

        // Missing facts default sensibly.
        assert_eq!(c.amount, "");
        assert_eq!(c.doc_type, "W-2");
        assert_eq!(c.year, 2023);
    }

    // ── Test 3: tolerance — missing facts default sensibly ────────────────

    #[test]
    fn parse_response_missing_facts_default_sensibly() {
        let rules = two_rules();
        // Minimal response — only rule_signals.
        let json = r#"{
            "rule_signals": [
                {"label": "tax",     "score": 0.1},
                {"label": "invoice", "score": 0.2}
            ]
        }"#;

        let c = parse_response(json, &rules);
        assert_eq!(c.doc_date, "", "missing doc_date -> empty string");
        assert_eq!(c.year, 0, "missing year -> 0");
        assert_eq!(c.issuer, "", "missing issuer -> empty string");
        assert_eq!(c.amount, "", "missing amount -> empty string");
        assert_eq!(c.doc_type, "", "missing doc_type -> empty string");
        assert_eq!(c.tags, Vec::<String>::new());
        assert_eq!(c.rule_signals.len(), 2);
        assert!(c.fallback_reason.is_none());
    }

    // ── Test 4: build_prompt_context asks for facts + per-rule scores ──────

    #[test]
    fn prompt_contains_facts_and_per_rule_score_request() {
        let rules = two_rules();
        let prompt = rules::build_prompt_context(&rules);

        // Must mention the facts block keys.
        assert!(prompt.contains("doc_date"), "prompt must request doc_date");
        assert!(prompt.contains("issuer"),   "prompt must request issuer");
        assert!(prompt.contains("amount"),   "prompt must request amount");
        assert!(prompt.contains("doc_type"), "prompt must request doc_type");
        assert!(prompt.contains("confidence"), "prompt must request confidence");

        // Must mention rule_signals.
        assert!(prompt.contains("rule_signals"), "prompt must request rule_signals");

        // Must embed each enabled rule label so the LLM knows what to score.
        assert!(prompt.contains("tax"),     "prompt must list rule label 'tax'");
        assert!(prompt.contains("invoice"), "prompt must list rule label 'invoice'");

        // Must ask for a score per rule, not just a single category.
        assert!(prompt.contains("score"), "prompt must ask for a score per rule");
        // Must make clear all rules should be scored.
        assert!(
            prompt.contains("ALL") || prompt.contains("every") || prompt.contains("EVERY") || prompt.contains("each"),
            "prompt must instruct the LLM to score all rules"
        );
    }

    // ── Test 5: prompt omits disabled rules ────────────────────────────────

    #[test]
    fn prompt_omits_disabled_rules() {
        let rules = vec![
            make_rule("tax",     "Tax documents.", true),
            make_rule("ignored", "Disabled rule.", false),
        ];
        let prompt = rules::build_prompt_context(&rules);
        assert!(prompt.contains("tax"), "enabled rule must appear");
        assert!(!prompt.contains("ignored"), "disabled rule must NOT appear in rule list");
    }

    // ── Test 6: integration — small rule set + simulated LLM JSON ─────────
    // Verifies the full parse path produces a well-formed envelope for W3.

    #[test]
    fn integration_parse_produces_w3_ready_envelope() {
        let rules = vec![
            make_rule("tax",     "Tax returns, W-2s, 1099s, and similar IRS forms.", true),
            make_rule("invoice", "Invoices and bills from vendors.",                 true),
            make_rule("medical", "Medical bills, EOBs, and lab results.",            true),
        ];

        // Simulate a well-formed LLM JSON response.
        let llm_json = r#"{
            "doc_date":    "2023-03-15",
            "issuer":      "General Hospital",
            "amount":      "450.00",
            "doc_type":    "medical bill",
            "description": "Hospital bill for outpatient procedure.",
            "tags":        ["medical", "hospital", "bill"],
            "confidence":  0.87,
            "rule_signals": [
                {"label": "tax",     "score": 0.02},
                {"label": "invoice", "score": 0.15},
                {"label": "medical", "score": 0.89}
            ]
        }"#;

        let c = parse_response(llm_json, &rules);

        // W3-readiness: every enabled rule has a signal entry.
        assert_eq!(c.rule_signals.len(), 3, "one signal per enabled rule");
        let labels: Vec<&str> = c.rule_signals.iter().map(|s| s.label.as_str()).collect();
        assert!(labels.contains(&"tax"));
        assert!(labels.contains(&"invoice"));
        assert!(labels.contains(&"medical"));

        // All scores are in [0, 1].
        for sig in &c.rule_signals {
            assert!(sig.score >= 0.0 && sig.score <= 1.0, "score out of range: {}", sig.score);
        }

        // Category derived correctly.
        assert_eq!(c.category, "medical");
        assert_eq!(c.year, 2023);
        assert_eq!(c.doc_type, "medical bill");
        assert_eq!(c.amount, "450.00");
        assert!(c.fallback_reason.is_none());
    }

    // ── Test 7: fallback result still produces well-formed W3 envelope ─────

    #[test]
    fn fallback_result_produces_well_formed_envelope() {
        let rules = two_rules();
        // Completely unparseable response.
        let c = parse_response("not json at all", &rules);

        assert!(c.fallback_reason.is_some(), "must record fallback reason");
        assert_eq!(c.rule_signals.len(), 2, "fallback must still emit one signal per enabled rule");
        for sig in &c.rule_signals {
            assert_eq!(sig.score, 0.0, "fallback signals must be 0.0");
        }
        assert_eq!(c.year, 0);
        assert_eq!(c.amount, "");
        assert_eq!(c.doc_type, "");
    }

    // ── Test 8: legacy `sender` alias is still accepted ───────────────────

    #[test]
    fn legacy_sender_alias_accepted() {
        let rules = two_rules();
        let json = r#"{
            "doc_date": "2022-12-01",
            "sender": "Old Sender Corp",
            "doc_type": "receipt",
            "confidence": 0.7,
            "rule_signals": [
                {"label": "tax",     "score": 0.0},
                {"label": "invoice", "score": 0.7}
            ]
        }"#;

        let c = parse_response(json, &rules);
        assert_eq!(c.issuer, "Old Sender Corp", "sender alias must map to issuer");
    }

    // ── Test 9: year derived from doc_date when year field absent ──────────

    #[test]
    fn year_derived_from_doc_date() {
        let rules = two_rules();
        let json = r#"{
            "doc_date": "2021-07-04",
            "confidence": 0.5,
            "rule_signals": []
        }"#;
        let c = parse_response(json, &rules);
        assert_eq!(c.year, 2021);
    }

    // ── Test 10: amount accepts numeric value from LLM ────────────────────

    #[test]
    fn amount_accepts_numeric_value() {
        let rules = two_rules();
        let json = r#"{
            "doc_date": "2024-01-01",
            "amount": 9876.54,
            "confidence": 0.6,
            "rule_signals": [
                {"label": "tax",     "score": 0.1},
                {"label": "invoice", "score": 0.6}
            ]
        }"#;
        let c = parse_response(json, &rules);
        assert!(!c.amount.is_empty(), "numeric amount must be non-empty");
        assert!(c.amount.contains("9876"), "amount must contain the value");
    }
}
