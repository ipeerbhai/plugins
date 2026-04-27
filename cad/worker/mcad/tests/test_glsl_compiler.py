"""Tests for the MCAD GLSL compiler (task 3.2).

All tests use pure Python string generation — no Build123d required.
"""

import pytest

from mcad.parser import parse
from mcad.glsl_compiler import GLSLCompiler, CompileError


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def compile_src(src: str) -> str:
    """Parse *src* and compile to a scene_sdf string."""
    prog = parse(src)
    return GLSLCompiler().compile(prog)


def count_occurrences(glsl: str, fragment: str) -> int:
    return glsl.count(fragment)


# ---------------------------------------------------------------------------
# 1. Simple box
# ---------------------------------------------------------------------------

SIMPLE_BOX_SRC = """\
sketch:
    s = rect(50, 30)
b = extrude(s, 20)
"""


class TestSimpleBox:
    def test_contains_sdf_rect_2d(self):
        glsl = compile_src(SIMPLE_BOX_SRC)
        assert "sdf_rect_2d" in glsl

    def test_contains_sdf_extrude(self):
        glsl = compile_src(SIMPLE_BOX_SRC)
        assert "sdf_extrude" in glsl

    def test_rect_size_args(self):
        """rect(50, 30) → vec2(50.0, 30.0)"""
        glsl = compile_src(SIMPLE_BOX_SRC)
        assert "vec2(50.0, 30.0)" in glsl

    def test_extrude_length_arg(self):
        """extrude(s, 20) → sdf_extrude(p, ..., 20.0)"""
        glsl = compile_src(SIMPLE_BOX_SRC)
        assert "20.0" in glsl

    def test_function_signature(self):
        glsl = compile_src(SIMPLE_BOX_SRC)
        assert "float scene_sdf(vec3 p)" in glsl

    def test_has_return(self):
        glsl = compile_src(SIMPLE_BOX_SRC)
        assert "return" in glsl


# ---------------------------------------------------------------------------
# 2. T-beam
# ---------------------------------------------------------------------------

T_BEAM_SRC = """\
height = 100
width = 80
thickness = 10
length = 200

sketch:
    flange = rect(width, thickness) at (0, height - thickness/2)
    web = rect(thickness, height - thickness) at (0, (height - thickness)/2)
    profile = flange + web

beam = extrude(profile, length)
"""


class TestTBeam:
    @pytest.fixture
    def glsl(self):
        return compile_src(T_BEAM_SRC)

    def test_has_two_rect_calls(self, glsl):
        assert count_occurrences(glsl, "sdf_rect_2d") == 2

    def test_has_union(self, glsl):
        """profile = flange + web should emit sdf_union or sdf_smooth_union."""
        assert "sdf_union" in glsl

    def test_has_extrude(self, glsl):
        assert "sdf_extrude" in glsl

    def test_function_signature(self, glsl):
        assert "float scene_sdf(vec3 p)" in glsl

    def test_has_return(self, glsl):
        assert "return" in glsl

    def test_braces_balanced(self, glsl):
        assert glsl.count("{") == glsl.count("}")

    def test_flange_position(self, glsl):
        """flange at (0, 95.0) — height - thickness/2 = 100 - 5 = 95."""
        assert "95.0" in glsl

    def test_web_position(self, glsl):
        """web at (0, 45.0) — (height - thickness)/2 = 90/2 = 45."""
        assert "45.0" in glsl

    def test_flange_size(self, glsl):
        """rect(width=80, thickness=10) → vec2(80.0, 10.0)"""
        assert "vec2(80.0, 10.0)" in glsl

    def test_web_size(self, glsl):
        """rect(thickness=10, height-thickness=90) → vec2(10.0, 90.0)"""
        assert "vec2(10.0, 90.0)" in glsl

    def test_extrude_length(self, glsl):
        """extrude(profile, length=200) → ..., 200.0)"""
        assert "200.0" in glsl


# ---------------------------------------------------------------------------
# 3. T-beam with fillet → smooth_union
# ---------------------------------------------------------------------------

T_BEAM_FILLET_SRC = """\
height = 100
width = 80
thickness = 10
length = 200

sketch:
    flange = rect(width, thickness) at (0, height - thickness/2)
    web = rect(thickness, height - thickness) at (0, (height - thickness)/2)
    profile = flange + web

beam = extrude(profile, length)

fillet beam, 2, r=4
fillet beam, 8, r=4
"""


class TestTBeamWithFillet:
    @pytest.fixture
    def glsl(self):
        return compile_src(T_BEAM_FILLET_SRC)

    def test_uses_smooth_union_not_plain(self, glsl):
        """Fillet should convert union to smooth_union."""
        assert "sdf_smooth_union" in glsl

    def test_no_plain_union(self, glsl):
        """With fillets present, plain sdf_union should not appear."""
        # sdf_smooth_union contains "sdf_union" as a substring, so check
        # that the non-smooth form does not appear independently
        import re
        plain_union = re.findall(r'\bsdf_union\b', glsl)
        assert len(plain_union) == 0, f"Plain sdf_union found: {glsl}"

    def test_smooth_radius_is_4(self, glsl):
        """The fillet radius is 4.0."""
        assert "4.0" in glsl

    def test_function_signature(self, glsl):
        assert "float scene_sdf(vec3 p)" in glsl


