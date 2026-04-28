"""Shape-tree -> Build123d translator.

Walks the AST produced by ``mcad.parser.parse`` and builds real 3D geometry
using Build123d.  Each AST node maps to one or two Build123d operations.

Design
------
* ``env`` holds variable bindings (name -> value).  Values can be numbers
  (float) or Build123d shapes (Sketch / Part).
* ``parts`` collects named parts produced by ``export`` commands, keyed by
  the export filename.
* Sketch blocks establish a 2D context.  ``rect()`` produces a Build123d
  ``Rectangle`` wrapped in a ``Sketch``.  ``at`` positions it via
  ``Location``.  ``+`` / ``-`` on 2D shapes become boolean fuse / cut.
* ``extrude(profile, length)`` converts a 2D Sketch into a 3D Part.
* ``fillet`` / ``chamfer`` use the edge-numbering module to identify which
  longitudinal edge to modify by matching (x, y) midpoint coordinates.
"""

from __future__ import annotations

from pathlib import Path
import hashlib
import math
from typing import Any

from . import build123d_compat  # noqa: F401  Ensures OCP shims are applied first.

from build123d import (
    Axis,
    Align,
    Box,
    BuildPart,
    BuildSketch,
    Circle,
    Cone,
    Cylinder,
    Ellipse,
    Face,
    GeomType,
    Location,
    Plane,
    Rectangle,
    Shell,
    Solid,
    Sphere,
    Vector,
    Wire,
    add,
    chamfer as bd_chamfer,
    extrude as bd_extrude,
    export_step,
    export_stl,
    fillet as bd_fillet,
    loft as bd_loft,
    mirror as bd_mirror,
    offset as bd_offset,
    scale as bd_scale,
)

from .ast_nodes import (
    Assignment,
    AtClause,
    BinOp,
    Bool,
    Command,
    Export,
    Extrude,
    ForLoop,
    FuncCall,
    Identifier,
    If,
    Index,
    Loft,
    LoftSection,
    MethodCall,
    ModuleDef,
    Number,
    Parameter,
    Program,
    Return,
    SketchBlock,
    String,
    Tuple,
    UnaryOp,
    While,
)
from .edge_numbering import number_edges_2d, number_edges_extruded


class TranslatorError(Exception):
    """Raised when the translator encounters an error during evaluation."""


class _ModuleReturn(Exception):
    """Internal signal raised by a ``Return`` statement.

    Carries the returned value. Caught by ``_call_module`` and never leaks
    to user-visible layers. Using an exception (rather than threading a
    sentinel through normal statement dispatch) keeps control-flow clean:
    any nested ``for`` / ``if`` / ``while`` in the body unwinds naturally.
    """

    def __init__(self, value: Any):
        super().__init__("module return")
        self.value = value


