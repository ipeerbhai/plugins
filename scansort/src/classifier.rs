//! Document classification prompt builder and response parser.
//!
//! GDScript→Rust port of classifier.gd (115 lines).
//! Uses rules::build_prompt_context for the system prompt.
//! All message construction returns serde_json::Value (OpenAI format).

use crate::rules;
use crate::types::{Classification, Rule};
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

    let category = parsed
        .get("category")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_lowercase();

    if !rules::is_valid_label(rules, &category) {
        return fallback_result(
            response_text,
            &format!("Invalid category: '{category}'"),
            rules,
        );
    }

    let confidence = parsed
        .get("confidence")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    // Accept "issuer" (new) with "sender" as backward-compat alias.
    let issuer = parsed
        .get("issuer")
        .or_else(|| parsed.get("sender"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();
    let description = parsed
        .get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let doc_date = parsed
        .get("date")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    let tags: Vec<String> = parsed
        .get("tags")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|t| t.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    Classification {
        category,
        confidence,
        issuer,
        description,
        doc_date,
        tags,
        raw_response: response_text.to_string(),
        fallback_reason: None,
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fallback_result(raw: &str, reason: &str, rules: &[Rule]) -> Classification {
    Classification {
        category: rules::default_category(rules).to_string(),
        confidence: 0.1,
        issuer: "unknown".to_string(),
        description: "unclassified".to_string(),
        doc_date: String::new(),
        tags: Vec::new(),
        raw_response: raw.to_string(),
        fallback_reason: Some(reason.to_string()),
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
