"""AST node definitions for the MCAD DSL.

Every node is a simple dataclass.  The tree is backend-independent — the
translator (not built yet) will walk these nodes to emit Build123d calls or
SDF shader code.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


# ---------------------------------------------------------------------------
# Leaf nodes
# ---------------------------------------------------------------------------

@dataclass
class Number:
    """Numeric literal (int or float)."""
    value: float

    def __repr__(self) -> str:
        # Show ints without trailing .0 for readability
        if self.value == int(self.value):
            return f"Number({int(self.value)})"
        return f"Number({self.value})"


@dataclass
class String:
    """Double-quoted string literal."""
    value: str


@dataclass
class Bool:
    """Boolean literal."""
    value: bool


@dataclass
class Identifier:
    """Variable / shape name reference."""
    name: str


# ---------------------------------------------------------------------------
# Expressions
# ---------------------------------------------------------------------------

@dataclass
class BinOp:
    """Binary operation — arithmetic (+, -, *, /) or CSG (+, -).

    Type resolution (arithmetic vs CSG) is deferred to the translator.
    """
    op: str
    left: Any
    right: Any


@dataclass
class UnaryOp:
    """Unary negation."""
    op: str  # always "-"
    operand: Any


@dataclass
class FuncCall:
    """Function / constructor call, e.g. ``rect(width, thickness)``."""
    name: str
    args: list = field(default_factory=list)
    kwargs: dict = field(default_factory=dict)


@dataclass
class Index:
    """Postfix bracket-index: target[index]."""
    target: Any
    index: Any


@dataclass
class MethodCall:
    """Postfix method call, e.g. ``shape.rotate(45)``."""
    target: Any
    method: str
    args: list = field(default_factory=list)
    kwargs: dict = field(default_factory=dict)


@dataclass
class AtClause:
    """Positioning clause such as ``expr at (x, y)`` or ``expr center at point(x, y)``."""
    target: Any          # the expression being positioned (e.g. FuncCall)
    position: list       # list of position expressions (usually [x, y])
    anchor: str = "center"


@dataclass
class Tuple:
    """Tuple literal: ``(a, b)`` or ``(a, b, c)``."""
    elements: list


# ---------------------------------------------------------------------------
# Statements
# ---------------------------------------------------------------------------

@dataclass
class Assignment:
    """Variable binding: ``name = value``."""
    name: str
    value: Any


@dataclass
class SketchBlock:
    """``sketch:`` block containing 2D profile definitions."""
    statements: list = field(default_factory=list)


@dataclass
class Command:
    """Single-line command: ``fillet beam, 2, r=4``."""
    name: str
    args: list = field(default_factory=list)
    kwargs: dict = field(default_factory=dict)


@dataclass
class Export:
    """``export <name> "<path>"`` — write a shape to disk.

    Format is inferred from the path's extension (``.stl``, ``.3mf``, ``.step``).
    Relative paths are resolved against the user's home directory.
    """
    name: str
    path: str


@dataclass
class Extrude:
    """``extrude(profile, length)`` — sugar over FuncCall for clarity."""
    profile: Any
    length: Any


@dataclass
class LoftSection:
    """Single loft section entry such as ``z=40: oval(60, 35)``."""
    axis: str
    position: Any
    profile: Any


@dataclass
class Loft:
    """``loft:`` block containing ordered section definitions."""
    sections: list = field(default_factory=list)


@dataclass
class ForLoop:
    """``for <var> in <iterable>:`` + indented body."""
    variable: str
    iterable: Any
    body: list = field(default_factory=list)


@dataclass
class If:
    """``if <condition>:`` block with optional ``else:`` branch.

    Both ``then_body`` and ``else_body`` are lists of statements.  ``else_body``
    is an empty list when no ``else:`` clause was provided.
    """
    condition: Any
    then_body: list = field(default_factory=list)
    else_body: list = field(default_factory=list)


@dataclass
class While:
    """``while <condition>:`` + indented body."""
    condition: Any
    body: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# User-defined modules
# ---------------------------------------------------------------------------

@dataclass
class Parameter:
    """A single module parameter.

    ``default`` is ``None`` for required params, or an AST expression node
    that will be evaluated in the caller's lexical environment when the
    parameter is not supplied.
    """
    name: str
    default: Any = None


@dataclass
class ModuleDef:
    """``module <name>(<params>):`` + indented body.

    ``body`` is a list of statements. The module body must contain a
    ``Return`` statement — the translator enforces this at call time.
    """
    name: str
    params: list = field(default_factory=list)
    body: list = field(default_factory=list)


@dataclass
class Return:
    """``return <expression>`` — only valid inside a module body."""
    value: Any


# ---------------------------------------------------------------------------
# Top-level
# ---------------------------------------------------------------------------

@dataclass
class Program:
    """Root AST node — a list of top-level statements."""
    statements: list = field(default_factory=list)
