"""Tests for the MCAD lexer."""

import pytest

from mcad.lexer import TT, Token, tokenize, LexError


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def types(tokens: list[Token]) -> list[TT]:
    """Return just the token types (excluding EOF)."""
    return [t.type for t in tokens if t.type != TT.EOF]


def values(tokens: list[Token]) -> list:
    """Return just the token values (excluding EOF and NEWLINE)."""
    return [t.value for t in tokens if t.type not in (TT.EOF, TT.NEWLINE)]


# ---------------------------------------------------------------------------
# Simple assignment
# ---------------------------------------------------------------------------

class TestSimpleAssignment:
    def test_height_equals_100(self):
        toks = tokenize("height = 100")
        assert types(toks) == [TT.IDENT, TT.EQ, TT.NUMBER, TT.NEWLINE]

    def test_values(self):
        toks = tokenize("height = 100")
        assert values(toks) == ["height", "=", 100]

    def test_float_value(self):
        toks = tokenize("ratio = 3.14")
        toks_vals = [(t.type, t.value) for t in toks if t.type == TT.NUMBER]
        assert toks_vals == [(TT.NUMBER, 3.14)]


# ---------------------------------------------------------------------------
# Arithmetic expressions
# ---------------------------------------------------------------------------

class TestArithmetic:
    def test_subtraction_and_division(self):
        toks = tokenize("height - thickness/2")
        expected_types = [TT.IDENT, TT.MINUS, TT.IDENT, TT.SLASH, TT.NUMBER, TT.NEWLINE]
        assert types(toks) == expected_types

    def test_complex_expression(self):
        toks = tokenize("(height - thickness) / 2")
        expected_types = [
            TT.LPAREN, TT.IDENT, TT.MINUS, TT.IDENT, TT.RPAREN,
            TT.SLASH, TT.NUMBER, TT.NEWLINE,
        ]
        assert types(toks) == expected_types


# ---------------------------------------------------------------------------
# Sketch block — INDENT / DEDENT
# ---------------------------------------------------------------------------

class TestSketchBlock:
    SOURCE = (
        "sketch:\n"
        "    flange = rect(width, thickness)\n"
        "    profile = flange + web\n"
    )

    def test_indent_dedent_emitted(self):
        toks = tokenize(self.SOURCE)
        tt = types(toks)
        assert TT.INDENT in tt
        assert TT.DEDENT in tt

    def test_structure(self):
        toks = tokenize(self.SOURCE)
        tt = types(toks)
        # sketch : NEWLINE INDENT ... DEDENT
        sketch_idx = tt.index(TT.KW_SKETCH)
        assert tt[sketch_idx + 1] == TT.COLON
        assert tt[sketch_idx + 2] == TT.NEWLINE
        assert tt[sketch_idx + 3] == TT.INDENT

    def test_nested_indent_levels(self):
        """Double indent is two INDENT tokens."""
        src = "a:\n    b:\n        c = 1\n"
        toks = tokenize(src)
        tt = types(toks)
        indent_count = tt.count(TT.INDENT)
        dedent_count = tt.count(TT.DEDENT)
        assert indent_count == 2
        assert dedent_count == 2


# ---------------------------------------------------------------------------
# Comments
# ---------------------------------------------------------------------------

class TestComments:
    def test_comment_line_ignored(self):
        toks = tokenize("# this is a comment\nheight = 100\n")
        # Comment line produces no tokens — first real token is 'height'
        assert toks[0].type == TT.IDENT
        assert toks[0].value == "height"

    def test_inline_comment_ignored(self):
        toks = tokenize("height = 100  # inline comment\n")
        tt = types(toks)
        assert TT.IDENT in tt
        assert tt == [TT.IDENT, TT.EQ, TT.NUMBER, TT.NEWLINE]

    def test_comment_only_file(self):
        toks = tokenize("# just a comment\n# another one\n")
        assert types(toks) == []  # only EOF remains


# ---------------------------------------------------------------------------
# String tokens
# ---------------------------------------------------------------------------

class TestStrings:
    def test_simple_string(self):
        toks = tokenize('export beam "t_beam.3mf"\n')
        str_toks = [t for t in toks if t.type == TT.STRING]
        assert len(str_toks) == 1
        assert str_toks[0].value == "t_beam.3mf"

    def test_string_with_path(self):
        toks = tokenize('export beam "output/t_beam.step"\n')
        str_toks = [t for t in toks if t.type == TT.STRING]
        assert str_toks[0].value == "output/t_beam.step"


# ---------------------------------------------------------------------------
# Keywords
# ---------------------------------------------------------------------------

class TestKeywords:
    @pytest.mark.parametrize("kw,tt", [
        ("sketch", TT.KW_SKETCH),
        ("center", TT.KW_CENTER),
        ("at", TT.KW_AT),
        ("extrude", TT.KW_EXTRUDE),
        ("fillet", TT.KW_FILLET),
        ("chamfer", TT.KW_CHAMFER),
        ("export", TT.KW_EXPORT),
    ])
    def test_keyword_recognised(self, kw, tt):
        toks = tokenize(kw + "\n")
        assert toks[0].type == tt

    def test_center_at_point_tokens(self):
        toks = tokenize("flange = rect(w, t) center at point(0, 2)\n")
        tt = types(toks)
        assert TT.KW_CENTER in tt
        assert TT.KW_AT in tt

    def test_ident_not_keyword(self):
        toks = tokenize("mysketch\n")
        assert toks[0].type == TT.IDENT


# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------

class TestOperators:
    @pytest.mark.parametrize("ch,tt", [
        ("+", TT.PLUS),
        ("-", TT.MINUS),
        ("*", TT.STAR),
        ("/", TT.SLASH),
        ("=", TT.EQ),
        ("(", TT.LPAREN),
        (")", TT.RPAREN),
        (",", TT.COMMA),
        (":", TT.COLON),
        (".", TT.DOT),
    ])
    def test_operator(self, ch, tt):
        # Wrap in enough context to be valid
        toks = tokenize(f"a {ch} b\n")
        op_toks = [t for t in toks if t.type == tt]
        assert len(op_toks) >= 1


# ---------------------------------------------------------------------------
# Line numbers
# ---------------------------------------------------------------------------

class TestLineNumbers:
    def test_tokens_have_correct_line_numbers(self):
        src = "a = 1\nb = 2\n"
        toks = tokenize(src)
        a_tok = toks[0]
        b_tok = [t for t in toks if t.value == "b"][0]
        assert a_tok.line == 1
        assert b_tok.line == 2


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

class TestErrors:
    def test_unterminated_string(self):
        with pytest.raises(LexError, match="Unterminated string"):
            tokenize('"hello\n')

    def test_unexpected_character(self):
        with pytest.raises(LexError, match="Unexpected character"):
            tokenize("a @ b\n")

    def test_bad_indent(self):
        src = "a:\n        b = 1\n    c = 2\n  d = 3\n"
        with pytest.raises(LexError, match="Unindent does not match"):
            tokenize(src)