class Translator:
    """Walk an MCAD AST and build Build123d geometry."""

    # Hard cap on while-loop iterations; protects against infinite loops
    # in user code.  Exceeding raises a TranslatorError.
    MAX_WHILE_ITERATIONS = 10_000

    def __init__(self) -> None:
        # Lexical-scope frame stack. The top frame is the *innermost* scope;
        # the base frame (index 0) is the global / top-level environment.
        # Writes always target the top frame (via the ``env`` property);
        # reads walk top-down through ``_lookup``.
        self._env_stack: list[dict[str, Any]] = [{}]
        self.parts: dict[str, Any] = {}  # export filename -> Part (legacy surface)
        # Declared export targets from DSL ``export`` statements. The statement
        # records intent — it does NOT write to disk during translation.
        # Call ``write_exports()`` (or walk this list externally) to flush.
        self.export_targets: list[dict[str, Any]] = []
        self._in_sketch = False  # whether we're inside a sketch: block
        # Track 2D profile vertices for edge numbering.
        # Maps variable name -> list of (x, y) vertices of the composite profile.
        self._profile_vertices: dict[str, list[tuple[float, float]]] = {}
        self._logical_edge_registry: dict[str, list[dict[str, Any]]] = {}
        # Transient state for propagating vertex info through expressions
        self._last_shape_vertices: list[tuple[float, float]] = []
        self._pending_vertices: list[tuple[float, float]] = []
        self._pending_edge_registry: list[dict[str, Any]] = []
        # Name of the most recently bound 3D part; what last_part() returns.
        self._last_part_name: str | None = None
        # User-defined modules: name -> ModuleDef.
        self._module_defs: dict[str, ModuleDef] = {}
        # Active call stack for recursion detection (module names).
        self._call_stack: list[str] = []

    @property
    def env(self) -> dict[str, Any]:
        """Top (innermost) lexical frame.

        Exposed so the dozens of legacy ``self.env[name] = value`` and
        ``self.env.get(name)`` sites keep working unchanged — they all write
        to / read from the innermost scope, which is exactly what we want.
        Cross-scope reads (variables defined in an enclosing frame) go
        through ``_lookup`` instead.
        """
        return self._env_stack[-1]

    def _lookup(self, name: str) -> Any:
        """Walk the frame stack top-down and return the first binding found.

        Raises ``TranslatorError`` with the standard "Undefined variable"
        message if ``name`` is not bound in any frame.
        """
        for frame in reversed(self._env_stack):
            if name in frame:
                return frame[name]
        raise TranslatorError(f"Undefined variable: {name}")

    def translate(self, program: Program) -> dict[str, Any]:
        """Walk the AST and build geometry.  Returns {filename: Part} dict."""
        for stmt in program.statements:
            self._eval_statement(stmt)
        return self.parts

    def last_part(self) -> tuple[str | None, Any | None]:
        """Return the most recently *assigned* 3D part, regardless of whether
        the assignment target was a new name or a reused one.
        """
        name = self._last_part_name
        if name is None:
            return None, None
        value = self.env.get(name)
        if value is None:
            return None, None
        return name, value

    def _bind_value(self, name: str, value: Any) -> None:
        """Bind a value into the env and, if it's a 3D part, mark it as the
        current render target. Centralizing this keeps render-target tracking
        out of dict-insertion-order semantics.
        """
        self.env[name] = value
        if hasattr(value, "tessellate") and hasattr(value, "volume"):
            self._last_part_name = name

    def get_edge_registry(self, shape_name: str) -> list[dict[str, Any]]:
        """Return the stored logical edge registry for an extruded profile."""
        return list(self._logical_edge_registry.get(shape_name, []))

    # ------------------------------------------------------------------
    # Statement dispatch
    # ------------------------------------------------------------------

    def _eval_statement(self, node: Any) -> None:
        if isinstance(node, Assignment):
            self._eval_assignment(node)
        elif isinstance(node, SketchBlock):
            self._eval_sketch_block(node)
        elif isinstance(node, ForLoop):
            self._eval_for_loop(node)
        elif isinstance(node, If):
            self._eval_if(node)
        elif isinstance(node, While):
            self._eval_while(node)
        elif isinstance(node, Command):
            self._eval_command(node)
        elif isinstance(node, Export):
            self._eval_export(node)
        elif isinstance(node, ModuleDef):
            self._eval_module_def(node)
        elif isinstance(node, Return):
            # ``return <expr>`` evaluated in the current (innermost) frame;
            # caught by the enclosing ``_call_module`` via _ModuleReturn.
            raise _ModuleReturn(self._eval_expr(node.value))
        elif isinstance(node, Extrude):
            # Bare extrude (not assigned) -- evaluate but discard
            self._eval_extrude(node)
        elif isinstance(node, Loft):
            self._eval_loft(node)
        else:
            # Expression statement -- evaluate for side effects
            self._eval_expr(node)

    def _eval_module_def(self, node: ModuleDef) -> None:
        """Register a module definition.

        Nested module definitions are not supported in V1: if this is being
        evaluated with more than the base frame on the stack, we're inside
        another module body and must reject.
        """
        if len(self._env_stack) > 1:
            raise TranslatorError("nested module definitions not supported in V1")
        self._module_defs[node.name] = node

    def _eval_assignment(self, node: Assignment) -> None:
        value = self._eval_expr(node.value)
        self._bind_value(node.name, value)

        # Track vertices from rect() or at-clause for edge numbering
        if self._last_shape_vertices:
            self._profile_vertices[node.name] = list(self._last_shape_vertices)
            self._last_shape_vertices = []

        # Track merged vertices from CSG fuse or extrude propagation
        if self._pending_vertices:
            self._profile_vertices[node.name] = list(self._pending_vertices)
            self._pending_vertices = []

        if self._pending_edge_registry:
            self._logical_edge_registry[node.name] = [entry.copy() for entry in self._pending_edge_registry]
            self._pending_edge_registry = []

    # ------------------------------------------------------------------
    # Sketch block
    # ------------------------------------------------------------------

    def _eval_sketch_block(self, node: SketchBlock) -> None:
        self._in_sketch = True
        try:
            for stmt in node.statements:
                self._eval_statement(stmt)
        finally:
            self._in_sketch = False

    def _eval_for_loop(self, node: ForLoop) -> None:
        iterable = self._eval_expr(node.iterable)
        if not isinstance(iterable, list):
            raise TranslatorError(
                f"for-loop iterable must be a list, got {type(iterable).__name__}"
            )
        for element in iterable:
            self._bind_value(node.variable, element)
            for stmt in node.body:
                self._eval_statement(stmt)

    def _eval_if(self, node: If) -> None:
        """Execute the then- or else-branch based on condition truthiness.

        Body assignments leak to the outer environment (same scope as the
        surrounding for-loop / top-level).
        """
        condition = self._eval_expr(node.condition)
        branch = node.then_body if self._truthy(condition) else node.else_body
        for stmt in branch:
            self._eval_statement(stmt)

    def _eval_while(self, node: While) -> None:
        """Evaluate a while-loop with an iteration cap."""
        iterations = 0
        while self._truthy(self._eval_expr(node.condition)):
            if iterations >= self.MAX_WHILE_ITERATIONS:
                raise TranslatorError(
                    f"while-loop exceeded {self.MAX_WHILE_ITERATIONS} iterations"
                    " — probable infinite loop"
                )
            for stmt in node.body:
                self._eval_statement(stmt)
            iterations += 1

    # ------------------------------------------------------------------
    # Expression evaluation
    # ------------------------------------------------------------------

    def _eval_expr(self, node: Any) -> Any:
        if isinstance(node, Number):
            return node.value

        if isinstance(node, Bool):
            return node.value

        if isinstance(node, Tuple):
            return [self._eval_expr(element) for element in node.elements]

        if isinstance(node, String):
            return node.value

        if isinstance(node, Identifier):
            return self._lookup(node.name)

        if isinstance(node, UnaryOp):
            return self._eval_unaryop(node)

        if isinstance(node, BinOp):
            return self._eval_binop(node)

        if isinstance(node, FuncCall):
            return self._eval_func_call(node)

        if isinstance(node, AtClause):
            return self._eval_at_clause(node)

        if isinstance(node, Extrude):
            return self._eval_extrude(node)

        if isinstance(node, Loft):
            return self._eval_loft(node)

        if isinstance(node, MethodCall):
            return self._eval_method_call(node)

        if isinstance(node, Index):
            return self._eval_index(node)

        raise TranslatorError(f"Cannot evaluate AST node: {type(node).__name__}")

    # ------------------------------------------------------------------
    # Binary operations (arithmetic or CSG)
    # ------------------------------------------------------------------

    def _eval_binop(self, node: BinOp) -> Any:
        # Short-circuit logical ops: evaluate the right side only if needed.
        if node.op == "&&":
            left = self._eval_expr(node.left)
            if not self._truthy(left):
                return False
            return self._truthy(self._eval_expr(node.right))
        if node.op == "||":
            left = self._eval_expr(node.left)
            if self._truthy(left):
                return True
            return self._truthy(self._eval_expr(node.right))

        left = self._eval_expr(node.left)
        right = self._eval_expr(node.right)

        # Comparison ops — both sides must be numeric (bools allowed as ints).
        if node.op in ("<", ">", "<=", ">=", "==", "!="):
            if isinstance(left, bool) or isinstance(right, bool):
                # Only '==' and '!=' make sense for bools; forbid ordering.
                if node.op in ("==", "!="):
                    return (left == right) if node.op == "==" else (left != right)
                raise TranslatorError(
                    f"Comparison '{node.op}' not supported on booleans"
                )
            if not (isinstance(left, (int, float)) and isinstance(right, (int, float))):
                raise TranslatorError(
                    f"Comparison '{node.op}' requires numeric operands, got "
                    f"{type(left).__name__} and {type(right).__name__}"
                )
            if node.op == "<":
                return left < right
            if node.op == ">":
                return left > right
            if node.op == "<=":
                return left <= right
            if node.op == ">=":
                return left >= right
            if node.op == "==":
                return left == right
            if node.op == "!=":
                return left != right

        # Arithmetic on numbers
        if isinstance(left, (int, float)) and isinstance(right, (int, float)) \
                and not isinstance(left, bool) and not isinstance(right, bool):
            if node.op == "+":
                return left + right
            if node.op == "-":
                return left - right
            if node.op == "*":
                return left * right
            if node.op == "/":
                if right == 0:
                    raise TranslatorError("Division by zero")
                return left / right
            raise TranslatorError(f"Unknown arithmetic op: {node.op}")

        # CSG on shapes (Sketch or Part)
        if node.op == "+":
            return self._csg_fuse(left, right)
        if node.op == "-":
            return self._csg_cut(left, right)

        raise TranslatorError(
            f"Operator '{node.op}' not supported between "
            f"{type(left).__name__} and {type(right).__name__}"
        )

    def _eval_unaryop(self, node: UnaryOp) -> Any:
        if node.op == "!":
            # `!` always evaluates its operand; truthiness rule applies.
            operand = self._eval_expr(node.operand)
            return not self._truthy(operand)
        if node.op == "-":
            operand = self._eval_expr(node.operand)
            if isinstance(operand, bool):
                raise TranslatorError("Unary '-' not supported on bool")
            if isinstance(operand, (int, float)):
                return -operand
            raise TranslatorError(
                f"Unary '-' not supported on {type(operand).__name__}"
            )
        raise TranslatorError(f"Unknown unary op: {node.op}")

    def _truthy(self, value: Any) -> bool:
        """Unified truthiness rule used by ``if``, ``while``, ``&&``, ``||``, ``!``.

        - bool: self
        - int/float: non-zero is truthy
        - list: non-empty is truthy
        - shape (has .tessellate and .volume): always truthy
        - anything else: TranslatorError
        """
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return value != 0
        if isinstance(value, list):
            return len(value) > 0
        if hasattr(value, "tessellate") and hasattr(value, "volume"):
            return True
        raise TranslatorError(
            f"Cannot evaluate truthiness of {type(value).__name__}"
        )

    def _csg_fuse(self, left: Any, right: Any) -> Any:
        """Boolean fuse (union) of two shapes."""
        result = left.fuse(right)
        self._merge_profile_vertices(left, right)
        # Skip for 2D sketches: they have edges() but volume == 0, and the
        # extrude path will populate the proper registry once they go 3D.
        if self._is_solid(result):
            self._pending_edge_registry = self._rebuild_registry_preserving_ids(
                left, result
            )
        return result

    def _csg_cut(self, left: Any, right: Any) -> Any:
        """Boolean cut (difference) of two shapes."""
        result = left.cut(right)
        if self._is_solid(result):
            self._pending_edge_registry = self._rebuild_registry_preserving_ids(
                left, result
            )
        return result

    def _rebuild_registry_preserving_ids(
        self, left: Any, result: Any
    ) -> list[dict[str, Any]]:
        """Rebuild registry for ``result`` after a topology-changing op.

        Preserves LEFT's logical IDs for edges whose midpoints survive the
        operation (matched within 0.1mm). Genuinely new edges get fresh IDs
        assigned after ``max(preserved_ids)``.

        Falls back to fresh 1..N enumeration when LEFT has no extruded
        registry (i.e., its entries lack ``axis_name``).
        """
        left_name = self._find_env_name(left)
        old_registry: list[dict[str, Any]] = []
        if left_name:
            old_registry = self._logical_edge_registry.get(left_name, [])

        has_extruded = any(e.get("axis_name") is not None for e in old_registry)
        if not has_extruded:
            return self._enumerate_edges(result)

        new_entries = self._enumerate_edges(result)
        tol = 0.1

        preserved: list[dict[str, Any]] = []
        unmatched: list[dict[str, Any]] = []
        used_old_ids: set[int] = set()

        for new_entry in new_entries:
            new_mid = new_entry.get("midpoint")
            match = None
            if isinstance(new_mid, list) and len(new_mid) >= 3:
                for old_entry in old_registry:
                    old_id = old_entry.get("id")
                    if old_id in used_old_ids:
                        continue
                    old_mid = old_entry.get("midpoint")
                    if not (isinstance(old_mid, list) and len(old_mid) >= 3):
                        continue
                    if (
                        abs(old_mid[0] - new_mid[0]) < tol
                        and abs(old_mid[1] - new_mid[1]) < tol
                        and abs(old_mid[2] - new_mid[2]) < tol
                    ):
                        match = old_entry
                        break
            if match is None:
                unmatched.append(new_entry)
                continue
            merged = dict(new_entry)
            merged["id"] = match["id"]
            merged["source_plane"] = match.get("source_plane")
            merged["source_point"] = match.get("source_point")
            if match.get("axis_name") is not None:
                merged["axis_name"] = match["axis_name"]
            if match.get("tags"):
                merged["tags"] = list(match["tags"])
            preserved.append(merged)
            used_old_ids.add(match["id"])

        next_id = (max(used_old_ids) if used_old_ids else 0) + 1
        for new_entry in unmatched:
            new_entry["id"] = next_id
            next_id += 1

        return preserved + unmatched

    @staticmethod
    def _is_solid(value: Any) -> bool:
        """True iff value looks like a 3D part (non-zero volume)."""
        if not hasattr(value, "edges") or not hasattr(value, "volume"):
            return False
        try:
            return float(value.volume) > 0.0
        except Exception:
            return False

    def _merge_profile_vertices(self, left: Any, right: Any) -> None:
        """Track composite profile vertices after a fuse operation.

        When two 2D profiles are fused, the resulting profile's vertices
        are the union of the originals' vertices (for edge numbering
        purposes, the unique vertices of the combined profile).
        """
        left_name = self._find_env_name(left)
        right_name = self._find_env_name(right)

        merged: list[tuple[float, float]] = []
        if left_name and left_name in self._profile_vertices:
            merged.extend(self._profile_vertices[left_name])
        if right_name and right_name in self._profile_vertices:
            merged.extend(self._profile_vertices[right_name])

        if merged:
            # Store as pending so _eval_assignment can pick it up.
            self._pending_vertices = merged

    def _find_env_name(self, value: Any) -> str | None:
        """Find the environment variable name for a given value (by identity)."""
        for name, val in self.env.items():
            if val is value:
                return name
        return None

    # ------------------------------------------------------------------
    # Function calls
    # ------------------------------------------------------------------

    def _eval_func_call(self, node: FuncCall) -> Any:
        # User-defined modules take priority over built-ins. Built-in names
        # may therefore be shadowed by a module of the same name, which is
        # consistent with how a user would expect their own definitions to
        # win.
        if node.name in self._module_defs:
            return self._call_module(node)
        if node.name == "rect":
            return self._make_rect(node)
        if node.name == "circle":
            return self._make_circle(node)
        if node.name == "oval":
            return self._make_oval(node)
        if node.name == "cube":
            return self._make_cube(node)
        if node.name == "sphere":
            return self._make_sphere(node)
        if node.name == "cylinder":
            return self._make_cylinder(node)
        if node.name == "polyhedron":
            return self._make_polyhedron(node)
        if node.name == "translate":
            return self._apply_translate(node)
        if node.name == "rotate":
            return self._apply_rotate(node)
        if node.name == "scale":
            return self._apply_scale(node)
        if node.name == "mirror":
            return self._apply_mirror(node)
        raise TranslatorError(f"Unknown function: {node.name}")

    # ------------------------------------------------------------------
    # User-defined module call
    # ------------------------------------------------------------------

    def _call_module(self, node: FuncCall) -> Any:
        """Invoke a user-defined module with the caller's args/kwargs.

        Calling convention:
          * Positional args bind to params in declaration order.
          * Kwargs must match a declared parameter name; duplicates with
            a positional binding raise.
          * Unbound params use their default (evaluated in the caller's
            frame stack); missing required params raise.
          * Recursion is rejected in V1: if the module name is already on
            ``_call_stack``, raise before pushing.
          * A fresh frame is pushed onto ``_env_stack`` for the body. All
            parameter bindings go into that frame; local assignments in
            the body write there too. Outer scopes remain visible for
            reads via ``_lookup``.
          * The body must ``return``. If it completes without a
            ``_ModuleReturn`` surfacing, we raise the "did not return"
            error.
          * The frame + call-stack entry are always popped in ``finally``.
        """
        module_def = self._module_defs[node.name]
        params: list[Parameter] = module_def.params

        if len(node.args) > len(params):
            raise TranslatorError(
                f"module {node.name}() takes {len(params)} positional "
                f"argument(s), got {len(node.args)}"
            )

        # Evaluate positional args in the caller's (current) frame.
        positional_values = [self._eval_expr(arg) for arg in node.args]

        # Validate kwargs against declared param names.
        param_names = {p.name for p in params}
        for kw_name in node.kwargs:
            if kw_name not in param_names:
                raise TranslatorError(
                    f"module {node.name}() got unexpected keyword argument '{kw_name}'"
                )

        # Build the binding map in param order.
        bindings: dict[str, Any] = {}
        for idx, param in enumerate(params):
            if idx < len(positional_values):
                if param.name in node.kwargs:
                    raise TranslatorError(
                        f"module {node.name}() got multiple values for argument "
                        f"'{param.name}'"
                    )
                bindings[param.name] = positional_values[idx]
            elif param.name in node.kwargs:
                bindings[param.name] = self._eval_expr(node.kwargs[param.name])
            elif param.default is not None:
                # Defaults are evaluated in the caller's scope each call.
                bindings[param.name] = self._eval_expr(param.default)
            else:
                raise TranslatorError(
                    f"module {node.name}() missing required argument '{param.name}'"
                )

        # Recursion check: V1 forbids a module from being on its own
        # active call stack.
        if node.name in self._call_stack:
            raise TranslatorError(f"recursion not supported in V1: {node.name}")

        self._call_stack.append(node.name)
        self._env_stack.append(dict(bindings))
        try:
            for stmt in module_def.body:
                self._eval_statement(stmt)
        except _ModuleReturn as ret:
            return ret.value
        else:
            raise TranslatorError(f"module {node.name} did not return a value")
        finally:
            self._env_stack.pop()
            self._call_stack.pop()

    def _make_rect(self, node: FuncCall) -> Any:
        """Create a Build123d Rectangle (2D sketch)."""
        if len(node.args) < 2:
            raise TranslatorError("rect() requires 2 arguments (width, height)")

        width = self._eval_expr(node.args[0])
        height = self._eval_expr(node.args[1])

        if not isinstance(width, (int, float)) or not isinstance(height, (int, float)):
            raise TranslatorError(
                f"rect() arguments must be numbers, got {type(width).__name__} "
                f"and {type(height).__name__}"
            )

        with BuildSketch() as sk:
            Rectangle(width, height)

        sketch = sk.sketch

        # Track the rectangle vertices (centred at origin before positioning)
        hw, hh = width / 2, height / 2
        verts = [
            (hw, hh),
            (-hw, hh),
            (-hw, -hh),
            (hw, -hh),
        ]
        self._last_shape_vertices = verts
        return sketch

    def _make_circle(self, node: FuncCall) -> Any:
        """Create a Build123d Circle (2D sketch)."""
        if len(node.args) < 1:
            raise TranslatorError("circle() requires 1 argument (radius)")

        radius = self._eval_expr(node.args[0])

        with BuildSketch() as sk:
            Circle(radius)

        return sk.sketch

    def _make_oval(self, node: FuncCall) -> Any:
        """Create a Build123d Ellipse from width + height."""
        if len(node.args) < 2:
            raise TranslatorError("oval() requires 2 arguments (width, height)")

        width = self._eval_expr(node.args[0])
        height = self._eval_expr(node.args[1])

        if not isinstance(width, (int, float)) or not isinstance(height, (int, float)):
            raise TranslatorError(
                f"oval() arguments must be numbers, got {type(width).__name__} "
                f"and {type(height).__name__}"
            )
        if float(width) <= 0.0 or float(height) <= 0.0:
            raise TranslatorError("oval() width and height must be > 0")

        with BuildSketch() as sk:
            Ellipse(float(width) / 2.0, float(height) / 2.0)

        # Ovals don't participate in the legacy profile-vertex numbering path.
        self._last_shape_vertices = []
        return sk.sketch

    def _make_cube(self, node: FuncCall) -> Any:
        """Create an OpenSCAD-style cube as a 3D solid."""
        if self._in_sketch:
            raise TranslatorError("cube() is a 3D primitive and cannot be used inside sketch:")

        center = self._coerce_center_kw(node.kwargs.get("center", False))
        size_value = node.kwargs.get("size")
        if size_value is not None:
            if node.args:
                raise TranslatorError("cube() cannot combine size= with positional size arguments")
            size = self._eval_expr(size_value)
            if not isinstance(size, (int, float)):
                raise TranslatorError("cube(size=...) requires a numeric scalar in V1")
            dimensions = (float(size), float(size), float(size))
        else:
            dimensions = self._coerce_cube_dimensions(node.args)

        align = (
            (Align.CENTER, Align.CENTER, Align.CENTER)
            if center
            else (Align.MIN, Align.MIN, Align.MIN)
        )
        result = Box(*dimensions, align=align)
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _make_sphere(self, node: FuncCall) -> Any:
        """Create an OpenSCAD-style sphere as a 3D solid."""
        if self._in_sketch:
            raise TranslatorError("sphere() is a 3D primitive and cannot be used inside sketch:")

        radius_expr = node.kwargs.get("r")
        if radius_expr is None:
            if len(node.args) != 1:
                raise TranslatorError("sphere() requires exactly 1 radius argument")
            radius = self._eval_expr(node.args[0])
        else:
            if node.args:
                raise TranslatorError("sphere() cannot mix r= with positional arguments")
            radius = self._eval_expr(radius_expr)

        if not isinstance(radius, (int, float)):
            raise TranslatorError("sphere() radius must be numeric")
        result = Sphere(float(radius))
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _make_cylinder(self, node: FuncCall) -> Any:
        """Create an OpenSCAD-style cylinder or tapered cylinder."""
        if self._in_sketch:
            raise TranslatorError("cylinder() is a 3D primitive and cannot be used inside sketch:")

        center = self._coerce_center_kw(node.kwargs.get("center", False))
        height, radius, radius1, radius2 = self._coerce_cylinder_args(node)
        align = (
            (Align.CENTER, Align.CENTER, Align.CENTER)
            if center
            else (Align.CENTER, Align.CENTER, Align.MIN)
        )

        if radius is not None:
            result = Cylinder(float(radius), float(height), align=align)
        else:
            result = Cone(float(radius1), float(radius2), float(height), align=align)
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _make_polyhedron(self, node: FuncCall) -> Any:
        """Create an OpenSCAD-style polyhedron from points + face indices."""
        if self._in_sketch:
            raise TranslatorError("polyhedron() is a 3D primitive and cannot be used inside sketch:")

        points_expr = node.kwargs.get("points")
        faces_expr = node.kwargs.get("faces")
        if points_expr is None and faces_expr is None:
            if len(node.args) < 2:
                raise TranslatorError("polyhedron() requires points and faces")
            points_expr, faces_expr = node.args[0], node.args[1]
        elif points_expr is None or faces_expr is None:
            raise TranslatorError("polyhedron() requires both points= and faces=")
        elif node.args:
            raise TranslatorError("polyhedron() cannot mix keyword and positional points/faces")

        points = self._eval_expr(points_expr)
        faces = self._eval_expr(faces_expr)

        if not isinstance(points, list) or not points:
            raise TranslatorError("polyhedron() points must be a non-empty list of [x,y,z]")
        vectors: list[Vector] = []
        for i, pt in enumerate(points):
            if not isinstance(pt, list) or len(pt) != 3 or not all(isinstance(c, (int, float)) for c in pt):
                raise TranslatorError(f"polyhedron() point {i} must be a 3-element numeric vector")
            vectors.append(Vector(float(pt[0]), float(pt[1]), float(pt[2])))

        if not isinstance(faces, list) or not faces:
            raise TranslatorError("polyhedron() faces must be a non-empty list of index lists")
        bd_faces: list[Face] = []
        for fi, face in enumerate(faces):
            if not isinstance(face, list) or len(face) < 3:
                raise TranslatorError(f"polyhedron() face {fi} must be a list of ≥3 vertex indices")
            verts: list[Vector] = []
            for idx in face:
                if not isinstance(idx, (int, float)) or int(idx) != idx:
                    raise TranslatorError(f"polyhedron() face {fi} indices must be integers")
                i = int(idx)
                if i < 0 or i >= len(vectors):
                    raise TranslatorError(f"polyhedron() face {fi} index {i} out of range")
                verts.append(vectors[i])
            try:
                wire = Wire.make_polygon(verts, close=True)
                bd_faces.append(Face(wire))
            except Exception as exc:
                raise TranslatorError(f"polyhedron() face {fi} is degenerate: {exc}") from exc

        try:
            shell = Shell(bd_faces)
            result = Solid(shell)
        except Exception as exc:
            raise TranslatorError(
                f"polyhedron() could not form a closed solid from {len(bd_faces)} faces: {exc}"
            ) from exc
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _coerce_center_kw(self, raw_value: Any) -> bool:
        value = raw_value if isinstance(raw_value, bool) else self._eval_expr(raw_value)
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return bool(value)
        raise TranslatorError("center= must be a boolean or numeric 0/1 value")

    def _coerce_cube_dimensions(self, args: list[Any]) -> tuple[float, float, float]:
        if len(args) == 1:
            size = self._eval_expr(args[0])
            if not isinstance(size, (int, float)):
                raise TranslatorError("cube(size) requires a numeric scalar in V1")
            side = float(size)
            return (side, side, side)
        if len(args) == 3:
            dims = [self._eval_expr(arg) for arg in args]
            if not all(isinstance(dim, (int, float)) for dim in dims):
                raise TranslatorError("cube(x, y, z) requires numeric dimensions")
            return (float(dims[0]), float(dims[1]), float(dims[2]))
        raise TranslatorError("cube() requires either 1 scalar size or 3 dimensions in V1")

    def _coerce_cylinder_args(
        self,
        node: FuncCall,
    ) -> tuple[float, float | None, float | None, float | None]:
        if len(node.args) > 2:
            raise TranslatorError("cylinder() accepts at most 2 positional arguments in V1")

        kwargs = node.kwargs
        if "h" in kwargs:
            if node.args:
                raise TranslatorError("cylinder() cannot mix h= with positional height arguments")
            height = self._eval_expr(kwargs["h"])
            remaining_args: list[Any] = []
        else:
            if not node.args:
                raise TranslatorError("cylinder() requires height as the first positional arg or h=")
            height = self._eval_expr(node.args[0])
            remaining_args = node.args[1:]

        if not isinstance(height, (int, float)):
            raise TranslatorError("cylinder() height must be numeric")

        radius = None
        radius1 = None
        radius2 = None

        if "r" in kwargs:
            if remaining_args:
                raise TranslatorError("cylinder() cannot mix r= with a positional radius")
            radius = self._eval_expr(kwargs["r"])
        elif remaining_args:
            radius = self._eval_expr(remaining_args[0])

        if "r1" in kwargs:
            radius1 = self._eval_expr(kwargs["r1"])
        if "r2" in kwargs:
            radius2 = self._eval_expr(kwargs["r2"])

        if radius is not None and (radius1 is not None or radius2 is not None):
            raise TranslatorError("cylinder() cannot combine r with r1/r2")

        if radius is not None:
            if not isinstance(radius, (int, float)):
                raise TranslatorError("cylinder() radius must be numeric")
            return (float(height), float(radius), None, None)

        if radius1 is None and radius2 is None:
            raise TranslatorError("cylinder() requires r or r1/r2")
        if radius1 is None:
            radius1 = radius2
        if radius2 is None:
            radius2 = radius1
        if not isinstance(radius1, (int, float)) or not isinstance(radius2, (int, float)):
            raise TranslatorError("cylinder() radii must be numeric")
        return (float(height), None, float(radius1), float(radius2))

    def _apply_translate(self, node: FuncCall) -> Any:
        """Translate a shape using OpenSCAD-style translate([x, y, z], shape)."""
        offset_values, shape = self._coerce_transform_args(node, "translate")
        result = shape.moved(Location(tuple(offset_values), (0.0, 0.0, 0.0)))
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _apply_rotate(self, node: FuncCall) -> Any:
        """Rotate a shape using OpenSCAD-style rotate([rx, ry, rz], shape)."""
        rotation_values, shape = self._coerce_transform_args(node, "rotate")
        result = shape.moved(Location((0.0, 0.0, 0.0), tuple(rotation_values)))
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _apply_scale(self, node: FuncCall) -> Any:
        """Scale a 3D solid using OpenSCAD-style scale([sx, sy, sz], shape)."""
        scale_values, shape = self._coerce_transform_args(node, "scale")
        if not self._is_solid(shape):
            raise TranslatorError("scale() second argument must be a 3D solid")
        result = bd_scale(shape, by=tuple(scale_values))
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _apply_mirror(self, node: FuncCall) -> Any:
        """Mirror a 3D solid about an origin-centered plane normal."""
        normal_values, shape = self._coerce_transform_args(node, "mirror")
        if not self._is_solid(shape):
            raise TranslatorError("mirror() second argument must be a 3D solid")

        nx, ny, nz = normal_values
        mag = math.sqrt(nx * nx + ny * ny + nz * nz)
        if mag <= 0.0:
            raise TranslatorError("mirror() normal vector must be non-zero")
        plane = Plane(origin=(0.0, 0.0, 0.0), z_dir=(nx / mag, ny / mag, nz / mag))
        result = bd_mirror(shape, about=plane)
        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    def _coerce_transform_args(
        self,
        node: FuncCall,
        name: str,
    ) -> tuple[list[float], Any]:
        if node.kwargs:
            raise TranslatorError(f"{name}() does not support keyword arguments in V1")
        if len(node.args) != 2:
            raise TranslatorError(f"{name}() requires exactly 2 arguments: [x, y, z], shape")

        raw_values = self._eval_expr(node.args[0])
        if not isinstance(raw_values, list) or len(raw_values) != 3:
            raise TranslatorError(f"{name}() first argument must be a 3-element vector literal")
        if not all(isinstance(value, (int, float)) for value in raw_values):
            raise TranslatorError(f"{name}() vector values must be numeric")

        shape = self._eval_expr(node.args[1])
        if not hasattr(shape, "moved"):
            raise TranslatorError(f"{name}() second argument must be a shape")
        return ([float(value) for value in raw_values], shape)

    # ------------------------------------------------------------------
    # At clause (positioning)
    # ------------------------------------------------------------------

    def _eval_at_clause(self, node: AtClause) -> Any:
        """Position a shape at (x, y) using Build123d Location."""
        shape = self._eval_expr(node.target)

        if node.anchor != "center":
            raise TranslatorError(f"Unsupported placement anchor: {node.anchor}")

        if len(node.position) < 2:
            raise TranslatorError("at clause requires (x, y) position")

        x = self._eval_expr(node.position[0])
        y = self._eval_expr(node.position[1])

        if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
            raise TranslatorError(
                f"at clause position must be numbers, got {type(x).__name__} "
                f"and {type(y).__name__}"
            )

        # Move the shape using Location
        positioned = shape.moved(Location(Vector(x, y, 0)))

        # Update tracked vertices with the offset
        if self._last_shape_vertices:
            self._last_shape_vertices = [
                (vx + x, vy + y) for vx, vy in self._last_shape_vertices
            ]

        return positioned

    # ------------------------------------------------------------------
    # Extrude
    # ------------------------------------------------------------------

    def _eval_extrude(self, node: Extrude) -> Any:
        """Extrude a 2D profile into a 3D part."""
        # Resolve the profile name (for vertex tracking)
        profile_name = None
        if isinstance(node.profile, Identifier):
            profile_name = node.profile.name

        profile = self._eval_expr(node.profile)
        length = self._eval_expr(node.length)

        if not isinstance(length, (int, float)):
            raise TranslatorError(
                f"extrude() length must be a number, got {type(length).__name__}"
            )

        with BuildPart() as bp:
            add(profile)
            bd_extrude(amount=length)

        result = bp.part

        # Propagate profile vertices so fillet/chamfer can find them.
        # The extruded part inherits the 2D profile's vertex data.
        # We store this as pending so _eval_assignment can pick it up.
        if profile_name and profile_name in self._profile_vertices:
            self._pending_vertices = list(
                self._profile_vertices[profile_name]
            )
            self._pending_edge_registry = self._build_extruded_edge_registry(
                result,
                self._profile_vertices[profile_name],
            )
        else:
            self._pending_edge_registry = self._enumerate_edges(result)

        return result

    def _eval_loft(self, node: Loft) -> Any:
        """Loft a solid through multiple ordered 2D sections.

        V1 keeps the section syntax explicit but only supports ``z=<pos>``
        sections. That is sufficient for ergonomic body tests such as a mouse
        shell without forcing us to finalize multi-axis loft placement yet.
        """
        if len(node.sections) < 2:
            raise TranslatorError("loft requires at least 2 sections")

        axis_name: str | None = None
        sections: list[tuple[float, Any]] = []
        for section in node.sections:
            if not isinstance(section, LoftSection):
                raise TranslatorError("invalid loft section")
            sec_axis = section.axis.lower()
            if axis_name is None:
                axis_name = sec_axis
            elif sec_axis != axis_name:
                raise TranslatorError("all loft sections must use the same axis")
            if sec_axis != "z":
                raise TranslatorError("V1 loft currently supports only z=<position> sections")

            position = self._eval_expr(section.position)
            if not isinstance(position, (int, float)):
                raise TranslatorError("loft section positions must be numeric")

            profile = self._eval_expr(section.profile)
            if self._is_solid(profile):
                raise TranslatorError("loft sections must be closed 2D profiles, not solids")
            if not hasattr(profile, "moved"):
                raise TranslatorError("loft section expression must evaluate to a 2D profile")

            moved_profile = profile.moved(
                Location((0.0, 0.0, float(position)), (0.0, 0.0, 0.0))
            )
            sections.append((float(position), moved_profile))

        sections.sort(key=lambda item: item[0])
        ordered_profiles = [profile for _, profile in sections]

        try:
            result = bd_loft(ordered_profiles)
        except Exception as exc:
            raise TranslatorError(f"loft failed: {exc}") from exc

        self._pending_edge_registry = self._enumerate_edges(result)
        return result

    # ------------------------------------------------------------------
    # Commands (fillet, chamfer, export)
    # ------------------------------------------------------------------

    def _eval_command(self, node: Command) -> None:
        if node.name == "fillet":
            self._cmd_fillet(node)
        elif node.name == "chamfer":
            self._cmd_chamfer(node)
        elif node.name == "shell":
            self._cmd_shell(node)
        else:
            raise TranslatorError(f"Unknown command: {node.name}")

    def _cmd_fillet(self, node: Command) -> None:
        """``fillet shape, edge_num, r=radius``"""
        if len(node.args) < 2:
            raise TranslatorError(
                "fillet requires at least 2 arguments (shape, edge_num)"
            )
        if "r" not in node.kwargs:
            raise TranslatorError("fillet requires r=radius keyword argument")

        shape_node = node.args[0]
        edge_num_node = node.args[1]
        radius_node = node.kwargs["r"]

        if not isinstance(shape_node, Identifier):
            raise TranslatorError("fillet first argument must be a variable name")

        shape_name = shape_node.name
        shape = self.env.get(shape_name)
        if shape is None:
            raise TranslatorError(f"Undefined variable: {shape_name}")

        edge_num = int(self._eval_expr(edge_num_node))
        radius = self._eval_expr(radius_node)

        target_edge = self._find_edge_by_number(shape, shape_name, edge_num)

        # Apply fillet -- updates the shape in-place in the env
        result = bd_fillet(target_edge, radius=radius)
        self._bind_value(shape_name, result)
        # Topology changed; refresh registry with a fresh 1..N enumeration.
        # Extruded shapes keep their richer plane-based registry — generic
        # enumeration is only used when the existing registry is generic
        # or empty (cubes/spheres/cylinders/booleans).
        self._refresh_registry_after_topology_change(shape_name, result)

    def _cmd_chamfer(self, node: Command) -> None:
        """``chamfer shape, edge_num, d=distance``"""
        if len(node.args) < 2:
            raise TranslatorError(
                "chamfer requires at least 2 arguments (shape, edge_num)"
            )
        if "d" not in node.kwargs:
            raise TranslatorError("chamfer requires d=distance keyword argument")

        shape_node = node.args[0]
        edge_num_node = node.args[1]
        distance_node = node.kwargs["d"]

        if not isinstance(shape_node, Identifier):
            raise TranslatorError("chamfer first argument must be a variable name")

        shape_name = shape_node.name
        shape = self.env.get(shape_name)
        if shape is None:
            raise TranslatorError(f"Undefined variable: {shape_name}")

        edge_num = int(self._eval_expr(edge_num_node))
        distance = self._eval_expr(distance_node)

        target_edge = self._find_edge_by_number(shape, shape_name, edge_num)

        result = bd_chamfer(target_edge, length=distance)
        self._bind_value(shape_name, result)
        # Topology changed; refresh registry with a fresh 1..N enumeration.
        # See _cmd_fillet for why extruded registries are preserved.
        self._refresh_registry_after_topology_change(shape_name, result)

    def _cmd_shell(self, node: Command) -> None:
        """``shell shape, 1.5`` or ``shell shape, t=1.5``.

        V1 ships a closed-shell primitive only. Open-face selectors are
        deferred until we have a clearer face-addressing surface.
        """
        if not node.args:
            raise TranslatorError("shell requires at least 1 argument (shape)")

        shape_node = node.args[0]
        if not isinstance(shape_node, Identifier):
            raise TranslatorError("shell first argument must be a variable name")

        shape_name = shape_node.name
        shape = self.env.get(shape_name)
        if shape is None:
            raise TranslatorError(f"Undefined variable: {shape_name}")
        if not self._is_solid(shape):
            raise TranslatorError("shell target must be a 3D solid")

        if "open" in node.kwargs:
            raise TranslatorError("shell open-face selection is deferred in V1")

        thickness_node = node.kwargs.get("t") or node.kwargs.get("thickness")
        if thickness_node is None:
            if len(node.args) < 2:
                raise TranslatorError("shell requires a thickness argument")
            thickness_node = node.args[1]

        thickness = self._eval_expr(thickness_node)
        if not isinstance(thickness, (int, float)):
            raise TranslatorError("shell thickness must be numeric")
        if float(thickness) <= 0.0:
            raise TranslatorError("shell thickness must be > 0")

        try:
            result = bd_offset(shape, amount=-float(thickness))
        except Exception as exc:
            raise TranslatorError(f"shell failed: {exc}") from exc

        self._bind_value(shape_name, result)
        self._logical_edge_registry[shape_name] = self._enumerate_edges(result)

    def _refresh_registry_after_topology_change(
        self, shape_name: str, result: Any
    ) -> None:
        """Re-enumerate edges generically iff the existing registry is generic.

        Extruded solids carry the richer plane-based registry built by
        ``_build_extruded_edge_registry`` (entries have ``axis_name`` and
        ``source_plane`` populated). We preserve that across fillet/chamfer
        so users can keep referring to the extrusion's logical edge IDs.
        For everything else (primitives, transforms, boolean results), the
        existing registry — if any — is generic, so a fresh enumeration is
        the right answer.
        """
        existing = self._logical_edge_registry.get(shape_name, [])
        is_extruded_registry = bool(existing) and any(
            entry.get("axis_name") is not None for entry in existing
        )
        if is_extruded_registry:
            return
        self._logical_edge_registry[shape_name] = self._enumerate_edges(result)

    def _find_edge_by_number(
        self, shape: Any, shape_name: str, edge_num: int
    ) -> Any:
        """Map an MCAD edge number to a Build123d Edge object.

        For extruded profiles, each 2D vertex becomes a longitudinal edge
        parallel to the Z axis.  We use the edge numbering module to get
        the (x, y) coordinates, then match by comparing the edge midpoint.
        """
        registry = self._logical_edge_registry.get(shape_name, [])
        if not registry:
            raise TranslatorError(
                f"No logical edge registry for {shape_name} -- "
                f"edge numbering requires a known 2D profile"
            )

        target_info = None
        for edge_info in registry:
            if int(edge_info.get("id", 0)) == edge_num:
                target_info = edge_info
                break
        if target_info is None:
            raise TranslatorError(
                f"Edge number {edge_num} out of range "
                f"(profile has {len(registry)} logical edges)"
            )

        axis_name_raw = target_info.get("axis_name")
        midpoint = target_info.get("midpoint", [])
        if not (isinstance(midpoint, list) and len(midpoint) >= 3):
            raise TranslatorError(f"Logical edge {edge_num} is missing midpoint data")

        # Extruded entries carry ``axis_name`` ("X"/"Y"/"Z") and we filter
        # candidates by that axis for accuracy. Generic entries (cube/sphere/
        # cylinder/booleans/post-fillet) lack ``axis_name`` — match by
        # midpoint across all edges.
        if axis_name_raw is None:
            candidate_edges = list(shape.edges())
            axis_label = "any"
        else:
            axis_name = str(axis_name_raw)
            axis = {"X": Axis.X, "Y": Axis.Y, "Z": Axis.Z}.get(axis_name, Axis.Z)
            candidate_edges = shape.edges().filter_by(axis)
            axis_label = axis_name

        tolerance = 0.1
        for edge in candidate_edges:
            mid = edge.center()
            if (
                abs(mid.X - float(midpoint[0])) < tolerance
                and abs(mid.Y - float(midpoint[1])) < tolerance
                and abs(mid.Z - float(midpoint[2])) < tolerance
            ):
                return edge

        raise TranslatorError(
            f"Could not locate {axis_label}-parallel edge near "
            f"({midpoint[0]}, {midpoint[1]}, {midpoint[2]}) for edge number {edge_num}"
        )

    # ------------------------------------------------------------------
    # Generic edge enumeration (non-extrusion shapes)
    # ------------------------------------------------------------------

    # Default view-visibility for generic registry entries: all six standard
    # orthographic views. We don't compute per-edge visibility in V1.
    _GENERIC_VISIBLE_VIEWS = ["Top", "Bottom", "Left", "Right", "Front", "Back"]

    def _enumerate_edges(self, shape: Any) -> list[dict[str, Any]]:
        """Walk shape.edges() and produce a generic registry list.

        Used for primitives, transforms, booleans, and post-fillet/chamfer
        shapes — anywhere ``_build_extruded_edge_registry`` doesn't apply.

        Each entry conforms to the same schema as extrude-registry entries
        (``id``/``source_plane``/``start``/``end``/``source_point``/
        ``midpoint``/``axis``/``length``/``tags``/``visible_in_views``) and
        adds ``kind`` plus optional ``center``/``radius``/``normal`` for
        circular edges. ``axis`` is the unit direction for straight edges,
        ``None`` otherwise.

        IDs are a fresh 1..N sequence; they are NOT preserved across
        topology-changing operations.
        """
        if shape is None or not hasattr(shape, "edges"):
            return []

        all_edges = list(shape.edges())
        adjacency = self._build_edge_face_adjacency(shape, all_edges)
        wire_membership = self._build_wire_membership(shape, all_edges)

        entries: list[dict[str, Any]] = []
        next_id = 1
        for i, edge in enumerate(all_edges):
            geom = edge.geom_type
            if geom == GeomType.LINE:
                kind = "straight"
            elif geom == GeomType.CIRCLE:
                kind = "circle"
            else:
                kind = "curve"

            face_types = adjacency[i]
            role = self._classify_edge_role(kind, face_types)

            # Seams are parametric-surface closure artifacts (OCCT represents
            # cylinders/cones/spheres as "rolled" sheets; the closure line is
            # a seam edge). They aren't user-visible features — hide them from
            # the registry so they don't get numbered or rendered.
            if role == "seam":
                continue
            entry_id = next_id
            next_id += 1

            start_v = edge.start_point()
            end_v = edge.end_point()
            mid_v = edge @ 0.5

            start = [float(start_v.X), float(start_v.Y), float(start_v.Z)]
            end = [float(end_v.X), float(end_v.Y), float(end_v.Z)]
            midpoint = [float(mid_v.X), float(mid_v.Y), float(mid_v.Z)]

            axis: list[float] | None = None
            center: list[float] | None = None
            radius: float | None = None
            normal: list[float] | None = None

            if kind == "straight":
                dx = end[0] - start[0]
                dy = end[1] - start[1]
                dz = end[2] - start[2]
                mag = math.sqrt(dx * dx + dy * dy + dz * dz)
                if mag > 0.0:
                    axis = [dx / mag, dy / mag, dz / mag]
                else:
                    axis = [0.0, 0.0, 0.0]
            elif kind == "circle":
                arc_center = edge.arc_center
                center = [float(arc_center.X), float(arc_center.Y), float(arc_center.Z)]
                radius = float(edge.radius)
                normal_v = edge.normal()
                normal = [float(normal_v.X), float(normal_v.Y), float(normal_v.Z)]

            tags = self._derive_semantic_tags(kind, role, wire_membership[i])

            entries.append(
                {
                    "id": entry_id,
                    "kind": kind,
                    "source_plane": None,
                    "source_point": None,
                    "start": start,
                    "end": end,
                    "midpoint": midpoint,
                    "axis": axis,
                    "center": center,
                    "radius": radius,
                    "normal": normal,
                    "length": float(edge.length),
                    "role": role,
                    "tags": tags,
                    "visible_in_views": list(self._GENERIC_VISIBLE_VIEWS),
                }
            )
        return entries

    def _build_edge_face_adjacency(
        self, shape: Any, edges: list[Any]
    ) -> list[list[str]]:
        """For each edge in ``edges``, return the sorted list of adjacent face
        ``geom_type`` strings (e.g. ``["PLANE", "CYLINDER"]``).

        Gotcha: in OCCT, ``edge.faces()`` on a standalone edge returns an empty
        list. You have to iterate ``shape.faces()`` and match each face's own
        edges against the target edges using ``IsSame``. Python ``id()`` does
        NOT work for TopoDS_Shape identity.
        """
        adjacency: list[list[str]] = [[] for _ in edges]
        try:
            faces = list(shape.faces())
        except Exception:
            return adjacency
        for face in faces:
            face_type = str(face.geom_type).replace("GeomType.", "")
            try:
                face_edges = list(face.edges())
            except Exception:
                continue
            for fe in face_edges:
                fe_shape = getattr(fe, "wrapped", None)
                if fe_shape is None:
                    continue
                for i, edge in enumerate(edges):
                    e_shape = getattr(edge, "wrapped", None)
                    if e_shape is None:
                        continue
                    if e_shape.IsSame(fe_shape):
                        adjacency[i].append(face_type)
                        break
        for entry in adjacency:
            entry.sort()
        return adjacency

    def _build_wire_membership(
        self, shape: Any, edges: list[Any]
    ) -> list[set[str]]:
        """For each edge in ``edges``, return the set of wire-membership labels.

        Labels are ``"outer"`` (edge belongs to a face's outer wire) and/or
        ``"inner"`` (edge belongs to a face's inner wire / hole boundary).

        An edge can appear in both sets when it sits on the outer wire of one
        face and the inner wire of another (rare but topologically valid).

        Uses the same ``IsSame`` matching as ``_build_edge_face_adjacency``
        because Python object identity does not work for OCCT shapes.
        """
        membership: list[set[str]] = [set() for _ in edges]
        try:
            faces = list(shape.faces())
        except Exception:
            return membership

        for face in faces:
            try:
                outer_wire = face.outer_wire()
                outer_edges = list(outer_wire.edges())
            except Exception:
                outer_edges = []

            try:
                inner_wire_edges: list[Any] = []
                for iw in face.inner_wires():
                    inner_wire_edges.extend(list(iw.edges()))
            except Exception:
                inner_wire_edges = []

            for wire_edge in outer_edges:
                we_shape = getattr(wire_edge, "wrapped", None)
                if we_shape is None:
                    continue
                for i, edge in enumerate(edges):
                    e_shape = getattr(edge, "wrapped", None)
                    if e_shape is None:
                        continue
                    if e_shape.IsSame(we_shape):
                        membership[i].add("outer")
                        break

            for wire_edge in inner_wire_edges:
                we_shape = getattr(wire_edge, "wrapped", None)
                if we_shape is None:
                    continue
                for i, edge in enumerate(edges):
                    e_shape = getattr(edge, "wrapped", None)
                    if e_shape is None:
                        continue
                    if e_shape.IsSame(we_shape):
                        membership[i].add("inner")
                        break

        return membership

    @staticmethod
    def _classify_edge_role(kind: str, face_types: list[str]) -> str:
        """Classify an edge's geometric role from its curve kind plus the
        geom_types of its adjacent faces.

        See DCR 019d8fb3dbe6 for the role catalog.
        """
        n = len(face_types)
        types = set(face_types)
        curved = {"CYLINDER", "CONE", "SPHERE", "TORUS", "BSPLINE_SURFACE", "BEZIER_SURFACE"}

        if kind == "curve":
            return "curve"
        if kind == "straight":
            if n == 2 and types == {"PLANE"}:
                return "corner"
            # Parametric-surface seam: a closed revolved surface (cylinder/cone)
            # is stored by OCCT as a rolled sheet stitched along a line edge.
            # That edge reports 1 adjacent face (the curved surface itself).
            if n == 1 and face_types[0] in curved:
                return "seam"
            if n == 2 and "PLANE" in types and types & curved:
                return "chamfer_connector"
            return "other"
        if kind == "circle":
            if n == 2 and "PLANE" in types and (types & curved):
                return "rim"
            if n == 2 and types.issubset(curved) and "CONE" in types and "CYLINDER" in types:
                return "cone_cylinder_junction"
            # Sphere seam: a build123d Sphere reports a single CIRCLE edge
            # adjacent to only 1 SPHERE face — the meridian closure. Same
            # artifact as cylinder seams, different curve kind.
            if n == 1 and face_types[0] in curved:
                return "seam"
            return "other"
        return "other"

    @staticmethod
    def _derive_semantic_tags(
        kind: str,
        role: str,
        wire_labels: set[str],
    ) -> list[str]:
        """Return the semantic tag list for an edge given its curve kind, role,
        and wire-membership labels.

        Tag vocabulary
        --------------
        Curve-kind tags (mutually exclusive):
          ``"linear"``      — straight (LINE) edge
          ``"circular"``    — circle or arc edge
          ``"curve"``       — any other parametric curve

        Role-derived tags (may be combined):
          ``"corner"``             — straight edge between two planar faces
          ``"rim"``                — circle edge between a planar and curved face
          ``"chamfer_connector"``  — straight edge between planar and curved faces
          ``"feature"``            — superset: any of corner / rim / chamfer_connector

        Wire-membership tags (may be combined):
          ``"outer"``   — edge appears in at least one face's outer wire
          ``"inner"``   — edge appears in at least one face's inner wire (hole)

        Seam edges are never passed to this method (they are skipped before
        tag assignment in both emission paths).
        """
        tags: list[str] = []

        # Curve-kind tag.
        if kind == "straight":
            tags.append("linear")
        elif kind == "circle":
            tags.append("circular")
        else:
            tags.append("curve")

        # Role-derived semantic tags.
        if role in {"corner", "rim", "chamfer_connector"}:
            tags.append(role)
            tags.append("feature")

        # Wire-membership tags (deduplication via set → sorted for stability).
        for label in sorted(wire_labels):
            tags.append(label)

        return tags

    def _build_extruded_edge_registry(
        self,
        shape: Any,
        profile_vertices: list[tuple[float, float]],
    ) -> list[dict[str, Any]]:
        """Build a stable logical registry for an axis-aligned extrusion.

        V1 fast path:
        - XY plane numbers longitudinal Z edges from the source profile vertices.
        - XZ plane numbers X-parallel cap edges.
        - YZ plane numbers Y-parallel cap edges.

        Wire membership (outer/inner) is computed once for the whole shape and
        threaded through the sub-builders so semantic tags are consistent with
        the generic path.
        """
        # Build face-adjacency and wire-membership once for the whole shape.
        # The sub-builders receive both tables and look up individual edges via
        # IsSame when assembling each registry entry.
        all_shape_edges = list(shape.edges())
        adjacency = self._build_edge_face_adjacency(shape, all_shape_edges)
        wire_membership = self._build_wire_membership(shape, all_shape_edges)

        registry: list[dict[str, Any]] = []
        xy_entries = self._build_xy_registry_entries(
            shape, profile_vertices, all_shape_edges, adjacency, wire_membership
        )
        registry.extend(xy_entries)

        next_id = len(registry) + 1
        x_edges = list(shape.edges().filter_by(Axis.X))
        registry.extend(
            self._build_axis_plane_entries(
                x_edges, "XZ", "X", next_id, all_shape_edges, adjacency, wire_membership
            )
        )

        next_id = len(registry) + 1
        y_edges = list(shape.edges().filter_by(Axis.Y))
        registry.extend(
            self._build_axis_plane_entries(
                y_edges, "YZ", "Y", next_id, all_shape_edges, adjacency, wire_membership
            )
        )
        return registry

    def _build_xy_registry_entries(
        self,
        shape: Any,
        profile_vertices: list[tuple[float, float]],
        all_shape_edges: list[Any] | None = None,
        adjacency: list[list[str]] | None = None,
        wire_membership: list[set[str]] | None = None,
    ) -> list[dict[str, Any]]:
        """Number longitudinal edges from the 2D profile vertices."""
        numbering = number_edges_2d(profile_vertices)
        z_edges = list(shape.edges().filter_by(Axis.Z))
        entries: list[dict[str, Any]] = []

        for edge_num, target_xy in numbering.items():
            matched_edge = None
            for edge in z_edges:
                midpoint = edge.center()
                if (
                    abs(midpoint.X - target_xy[0]) < 0.1
                    and abs(midpoint.Y - target_xy[1]) < 0.1
                ):
                    matched_edge = edge
                    break
            if matched_edge is None:
                continue
            face_types = self._lookup_face_types(matched_edge, all_shape_edges, adjacency)
            role = self._classify_edge_role("straight", face_types)
            wire_labels = self._lookup_wire_labels(
                matched_edge, all_shape_edges, wire_membership
            )
            spatial_tags = self._derive_spatial_tags(matched_edge.center(), "Z")
            semantic_tags = self._derive_semantic_tags("straight", role, wire_labels)
            # Merge: spatial first, then semantic (deduped, order-stable).
            seen: set[str] = set(spatial_tags)
            combined = list(spatial_tags)
            for t in semantic_tags:
                if t not in seen:
                    combined.append(t)
                    seen.add(t)
            entries.append(
                self._make_registry_entry(
                    edge_num=edge_num,
                    edge=matched_edge,
                    source_plane="XY",
                    axis_name="Z",
                    kind="longitudinal",
                    source_point=[float(target_xy[0]), float(target_xy[1])],
                    tags=combined,
                )
            )
        return entries

    def _build_axis_plane_entries(
        self,
        edges: list[Any],
        source_plane: str,
        axis_name: str,
        start_id: int,
        all_shape_edges: list[Any] | None = None,
        adjacency: list[list[str]] | None = None,
        wire_membership: list[set[str]] | None = None,
    ) -> list[dict[str, Any]]:
        """Number X- or Y-parallel cap edges by plane-local polar sweep."""
        projected = [self._project_midpoint(edge.center(), source_plane) for edge in edges]
        if not projected:
            return []

        center = (
            sum(point[0] for point in projected) / len(projected),
            sum(point[1] for point in projected) / len(projected),
        )
        ordered_edges = sorted(
            edges,
            key=lambda edge: self._plane_sort_key(edge, source_plane, center),
        )

        entries: list[dict[str, Any]] = []
        for offset, edge in enumerate(ordered_edges):
            midpoint = edge.center()
            face_types = self._lookup_face_types(edge, all_shape_edges, adjacency)
            role = self._classify_edge_role("straight", face_types)
            wire_labels = self._lookup_wire_labels(
                edge, all_shape_edges, wire_membership
            )
            spatial_tags = self._derive_spatial_tags(midpoint, axis_name)
            semantic_tags = self._derive_semantic_tags("straight", role, wire_labels)
            seen: set[str] = set(spatial_tags)
            combined = list(spatial_tags)
            for t in semantic_tags:
                if t not in seen:
                    combined.append(t)
                    seen.add(t)
            entries.append(
                self._make_registry_entry(
                    edge_num=start_id + offset,
                    edge=edge,
                    source_plane=source_plane,
                    axis_name=axis_name,
                    kind="cap_edge",
                    source_point=list(self._project_midpoint(midpoint, source_plane)),
                    tags=combined,
                )
            )
        return entries

    def _make_registry_entry(
        self,
        *,
        edge_num: int,
        edge: Any,
        source_plane: str,
        axis_name: str,
        kind: str,
        source_point: list[float],
        tags: list[str],
    ) -> dict[str, Any]:
        vertices = list(edge.vertices())
        if len(vertices) >= 2:
            start = [float(vertices[0].X), float(vertices[0].Y), float(vertices[0].Z)]
            end = [float(vertices[1].X), float(vertices[1].Y), float(vertices[1].Z)]
        else:
            midpoint = edge.center()
            start = [float(midpoint.X), float(midpoint.Y), float(midpoint.Z)]
            end = list(start)

        midpoint = edge.center()
        midpoint_list = [float(midpoint.X), float(midpoint.Y), float(midpoint.Z)]
        axis_vector = {
            "X": [1.0, 0.0, 0.0],
            "Y": [0.0, 1.0, 0.0],
            "Z": [0.0, 0.0, 1.0],
        }[axis_name]

        return {
            "id": edge_num,
            "kind": kind,
            "source_plane": source_plane,
            "source_point": source_point,
            "start": start,
            "end": end,
            "midpoint": midpoint_list,
            "axis": axis_vector,
            "axis_name": axis_name,
            "length": float(edge.length),
            "tags": tags,
            "visible_in_views": self._visible_views_for_axis(axis_name),
        }

    def _plane_sort_key(
        self,
        edge: Any,
        source_plane: str,
        center: tuple[float, float],
    ) -> tuple[float, float, str]:
        projected = self._project_midpoint(edge.center(), source_plane)
        dx = projected[0] - center[0]
        dy = projected[1] - center[1]
        angle = math.atan2(dy, dx)
        if angle < 0:
            angle += 2 * math.pi
        distance = math.hypot(dx, dy)
        return (angle, distance, self._edge_hash(edge))

    def _project_midpoint(
        self,
        point: Any,
        source_plane: str,
    ) -> tuple[float, float]:
        if source_plane == "XY":
            return (float(point.X), float(point.Y))
        if source_plane == "XZ":
            return (float(point.X), float(point.Z))
        if source_plane == "YZ":
            return (float(point.Y), float(point.Z))
        raise TranslatorError(f"Unsupported source plane: {source_plane}")

    def _edge_hash(self, edge: Any) -> str:
        vertices = list(edge.vertices())
        coords = sorted(
            (round(v.X, 6), round(v.Y, 6), round(v.Z, 6))
            for v in vertices
        )
        raw = "|".join(f"{x},{y},{z}" for x, y, z in coords)
        return hashlib.sha256(raw.encode()).hexdigest()

    @staticmethod
    def _lookup_wire_labels(
        edge: Any,
        all_shape_edges: list[Any] | None,
        wire_membership: list[set[str]] | None,
    ) -> set[str]:
        """Return the wire-membership label set for ``edge`` by finding its
        position in ``all_shape_edges`` via ``IsSame``.

        Returns an empty set when either lookup table is absent (graceful
        degradation for call-sites that don't have them).
        """
        if all_shape_edges is None or wire_membership is None:
            return set()
        e_shape = getattr(edge, "wrapped", None)
        if e_shape is None:
            return set()
        for i, candidate in enumerate(all_shape_edges):
            c_shape = getattr(candidate, "wrapped", None)
            if c_shape is None:
                continue
            if e_shape.IsSame(c_shape):
                return set(wire_membership[i])
        return set()

    @staticmethod
    def _lookup_face_types(
        edge: Any,
        all_shape_edges: list[Any] | None,
        adjacency: list[list[str]] | None,
    ) -> list[str]:
        """Return the sorted adjacent face-type list for ``edge`` by finding
        its position in ``all_shape_edges`` via ``IsSame``.

        Returns ``[]`` when either lookup table is absent.
        """
        if all_shape_edges is None or adjacency is None:
            return []
        e_shape = getattr(edge, "wrapped", None)
        if e_shape is None:
            return []
        for i, candidate in enumerate(all_shape_edges):
            c_shape = getattr(candidate, "wrapped", None)
            if c_shape is None:
                continue
            if e_shape.IsSame(c_shape):
                return list(adjacency[i])
        return []

    def _derive_spatial_tags(self, point: Any, axis_name: str) -> list[str]:
        tags = [f"axis_{axis_name.lower()}"]

        tolerance = 0.001
        if point.X > tolerance:
            tags.append("positive_x")
            tags.append("right")
        elif point.X < -tolerance:
            tags.append("negative_x")
            tags.append("left")

        if point.Y > tolerance:
            tags.append("positive_y")
            tags.append("up_y")
        elif point.Y < -tolerance:
            tags.append("negative_y")
            tags.append("down_y")

        if point.Z > tolerance:
            tags.append("positive_z")
            tags.append("far_z")
        elif point.Z < -tolerance:
            tags.append("negative_z")
            tags.append("near_z")

        return tags

    def _visible_views_for_axis(self, axis_name: str) -> list[str]:
        """Return orthographic views where an edge axis projects as a line.

        A view can only show/select an edge when the edge is not parallel to
        that view's look direction. Perspective is handled viewer-side.
        """
        if axis_name == "X":
            return ["Front", "Back", "Top", "Bottom"]
        if axis_name == "Y":
            return ["Front", "Back", "Left", "Right"]
        if axis_name == "Z":
            return ["Top", "Bottom", "Left", "Right"]
        return []

    def _eval_export(self, node: Export) -> None:
        """``export <name> "<path>"`` — declare a file-export target.

        The DSL statement is declarative, not imperative: evaluating it records
        the target in ``self.export_targets`` but does NOT write to disk. This
        keeps iterative preview runs side-effect-free. To actually flush the
        files, call ``write_exports()`` or walk ``export_targets`` externally
        (e.g. a UI-driven export button).

        Path resolution (cross-platform):
          * absolute path → used as-is
          * starts with ``~`` → ``expanduser()``
          * bare relative path → resolved against ``Path.home()``

        Format is inferred from the extension (``.stl``, ``.3mf``,
        ``.step``/``.stp``). Unsupported extensions fail at declaration time.
        """
        shape = self._lookup(node.name)
        if shape is None:
            raise TranslatorError(f"Undefined variable: {node.name}")
        if isinstance(shape, (int, float, bool, str, list, tuple)):
            raise TranslatorError(
                f"export target '{node.name}' must be a 3D shape, got "
                f"{type(shape).__name__}"
            )

        resolved = _resolve_export_path(node.path)
        ext = resolved.suffix.lower()
        if ext not in _SUPPORTED_EXPORT_EXTS:
            raise TranslatorError(f"Unsupported export format: {ext}")

        self.export_targets.append({
            "name": node.name,
            "path": str(resolved),
            "shape": shape,
        })

    def write_exports(self) -> list[str]:
        """Flush all declared export targets to disk. Returns written paths."""
        written: list[str] = []
        for target in self.export_targets:
            path = export_shape(target["shape"], target["path"])
            self.parts[path] = target["shape"]
            written.append(path)
        return written

    # ------------------------------------------------------------------
    # Method calls (future: .rotate, .mirror, etc.)
    # ------------------------------------------------------------------

    def _eval_method_call(self, node: MethodCall) -> Any:
        raise TranslatorError(f"Method call .{node.method}() not yet supported")

    def _eval_index(self, node: Index) -> Any:
        target = self._eval_expr(node.target)
        index = self._eval_expr(node.index)
        if isinstance(target, str):
            raise TranslatorError("strings aren't indexable in V1")
        if not isinstance(target, list):
            raise TranslatorError(f"cannot index {type(target).__name__}")
        if isinstance(index, bool) or not isinstance(index, (int, float)):
            raise TranslatorError(f"index must be an integer, got {type(index).__name__}")
        if isinstance(index, float) and int(index) != index:
            raise TranslatorError(f"index must be integer-valued, got {index}")
        i = int(index)
        if i < 0 or i >= len(target):
            raise TranslatorError(f"index {i} out of range for list of length {len(target)}")
        return target[i]