# ---------------------------------------------------------------------------
# 4. Variable substitution
# ---------------------------------------------------------------------------

class TestVariableSubstitution:
    def test_number_variable_inlined(self):
        """Numeric variables are inlined — their values appear in the output."""
        src = "height = 100\nsketch:\n    s = rect(50, height)\nb = extrude(s, 20)\n"
        glsl = compile_src(src)
        # height=100 should be inlined
        assert "100.0" in glsl

    def test_rect_with_variable_width(self):
        """Variables used as rect dimensions should be resolved to their values."""
        src = "w = 60\nh = 40\nsketch:\n    s = rect(w, h)\nb = extrude(s, 10)\n"
        glsl = compile_src(src)
        assert "vec2(60.0, 40.0)" in glsl

    def test_arithmetic_variable_resolved(self):
        """Arithmetic on variables (height - thickness/2) should be evaluated."""
        src = (
            "height = 100\n"
            "thickness = 10\n"
            "sketch:\n"
            "    s = rect(thickness, height - thickness) at (0, (height - thickness)/2)\n"
            "b = extrude(s, 20)\n"
        )
        glsl = compile_src(src)
        # (100 - 10)/2 = 45.0
        assert "45.0" in glsl
        # height - thickness = 90
        assert "90.0" in glsl


# ---------------------------------------------------------------------------
# 5. Output is valid GLSL (structural checks)
# ---------------------------------------------------------------------------

class TestOutputIsValidGlsl:
    @pytest.fixture
    def glsl(self):
        return compile_src(T_BEAM_FILLET_SRC)

    def test_function_signature_present(self, glsl):
        assert "float scene_sdf(vec3 p)" in glsl

    def test_outer_braces_balanced(self, glsl):
        assert glsl.count("{") == glsl.count("}")

    def test_starts_with_function(self, glsl):
        assert glsl.strip().startswith("float scene_sdf(vec3 p)")

    def test_ends_with_closing_brace(self, glsl):
        assert glsl.strip().endswith("}")

    def test_all_lines_end_with_semicolon_or_brace(self, glsl):
        """Every non-empty interior line should end with ';' or '{'/'}'."""
        lines = glsl.strip().splitlines()
        # Skip the opening and closing function braces
        interior = [l.strip() for l in lines[1:-1] if l.strip()]
        for line in interior:
            assert line.endswith(";") or line.endswith("{") or line.endswith("}"), (
                f"Line does not end with ';' or brace: {line!r}"
            )

    def test_return_statement_present(self, glsl):
        assert "return d;" in glsl

    def test_vec3_p_parameter_used(self, glsl):
        """The scene_sdf body should reference p (from vec3 p)."""
        # At minimum p.xy or p.z should appear
        assert "p." in glsl

    def test_compile_full_shader_includes_include(self):
        src = SIMPLE_BOX_SRC
        prog = parse(src)
        full = GLSLCompiler().compile_full_shader(prog)
        assert '#include "sdf_primitives.gdshaderinc"' in full
        assert "float scene_sdf(vec3 p)" in full


# ---------------------------------------------------------------------------
# 6. Chamfer command
# ---------------------------------------------------------------------------

class TestChamfer:
    def test_chamfer_uses_smooth_difference(self):
        """chamfer on a subtraction shape should use sdf_smooth_difference."""
        src = (
            "sketch:\n"
            "    base = rect(100, 100)\n"
            "    cutout = rect(20, 20)\n"
            "    profile = base - cutout\n"
            "part = extrude(profile, 50)\n"
            "chamfer part, 1, d=3\n"
        )
        glsl = compile_src(src)
        assert "sdf_smooth_difference" in glsl
        assert "3.0" in glsl

    def test_chamfer_radius_applied(self):
        src = (
            "sketch:\n"
            "    base = rect(100, 100)\n"
            "    cutout = rect(20, 20)\n"
            "    profile = base - cutout\n"
            "part = extrude(profile, 50)\n"
            "chamfer part, 1, d=5\n"
        )
        glsl = compile_src(src)
        assert "5.0" in glsl


# ---------------------------------------------------------------------------
# 7. compile_full_shader API
# ---------------------------------------------------------------------------

class TestCompileFullShader:
    def test_full_shader_contains_scene_sdf(self):
        prog = parse(SIMPLE_BOX_SRC)
        full = GLSLCompiler().compile_full_shader(prog)
        assert "float scene_sdf(vec3 p)" in full

    def test_full_shader_contains_include(self):
        prog = parse(SIMPLE_BOX_SRC)
        full = GLSLCompiler().compile_full_shader(prog)
        assert "sdf_primitives.gdshaderinc" in full
