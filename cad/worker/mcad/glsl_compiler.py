"""GLSL compiler: walks the MCAD AST and emits a ``scene_sdf`` function.

Design
------
* A first pass collects all ``Assignment`` statements into an environment
  (a dict mapping name → AST node).  Number-valued variables may be emitted
  as GLSL ``float`` declarations or inlined at use-site.

* A second pass walks the expression tree for the scene's *root shape* (the
  last non-Command, non-export binding that is an ``Extrude`` or a shape
  expression).

* Fillet/chamfer ``Command`` nodes are collected separately and used to
  decide whether a ``BinOp`` CSG operation should use the smooth variant.

Mapping
-------
  rect(w, h)             → sdf_rect_2d(p.xy, vec2(w, h))
  at (x, y) on rect      → sdf_rect_2d(p.xy - vec2(x, y), vec2(w, h))
  a + b (shapes)         → sdf_union(a, b)  [or sdf_smooth_union if filleted]
  a - b (shapes)         → sdf_difference(a, b)  [or sdf_smooth_difference]
  extrude(profile, len)  → sdf_extrude(p, profile_sdf, len)
  fillet shape, n, r=R   → max smooth radius stored; applied to all CSG ops
  chamfer shape, n, d=D  → same treatment as fillet (approximate)
"""

from __future__ import annotations

import textwrap
from typing import Any

