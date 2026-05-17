//! W2 (DCR 019e33bf): per-rule classification pipeline.
//!
//! For each rule that passed Phase-1 thresholding, walk its `stages` array.
//! Each stage = one LLM round consisting of:
//!   1. an `ask` question
//!   2. a `classify` map of named extraction slots (closed list or open NL)
//!   3. an optional `keep_when` expression that gates whether the rule is
//!      kept-or-filtered after this stage's slots are populated
//!
//! Slot values accumulate across stages; later stages' templates and filters
//! can reference earlier stages' slots (cross-stage prompt templating is
//! disallowed by DCR §"Scope: OUT").
//!
//! ### Stage-folding optimisation
//!
//! Adjacent stages with `keep_when: None` are composed into a single LLM
//! call: their `classify` slots are merged and the asks concatenated. This
//! keeps the LLM-call count proportional to the number of *gates*, not the
//! number of asks. Author-invisible.
//!
//! ### Filter grammar (`keep_when`)
//!
//! Per DCR §"Design choices" — minimal grammar only:
//!   - `slot == 'value'`
//!   - `slot != 'value'`
//!   - `slot in ['a', 'b', 'c']`
//!
//! Unknown grammar / parse failure → `keep_when` evaluates *false* (defensive:
//! a malformed filter never silently passes a document through).

use crate::types::{Rule, Slot, SlotValues, Stage};
use serde_json::{json, Value};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Trait the engine uses to make one LLM round. Real implementations live in
/// `process.rs` (delegates to host.providers.chat) and `dryrun_one`. Tests
/// pass a mock implementation.
pub trait LlmCaller {
    /// Issue one chat completion with OpenAI-format `messages`. Return the
    /// raw assistant text. The walker parses that text into slot values.
    fn call(&mut self, messages: Vec<Value>) -> Result<String, String>;
}

/// Per-stage trace event emitted by the walker. Used by `dryrun_one` to
/// surface stage-by-stage execution to the UI; also forms the basis of the
/// `stage_executed` trace-log event (DCR 019e33a2).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct StageTrace {
    pub ask: String,
    pub slot_values: BTreeMap<String, String>,
    pub keep_when: Option<String>,
    pub kept: bool,
}

