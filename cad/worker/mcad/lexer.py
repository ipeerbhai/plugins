"""Tokeniser for the MCAD DSL.

Produces a stream of Token objects from source text.  Handles:
  - INDENT / DEDENT tracking (Python-style indentation stack)
  - Keywords, operators, identifiers, numbers, strings
  - Comments (``# ...``) — discarded
  - NEWLINE tokens (blank lines and trailing whitespace ignored)

Design note on INDENT/DEDENT
-----------------------------
We follow CPython's approach: maintain a stack of indentation levels
(starting with [0]).  At the start of each logical line we measure
the leading whitespace.  If it exceeds the top of stack we push and
emit INDENT.  If it's less we pop (possibly multiple times) and emit
one DEDENT per pop.  Tabs are treated as 4 spaces (configurable but
not recommended — spec says spaces).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum, auto
from typing import Iterator


# ---------------------------------------------------------------------------
# Token types
# ---------------------------------------------------------------------------

class TT(Enum):
    """Token types."""
    # Structural
    NEWLINE   = auto()
    INDENT    = auto()
    DEDENT    = auto()
    EOF       = auto()

    # Literals
    NUMBER    = auto()
    STRING    = auto()
    BOOL      = auto()
    IDENT     = auto()

    # Keywords (same string value as the keyword itself)
    KW_SKETCH   = auto()
    KW_CENTER   = auto()
    KW_AT       = auto()
    KW_EXTRUDE  = auto()
    KW_LOFT     = auto()
    KW_FILLET   = auto()
    KW_CHAMFER  = auto()
    KW_SHELL    = auto()
    KW_SPLIT    = auto()
    KW_CUT      = auto()
    KW_ADD      = auto()
    KW_JOIN     = auto()
    KW_CAP      = auto()
    KW_PATTERN  = auto()
    KW_EXPORT   = auto()
    KW_FOR      = auto()
    KW_IN       = auto()
    KW_IF       = auto()
    KW_ELSE     = auto()
    KW_WHILE    = auto()
    KW_MODULE   = auto()
    KW_RETURN   = auto()

    # Operators / punctuation
    PLUS      = auto()
    MINUS     = auto()
    STAR      = auto()
    SLASH     = auto()
    EQ        = auto()
    LPAREN    = auto()
    RPAREN    = auto()
    LBRACKET  = auto()
    RBRACKET  = auto()
    COMMA     = auto()
    COLON     = auto()
    DOT       = auto()

    # Comparison operators
    LT        = auto()
    GT        = auto()
    LTE       = auto()
    GTE       = auto()
    EQEQ      = auto()
    BANGEQ    = auto()

    # Logical operators (symbol form only — no keyword aliases)
    AMPAMP    = auto()
    PIPEPIPE  = auto()
    BANG      = auto()


# Keyword lookup table
KEYWORDS: dict[str, TT] = {
    "true":    TT.BOOL,
    "false":   TT.BOOL,
    "sketch":  TT.KW_SKETCH,
    "center":  TT.KW_CENTER,
    "at":      TT.KW_AT,
    "extrude": TT.KW_EXTRUDE,
    "loft":    TT.KW_LOFT,
    "fillet":  TT.KW_FILLET,
    "chamfer": TT.KW_CHAMFER,
    "shell":   TT.KW_SHELL,
    "split":   TT.KW_SPLIT,
    "cut":     TT.KW_CUT,
    "add":     TT.KW_ADD,
    "join":    TT.KW_JOIN,
    "cap":     TT.KW_CAP,
    "pattern": TT.KW_PATTERN,
    "export":  TT.KW_EXPORT,
    "for":     TT.KW_FOR,
    "in":      TT.KW_IN,
    "if":      TT.KW_IF,
    "else":    TT.KW_ELSE,
    "while":   TT.KW_WHILE,
    "module":  TT.KW_MODULE,
    "return":  TT.KW_RETURN,
}

# Single-character operator map
SINGLE_CHAR_TOKENS: dict[str, TT] = {
    "+": TT.PLUS,
    "-": TT.MINUS,
    "*": TT.STAR,
    "/": TT.SLASH,
    "=": TT.EQ,
    "(": TT.LPAREN,
    ")": TT.RPAREN,
    "[": TT.LBRACKET,
    "]": TT.RBRACKET,
    ",": TT.COMMA,
    ":": TT.COLON,
    ".": TT.DOT,
}


# ---------------------------------------------------------------------------
# Token data class
# ---------------------------------------------------------------------------

@dataclass(frozen=True, slots=True)
class Token:
    type: TT
    value: str | float | int | bool | None = None
    line: int = 0
    col: int = 0

    def __repr__(self) -> str:
        if self.value is not None:
            return f"Token({self.type.name}, {self.value!r}, L{self.line}:{self.col})"
        return f"Token({self.type.name}, L{self.line}:{self.col})"


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

# Regex fragments used by the scanner
_RE_NUMBER = re.compile(r"\d+(?:\.\d+)?")
_RE_IDENT  = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_RE_STRING = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')


class LexError(Exception):
    """Raised on invalid input."""

    def __init__(self, message: str, line: int = 0, col: int = 0):
        self.line = line
        self.col = col
        super().__init__(f"Line {line}, col {col}: {message}")


def tokenize(source: str) -> list[Token]:
    """Tokenize *source* and return a flat list of tokens.

    The list always ends with a single ``EOF`` token.  INDENT / DEDENT
    tokens are generated for indentation changes at the start of logical
    lines.
    """
    tokens: list[Token] = []
    indent_stack: list[int] = [0]
    lines = source.split("\n")

    # Track whether we're inside parentheses (implicit line continuation)
    paren_depth = 0

    for lineno_0, raw_line in enumerate(lines):
        lineno = lineno_0 + 1  # 1-based

        # Strip trailing whitespace (including \r)
        line = raw_line.rstrip()

        # Skip blank lines and comment-only lines
        stripped = line.lstrip()
        if stripped == "" or stripped.startswith("#"):
            continue

        # ---- Indentation handling (only when not inside parens) ----
        if paren_depth == 0:
            indent = len(line) - len(stripped)
            top = indent_stack[-1]

            if indent > top:
                indent_stack.append(indent)
                tokens.append(Token(TT.INDENT, None, lineno, 0))
            elif indent < top:
                while indent_stack[-1] > indent:
                    indent_stack.pop()
                    tokens.append(Token(TT.DEDENT, None, lineno, 0))
                if indent_stack[-1] != indent:
                    raise LexError(
                        f"Unindent does not match any outer level (got {indent}, "
                        f"stack top is {indent_stack[-1]})",
                        lineno, 0,
                    )

        # ---- Scan tokens within the line ----
        col = len(line) - len(stripped)
        end = len(line)

        while col < end:
            ch = line[col]

            # Whitespace (skip)
            if ch in " \t":
                col += 1
                continue

            # Comment — rest of line
            if ch == "#":
                break

            # String literal
            if ch == '"':
                m = _RE_STRING.match(line, col)
                if not m:
                    raise LexError("Unterminated string literal", lineno, col)
                tokens.append(Token(TT.STRING, m.group(1), lineno, col))
                col = m.end()
                continue

            # Number literal
            if ch.isdigit():
                m = _RE_NUMBER.match(line, col)
                assert m  # ch.isdigit() guarantees a match
                text = m.group(0)
                value: float | int = float(text) if "." in text else int(text)
                tokens.append(Token(TT.NUMBER, value, lineno, col))
                col = m.end()
                continue

            # Identifier / keyword
            if ch.isalpha() or ch == "_":
                m = _RE_IDENT.match(line, col)
                assert m
                word = m.group(0)
                tt = KEYWORDS.get(word, TT.IDENT)
                value: str | bool = word
                if tt == TT.BOOL:
                    value = word == "true"
                tokens.append(Token(tt, value, lineno, col))
                col = m.end()
                continue

            # Multi-character operators (check before single-char fallback so
            # that e.g. `==` wins over `=`, `!=` over `!`, `&&` over `&`, etc.)
            nxt = line[col + 1] if col + 1 < end else ""

            if ch == "=" and nxt == "=":
                tokens.append(Token(TT.EQEQ, "==", lineno, col))
                col += 2
                continue
            if ch == "!" and nxt == "=":
                tokens.append(Token(TT.BANGEQ, "!=", lineno, col))
                col += 2
                continue
            if ch == "<":
                if nxt == "=":
                    tokens.append(Token(TT.LTE, "<=", lineno, col))
                    col += 2
                else:
                    tokens.append(Token(TT.LT, "<", lineno, col))
                    col += 1
                continue
            if ch == ">":
                if nxt == "=":
                    tokens.append(Token(TT.GTE, ">=", lineno, col))
                    col += 2
                else:
                    tokens.append(Token(TT.GT, ">", lineno, col))
                    col += 1
                continue
            if ch == "&":
                if nxt == "&":
                    tokens.append(Token(TT.AMPAMP, "&&", lineno, col))
                    col += 2
                    continue
                raise LexError(
                    "Unexpected '&' — did you mean '&&'?", lineno, col
                )
            if ch == "|":
                if nxt == "|":
                    tokens.append(Token(TT.PIPEPIPE, "||", lineno, col))
                    col += 2
                    continue
                raise LexError(
                    "Unexpected '|' — did you mean '||'?", lineno, col
                )
            if ch == "!":
                # Bare '!' (prefix negation); '!=' handled above.
                tokens.append(Token(TT.BANG, "!", lineno, col))
                col += 1
                continue

            # Single-character operators / punctuation
            if ch in SINGLE_CHAR_TOKENS:
                tt = SINGLE_CHAR_TOKENS[ch]
                tokens.append(Token(tt, ch, lineno, col))
                if ch == "(":
                    paren_depth += 1
                elif ch == ")":
                    paren_depth = max(0, paren_depth - 1)
                col += 1
                continue

            raise LexError(f"Unexpected character {ch!r}", lineno, col)

        # Emit NEWLINE at end of logical line (unless inside parens)
        if paren_depth == 0:
            tokens.append(Token(TT.NEWLINE, None, lineno, end))

    # ---- End-of-file: close any remaining indentation levels ----
    final_line = len(lines) + 1
    while len(indent_stack) > 1:
        indent_stack.pop()
        tokens.append(Token(TT.DEDENT, None, final_line, 0))

    tokens.append(Token(TT.EOF, None, final_line, 0))
    return tokens
