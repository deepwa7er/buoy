//! Full-text search support types and query handling.
//!
//! The search index itself is an FTS5 external-content table kept in sync
//! with `thoughts` by triggers (see the schema v3 migration in `store.rs`).
//! This module owns the result types and the two pure transformations
//! around a search: turning raw user input into a safe FTS5 MATCH
//! expression, and turning a marker-wrapped FTS5 snippet into clean text
//! plus highlight ranges.

use crate::thought::Thought;

/// Marker characters wrapped around matched terms in FTS5 snippets, chosen
/// from the Unicode private-use area so they cannot collide with anything a
/// user plausibly types. `extract_ranges` strips them back out; if a user
/// somehow does store them, the parse degrades to ignoring the stray marker
/// rather than corrupting the snippet text.
pub(crate) const MATCH_MARK_START: char = '\u{E000}';
pub(crate) const MATCH_MARK_END: char = '\u{E001}';

/// How many tokens of context `snippet()` returns around matched terms.
pub(crate) const SNIPPET_TOKENS: u32 = 12;

/// A half-open byte range (UTF-8 offsets) into a [`ThoughtMatch`] snippet
/// covering one matched term.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MatchRange {
    pub start: usize,
    pub len: usize,
}

/// One ranked full-text search result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThoughtMatch {
    pub thought: Thought,
    /// A fragment of the thought's text containing the matched terms,
    /// truncated with `…` when the thought is longer than the window.
    pub snippet: String,
    /// Byte ranges into `snippet` for highlighting, in document order.
    pub ranges: Vec<MatchRange>,
}

/// Convert raw user input into an FTS5 MATCH expression that treats the
/// input as literal text rather than FTS5 query syntax.
///
/// Each whitespace-separated token becomes a quoted phrase (so operators
/// like `OR`, `*`, and parentheses have no special meaning), and the final
/// token is a prefix match so results stay useful while the user is still
/// typing a word. Tokens with no alphanumeric content are dropped — they
/// tokenize to an empty phrase, which FTS5 rejects as a syntax error.
///
/// Returns `None` when the input contains nothing searchable.
pub(crate) fn build_match_query(input: &str) -> Option<String> {
    let tokens: Vec<&str> = input
        .split_whitespace()
        .filter(|token| token.chars().any(char::is_alphanumeric))
        .collect();
    let (last, rest) = tokens.split_last()?;

    let mut query = String::new();
    for token in rest {
        query.push('"');
        query.push_str(&token.replace('"', "\"\""));
        query.push_str("\" ");
    }
    query.push('"');
    query.push_str(&last.replace('"', "\"\""));
    query.push_str("\"*");
    Some(query)
}

/// Split a marker-wrapped snippet (as produced by FTS5 `snippet()` with
/// [`MATCH_MARK_START`]/[`MATCH_MARK_END`] delimiters) into the clean
/// snippet text and the byte ranges the markers enclosed.
pub(crate) fn extract_ranges(marked: &str) -> (String, Vec<MatchRange>) {
    let mut clean = String::with_capacity(marked.len());
    let mut ranges = Vec::new();
    let mut open: Option<usize> = None;
    for ch in marked.chars() {
        match ch {
            MATCH_MARK_START => open = Some(clean.len()),
            MATCH_MARK_END => {
                if let Some(start) = open.take() {
                    ranges.push(MatchRange {
                        start,
                        len: clean.len() - start,
                    });
                }
            }
            _ => clean.push(ch),
        }
    }
    (clean, ranges)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_token_becomes_prefix_phrase() {
        assert_eq!(build_match_query("hello"), Some("\"hello\"*".to_owned()));
    }

    #[test]
    fn multiple_tokens_quote_all_and_prefix_last() {
        assert_eq!(
            build_match_query("grocery list ap"),
            Some("\"grocery\" \"list\" \"ap\"*".to_owned())
        );
    }

    #[test]
    fn fts5_operators_are_neutralized_by_quoting() {
        assert_eq!(
            build_match_query("cats OR dogs"),
            Some("\"cats\" \"OR\" \"dogs\"*".to_owned())
        );
        assert_eq!(
            build_match_query("wild*card"),
            Some("\"wild*card\"*".to_owned())
        );
        assert_eq!(
            build_match_query("(paren)"),
            Some("\"(paren)\"*".to_owned())
        );
    }

    #[test]
    fn double_quotes_are_escaped() {
        assert_eq!(
            build_match_query("say \"hi\""),
            Some("\"say\" \"\"\"hi\"\"\"*".to_owned())
        );
    }

    #[test]
    fn punctuation_only_tokens_are_dropped() {
        assert_eq!(
            build_match_query("— hello !!"),
            Some("\"hello\"*".to_owned())
        );
    }

    #[test]
    fn unsearchable_input_returns_none() {
        assert_eq!(build_match_query(""), None);
        assert_eq!(build_match_query("   "), None);
        assert_eq!(build_match_query("— !! ***"), None);
    }

    #[test]
    fn extract_ranges_finds_marked_terms() {
        let marked = format!(
            "pick up {MATCH_MARK_START}milk{MATCH_MARK_END} and {MATCH_MARK_START}eggs{MATCH_MARK_END}"
        );
        let (clean, ranges) = extract_ranges(&marked);
        assert_eq!(clean, "pick up milk and eggs");
        assert_eq!(
            ranges,
            vec![
                MatchRange { start: 8, len: 4 },
                MatchRange { start: 17, len: 4 },
            ]
        );
        for range in ranges {
            let term = &clean[range.start..range.start + range.len];
            assert!(term == "milk" || term == "eggs");
        }
    }

    #[test]
    fn extract_ranges_uses_byte_offsets_for_multibyte_text() {
        let marked = format!("café {MATCH_MARK_START}déjà{MATCH_MARK_END} vu");
        let (clean, ranges) = extract_ranges(&marked);
        assert_eq!(clean, "café déjà vu");
        assert_eq!(ranges.len(), 1);
        let range = ranges[0];
        assert_eq!(&clean[range.start..range.start + range.len], "déjà");
    }

    #[test]
    fn extract_ranges_tolerates_stray_markers() {
        let (clean, ranges) = extract_ranges("no opener here\u{E001} text");
        assert_eq!(clean, "no opener here text");
        assert!(ranges.is_empty());

        let (clean, ranges) = extract_ranges("dangling \u{E000}opener");
        assert_eq!(clean, "dangling opener");
        assert!(ranges.is_empty());
    }
}