# ---------------------------------------------------------------------------
# Public convenience function
# ---------------------------------------------------------------------------


def translate(source: str) -> dict[str, Any]:
    """Parse and translate MCAD source text.  Returns {filename: Part}."""
    from .parser import parse

    program = parse(source)
    translator = Translator()
    return translator.translate(program)


_SUPPORTED_EXPORT_EXTS: set[str] = {".stl", ".step", ".stp", ".3mf"}


def _resolve_export_path(raw: str) -> Path:
    """Resolve an export path per MCAD DSL conventions.

    Absolute paths (``/foo``, ``C:\\foo``) are used as-is. Paths that start
    with ``~`` are expanded. Bare relative paths resolve against the user's
    home directory (``Path.home()``) — cross-platform-safe via pathlib.
    """
    p = Path(raw).expanduser()
    if p.is_absolute():
        return p
    return Path.home() / p


def export_shape(shape: Any, filename: str) -> str:
    """Export a Build123d shape to the path indicated by *filename*."""
    output_path = Path(filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    ext = output_path.suffix.lower()
    if ext in (".step", ".stp"):
        export_step(shape, str(output_path))
    elif ext == ".stl":
        export_stl(shape, str(output_path))
    elif ext == ".3mf":
        from build123d import Mesher

        mesher = Mesher()
        mesher.add_shape(shape)
        mesher.write(str(output_path))
    else:
        raise TranslatorError(f"Unsupported export format: {ext}")

    return str(output_path)