/// The result of walking one rule's pipeline.
#[derive(Debug, Clone, serde::Serialize)]
pub struct StageWalkOutcome {
    /// True if any stage's `keep_when` evaluated false (doc filtered for this rule).
    pub filtered: bool,
    /// Accumulated slot values across all stages that ran. When `filtered`, this
    /// reflects the slots populated up to the point of the filter failure.
    pub slots: BTreeMap<String, String>,
    /// Stage-by-stage trace for diagnostics / `dryrun_one`.
    pub stages_executed: Vec<StageTrace>,
    /// Number of LLM calls actually issued (≤ stage count due to folding).
    pub llm_calls: u32,
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Walk every stage in `rule.stages`, issuing LLM calls (stage-folded where
/// possible), populating slot values, and evaluating `keep_when` after each
/// gate. Returns the outcome including whether the doc was filtered out.
///
/// A rule with no stages returns `StageWalkOutcome::default()` (no LLM calls,
/// no slots, not filtered). The engine then resolves its templates against
/// the Phase-1 classification facts (legacy path).
pub fn walk(
    rule: &Rule,
    document_text: &str,
    llm: &mut dyn LlmCaller,
) -> StageWalkOutcome {
    let mut outcome = StageWalkOutcome::default();
    if rule.stages.is_empty() {
        return outcome;
    }

    // Build fold groups: each group is a non-empty consecutive run of stages
    // such that only the *last* stage in the group has a keep_when (or the
    // group ends because the next stage starts a new keep_when gate).
    //
    // Concretely: walk the stages, greedily grow a group; whenever the
    // current stage has `keep_when = Some`, the group ends with that stage.
    let groups = fold_groups(&rule.stages);

    for group in groups {
        let merged_ask: String = group
            .iter()
            .map(|s| s.ask.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");
        let merged_classify: BTreeMap<&String, &Slot> = group
            .iter()
            .flat_map(|s| s.classify.iter())
            .collect();

        let messages = build_stage_messages(&merged_ask, &merged_classify, document_text);
        let response_text = match llm.call(messages) {
            Ok(t) => t,
            Err(e) => {
                log::warn!("stage_walker: LLM call failed: {e}");
                // Defensive: treat LLM failure as if all slots in this group
                // produced "unknown". Subsequent keep_when (if any) likely
                // filters the doc out, which is the safe behavior.
                for stage in &group {
                    for name in stage.classify.keys() {
                        outcome.slots.entry(name.clone()).or_insert_with(|| "unknown".to_string());
                    }
                }
                outcome.llm_calls += 1;
                // Emit one trace per stage in the group so the failure is visible.
                for stage in &group {
                    outcome.stages_executed.push(StageTrace {
                        ask: stage.ask.clone(),
                        slot_values: stage
                            .classify
                            .keys()
                            .map(|k| (k.clone(), outcome.slots.get(k).cloned().unwrap_or_else(|| "unknown".to_string())))
                            .collect(),
                        keep_when: stage.keep_when.clone(),
                        kept: false,
                    });
                }
                outcome.filtered = true;
                return outcome;
            }
        };
        outcome.llm_calls += 1;

        // Parse the response into slot values, validating closed-list slots.
        let parsed = parse_slot_response(&response_text, &merged_classify);
        for (k, v) in parsed.iter() {
            outcome.slots.insert(k.clone(), v.clone());
        }
        // Fill missing slots (LLM didn't return them) with "unknown".
        for name in merged_classify.keys() {
            outcome.slots.entry((*name).clone()).or_insert_with(|| "unknown".to_string());
        }

        // Per-stage trace, evaluating keep_when on the stage that owns it.
        for (idx, stage) in group.iter().enumerate() {
            let stage_slot_view: BTreeMap<String, String> = stage
                .classify
                .keys()
                .map(|k| (k.clone(), outcome.slots.get(k).cloned().unwrap_or_else(|| "unknown".to_string())))
                .collect();
            let is_last_in_group = idx + 1 == group.len();
            let (kept, recorded_filter) = if is_last_in_group {
                match stage.keep_when.as_deref() {
                    Some(expr) => (eval_keep_when(expr, &outcome.slots), Some(expr.to_string())),
                    None => (true, None),
                }
            } else {
                // Non-terminal stages in a fold-group, by definition, have no keep_when.
                (true, None)
            };
            outcome.stages_executed.push(StageTrace {
                ask: stage.ask.clone(),
                slot_values: stage_slot_view,
                keep_when: recorded_filter,
                kept,
            });
            if !kept {
                outcome.filtered = true;
                return outcome;
            }
        }
    }

    outcome
}

impl Default for StageWalkOutcome {
    fn default() -> Self {
        Self {
            filtered: false,
            slots: BTreeMap::new(),
            stages_executed: Vec::new(),
            llm_calls: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// Stage folding
// ---------------------------------------------------------------------------

/// Group adjacent stages into fold-groups: each group ends at the first stage
/// with `keep_when = Some`, or at the end of the array. The last stage in a
/// group is the only one that may carry a `keep_when`.
fn fold_groups<'a>(stages: &'a [Stage]) -> Vec<Vec<&'a Stage>> {
    let mut groups: Vec<Vec<&'a Stage>> = Vec::new();
    let mut current: Vec<&'a Stage> = Vec::new();
    for stage in stages {
        current.push(stage);
        if stage.keep_when.is_some() {
            groups.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        groups.push(current);
    }
    groups
}

// ---------------------------------------------------------------------------
// Prompt construction
// ---------------------------------------------------------------------------

fn build_stage_messages(
    ask: &str,
    classify: &BTreeMap<&String, &Slot>,
    document_text: &str,
) -> Vec<Value> {
    let mut lines: Vec<String> = Vec::new();
    lines.push("You are a document classifier. Answer the question(s) by filling in the named slots below.".to_string());
    lines.push(String::new());
    lines.push("## Question(s)".to_string());
    lines.push(ask.to_string());
    lines.push(String::new());
    lines.push("## Slots to fill".to_string());
    for (name, slot) in classify {
        let values_line = match &slot.values {
            SlotValues::Closed(list) => {
                let quoted: Vec<String> = list.iter().map(|s| format!("'{}'", s)).collect();
                format!("Allowed values: {} (pick exactly one). If none apply, return 'unknown'.", quoted.join(", "))
            }
            SlotValues::Open(constraint) => {
                format!("Expected: {}.", constraint)
            }
        };
        lines.push(format!("- {name} — {}. {values_line}", slot.description));
    }
    lines.push(String::new());
    lines.push("## Output format".to_string());
    let example_keys: Vec<String> = classify
        .keys()
        .map(|k| format!("\"{}\": \"<value>\"", k))
        .collect();
    lines.push(format!(
        "Respond with a single JSON object, no prose, no markdown fences:\n{{{}}}",
        example_keys.join(", ")
    ));

    vec![
        json!({"role": "system", "content": lines.join("\n")}),
        json!({"role": "user", "content": format!("Document:\n\n{document_text}")}),
    ]
}

// ---------------------------------------------------------------------------
// Response parsing — extract slot values from LLM JSON
// ---------------------------------------------------------------------------

fn parse_slot_response(
    response_text: &str,
    classify: &BTreeMap<&String, &Slot>,
) -> BTreeMap<String, String> {
    let cleaned = strip_markdown_fences(response_text.trim());

    // Try direct parse first, then bracket-search fallback.
    let parsed: Option<serde_json::Map<String, Value>> = serde_json::from_str(&cleaned)
        .ok()
        .and_then(|v: Value| match v {
            Value::Object(m) => Some(m),
            _ => None,
        })
        .or_else(|| {
            if let (Some(start), Some(end)) = (response_text.find('{'), response_text.rfind('}')) {
                if end > start {
                    return serde_json::from_str::<Value>(&response_text[start..=end])
                        .ok()
                        .and_then(|v| if let Value::Object(m) = v { Some(m) } else { None });
                }
            }
            None
        });

    let mut out: BTreeMap<String, String> = BTreeMap::new();
    let Some(obj) = parsed else {
        return out;
    };
    for (name, slot) in classify {
        let raw = obj.get(name.as_str()).and_then(|v| value_to_string(v));
        let final_value = match (raw, &slot.values) {
            (Some(s), SlotValues::Closed(allowed)) => {
                if allowed.iter().any(|a| a.eq_ignore_ascii_case(&s)) {
                    // Canonicalise to the exact spelling in the allowed list.
                    allowed
                        .iter()
                        .find(|a| a.eq_ignore_ascii_case(&s))
                        .cloned()
                        .unwrap_or(s)
                } else {
                    "unknown".to_string()
                }
            }
            (Some(s), SlotValues::Open(_)) => s,
            (None, _) => "unknown".to_string(),
        };
        out.insert((*name).clone(), final_value);
    }
    out
}

fn value_to_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Null => None,
        _ => Some(v.to_string()),
    }
}

fn strip_markdown_fences(text: &str) -> String {
    let trimmed = text.trim();
    if let Some(rest) = trimmed.strip_prefix("```json") {
        return rest.trim_start().trim_end_matches("```").trim().to_string();
    }
    if let Some(rest) = trimmed.strip_prefix("```") {
        return rest.trim_start().trim_end_matches("```").trim().to_string();
    }
    trimmed.to_string()
}

// ---------------------------------------------------------------------------
// keep_when expression evaluation (minimal grammar)
// ---------------------------------------------------------------------------

/// Evaluate a `keep_when` expression against accumulated slot values.
/// Grammar: `<slot> ==/!= '<value>'` or `<slot> in ['<a>', '<b>', ...]`.
/// Returns `false` on any parse failure (defensive).
pub fn eval_keep_when(expr: &str, slots: &BTreeMap<String, String>) -> bool {
    let expr = expr.trim();
    if expr.is_empty() {
        return true;
    }

    // Try `in [...]` form first.
    if let Some(parsed) = parse_in_expr(expr) {
        let (slot, allowed) = parsed;
        let value = slots.get(&slot).map(String::as_str).unwrap_or("");
        return allowed.iter().any(|a| a.eq_ignore_ascii_case(value));
    }

    // `==` / `!=` form.
    for (op, equals) in [("==", true), ("!=", false)] {
        if let Some(idx) = expr.find(op) {
            let (lhs, rhs) = expr.split_at(idx);
            let slot = lhs.trim().to_string();
            let rhs = rhs[op.len()..].trim();
            let value = match strip_quotes(rhs) {
                Some(v) => v,
                None => return false,
            };
            let actual = slots.get(&slot).map(String::as_str).unwrap_or("");
            let matches = actual.eq_ignore_ascii_case(&value);
            return if equals { matches } else { !matches };
        }
    }

    false
}

fn parse_in_expr(expr: &str) -> Option<(String, Vec<String>)> {
    // Pattern: <slot> in [ '<v1>', '<v2>', ... ]
    let lower = expr.to_ascii_lowercase();
    let in_idx = lower.find(" in ")?;
    let slot = expr[..in_idx].trim().to_string();
    let rest = expr[in_idx + 4..].trim();
    let body = rest.strip_prefix('[').and_then(|s| s.strip_suffix(']'))?.trim();
    let mut values: Vec<String> = Vec::new();
    for raw in body.split(',') {
        let v = strip_quotes(raw.trim())?;
        values.push(v);
    }
    Some((slot, values))
}

fn strip_quotes(s: &str) -> Option<String> {
    let s = s.trim();
    let (open, close) = (s.chars().next()?, s.chars().last()?);
    if (open == '\'' && close == '\'') || (open == '"' && close == '"') {
        if s.len() >= 2 {
            return Some(s[1..s.len() - 1].to_string());
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Subtype;

    /// Scripted LLM caller: returns canned responses in order, counts calls.
    struct ScriptedLlm {
        responses: Vec<String>,
        calls: u32,
        last_messages: Vec<Vec<Value>>,
    }

    impl ScriptedLlm {
        fn new(responses: Vec<&str>) -> Self {
            Self {
                responses: responses.into_iter().map(String::from).collect(),
                calls: 0,
                last_messages: Vec::new(),
            }
        }
    }

    impl LlmCaller for ScriptedLlm {
        fn call(&mut self, messages: Vec<Value>) -> Result<String, String> {
            self.last_messages.push(messages);
            let idx = self.calls as usize;
            self.calls += 1;
            if idx >= self.responses.len() {
                return Err(format!("ScriptedLlm out of responses (call #{})", idx + 1));
            }
            Ok(self.responses[idx].clone())
        }
    }

    fn make_rule_with_stages(label: &str, stages: Vec<Stage>) -> Rule {
        Rule {
            rule_id: 0,
            label: label.to_string(),
            name: label.to_string(),
            instruction: String::new(),
            signals: vec![],
            subfolder: String::new(),
            rename_pattern: String::new(),
            confidence_threshold: 0.5,
            encrypt: false,
            enabled: true,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: vec![],
            subtypes: Vec::<Subtype>::new(),
            stages,
        }
    }

    fn mk_stage(ask: &str, slots: Vec<(&str, Slot)>, keep_when: Option<&str>) -> Stage {
        let mut classify = BTreeMap::new();
        for (k, v) in slots {
            classify.insert(k.to_string(), v);
        }
        Stage {
            ask: ask.to_string(),
            classify,
            keep_when: keep_when.map(String::from),
        }
    }

    fn closed_slot(desc: &str, values: &[&str]) -> Slot {
        Slot {
            description: desc.to_string(),
            values: SlotValues::Closed(values.iter().map(|s| s.to_string()).collect()),
        }
    }

    fn open_slot(desc: &str, constraint: &str) -> Slot {
        Slot {
            description: desc.to_string(),
            values: SlotValues::Open(constraint.to_string()),
        }
    }

    // ----- single-stage rule -----------------------------------------------

    #[test]
    fn single_stage_rule_extracts_slots_and_is_not_filtered() {
        let rule = make_rule_with_stages(
            "drawings",
            vec![mk_stage(
                "What does this drawing show?",
                vec![("subject", open_slot("subject", "a short phrase"))],
                None,
            )],
        );
        let mut llm = ScriptedLlm::new(vec![r#"{"subject": "a rocket ship"}"#]);
        let out = walk(&rule, "doc text", &mut llm);
        assert!(!out.filtered);
        assert_eq!(out.llm_calls, 1);
        assert_eq!(out.slots.get("subject").map(String::as_str), Some("a rocket ship"));
        assert_eq!(out.stages_executed.len(), 1);
        assert!(out.stages_executed[0].kept);
    }

    // ----- multi-stage with filter that PASSES ------------------------------

    #[test]
    fn multi_stage_filter_passes_continues_to_next_stage() {
        let rule = make_rule_with_stages(
            "tax",
            vec![
                mk_stage(
                    "Is this tax-relevant?",
                    vec![("is_tax", closed_slot("tax-relevant", &["yes", "no"]))],
                    Some("is_tax == 'yes'"),
                ),
                mk_stage(
                    "Whose form?",
                    vec![("client", open_slot("name", "a person's name, or 'unknown'"))],
                    None,
                ),
            ],
        );
        let mut llm = ScriptedLlm::new(vec![
            r#"{"is_tax": "yes"}"#,
            r#"{"client": "Smith"}"#,
        ]);
        let out = walk(&rule, "doc text", &mut llm);
        assert!(!out.filtered);
        assert_eq!(out.llm_calls, 2);
        assert_eq!(out.slots.get("is_tax").map(String::as_str), Some("yes"));
        assert_eq!(out.slots.get("client").map(String::as_str), Some("Smith"));
        assert_eq!(out.stages_executed.len(), 2);
    }

    // ----- multi-stage with filter that FAILS -------------------------------

    #[test]
    fn multi_stage_filter_fails_filters_doc_and_stops() {
        let rule = make_rule_with_stages(
            "tax",
            vec![
                mk_stage(
                    "Is this tax-relevant?",
                    vec![("is_tax", closed_slot("tax-relevant", &["yes", "no"]))],
                    Some("is_tax == 'yes'"),
                ),
                mk_stage(
                    "Whose form?",
                    vec![("client", open_slot("name", "a person's name, or 'unknown'"))],
                    None,
                ),
            ],
        );
        // First stage returns is_tax=no — filter fails, second stage must NOT run.
        let mut llm = ScriptedLlm::new(vec![r#"{"is_tax": "no"}"#]);
        let out = walk(&rule, "doc text", &mut llm);
        assert!(out.filtered, "doc must be filtered when keep_when fails");
        assert_eq!(out.llm_calls, 1, "second LLM call must not happen after filter failure");
        assert_eq!(out.stages_executed.len(), 1);
        assert!(!out.stages_executed[0].kept);
    }

    // ----- slot accumulation across stages ----------------------------------

    #[test]
    fn slots_accumulate_across_stages() {
        let rule = make_rule_with_stages(
            "multi",
            vec![
                mk_stage(
                    "What kind?",
                    vec![("kind", closed_slot("kind", &["a", "b"]))],
                    Some("kind != 'unknown'"),
                ),
                mk_stage(
                    "What year?",
                    vec![("year", open_slot("year", "YYYY"))],
                    None,
                ),
            ],
        );
        let mut llm = ScriptedLlm::new(vec![
            r#"{"kind": "a"}"#,
            r#"{"year": "2024"}"#,
        ]);
        let out = walk(&rule, "doc text", &mut llm);
        assert!(!out.filtered);
        assert_eq!(out.slots.get("kind").map(String::as_str), Some("a"));
        assert_eq!(out.slots.get("year").map(String::as_str), Some("2024"));
    }

    // ----- missing-slot fallback to "unknown" -------------------------------

    #[test]
    fn missing_slot_in_response_falls_back_to_unknown() {
        let rule = make_rule_with_stages(
            "r",
            vec![mk_stage(
                "Q",
                vec![
                    ("a", open_slot("a", "x")),
                    ("b", open_slot("b", "y")),
                ],
                None,
            )],
        );
        // LLM returns only `a`; `b` must default to "unknown".
        let mut llm = ScriptedLlm::new(vec![r#"{"a": "alpha"}"#]);
        let out = walk(&rule, "doc text", &mut llm);
        assert_eq!(out.slots.get("a").map(String::as_str), Some("alpha"));
        assert_eq!(out.slots.get("b").map(String::as_str), Some("unknown"));
    }

    // ----- closed-list slot canonicalization -------------------------------

    #[test]
    fn closed_slot_canonicalizes_case_and_rejects_unlisted_values() {
        let rule = make_rule_with_stages(
            "r",
            vec![mk_stage(
                "Q",
                vec![(
                    "form",
                    closed_slot("form", &["W-2", "1099"]),
                )],
                None,
            )],
        );
        // Case-insensitive match → canonical "W-2"
        let mut llm = ScriptedLlm::new(vec![r#"{"form": "w-2"}"#]);
        let out = walk(&rule, "doc text", &mut llm);
        assert_eq!(out.slots.get("form").map(String::as_str), Some("W-2"));

        // Unlisted value → "unknown"
        let mut llm2 = ScriptedLlm::new(vec![r#"{"form": "1040"}"#]);
        let out2 = walk(&rule, "doc text", &mut llm2);
        assert_eq!(out2.slots.get("form").map(String::as_str), Some("unknown"));
    }

    // ----- stage-folding: 2 stages, no keep_when → 1 LLM call ---------------

    #[test]
    fn stage_folding_two_stages_no_filter_issues_single_llm_call() {
        let rule = make_rule_with_stages(
            "tax",
            vec![
                mk_stage(
                    "What kind?",
                    vec![("kind", closed_slot("kind", &["W-2", "1099"]))],
                    None,
                ),
                mk_stage(
                    "What year?",
                    vec![("year", open_slot("year", "YYYY"))],
                    None,
                ),
            ],
        );
        let mut llm = ScriptedLlm::new(vec![r#"{"kind": "W-2", "year": "2024"}"#]);
        let out = walk(&rule, "doc text", &mut llm);
        assert_eq!(out.llm_calls, 1, "two stages with no keep_when must fold into one call");
        assert_eq!(out.slots.get("kind").map(String::as_str), Some("W-2"));
        assert_eq!(out.slots.get("year").map(String::as_str), Some("2024"));
        assert_eq!(out.stages_executed.len(), 2, "trace still records both stages");
    }

    #[test]
    fn stage_folding_does_not_fold_across_keep_when() {
        // stage[0] has keep_when=Some, stage[1] starts a new group.
        let rule = make_rule_with_stages(
            "tax",
            vec![
                mk_stage(
                    "Is it tax?",
                    vec![("is_tax", closed_slot("tax?", &["yes", "no"]))],
                    Some("is_tax == 'yes'"),
                ),
                mk_stage(
                    "Year?",
                    vec![("year", open_slot("year", "YYYY"))],
                    None,
                ),
            ],
        );
        let mut llm = ScriptedLlm::new(vec![
            r#"{"is_tax": "yes"}"#,
            r#"{"year": "2024"}"#,
        ]);
        let out = walk(&rule, "doc text", &mut llm);
        assert_eq!(out.llm_calls, 2, "filter boundary forces a second LLM call");
    }

    // ----- empty-stages rule is a no-op -------------------------------------

    #[test]
    fn rule_with_no_stages_is_pure_noop() {
        let rule = make_rule_with_stages("legacy", vec![]);
        struct PanicLlm;
        impl LlmCaller for PanicLlm {
            fn call(&mut self, _: Vec<Value>) -> Result<String, String> {
                panic!("LLM must not be called for empty-stages rule");
            }
        }
        let mut llm = PanicLlm;
        let out = walk(&rule, "doc text", &mut llm);
        assert!(!out.filtered);
        assert_eq!(out.llm_calls, 0);
        assert!(out.slots.is_empty());
    }

    // ----- keep_when grammar --------------------------------------------------

    #[test]
    fn keep_when_equals_passes_when_value_matches_case_insensitive() {
        let mut slots = BTreeMap::new();
        slots.insert("x".to_string(), "Yes".to_string());
        assert!(eval_keep_when("x == 'yes'", &slots));
        assert!(eval_keep_when("x == 'YES'", &slots));
    }

    #[test]
    fn keep_when_not_equals_negates_correctly() {
        let mut slots = BTreeMap::new();
        slots.insert("client".to_string(), "unknown".to_string());
        assert!(!eval_keep_when("client != 'unknown'", &slots));
        slots.insert("client".to_string(), "Smith".to_string());
        assert!(eval_keep_when("client != 'unknown'", &slots));
    }

    #[test]
    fn keep_when_in_list_membership() {
        let mut slots = BTreeMap::new();
        slots.insert("form".to_string(), "W-2".to_string());
        assert!(eval_keep_when("form in ['W-2', '1099']", &slots));
        assert!(!eval_keep_when("form in ['1040', 'K-1']", &slots));
    }

    #[test]
    fn keep_when_malformed_evaluates_false() {
        let slots = BTreeMap::new();
        assert!(!eval_keep_when("garbage", &slots));
        assert!(!eval_keep_when("x = 'y'", &slots), "single '=' is not valid grammar");
    }

    #[test]
    fn keep_when_missing_slot_compares_to_empty_string() {
        let slots = BTreeMap::new();
        assert!(eval_keep_when("nonexistent == ''", &slots));
        assert!(!eval_keep_when("nonexistent == 'something'", &slots));
    }
}
