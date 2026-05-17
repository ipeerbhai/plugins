//! W5: One-shot migration of legacy library rules into the new shape.
//!
//! DCR 019e33bf removed three legacy concepts from the rule schema:
//!   1. `signals: [...]`           — absorbed into `instruction` text
//!   2. `subtypes: [...]`          — replaced by a closed `classify` slot
//!   3. Built-in tokens in templates (`{date}`, `{sender}`, `{description}`,
//!      `{issuer}`, `{year}`, `{amount}`, `{category}`, `{doc_type}`) — every
//!      template token must now come from an explicit `classify` slot.
//!
//! `migrate_rule` rewrites a single rule in place; `library_load` (in
//! `library.rs`) detects any legacy markers, runs `migrate_rule` on every
//! rule, and writes the migrated file back to disk in the same pass. Once a
//! library is migrated, subsequent reads are a no-op (idempotent).

use crate::rules_file::FileRule;
use crate::types::{Slot, SlotValues, Stage};

/// Tokens that the legacy engine implicitly populated from extraction.
/// Used by `migrate_builtin_tokens` to detect which slots a rule's templates
/// referenced and inject the matching `classify` slots into a new stage.
pub const BUILTIN_TOKENS: &[&str] = &[
    "date",
    "sender",
    "description",
    "issuer",
    "year",
    "amount",
    "category",
    "doc_type",
];

/// True if `rule` carries any legacy marker that `migrate_rule` would rewrite.
/// Used by `library_load` to decide whether the disk file needs a write-back.
pub fn is_legacy(rule: &FileRule) -> bool {
    if !rule.signals.is_empty() || !rule.subtypes.is_empty() {
        return true;
    }
    if rule.stages.is_empty() && !referenced_tokens(rule).is_empty() {
        return true;
    }
    false
}

/// Apply all legacy → new conversions to a single rule in place.
/// Returns true if the rule was modified.
pub fn migrate_rule(rule: &mut FileRule) -> bool {
    let mut changed = false;
    if migrate_signals(rule) {
        changed = true;
    }
    if migrate_subtypes(rule) {
        changed = true;
    }
    if migrate_builtin_tokens(rule) {
        changed = true;
    }
    changed
}

// ---------------------------------------------------------------------------
// signals → instruction
// ---------------------------------------------------------------------------

fn migrate_signals(rule: &mut FileRule) -> bool {
    if rule.signals.is_empty() {
        return false;
    }
    let joined = rule.signals.join(", ");
    let trimmed = rule.instruction.trim_end();
    let sep = if trimmed.is_empty() {
        ""
    } else if trimmed.ends_with(['.', '!', '?']) {
        " "
    } else {
        "; "
    };
    rule.instruction = format!("{trimmed}{sep}typical signals include {joined}");
    rule.signals = Vec::new();
    true
}

// ---------------------------------------------------------------------------
// subtypes → stages[0] with closed-list doc_type slot
// ---------------------------------------------------------------------------

fn migrate_subtypes(rule: &mut FileRule) -> bool {
    if rule.subtypes.is_empty() {
        return false;
    }
    if rule.stages.is_empty() {
        let names: Vec<String> = rule.subtypes.iter().map(|s| s.name.clone()).collect();
        let mut classify = std::collections::BTreeMap::new();
        classify.insert(
            "doc_type".to_string(),
            Slot {
                description: "the document type".to_string(),
                values: SlotValues::Closed(names),
            },
        );
        rule.stages.push(Stage {
            ask: "What kind of document is this?".to_string(),
            classify,
            keep_when: None,
        });
    }
    rule.subtypes = Vec::new();
    true
}

// ---------------------------------------------------------------------------
// built-in tokens → stages[0] with extraction slots
// ---------------------------------------------------------------------------

fn migrate_builtin_tokens(rule: &mut FileRule) -> bool {
    // If subtypes-migration already populated stages, the doc_type slot is
    // there; we still want to add date/sender/description slots referenced in
    // templates, so we merge into stages[0] when it exists from subtype
    // migration, otherwise create a new stage.
    let referenced = referenced_tokens(rule);
    if referenced.is_empty() {
        return false;
    }

    if rule.stages.is_empty() {
        let ask = builtin_ask_for(&referenced);
        let mut classify = std::collections::BTreeMap::new();
        for tok in &referenced {
            if let Some(slot) = slot_for_builtin(tok) {
                classify.insert(tok.clone(), slot);
            }
        }
        if classify.is_empty() {
            return false;
        }
        rule.stages.push(Stage {
            ask,
            classify,
            keep_when: None,
        });
        return true;
    }

    // Stages already exist (from subtype migration). Add any builtins NOT
    // already declared in stage 0.
    let mut changed = false;
    let stage = &mut rule.stages[0];
    for tok in referenced {
        if stage.classify.contains_key(&tok) {
            continue;
        }
        if let Some(slot) = slot_for_builtin(&tok) {
            stage.classify.insert(tok, slot);
            changed = true;
        }
    }
    changed
}

