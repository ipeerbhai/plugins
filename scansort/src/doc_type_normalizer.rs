//! B8: doc_type token normalization.
//!
//! Maps an LLM-produced raw `doc_type` string to a canonical token defined by
//! the winning rule's `subtypes` list. Case-insensitive. Used by the
//! `canonicalize` and `both` strategies of `process()`.

use crate::types::Subtype;

/// Canonicalize a raw doc_type string against a rule's subtypes list.
///
/// Match order (all case-insensitive, trimmed):
/// 1. Exact match on `subtype.name` → returns `subtype.name`.
/// 2. Match on any `subtype.also_known_as` entry → returns parent `subtype.name`.
/// 3. No match → returns `raw` unchanged.
///
/// Empty `subtypes` returns `raw` unchanged (no-op fallback).
pub fn canonicalize(raw: &str, subtypes: &[Subtype]) -> String {
    if subtypes.is_empty() {
        return raw.to_string();
    }
    let needle = raw.trim().to_lowercase();
    if needle.is_empty() {
        return raw.to_string();
    }
    for st in subtypes {
        if st.name.trim().to_lowercase() == needle {
            return st.name.clone();
        }
    }
    for st in subtypes {
        for alias in &st.also_known_as {
            if alias.trim().to_lowercase() == needle {
                return st.name.clone();
            }
        }
    }
    raw.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(name: &str, aliases: &[&str]) -> Subtype {
        Subtype {
            name: name.to_string(),
            also_known_as: aliases.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn empty_subtypes_passthrough() {
        assert_eq!(canonicalize("anything", &[]), "anything");
    }

    #[test]
    fn exact_name_match() {
        let subs = vec![st("1099", &["1099-DIV"])];
        assert_eq!(canonicalize("1099", &subs), "1099");
    }

    #[test]
    fn exact_name_match_case_insensitive() {
        let subs = vec![st("W-2", &[])];
        assert_eq!(canonicalize("w-2", &subs), "W-2");
        assert_eq!(canonicalize("W-2 ", &subs), "W-2");
    }

    #[test]
    fn alias_match_returns_canonical_name() {
        let subs = vec![st("1099", &["1099-DIV", "1099-INT", "Consolidated 1099"])];
        assert_eq!(canonicalize("1099-DIV", &subs), "1099");
        assert_eq!(canonicalize("consolidated 1099", &subs), "1099");
    }

    #[test]
    fn unknown_returns_raw() {
        let subs = vec![st("1099", &["1099-DIV"])];
        assert_eq!(canonicalize("invoice", &subs), "invoice");
    }

    #[test]
    fn empty_raw_returns_raw() {
        let subs = vec![st("1099", &[])];
        assert_eq!(canonicalize("", &subs), "");
    }

    #[test]
    fn first_matching_subtype_wins_for_overlapping_aliases() {
        // Defensive: if two subtypes share an alias (user error), the first wins.
        let subs = vec![
            st("first", &["shared"]),
            st("second", &["shared"]),
        ];
        assert_eq!(canonicalize("shared", &subs), "first");
    }

    #[test]
    fn name_match_wins_over_alias_match() {
        // If `raw` is both a name (of one subtype) and an alias (of another),
        // the name match wins because we iterate names first.
        let subs = vec![
            st("alpha", &["beta"]),
            st("beta", &[]),
        ];
        assert_eq!(canonicalize("beta", &subs), "beta");
    }
}
