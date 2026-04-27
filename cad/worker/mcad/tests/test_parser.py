"""Tests for the MCAD parser."""

import pytest

from mcad.parser import parse, ParseError
from mcad.ast_nodes import (
    Assignment,
    AtClause,
    BinOp,
    Bool,
    Command,
    Extrude,
    ForLoop,
    FuncCall,
    Identifier,
    If,
    Index,
    Loft,
    LoftSection,
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


# ---------------------------------------------------------------------------
# Variable assignment
# ---------------------------------------------------------------------------

class TestAssignment:
    def test_simple_int(self):
        prog = parse("height = 100\n")
        assert len(prog.statements) == 1
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert stmt.name == "height"
        assert isinstance(stmt.value, Number)
        assert stmt.value.value == 100

    def test_simple_float(self):
        prog = parse("ratio = 3.14\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert isinstance(stmt.value, Number)
        assert stmt.value.value == 3.14

    def test_multiple_assignments(self):
        src = "height = 100\nwidth = 80\nthickness = 10\n"
        prog = parse(src)
        assert len(prog.statements) == 3
        assert all(isinstance(s, Assignment) for s in prog.statements)
        names = [s.name for s in prog.statements]
        assert names == ["height", "width", "thickness"]

    def test_boolean_literal(self):
        prog = parse("centered = true\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert isinstance(stmt.value, Bool)
        assert stmt.value.value is True


# ---------------------------------------------------------------------------
# Arithmetic expression precedence
# ---------------------------------------------------------------------------

class TestArithmeticPrecedence:
    def test_subtraction(self):
        prog = parse("x = a - b\n")
        val = prog.statements[0].value
        assert isinstance(val, BinOp)
        assert val.op == "-"
        assert isinstance(val.left, Identifier) and val.left.name == "a"
        assert isinstance(val.right, Identifier) and val.right.name == "b"

    def test_mul_binds_tighter_than_sub(self):
        """``height - thickness/2`` should parse as ``height - (thickness/2)``."""
        prog = parse("x = height - thickness/2\n")
        val = prog.statements[0].value
        assert isinstance(val, BinOp)
        assert val.op == "-"
        assert isinstance(val.left, Identifier)
        assert val.left.name == "height"
        # Right side should be thickness / 2
        assert isinstance(val.right, BinOp)
        assert val.right.op == "/"
        assert isinstance(val.right.left, Identifier)
        assert val.right.left.name == "thickness"
        assert isinstance(val.right.right, Number)
        assert val.right.right.value == 2

    def test_parens_override_precedence(self):
        """``(height - thickness) / 2`` should group the subtraction first."""
        prog = parse("x = (height - thickness) / 2\n")
        val = prog.statements[0].value
        assert isinstance(val, BinOp)
        assert val.op == "/"
        assert isinstance(val.left, BinOp)
        assert val.left.op == "-"

    def test_chained_addition(self):
        """``a + b + c`` is left-associative."""
        prog = parse("x = a + b + c\n")
        val = prog.statements[0].value
        assert isinstance(val, BinOp)
        assert val.op == "+"
        assert isinstance(val.left, BinOp)
        assert val.left.op == "+"
        assert isinstance(val.right, Identifier) and val.right.name == "c"

    def test_unary_negation(self):
        prog = parse("x = -5\n")
        val = prog.statements[0].value
        assert isinstance(val, UnaryOp)
        assert val.op == "-"
        assert isinstance(val.operand, Number)
        assert val.operand.value == 5


# ---------------------------------------------------------------------------
# Sketch block with rect and CSG
# ---------------------------------------------------------------------------

class TestSketchBlock:
    SOURCE = (
        "sketch:\n"
        "    flange = rect(width, thickness) center at point(0, height - thickness/2)\n"
        "    web = rect(thickness, height - thickness) center at point(0, (height - thickness)/2)\n"
        "    profile = flange + web\n"
    )

    def test_sketch_block_parsed(self):
        prog = parse(self.SOURCE)
        assert len(prog.statements) == 1
        sketch = prog.statements[0]
        assert isinstance(sketch, SketchBlock)

    def test_sketch_has_three_statements(self):
        prog = parse(self.SOURCE)
        sketch = prog.statements[0]
        assert len(sketch.statements) == 3

    def test_flange_assignment(self):
        prog = parse(self.SOURCE)
        sketch = prog.statements[0]
        flange = sketch.statements[0]
        assert isinstance(flange, Assignment)
        assert flange.name == "flange"
        # Value should be AtClause wrapping a FuncCall
        assert isinstance(flange.value, AtClause)
        assert flange.value.anchor == "center"
        assert isinstance(flange.value.target, FuncCall)
        assert flange.value.target.name == "rect"
        assert len(flange.value.target.args) == 2

    def test_flange_at_clause_position(self):
        prog = parse(self.SOURCE)
        sketch = prog.statements[0]
        flange = sketch.statements[0]
        at = flange.value
        assert isinstance(at, AtClause)
        # Position should be [0, height - thickness/2]
        assert len(at.position) == 2
        assert isinstance(at.position[0], Number)
        assert at.position[0].value == 0
        # Second position is an expression: height - thickness/2
        assert isinstance(at.position[1], BinOp)
        assert at.position[1].op == "-"

    def test_web_assignment(self):
        prog = parse(self.SOURCE)
        sketch = prog.statements[0]
        web = sketch.statements[1]
        assert isinstance(web, Assignment)
        assert web.name == "web"
        assert isinstance(web.value, AtClause)
        assert web.value.anchor == "center"
        assert isinstance(web.value.target, FuncCall)
        assert web.value.target.name == "rect"

    def test_web_rect_args(self):
        """rect(thickness, height - thickness) — second arg is a BinOp."""
        prog = parse(self.SOURCE)
        sketch = prog.statements[0]
        web = sketch.statements[1]
        rect_call = web.value.target
        assert len(rect_call.args) == 2
        assert isinstance(rect_call.args[0], Identifier)
        assert rect_call.args[0].name == "thickness"
        assert isinstance(rect_call.args[1], BinOp)
        assert rect_call.args[1].op == "-"

    def test_profile_csg_union(self):
        prog = parse(self.SOURCE)
        sketch = prog.statements[0]
        profile = sketch.statements[2]
        assert isinstance(profile, Assignment)
        assert profile.name == "profile"
        assert isinstance(profile.value, BinOp)
        assert profile.value.op == "+"
        assert isinstance(profile.value.left, Identifier)
        assert profile.value.left.name == "flange"
        assert isinstance(profile.value.right, Identifier)
        assert profile.value.right.name == "web"

    def test_legacy_at_syntax_still_parses(self):
        prog = parse("sketch:\n    flange = rect(width, thickness) at (0, 2)\n")
        sketch = prog.statements[0]
        flange = sketch.statements[0]
        assert isinstance(flange.value, AtClause)
        assert flange.value.anchor == "center"


# ---------------------------------------------------------------------------
# Fillet command
# ---------------------------------------------------------------------------

class TestFilletCommand:
    def test_fillet_parsed(self):
        prog = parse("fillet beam, 2, r=4\n")
        assert len(prog.statements) == 1
        cmd = prog.statements[0]
        assert isinstance(cmd, Command)
        assert cmd.name == "fillet"

    def test_fillet_args(self):
        prog = parse("fillet beam, 2, r=4\n")
        cmd = prog.statements[0]
        assert len(cmd.args) == 2
        assert isinstance(cmd.args[0], Identifier)
        assert cmd.args[0].name == "beam"
        assert isinstance(cmd.args[1], Number)
        assert cmd.args[1].value == 2

    def test_fillet_kwargs(self):
        prog = parse("fillet beam, 2, r=4\n")
        cmd = prog.statements[0]
        assert "r" in cmd.kwargs
        assert isinstance(cmd.kwargs["r"], Number)
        assert cmd.kwargs["r"].value == 4


# ---------------------------------------------------------------------------
# Chamfer command
# ---------------------------------------------------------------------------

class TestChamferCommand:
    def test_chamfer_parsed(self):
        prog = parse("chamfer beam, 1, d=3\n")
        cmd = prog.statements[0]
        assert isinstance(cmd, Command)
        assert cmd.name == "chamfer"
        assert len(cmd.args) == 2
        assert cmd.kwargs["d"].value == 3


# ---------------------------------------------------------------------------
# Loft block
# ---------------------------------------------------------------------------

class TestLoftBlock:
    SOURCE = (
        "body = loft:\n"
        "    z=0: oval(58, 34)\n"
        "    z=40: oval(64, 38)\n"
        "    z=85: oval(54, 30)\n"
        "    z=110: oval(32, 16)\n"
    )

    def test_loft_assignment_parsed(self):
        prog = parse(self.SOURCE)
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert stmt.name == "body"
        assert isinstance(stmt.value, Loft)

    def test_loft_has_sections(self):
        prog = parse(self.SOURCE)
        loft = prog.statements[0].value
        assert len(loft.sections) == 4
        assert all(isinstance(section, LoftSection) for section in loft.sections)

    def test_loft_section_contents(self):
        prog = parse(self.SOURCE)
        section = prog.statements[0].value.sections[1]
        assert section.axis == "z"
        assert isinstance(section.position, Number)
        assert section.position.value == 40
        assert isinstance(section.profile, FuncCall)
        assert section.profile.name == "oval"

    def test_loft_requires_at_least_two_sections(self):
        with pytest.raises(ParseError, match="at least 2 section"):
            parse("body = loft:\n    z=0: oval(58, 34)\n")


# ---------------------------------------------------------------------------
# Export command
# ---------------------------------------------------------------------------

class TestExportStatement:
    def test_export_parsed(self):
        from mcad.ast_nodes import Export

        prog = parse('export beam "t_beam.3mf"\n')
        stmt = prog.statements[0]
        assert isinstance(stmt, Export)
        assert stmt.name == "beam"
        assert stmt.path == "t_beam.3mf"

    def test_export_stl_parsed(self):
        from mcad.ast_nodes import Export

        prog = parse('export part "beam.stl"\n')
        stmt = prog.statements[0]
        assert isinstance(stmt, Export)
        assert stmt.name == "part"
        assert stmt.path == "beam.stl"

    def test_export_rejects_comma_syntax(self):
        import pytest as _pt

        from mcad.parser import ParseError

        with _pt.raises(ParseError):
            parse('export beam, "beam.stl"\n')

    def test_export_requires_string_path(self):
        import pytest as _pt

        from mcad.parser import ParseError

        with _pt.raises(ParseError):
            parse('export beam filename\n')

    def test_export_requires_identifier(self):
        import pytest as _pt

        from mcad.parser import ParseError

        with _pt.raises(ParseError):
            parse('export "beam.stl"\n')


class TestSolidPrimitiveCalls:
    def test_cube_with_center_kw_parsed(self):
        prog = parse("part = cube(10, center=true)\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert isinstance(stmt.value, FuncCall)
        assert stmt.value.name == "cube"
        assert len(stmt.value.args) == 1
        assert isinstance(stmt.value.kwargs["center"], Bool)
        assert stmt.value.kwargs["center"].value is True

    def test_cylinder_with_r1_r2_kwargs_parsed(self):
        prog = parse("part = cylinder(h=12, r1=4, r2=2, center=false)\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert isinstance(stmt.value, FuncCall)
        assert stmt.value.name == "cylinder"
        assert set(stmt.value.kwargs.keys()) == {"h", "r1", "r2", "center"}

    def test_translate_with_vector_literal_parsed(self):
        prog = parse("part = translate([1, 2, 3], cube(10))\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert isinstance(stmt.value, FuncCall)
        assert stmt.value.name == "translate"
        assert isinstance(stmt.value.args[0], Tuple)
        assert len(stmt.value.args[0].elements) == 3
        assert isinstance(stmt.value.args[1], FuncCall)
        assert stmt.value.args[1].name == "cube"


# ---------------------------------------------------------------------------
# Extrude
# ---------------------------------------------------------------------------

class TestExtrude:
    def test_extrude_assignment(self):
        prog = parse("beam = extrude(profile, length)\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert stmt.name == "beam"
        assert isinstance(stmt.value, Extrude)
        assert isinstance(stmt.value.profile, Identifier)
        assert stmt.value.profile.name == "profile"
        assert isinstance(stmt.value.length, Identifier)
        assert stmt.value.length.name == "length"


# ---------------------------------------------------------------------------
# Full T-beam example from spec section 7.3
# ---------------------------------------------------------------------------

T_BEAM_SOURCE = """\
# T-beam — V1 test part
# t_beam.mcad

height = 100
width = 80
thickness = 10
length = 200

sketch:
    flange = rect(width, thickness) center at point(0, height - thickness/2)
    web = rect(thickness, height - thickness) center at point(0, (height - thickness)/2)
    profile = flange + web

beam = extrude(profile, length)

fillet beam, 2, r=4
fillet beam, 8, r=4
chamfer beam, 1, d=3
chamfer beam, 9, d=3

export beam "t_beam.3mf"
"""


class TestTBeamFull:
    @pytest.fixture
    def prog(self):
        return parse(T_BEAM_SOURCE)

    def test_parses_without_error(self, prog):
        assert isinstance(prog, Program)

    def test_statement_count(self, prog):
        # 4 assignments + 1 sketch + 1 extrude assignment + 2 fillets + 2 chamfers + 1 export = 11
        assert len(prog.statements) == 11

    def test_variable_assignments(self, prog):
        """First four statements are simple variable assignments."""
        for i, (name, val) in enumerate([
            ("height", 100),
            ("width", 80),
            ("thickness", 10),
            ("length", 200),
        ]):
            stmt = prog.statements[i]
            assert isinstance(stmt, Assignment), f"Statement {i} should be Assignment"
            assert stmt.name == name
            assert isinstance(stmt.value, Number)
            assert stmt.value.value == val

    def test_sketch_block(self, prog):
        sketch = prog.statements[4]
        assert isinstance(sketch, SketchBlock)
        assert len(sketch.statements) == 3

    def test_sketch_flange(self, prog):
        sketch = prog.statements[4]
        flange = sketch.statements[0]
        assert isinstance(flange, Assignment)
        assert flange.name == "flange"
        assert isinstance(flange.value, AtClause)
        fc = flange.value.target
        assert isinstance(fc, FuncCall)
        assert fc.name == "rect"

    def test_sketch_profile_csg(self, prog):
        sketch = prog.statements[4]
        profile = sketch.statements[2]
        assert isinstance(profile, Assignment)
        assert profile.name == "profile"
        assert isinstance(profile.value, BinOp)
        assert profile.value.op == "+"

    def test_extrude_beam(self, prog):
        beam_stmt = prog.statements[5]
        assert isinstance(beam_stmt, Assignment)
        assert beam_stmt.name == "beam"
        assert isinstance(beam_stmt.value, Extrude)
        assert isinstance(beam_stmt.value.profile, Identifier)
        assert beam_stmt.value.profile.name == "profile"
        assert isinstance(beam_stmt.value.length, Identifier)
        assert beam_stmt.value.length.name == "length"

    def test_fillets(self, prog):
        fillet1 = prog.statements[6]
        fillet2 = prog.statements[7]
        assert isinstance(fillet1, Command) and fillet1.name == "fillet"
        assert isinstance(fillet2, Command) and fillet2.name == "fillet"
        assert fillet1.args[1].value == 2
        assert fillet2.args[1].value == 8
        assert fillet1.kwargs["r"].value == 4
        assert fillet2.kwargs["r"].value == 4

    def test_chamfers(self, prog):
        chamfer1 = prog.statements[8]
        chamfer2 = prog.statements[9]
        assert isinstance(chamfer1, Command) and chamfer1.name == "chamfer"
        assert isinstance(chamfer2, Command) and chamfer2.name == "chamfer"
        assert chamfer1.args[1].value == 1
        assert chamfer2.args[1].value == 9
        assert chamfer1.kwargs["d"].value == 3
        assert chamfer2.kwargs["d"].value == 3

    def test_export(self, prog):
        from mcad.ast_nodes import Export

        export = prog.statements[10]
        assert isinstance(export, Export)
        assert export.name == "beam"
        assert export.path == "t_beam.3mf"


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

class TestParseErrors:
    def test_missing_equals_in_assignment(self):
        with pytest.raises(ParseError):
            parse("height 100\n")

    def test_unclosed_paren(self):
        with pytest.raises(ParseError):
            parse("x = rect(1, 2\n")

    def test_extrude_missing_args(self):
        with pytest.raises(ParseError, match="requires 2 positional"):
            parse("beam = extrude(profile)\n")


# ---------------------------------------------------------------------------
# For-loop
# ---------------------------------------------------------------------------

class TestForLoop:
    def test_basic_for_loop_produces_forloop_node(self):
        prog = parse("for i in [1, 2, 3]:\n    x = i\n")
        assert len(prog.statements) == 1
        loop = prog.statements[0]
        assert isinstance(loop, ForLoop)
        assert loop.variable == "i"
        assert isinstance(loop.iterable, Tuple)
        assert len(loop.iterable.elements) == 3
        assert len(loop.body) == 1
        assert isinstance(loop.body[0], Assignment)

    def test_for_loop_multi_statement_body(self):
        prog = parse("for i in [1, 2]:\n    a = i\n    b = a + 1\n")
        loop = prog.statements[0]
        assert len(loop.body) == 2

    def test_nested_for_loops_parse(self):
        prog = parse(
            "for i in [1, 2]:\n"
            "    for j in [3, 4]:\n"
            "        k = i + j\n"
        )
        outer = prog.statements[0]
        assert isinstance(outer, ForLoop)
        inner = outer.body[0]
        assert isinstance(inner, ForLoop)
        assert inner.variable == "j"

    def test_for_loop_over_list_of_vectors(self):
        prog = parse("for p in [[0, 0, 0], [1, 2, 3]]:\n    q = p\n")
        loop = prog.statements[0]
        assert isinstance(loop.iterable, Tuple)
        assert all(isinstance(e, Tuple) for e in loop.iterable.elements)

    def test_for_loop_missing_in(self):
        with pytest.raises(ParseError):
            parse("for i [1, 2]:\n    x = i\n")

    def test_for_loop_missing_colon(self):
        with pytest.raises(ParseError):
            parse("for i in [1, 2]\n    x = i\n")

    def test_for_loop_empty_body(self):
        with pytest.raises(ParseError):
            parse("for i in [1, 2]:\n")

    def test_for_loop_non_ident_variable(self):
        with pytest.raises(ParseError):
            parse("for 1 in [1, 2]:\n    x = 1\n")


# ---------------------------------------------------------------------------
# Comparison operators
# ---------------------------------------------------------------------------

class TestComparisonOps:
    @pytest.mark.parametrize("src_op,ast_op", [
        ("<", "<"),
        (">", ">"),
        ("<=", "<="),
        (">=", ">="),
        ("==", "=="),
        ("!=", "!="),
    ])
    def test_each_comparison(self, src_op, ast_op):
        prog = parse(f"x = a {src_op} b\n")
        val = prog.statements[0].value
        assert isinstance(val, BinOp)
        assert val.op == ast_op
        assert isinstance(val.left, Identifier) and val.left.name == "a"
        assert isinstance(val.right, Identifier) and val.right.name == "b"


# ---------------------------------------------------------------------------
# Logical operator precedence
# ---------------------------------------------------------------------------

class TestLogicalPrecedence:
    def test_full_precedence_tree(self):
        """``a + b < c * d && e > f`` must parse as
        ``((a + b) < (c * d)) && (e > f)``.
        """
        prog = parse("x = a + b < c * d && e > f\n")
        val = prog.statements[0].value
        # Top is &&
        assert isinstance(val, BinOp) and val.op == "&&"
        left, right = val.left, val.right

        # Left: (a + b) < (c * d)
        assert isinstance(left, BinOp) and left.op == "<"
        assert isinstance(left.left, BinOp) and left.left.op == "+"
        assert isinstance(left.right, BinOp) and left.right.op == "*"

        # Right: e > f
        assert isinstance(right, BinOp) and right.op == ">"
        assert right.left.name == "e" and right.right.name == "f"

    def test_bang_binds_tighter_than_comparison(self):
        """``!a < b`` → ``UnaryOp('!', BinOp('<', a, b))``.

        Our spec puts `!` between logical AND and comparison (lower than
        comparison). So `!a < b` parses as `!(a < b)`.
        """
        prog = parse("x = !a < b\n")
        val = prog.statements[0].value
        assert isinstance(val, UnaryOp) and val.op == "!"
        inner = val.operand
        assert isinstance(inner, BinOp) and inner.op == "<"
        assert inner.left.name == "a" and inner.right.name == "b"

    def test_or_is_lowest(self):
        prog = parse("x = a && b || c && d\n")
        val = prog.statements[0].value
        assert isinstance(val, BinOp) and val.op == "||"
        assert isinstance(val.left, BinOp) and val.left.op == "&&"
        assert isinstance(val.right, BinOp) and val.right.op == "&&"


# ---------------------------------------------------------------------------
# If / else
# ---------------------------------------------------------------------------

class TestIfStatement:
    def test_short_if_no_else(self):
        prog = parse("if x > 0:\n    y = 1\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, If)
        assert isinstance(stmt.condition, BinOp) and stmt.condition.op == ">"
        assert len(stmt.then_body) == 1
        assert stmt.else_body == []

    def test_if_else(self):
        prog = parse("if x > 0:\n    y = 1\nelse:\n    y = 2\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, If)
        assert len(stmt.then_body) == 1
        assert len(stmt.else_body) == 1
        assert isinstance(stmt.else_body[0], Assignment)
        assert stmt.else_body[0].name == "y"

    def test_if_inside_for(self):
        src = (
            "for i in [0, 1, 2]:\n"
            "    if i > 0:\n"
            "        x = i\n"
        )
        prog = parse(src)
        loop = prog.statements[0]
        assert isinstance(loop, ForLoop)
        assert isinstance(loop.body[0], If)

    def test_for_inside_if(self):
        src = (
            "if cond:\n"
            "    for i in [0, 1]:\n"
            "        x = i\n"
        )
        prog = parse(src)
        stmt = prog.statements[0]
        assert isinstance(stmt, If)
        assert isinstance(stmt.then_body[0], ForLoop)

    def test_missing_colon(self):
        with pytest.raises(ParseError):
            parse("if x > 0\n    y = 1\n")

    def test_missing_body(self):
        with pytest.raises(ParseError):
            parse("if x > 0:\n")

    def test_orphan_else(self):
        with pytest.raises(ParseError):
            parse("else:\n    y = 1\n")


# ---------------------------------------------------------------------------
# While
# ---------------------------------------------------------------------------

class TestWhileStatement:
    def test_basic_parse(self):
        prog = parse("while count < 4:\n    count = count + 1\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, While)
        assert isinstance(stmt.condition, BinOp) and stmt.condition.op == "<"
        assert len(stmt.body) == 1

    def test_while_inside_if(self):
        src = (
            "if cond:\n"
            "    while n < 10:\n"
            "        n = n + 1\n"
        )
        prog = parse(src)
        stmt = prog.statements[0]
        assert isinstance(stmt, If)
        assert isinstance(stmt.then_body[0], While)

    def test_if_inside_while(self):
        src = (
            "while n < 10:\n"
            "    if n > 5:\n"
            "        flag = true\n"
            "    n = n + 1\n"
        )
        prog = parse(src)
        stmt = prog.statements[0]
        assert isinstance(stmt, While)
        assert isinstance(stmt.body[0], If)

    def test_missing_colon(self):
        with pytest.raises(ParseError):
            parse("while x < 1\n    x = x + 1\n")

    def test_missing_body(self):
        with pytest.raises(ParseError):
            parse("while x < 1:\n")


# ---------------------------------------------------------------------------
# Bracket-index (postfix [expr])
# ---------------------------------------------------------------------------

class TestBracketIndex:
    def test_simple_index(self):
        """``x = p[0]`` → Assignment("x", Index(Identifier("p"), Number(0)))."""
        prog = parse("x = p[0]\n")
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert stmt.name == "x"
        node = stmt.value
        assert isinstance(node, Index)
        assert isinstance(node.target, Identifier)
        assert node.target.name == "p"
        assert isinstance(node.index, Number)
        assert node.index.value == 0

    def test_nested_index(self):
        """``x = m[0][1]`` → Index(Index(Identifier("m"), Number(0)), Number(1))."""
        prog = parse("x = m[0][1]\n")
        node = prog.statements[0].value
        assert isinstance(node, Index)
        assert isinstance(node.index, Number)
        assert node.index.value == 1
        inner = node.target
        assert isinstance(inner, Index)
        assert isinstance(inner.target, Identifier)
        assert inner.target.name == "m"
        assert isinstance(inner.index, Number)
        assert inner.index.value == 0

    def test_vector_literal_indexed(self):
        """``x = [1,2,3][0]`` — vector literal immediately followed by index."""
        prog = parse("x = [1,2,3][0]\n")
        node = prog.statements[0].value
        assert isinstance(node, Index)
        assert isinstance(node.target, Tuple)
        assert len(node.target.elements) == 3
        assert isinstance(node.index, Number)
        assert node.index.value == 0

    def test_call_result_indexed(self):
        """``x = f()[0]`` — function-call result indexed."""
        prog = parse("x = f()[0]\n")
        node = prog.statements[0].value
        assert isinstance(node, Index)
        assert isinstance(node.target, FuncCall)
        assert node.target.name == "f"
        assert isinstance(node.index, Number)
        assert node.index.value == 0

    def test_expression_as_index(self):
        """``x = p[i+1]`` — index is a BinOp."""
        prog = parse("x = p[i+1]\n")
        node = prog.statements[0].value
        assert isinstance(node, Index)
        assert isinstance(node.target, Identifier)
        assert node.target.name == "p"
        assert isinstance(node.index, BinOp)
        assert node.index.op == "+"
        assert isinstance(node.index.left, Identifier)
        assert node.index.left.name == "i"
        assert isinstance(node.index.right, Number)
        assert node.index.right.value == 1


# ---------------------------------------------------------------------------
# Module definition + return
# ---------------------------------------------------------------------------

class TestModuleDef:
    def test_zero_arg_module(self):
        """``module foo():`` parses with an empty parameter list."""
        src = "module foo():\n    return 1\n"
        prog = parse(src)
        assert len(prog.statements) == 1
        stmt = prog.statements[0]
        assert isinstance(stmt, ModuleDef)
        assert stmt.name == "foo"
        assert stmt.params == []
        assert len(stmt.body) == 1
        assert isinstance(stmt.body[0], Return)

    def test_required_params(self):
        src = "module foo(a, b):\n    return a + b\n"
        prog = parse(src)
        mod = prog.statements[0]
        assert isinstance(mod, ModuleDef)
        assert [p.name for p in mod.params] == ["a", "b"]
        assert all(p.default is None for p in mod.params)

    def test_default_params(self):
        src = "module foo(a, b=5):\n    return a\n"
        prog = parse(src)
        mod = prog.statements[0]
        assert isinstance(mod, ModuleDef)
        assert len(mod.params) == 2
        assert mod.params[0].name == "a"
        assert mod.params[0].default is None
        assert mod.params[1].name == "b"
        assert isinstance(mod.params[1].default, Number)
        assert mod.params[1].default.value == 5

    def test_default_params_expression(self):
        """A default can be any expression (evaluated at call time)."""
        src = "module foo(a, b=2+3):\n    return a\n"
        prog = parse(src)
        mod = prog.statements[0]
        assert isinstance(mod.params[1].default, BinOp)
        assert mod.params[1].default.op == "+"

    def test_body_with_multiple_statements(self):
        src = (
            "module foo(a, b):\n"
            "    x = a * 2\n"
            "    y = b + x\n"
            "    return y\n"
        )
        prog = parse(src)
        mod = prog.statements[0]
        assert isinstance(mod, ModuleDef)
        assert len(mod.body) == 3
        assert isinstance(mod.body[0], Assignment)
        assert isinstance(mod.body[1], Assignment)
        assert isinstance(mod.body[2], Return)

    def test_nested_module_parses(self):
        """Nested ``module`` definitions parse — the translator rejects them
        at evaluation time, not the parser."""
        src = (
            "module outer():\n"
            "    module inner():\n"
            "        return 1\n"
            "    return 2\n"
        )
        prog = parse(src)
        outer = prog.statements[0]
        assert isinstance(outer, ModuleDef)
        assert outer.name == "outer"
        assert isinstance(outer.body[0], ModuleDef)
        assert outer.body[0].name == "inner"

    def test_module_call_parses_as_funccall(self):
        """Call syntax reuses the ordinary FuncCall node."""
        src = "x = foo(1, 2)\n"
        prog = parse(src)
        stmt = prog.statements[0]
        assert isinstance(stmt, Assignment)
        assert isinstance(stmt.value, FuncCall)
        assert stmt.value.name == "foo"

    def test_module_call_with_kwarg(self):
        src = "x = foo(1, b=3)\n"
        prog = parse(src)
        call = prog.statements[0].value
        assert isinstance(call, FuncCall)
        assert call.name == "foo"
        assert len(call.args) == 1
        assert "b" in call.kwargs

    def test_return_outside_module_raises(self):
        with pytest.raises(ParseError):
            parse("return 1\n")

    def test_return_inside_for_outside_module_raises(self):
        """Even inside a ``for`` loop, return is illegal at top level."""
        with pytest.raises(ParseError):
            parse("for i in [1,2]:\n    return i\n")

    def test_mixed_param_order_raises(self):
        """Required parameter after a defaulted one is a ParseError."""
        with pytest.raises(ParseError):
            parse("module foo(a=1, b):\n    return a\n")

    def test_missing_colon_raises(self):
        with pytest.raises(ParseError):
            parse("module foo()\n    return 1\n")

    def test_empty_body_raises(self):
        """A module body with no statements is a ParseError (inherited from
        ``_parse_indented_block``)."""
        with pytest.raises(ParseError):
            parse("module foo():\n")

    def test_return_requires_expression(self):
        with pytest.raises(ParseError):
            parse("module foo():\n    return\n")

    def test_module_name_must_be_identifier(self):
        with pytest.raises(ParseError):
            parse("module 123():\n    return 1\n")