fn referenced_tokens(rule: &FileRule) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<&'static str> = std::collections::HashSet::new();
    for text in [&rule.subfolder, &rule.rename_pattern] {
        for tok in BUILTIN_TOKENS {
            if text.contains(&format!("{{{tok}}}")) && seen.insert(tok) {
                out.push((*tok).to_string());
            }
        }
    }
    out
}

fn builtin_ask_for(referenced: &[String]) -> String {
    // Friendly phrasing for the common combinations seen in legacy rules.
    let has = |t: &str| referenced.iter().any(|r| r == t);
    if has("date") && (has("sender") || has("issuer")) && has("description") {
        return "Extract the document's date, who issued/sent it, and a brief description.".to_string();
    }
    if has("date") && has("description") {
        return "Extract the document's date and a brief description.".to_string();
    }
    "Extract the fields referenced by this rule's templates.".to_string()
}

fn slot_for_builtin(name: &str) -> Option<Slot> {
    let (desc, values) = match name {
        "date" => (
            "the document date",
            SlotValues::Open("YYYY-MM-DD or 'undated'".to_string()),
        ),
        "sender" | "issuer" => (
            "who issued or sent the document",
            SlotValues::Open("a name or 'unknown'".to_string()),
        ),
        "description" => (
            "brief description in 2-5 words",
            SlotValues::Open("a short phrase or 'unknown'".to_string()),
        ),
        "year" => (
            "calendar year",
            SlotValues::Open("a 4-digit year, or 'unknown'".to_string()),
        ),
        "amount" => (
            "monetary amount",
            SlotValues::Open("a decimal amount as a string, or 'unknown'".to_string()),
        ),
        "category" => (
            "the document category",
            SlotValues::Open("a short category name, or 'unknown'".to_string()),
        ),
        "doc_type" => (
            "the document type",
            SlotValues::Open("a short doc type, or 'unknown'".to_string()),
        ),
        _ => return None,
    };
    Some(Slot {
        description: desc.to_string(),
        values,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Subtype, SlotValues};

    fn legacy_skeleton(label: &str) -> FileRule {
        FileRule {
            label: label.to_string(),
            name: format!("Rule {label}"),
            instruction: format!("Match {label} documents."),
            signals: Vec::new(),
            subfolder: String::new(),
            rename_pattern: String::new(),
            confidence_threshold: 0.7,
            encrypt: false,
            enabled: true,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: Vec::new(),
            subtypes: Vec::new(),
            stages: Vec::new(),
        }
    }

    // ----- signals-only migration ----------------------------------------

    #[test]
    fn migrate_signals_only_appends_to_instruction_and_clears_field() {
        let mut r = legacy_skeleton("tax");
        r.signals = vec!["wages".to_string(), "withholding".to_string()];
        assert!(migrate_rule(&mut r));
        assert!(r.signals.is_empty(), "signals field must be cleared");
        assert!(
            r.instruction.contains("typical signals include wages, withholding"),
            "expected signals appended to instruction, got: {}",
            r.instruction
        );
        assert!(r.stages.is_empty(), "signals-only must not inject a stage");
        assert!(!is_legacy(&r), "post-migrate must not look legacy");
    }

    #[test]
    fn migrate_signals_with_no_trailing_punctuation_uses_semicolon_separator() {
        let mut r = legacy_skeleton("memo");
        r.instruction = "Brief memo".to_string();
        r.signals = vec!["draft".to_string()];
        migrate_rule(&mut r);
        assert_eq!(r.instruction, "Brief memo; typical signals include draft");
    }

    #[test]
    fn migrate_signals_with_empty_instruction_does_not_add_separator() {
        let mut r = legacy_skeleton("bare");
        r.instruction = String::new();
        r.signals = vec!["x".to_string()];
        migrate_rule(&mut r);
        assert_eq!(r.instruction, "typical signals include x");
    }

    // ----- subtypes-only migration ---------------------------------------

    #[test]
    fn migrate_subtypes_only_injects_doc_type_slot_with_closed_list() {
        let mut r = legacy_skeleton("tax");
        r.subtypes = vec![
            Subtype { name: "W-2".to_string(), also_known_as: vec!["w2".to_string()] },
            Subtype { name: "1099".to_string(), also_known_as: vec![] },
        ];
        assert!(migrate_rule(&mut r));
        assert!(r.subtypes.is_empty(), "subtypes field must be cleared");
        assert_eq!(r.stages.len(), 1, "exactly one injected stage");
        let stage = &r.stages[0];
        assert_eq!(stage.ask, "What kind of document is this?");
        let slot = stage.classify.get("doc_type").expect("doc_type slot");
        match &slot.values {
            SlotValues::Closed(values) => {
                assert_eq!(values, &vec!["W-2".to_string(), "1099".to_string()]);
            }
            other => panic!("expected closed list, got {:?}", other),
        }
        assert!(stage.keep_when.is_none());
    }

    // ----- built-in tokens migration -------------------------------------

    #[test]
    fn migrate_builtin_tokens_only_injects_slots_for_referenced_tokens() {
        let mut r = legacy_skeleton("doc");
        r.subfolder = "{sender}".to_string();
        r.rename_pattern = "{date}_{sender}_{description}".to_string();
        assert!(migrate_rule(&mut r));
        assert_eq!(r.stages.len(), 1);
        let classify = &r.stages[0].classify;
        assert!(classify.contains_key("date"));
        assert!(classify.contains_key("sender"));
        assert!(classify.contains_key("description"));
        assert!(!classify.contains_key("year"), "year not referenced — must not be injected");
        assert!(!classify.contains_key("amount"));
    }

    #[test]
    fn migrate_builtin_tokens_with_no_references_is_noop() {
        let mut r = legacy_skeleton("plain");
        r.subfolder = "static/path".to_string();
        r.rename_pattern = "fixed_name.pdf".to_string();
        assert!(!migrate_rule(&mut r), "no legacy markers → migration is no-op");
    }

    // ----- combined ------------------------------------------------------

    #[test]
    fn migrate_all_three_combined_produces_single_consistent_rule() {
        let mut r = legacy_skeleton("tax");
        r.signals = vec!["wages".to_string()];
        r.subtypes = vec![Subtype { name: "W-2".to_string(), also_known_as: vec![] }];
        r.subfolder = "{year}".to_string();
        r.rename_pattern = "{date}_{sender}.pdf".to_string();

        assert!(migrate_rule(&mut r));
        // signals cleared and merged into instruction
        assert!(r.signals.is_empty());
        assert!(r.instruction.contains("typical signals include wages"));
        // subtypes cleared, stages[0] populated with doc_type AND template slots merged in
        assert!(r.subtypes.is_empty());
        assert_eq!(r.stages.len(), 1, "subtypes + built-ins fold into a single stage");
        let classify = &r.stages[0].classify;
        assert!(classify.contains_key("doc_type"));
        assert!(classify.contains_key("year"));
        assert!(classify.contains_key("date"));
        assert!(classify.contains_key("sender"));
    }

    // ----- idempotency ---------------------------------------------------

    #[test]
    fn migrate_is_idempotent_on_already_migrated_rule() {
        let mut r = legacy_skeleton("tax");
        r.signals = vec!["wages".to_string()];
        r.subtypes = vec![Subtype { name: "W-2".to_string(), also_known_as: vec![] }];
        r.rename_pattern = "{date}.pdf".to_string();

        assert!(migrate_rule(&mut r), "first call must report changed");
        let snapshot = serde_json::to_string(&r).expect("serialize");
        assert!(!is_legacy(&r), "migrated rule must not be flagged legacy");
        assert!(!migrate_rule(&mut r), "second call must report unchanged");
        let snapshot2 = serde_json::to_string(&r).expect("serialize 2");
        assert_eq!(snapshot, snapshot2, "second pass must not alter the rule");
    }

    #[test]
    fn already_new_shape_rule_is_unchanged() {
        let mut r = legacy_skeleton("new");
        let mut classify = std::collections::BTreeMap::new();
        classify.insert(
            "is_relevant".to_string(),
            Slot {
                description: "tag".to_string(),
                values: SlotValues::Closed(vec!["yes".to_string(), "no".to_string()]),
            },
        );
        r.stages.push(Stage {
            ask: "Is it relevant?".to_string(),
            classify,
            keep_when: Some("is_relevant == 'yes'".to_string()),
        });
        let snapshot = serde_json::to_string(&r).expect("serialize");
        assert!(!is_legacy(&r));
        assert!(!migrate_rule(&mut r));
        assert_eq!(snapshot, serde_json::to_string(&r).unwrap());
    }
}