from .ast_nodes import (
    Assignment,
    AtClause,
    BinOp,
    Command,
    Extrude,
    FuncCall,
    Identifier,
    MethodCall,
    Number,
    Program,
    SketchBlock,
    String,
    UnaryOp,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fmt_float(v: float) -> str:
    """Format a float for GLSL — always include the decimal point."""
    if v == int(v):
        return f"{int(v)}.0"
    # Avoid scientific notation for reasonable values
    return f"{v:g}"


def _glsl_name(var: str) -> str:
    """Return a GLSL-safe variable name for a shape SDF intermediate."""
    return f"d_{var}"


# ---------------------------------------------------------------------------
# Compiler
# ---------------------------------------------------------------------------

class CompileError(Exception):
    pass


class GLSLCompiler:
    """Compile an MCAD ``Program`` AST to a GLSL ``scene_sdf`` function."""

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def compile(self, program: Program) -> str:
        """Compile *program* and return a GLSL ``float scene_sdf(vec3 p)``
        function string.
        """
        self._reset()
        self._collect(program)
        body_lines = self._emit_scene()
        indented = "\n".join("    " + line for line in body_lines)
        return f"float scene_sdf(vec3 p) {{\n{indented}\n}}"

    def compile_full_shader(self, program: Program) -> str:
        """Return a complete Godot shader string that includes the SDF
        primitives and a generated ``scene_sdf``.

        The output is a self-contained ``.gdshader`` snippet that can replace
        the placeholder section in ``sdf_raymarch.gdshader``.
        """
        scene_sdf_fn = self.compile(program)
        return (
            '#include "sdf_primitives.gdshaderinc"\n\n'
            + scene_sdf_fn
        )

    # ------------------------------------------------------------------
    # Internal state helpers
    # ------------------------------------------------------------------

    def _reset(self) -> None:
        # Maps variable name → AST node (its assigned value)
        self._env: dict[str, Any] = {}
        # Maps shape variable name → max smooth radius (from fillet/chamfer)
        self._smooth_radius: dict[str, float] = {}
        # Ordered list of (var_name, glsl_expr_string) for the generated body
        self._lines: list[str] = []
        # Counter for anonymous intermediates
        self._anon_count: int = 0
        # Set of variable names already emitted as GLSL lines
        self._emitted: set[str] = set()
        # The root shape name (the Extrude assignment's LHS, or last shape)
        self._root_shape: str | None = None

    # ------------------------------------------------------------------
    # Pass 1: collect environment and modifiers
    # ------------------------------------------------------------------

    def _collect(self, program: Program) -> None:
        """Walk top-level statements and populate ``self._env`` and
        ``self._smooth_radius``.  Also identifies the root shape.
        """
        for stmt in program.statements:
            if isinstance(stmt, Assignment):
                self._env[stmt.name] = stmt.value
                # Track as candidate root if it is an Extrude
                if isinstance(stmt.value, Extrude):
                    self._root_shape = stmt.name
            elif isinstance(stmt, SketchBlock):
                for inner in stmt.statements:
                    if isinstance(inner, Assignment):
                        self._env[inner.name] = inner.value
            elif isinstance(stmt, Command):
                self._handle_command(stmt)
            # Ignore String, export, etc.

        # Propagate smooth radii through shape reference chains.
        # e.g. fillet beam → beam has Extrude(profile) → propagate to profile
        # and recursively to any shapes that profile references.
        self._propagate_smooth_radii()

    def _handle_command(self, cmd: Command) -> None:
        """Process ``fillet`` and ``chamfer`` commands into smooth radii."""
        if cmd.name not in ("fillet", "chamfer"):
            return
        if not cmd.args:
            return
        shape_arg = cmd.args[0]
        if not isinstance(shape_arg, Identifier):
            return
        shape_name = shape_arg.name

        radius = 0.0
        if cmd.name == "fillet" and "r" in cmd.kwargs:
            r_node = cmd.kwargs["r"]
            radius = self._eval_number(r_node)
        elif cmd.name == "chamfer" and "d" in cmd.kwargs:
            d_node = cmd.kwargs["d"]
            radius = self._eval_number(d_node)

        if radius > 0.0:
            current = self._smooth_radius.get(shape_name, 0.0)
            self._smooth_radius[shape_name] = max(current, radius)

    def _propagate_smooth_radii(self) -> None:
        """Push smooth radii down through the shape variable reference chain.

        If ``beam`` has a smooth radius and ``beam = extrude(profile, …)``
        then ``profile`` should inherit the same radius so that when its CSG
        BinOp is emitted it uses the smooth variant.  This is done
        recursively / iteratively until no further propagation occurs.
        """
        changed = True
        while changed:
            changed = False
            for name, radius in list(self._smooth_radius.items()):
                node = self._env.get(name)
                if node is None:
                    continue
                # Extrude: propagate to the profile variable
                if isinstance(node, Extrude):
                    deps = self._shape_deps(node.profile)
                    for dep in deps:
                        current = self._smooth_radius.get(dep, 0.0)
                        if radius > current:
                            self._smooth_radius[dep] = radius
                            changed = True
                # Shape variable holding another identifier
                elif isinstance(node, Identifier):
                    dep = node.name
                    current = self._smooth_radius.get(dep, 0.0)
                    if radius > current:
                        self._smooth_radius[dep] = radius
                        changed = True

    def _shape_deps(self, node: Any) -> list[str]:
        """Return the list of shape variable names directly referenced by *node*."""
        if isinstance(node, Identifier):
            return [node.name]
        if isinstance(node, BinOp):
            return self._shape_deps(node.left) + self._shape_deps(node.right)
        if isinstance(node, AtClause):
            return self._shape_deps(node.target)
        if isinstance(node, Extrude):
            return self._shape_deps(node.profile)
        return []

    # ------------------------------------------------------------------
    # Pass 2: emit body lines for the scene SDF
    # ------------------------------------------------------------------

    def _emit_scene(self) -> list[str]:
        """Return the list of GLSL statement strings for the function body."""
        if self._root_shape is None:
            raise CompileError("No extruded shape found in program")

        self._lines = []
        self._emitted = set()

        # Emit the root shape expression, which drives all dependencies
        result_var = self._emit_expr(
            self._root_shape,
            self._env[self._root_shape],
        )

        # Final return
        self._lines.append(f"return {result_var};")
        return self._lines

    # ------------------------------------------------------------------
    # Expression emitter — returns the GLSL variable name holding the SDF
    # ------------------------------------------------------------------

    def _emit_expr(self, hint_name: str | None, node: Any) -> str:
        """Recursively emit GLSL for *node* and return the variable name that
        holds its SDF value.

        *hint_name* is used as the basis for the emitted variable name when
        available (e.g. the LHS of an assignment).
        """
        if isinstance(node, Number):
            # Numeric literals are inlined
            return _fmt_float(node.value)

        if isinstance(node, UnaryOp) and node.op == "-":
            inner = self._emit_expr(hint_name, node.operand)
            return f"-{inner}"

        if isinstance(node, BinOp):
            return self._emit_binop(hint_name, node)

        if isinstance(node, Identifier):
            return self._emit_identifier(node.name)

        if isinstance(node, FuncCall):
            return self._emit_funccall(hint_name, node)

        if isinstance(node, AtClause):
            return self._emit_atclause(hint_name, node)

        if isinstance(node, Extrude):
            return self._emit_extrude(hint_name, node)

        if isinstance(node, MethodCall):
            raise CompileError(f"MethodCall not supported in GLSL compiler: {node}")

        raise CompileError(f"Unhandled AST node type: {type(node).__name__}")

    # ------------------------------------------------------------------
    # Identifier: look up in env and emit if not yet emitted
    # ------------------------------------------------------------------

    def _emit_identifier(self, name: str) -> str:
        """Return the GLSL variable for *name*, emitting it if necessary."""
        if name not in self._env:
            raise CompileError(f"Undefined variable: {name!r}")

        node = self._env[name]

        # Pure number variable — inline the value rather than emitting a line
        if self._is_pure_number(node):
            return _fmt_float(self._eval_number(node))

        # Shape / SDF variable — emit if not already done
        glsl_var = _glsl_name(name)
        if name not in self._emitted:
            expr = self._emit_expr(name, node)
            # expr might BE glsl_var (recursive call returned same name) or
            # it might be a raw expression string — either way we assign it.
            if expr != glsl_var:
                self._lines.append(f"float {glsl_var} = {expr};")
                self._emitted.add(name)
        return glsl_var

    # ------------------------------------------------------------------
    # BinOp: arithmetic or CSG
    # ------------------------------------------------------------------

    def _emit_binop(self, hint_name: str | None, node: BinOp) -> str:
        """Emit a BinOp.  Arithmetic ops produce numeric expressions;
        CSG ops (+ / -) on shapes produce SDF calls.
        """
        left_is_shape = self._is_shape_expr(node.left)
        right_is_shape = self._is_shape_expr(node.right)

        if (node.op in ("+", "-")) and (left_is_shape or right_is_shape):
            return self._emit_csg_binop(hint_name, node)

        # Arithmetic — evaluate numerically and inline
        left_str = self._emit_numeric_expr(node.left)
        right_str = self._emit_numeric_expr(node.right)
        return f"({left_str} {node.op} {right_str})"

    def _emit_csg_binop(self, hint_name: str | None, node: BinOp) -> str:
        """Emit a CSG union or difference, choosing smooth variant if filleted."""
        left_name = self._derive_name(node.left)
        right_name = self._derive_name(node.right)

        left_var = self._emit_expr(left_name, node.left)
        right_var = self._emit_expr(right_name, node.right)

        # Determine smooth radius: check the hint_name (parent shape) for fillets
        smooth_r = self._smooth_radius.get(hint_name, 0.0) if hint_name else 0.0

        if node.op == "+":
            if smooth_r > 0.0:
                glsl_call = f"sdf_smooth_union({left_var}, {right_var}, {_fmt_float(smooth_r)})"
            else:
                glsl_call = f"sdf_union({left_var}, {right_var})"
        else:  # "-"
            if smooth_r > 0.0:
                glsl_call = f"sdf_smooth_difference({left_var}, {right_var}, {_fmt_float(smooth_r)})"
            else:
                glsl_call = f"sdf_difference({left_var}, {right_var})"

        # Name the result
        var_name = _glsl_name(hint_name) if hint_name else self._fresh_var()
        if var_name not in [l.split(" ")[1] for l in self._lines if l.startswith("float ")]:
            self._lines.append(f"float {var_name} = {glsl_call};")
        return var_name

    # ------------------------------------------------------------------
    # FuncCall: rect(...), circle(...), etc.
    # ------------------------------------------------------------------

    def _emit_funccall(self, hint_name: str | None, node: FuncCall) -> str:
        if node.name == "rect":
            return self._emit_rect(hint_name, node, offset=None)
        raise CompileError(f"Unknown function: {node.name!r}")

    def _emit_rect(
        self,
        hint_name: str | None,
        node: FuncCall,
        offset: list | None,
    ) -> str:
        """Emit ``sdf_rect_2d`` for a ``rect(w, h)`` call, optionally with
        an ``at (x, y)`` offset.
        """
        if len(node.args) < 2:
            raise CompileError(f"rect() requires 2 positional args, got {len(node.args)}")

        w_str = self._emit_numeric_expr(node.args[0])
        h_str = self._emit_numeric_expr(node.args[1])

        if offset is not None:
            ox_str = self._emit_numeric_expr(offset[0])
            oy_str = self._emit_numeric_expr(offset[1])
            p_expr = f"p.xy - vec2({ox_str}, {oy_str})"
        else:
            p_expr = "p.xy"

        glsl_call = f"sdf_rect_2d({p_expr}, vec2({w_str}, {h_str}))"

        var_name = _glsl_name(hint_name) if hint_name else self._fresh_var()
        self._lines.append(f"float {var_name} = {glsl_call};")
        if hint_name:
            self._emitted.add(hint_name)
        return var_name

    # ------------------------------------------------------------------
    # AtClause: rect(...) at (x, y)
    # ------------------------------------------------------------------

    def _emit_atclause(self, hint_name: str | None, node: AtClause) -> str:
        """Emit a positioned primitive.  Currently only supports ``rect at``."""
        target = node.target
        if isinstance(target, FuncCall) and target.name == "rect":
            return self._emit_rect(hint_name, target, offset=node.position)
        # Fallback: emit the target, ignoring position (unsupported)
        return self._emit_expr(hint_name, target)

    # ------------------------------------------------------------------
    # Extrude
    # ------------------------------------------------------------------

    def _emit_extrude(self, hint_name: str | None, node: Extrude) -> str:
        """Emit ``sdf_extrude(p, profile_sdf, length)``."""
        profile_name = self._derive_name(node.profile)
        profile_var = self._emit_expr(profile_name, node.profile)
        length_str = self._emit_numeric_expr(node.length)

        glsl_call = f"sdf_extrude(p, {profile_var}, {length_str})"

        var_name = "d"  # conventional final distance variable
        self._lines.append(f"float {var_name} = {glsl_call};")
        return var_name

    # ------------------------------------------------------------------
    # Numeric expression evaluator (for at-clause positions, rect sizes)
    # ------------------------------------------------------------------

    def _emit_numeric_expr(self, node: Any) -> str:
        """Return a GLSL numeric expression string for a numeric AST node.

        Tries to evaluate the expression to a constant first.  Falls back
        to building an inline expression string if evaluation fails.
        Does NOT emit any variable declarations.
        """
        # Try to evaluate as a constant — preferred, produces cleaner GLSL
        try:
            value = self._eval_number(node)
            return _fmt_float(value)
        except CompileError:
            pass

        # Fall back to structural string building
        if isinstance(node, Number):
            return _fmt_float(node.value)

        if isinstance(node, Identifier):
            name = node.name
            if name in self._env:
                resolved = self._env[name]
                if self._is_pure_number(resolved):
                    return _fmt_float(self._eval_number(resolved))
                # Non-numeric identifier — can't inline; use the name as-is
                return name
            return name

        if isinstance(node, UnaryOp) and node.op == "-":
            inner = self._emit_numeric_expr(node.operand)
            return f"-{inner}"

        if isinstance(node, BinOp):
            left = self._emit_numeric_expr(node.left)
            right = self._emit_numeric_expr(node.right)
            return f"({left} {node.op} {right})"

        raise CompileError(
            f"Cannot emit numeric expression for {type(node).__name__}"
        )

    # ------------------------------------------------------------------
    # Utility: evaluate a constant numeric expression to a Python float
    # ------------------------------------------------------------------

    def _eval_number(self, node: Any) -> float:
        """Evaluate a constant numeric AST node to a Python float."""
        if isinstance(node, Number):
            return node.value
        if isinstance(node, Identifier):
            name = node.name
            if name in self._env:
                return self._eval_number(self._env[name])
            raise CompileError(f"Cannot evaluate undefined variable: {name!r}")
        if isinstance(node, UnaryOp) and node.op == "-":
            return -self._eval_number(node.operand)
        if isinstance(node, BinOp):
            left = self._eval_number(node.left)
            right = self._eval_number(node.right)
            if node.op == "+":
                return left + right
            if node.op == "-":
                return left - right
            if node.op == "*":
                return left * right
            if node.op == "/":
                return left / right
        raise CompileError(
            f"Cannot evaluate as number: {type(node).__name__}"
        )

    def _is_pure_number(self, node: Any) -> bool:
        """Return True if *node* resolves to a constant numeric value."""
        try:
            self._eval_number(node)
            return True
        except CompileError:
            return False

    # ------------------------------------------------------------------
    # Utility: determine if an expression is a shape (SDF) expression
    # ------------------------------------------------------------------

    def _is_shape_expr(self, node: Any) -> bool:
        """Heuristic: is this node a shape/SDF expression (not a number)?"""
        if isinstance(node, Number):
            return False
        if isinstance(node, Identifier):
            name = node.name
            if name in self._env:
                return not self._is_pure_number(self._env[name])
            return True  # Unknown — assume shape
        if isinstance(node, FuncCall):
            return node.name in ("rect", "circle", "oval")
        if isinstance(node, AtClause):
            return self._is_shape_expr(node.target)
        if isinstance(node, Extrude):
            return True
        if isinstance(node, BinOp):
            return self._is_shape_expr(node.left) or self._is_shape_expr(node.right)
        return False

    # ------------------------------------------------------------------
    # Utility: derive a hint name from an expression node
    # ------------------------------------------------------------------

    def _derive_name(self, node: Any) -> str | None:
        """Extract a variable name hint from an expression node, if possible."""
        if isinstance(node, Identifier):
            return node.name
        return None

    def _fresh_var(self) -> str:
        """Generate a fresh anonymous GLSL variable name."""
        self._anon_count += 1
        return f"d_tmp{self._anon_count}"
