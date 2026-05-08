"""Tests for the MCAD Shape-tree -> Build123d translator.

These tests require Build123d (and its OCCT backend), which may not be
installed in every environment.  All tests are guarded with
``pytest.importorskip("build123d")`` so they skip gracefully when
Build123d is absent.
"""

from __future__ import annotations

import os
import tempfile

import pytest

# Skip entire module if build123d is not available.
# exc_type=ImportError covers transitive ImportErrors (e.g. missing libGL).
build123d = pytest.importorskip("build123d", exc_type=ImportError)

from mcad.parser import parse
from mcad.translator import Translator, TranslatorError


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _translate(source: str) -> Translator:
    """Parse + translate, return the Translator (for inspecting env/parts)."""
    program = parse(source)
    t = Translator()
    t.translate(program)
    return t


# ---------------------------------------------------------------------------
# 1. Simple box: sketch + rect + extrude
# ---------------------------------------------------------------------------

class TestSimpleBox:
    SOURCE = (
        "sketch:\n"
        "    s = rect(50, 30)\n"
        "b = extrude(s, 20)\n"
    )

    def test_part_produced(self):
        t = _translate(self.SOURCE)
        assert "b" in t.env
        part = t.env["b"]
        assert part is not None

    def test_non_zero_volume(self):
        t = _translate(self.SOURCE)
        part = t.env["b"]
        # Volume should be 50 * 30 * 20 = 30000
        assert part.volume > 0
        assert abs(part.volume - 30_000) < 1.0


class TestSolidPrimitives:
    def test_cube_scalar_size_volume(self):
        t = _translate("part = cube(10)\n")
        part = t.env["part"]
        assert abs(part.volume - 1000.0) < 0.1

    def test_cube_center_false_starts_at_origin(self):
        t = _translate("part = cube(10, 20, 30)\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.X == pytest.approx(0.0)
        assert bbox.min.Y == pytest.approx(0.0)
        assert bbox.min.Z == pytest.approx(0.0)
        assert bbox.max.X == pytest.approx(10.0)
        assert bbox.max.Y == pytest.approx(20.0)
        assert bbox.max.Z == pytest.approx(30.0)

    def test_cube_center_true_is_origin_centered(self):
        t = _translate("part = cube(10, center=true)\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.X == pytest.approx(-5.0)
        assert bbox.min.Y == pytest.approx(-5.0)
        assert bbox.min.Z == pytest.approx(-5.0)
        assert bbox.max.X == pytest.approx(5.0)
        assert bbox.max.Y == pytest.approx(5.0)
        assert bbox.max.Z == pytest.approx(5.0)

    def test_sphere_radius_volume(self):
        t = _translate("part = sphere(r=5)\n")
        part = t.env["part"]
        assert part.volume == pytest.approx((4.0 / 3.0) * 3.141592653589793 * 125.0, rel=0.02)

    def test_cylinder_center_false_has_base_at_zero(self):
        t = _translate("part = cylinder(h=10, r=2)\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.Z == pytest.approx(0.0)
        assert bbox.max.Z == pytest.approx(10.0)

    def test_tapered_cylinder_uses_r1_r2(self):
        t = _translate("part = cylinder(h=12, r1=4, r2=2, center=true)\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.Z == pytest.approx(-6.0)
        assert bbox.max.Z == pytest.approx(6.0)
        assert t.env["part"].volume > 0

    def test_polyhedron_tetrahedron_volume(self):
        source = (
            "part = polyhedron("
            "points=[[0,0,0],[1,0,0],[0,1,0],[0,0,1]], "
            "faces=[[0,2,1],[0,1,3],[0,3,2],[1,2,3]])\n"
        )
        part = _translate(source).env["part"]
        # Unit tetrahedron volume = 1/6
        assert part.volume == pytest.approx(1.0 / 6.0, abs=1e-6)
        assert len(part.faces()) == 4

    def test_polyhedron_positional_args(self):
        source = (
            "part = polyhedron("
            "[[0,0,0],[1,0,0],[0,1,0],[0,0,1]], "
            "[[0,2,1],[0,1,3],[0,3,2],[1,2,3]])\n"
        )
        part = _translate(source).env["part"]
        assert part.volume == pytest.approx(1.0 / 6.0, abs=1e-6)

    def test_polyhedron_rejects_out_of_range_index(self):
        source = (
            "part = polyhedron("
            "points=[[0,0,0],[1,0,0],[0,1,0],[0,0,1]], "
            "faces=[[0,2,99]])\n"
        )
        with pytest.raises(Exception):
            _translate(source)

    def test_translate_moves_solid(self):
        t = _translate("part = translate([10, 20, 30], cube(1, 2, 3, center=true))\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.X == pytest.approx(9.5)
        assert bbox.min.Y == pytest.approx(19.0)
        assert bbox.min.Z == pytest.approx(28.5)

    def test_rotate_rotates_solid(self):
        t = _translate("part = rotate([0, 0, 90], cube(2, 4, 6, center=true))\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.X == pytest.approx(-2.0)
        assert bbox.max.X == pytest.approx(2.0)
        assert bbox.min.Y == pytest.approx(-1.0)
        assert bbox.max.Y == pytest.approx(1.0)
        assert bbox.min.Z == pytest.approx(-3.0)
        assert bbox.max.Z == pytest.approx(3.0)

    def test_oval_extrude_produces_volume(self):
        t = _translate(
            "sketch:\n"
            "    p = oval(20, 10)\n"
            "part = extrude(p, 30)\n"
        )
        part = t.env["part"]
        expected = 3.141592653589793 * 10.0 * 5.0 * 30.0
        assert part.volume == pytest.approx(expected, rel=0.03)

    def test_scale_resizes_solid(self):
        t = _translate("part = scale([1, 0.5, 2], cube(10, center=true))\n")
        bbox = t.env["part"].bounding_box()
        assert bbox.min.X == pytest.approx(-5.0)
        assert bbox.max.X == pytest.approx(5.0)
        assert bbox.min.Y == pytest.approx(-2.5)
        assert bbox.max.Y == pytest.approx(2.5)
        assert bbox.min.Z == pytest.approx(-10.0)
        assert bbox.max.Z == pytest.approx(10.0)

    def test_mirror_reflects_solid_across_origin_plane(self):
        t = _translate(
            "half = translate([5, 0, 0], cube(2, 4, 6, center=true))\n"
            "part = mirror([1, 0, 0], half)\n"
        )
        bbox = t.env["part"].bounding_box()
        assert bbox.min.X == pytest.approx(-6.0)
        assert bbox.max.X == pytest.approx(-4.0)


class TestLoftAndShell:
    LOFT_SOURCE = (
        "body = loft:\n"
        "    z=0: oval(20, 10)\n"
        "    z=20: oval(24, 12)\n"
        "    z=40: oval(16, 8)\n"
    )

    def test_loft_produces_solid(self):
        t = _translate(self.LOFT_SOURCE)
        body = t.env["body"]
        assert body.volume > 0
        assert len(list(body.faces())) >= 3

    def test_shell_reduces_volume(self):
        plain = _translate(self.LOFT_SOURCE)
        shelled = _translate(self.LOFT_SOURCE + "shell body, 1.0\n")
        assert shelled.env["body"].volume < plain.env["body"].volume

    def test_shell_open_face_selection_deferred(self):
        with pytest.raises(TranslatorError, match="open-face selection is deferred"):
            _translate(self.LOFT_SOURCE + "shell body, 1.0, open=top\n")


class TestSolidCSG:
    def test_primitive_difference_reduces_volume(self):
        plain = _translate("part = cube(20, 20, 20, center=true)\n")
        cut = _translate(
            "part = cube(20, 20, 20, center=true) - cylinder(h=30, r=3, center=true)\n"
        )
        assert cut.env["part"].volume < plain.env["part"].volume

    def test_post_extrude_vertical_hole_subtraction(self):
        source = T_BEAM_NO_MODS + (
            "hole = translate([20, 95, 40], rotate([90, 0, 0], cylinder(h=12, r=3, center=true)))\n"
            "beam = beam - hole\n"
        )
        plain = _translate(T_BEAM_NO_MODS)
        cut = _translate(source)
        assert cut.env["beam"].volume < plain.env["beam"].volume

    def test_composite_countersink_cutter_subtracts_from_solid(self):
        source = (
            "body = cube(30, 20, 30, center=true)\n"
            "through_hole = rotate([90, 0, 0], cylinder(h=24, r=2, center=true))\n"
            "countersink = translate([0, 8, 0], rotate([90, 0, 0], cylinder(h=6, r1=5, r2=2, center=true)))\n"
            "tool = through_hole + countersink\n"
            "body = body - tool\n"
        )
        part = _translate(source).env["body"]
        assert part.volume > 0
        assert part.volume < _translate("body = cube(30, 20, 30, center=true)\n").env["body"].volume


# ---------------------------------------------------------------------------
# 2. T-beam builds (no fillet/chamfer)
# ---------------------------------------------------------------------------

T_BEAM_NO_MODS = """\
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


class TestTBeamBuilds:
    def test_part_produced(self):
        t = _translate(T_BEAM_NO_MODS)
        assert "beam" in t.env
        part = t.env["beam"]
        assert part is not None

    def test_non_zero_volume(self):
        t = _translate(T_BEAM_NO_MODS)
        part = t.env["beam"]
        assert part.volume > 0

    def test_expected_volume(self):
        """T-beam cross section: flange (80x10) + web (10x90) = 800 + 900 = 1700 mm^2.
        Extruded 200mm -> volume = 340,000 mm^3."""
        t = _translate(T_BEAM_NO_MODS)
        part = t.env["beam"]
        expected = 340_000.0
        assert abs(part.volume - expected) < 100.0  # tolerance for OCCT precision


# ---------------------------------------------------------------------------
# 3. T-beam with fillet
# ---------------------------------------------------------------------------

T_BEAM_FILLET = T_BEAM_NO_MODS + "fillet beam, 2, r=4\n"


class TestTBeamWithFillet:
    def test_fillet_succeeds(self):
        t = _translate(T_BEAM_FILLET)
        part = t.env["beam"]
        assert part is not None
        assert part.volume > 0

    def test_fillet_changes_volume(self):
        """Filleting removes a tiny sliver, so volume should decrease slightly."""
        t_plain = _translate(T_BEAM_NO_MODS)
        t_filleted = _translate(T_BEAM_FILLET)
        # Fillet on an interior edge adds material (concave fillet) or removes
        # it (convex fillet).  For a T-beam interior junction edge, the fillet
        # adds material.  In either case, volume should differ from the plain.
        assert t_plain.env["beam"].volume != pytest.approx(
            t_filleted.env["beam"].volume, abs=0.1
        )


# ---------------------------------------------------------------------------
# 4. T-beam with chamfer
# ---------------------------------------------------------------------------

T_BEAM_CHAMFER = T_BEAM_NO_MODS + "chamfer beam, 1, d=3\n"


class TestTBeamWithChamfer:
    def test_chamfer_succeeds(self):
        t = _translate(T_BEAM_CHAMFER)
        part = t.env["beam"]
        assert part is not None
        assert part.volume > 0

    def test_chamfer_changes_volume(self):
        t_plain = _translate(T_BEAM_NO_MODS)
        t_chamfered = _translate(T_BEAM_CHAMFER)
        assert t_plain.env["beam"].volume != pytest.approx(
            t_chamfered.env["beam"].volume, abs=0.1
        )


# ---------------------------------------------------------------------------
# 5. Export to 3MF
# ---------------------------------------------------------------------------

T_BEAM_EXPORT = T_BEAM_NO_MODS + 'export beam "{filepath}"\n'


class TestExportDeclaration:
    """``export`` is declaration-only — records a target, does not write."""

    def test_export_records_target_without_writing(self, tmp_path):
        filepath = str(tmp_path / "test_output.3mf")
        source = T_BEAM_EXPORT.format(filepath=filepath)
        t = _translate(source)
        assert not os.path.exists(filepath), "DSL export must not write during translate()"
        assert len(t.export_targets) == 1
        target = t.export_targets[0]
        assert target["name"] == "beam"
        assert target["path"] == filepath

    def test_write_exports_flushes_3mf(self, tmp_path):
        filepath = str(tmp_path / "test_output.3mf")
        source = T_BEAM_EXPORT.format(filepath=filepath)
        t = _translate(source)
        written = t.write_exports()
        assert written == [filepath]
        assert os.path.isfile(filepath)
        assert os.path.getsize(filepath) > 0
        assert filepath in t.parts

    def test_write_exports_step(self, tmp_path):
        filepath = str(tmp_path / "test_output.step")
        source = T_BEAM_EXPORT.format(filepath=filepath)
        t = _translate(source)
        t.write_exports()
        assert os.path.isfile(filepath)
        assert os.path.getsize(filepath) > 0

    def test_write_exports_stl(self, tmp_path):
        filepath = str(tmp_path / "test_output.stl")
        source = T_BEAM_EXPORT.format(filepath=filepath)
        t = _translate(source)
        t.write_exports()
        assert os.path.isfile(filepath)
        assert os.path.getsize(filepath) > 0


class TestExportPathResolution:
    """The DSL resolves bare/relative paths against the user's home directory.

    Tests monkeypatch ``Path.home`` to point at a tmp dir so they never write
    to the real home.
    """

    def _declared_paths(self, t) -> list[str]:
        return [target["path"] for target in t.export_targets]

    def test_bare_filename_resolves_to_home(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HOME", str(tmp_path))
        source = T_BEAM_EXPORT.format(filepath="beam.stl")
        t = _translate(source)
        expected = tmp_path / "beam.stl"
        assert self._declared_paths(t) == [str(expected)]
        t.write_exports()
        assert expected.is_file()

    def test_tilde_prefix_expands(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HOME", str(tmp_path))
        source = T_BEAM_EXPORT.format(filepath="~/sub/beam.stl")
        t = _translate(source)
        expected = tmp_path / "sub" / "beam.stl"
        assert self._declared_paths(t) == [str(expected)]
        t.write_exports()
        assert expected.is_file()

    def test_absolute_path_used_as_is(self, tmp_path):
        filepath = tmp_path / "elsewhere" / "beam.stl"
        source = T_BEAM_EXPORT.format(filepath=str(filepath))
        t = _translate(source)
        assert self._declared_paths(t) == [str(filepath)]
        t.write_exports()
        assert filepath.is_file()

    def test_relative_subdir_resolves_to_home(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HOME", str(tmp_path))
        source = T_BEAM_EXPORT.format(filepath="cad/out/beam.stl")
        t = _translate(source)
        expected = tmp_path / "cad" / "out" / "beam.stl"
        assert self._declared_paths(t) == [str(expected)]
        t.write_exports()
        assert expected.is_file()


class TestExportErrors:
    def test_export_unknown_name(self):
        with pytest.raises(TranslatorError, match="Undefined variable"):
            _translate('export ghost "x.stl"\n')

    def test_export_non_shape(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HOME", str(tmp_path))
        with pytest.raises(TranslatorError, match="must be a 3D shape"):
            _translate('x = 42\nexport x "x.stl"\n')

    def test_export_unsupported_extension(self, tmp_path):
        filepath = str(tmp_path / "beam.xyz")
        source = T_BEAM_EXPORT.format(filepath=filepath)
        with pytest.raises(TranslatorError, match="Unsupported export format"):
            _translate(source)


# ---------------------------------------------------------------------------
# 6. Variable arithmetic
# ---------------------------------------------------------------------------

class TestVariableArithmetic:
    def test_simple_assignment(self):
        t = _translate("height = 100\n")
        assert t.env["height"] == 100

    def test_division(self):
        source = "height = 100\nhalf = height / 2\n"
        t = _translate(source)
        assert t.env["half"] == 50.0

    def test_complex_expression(self):
        source = (
            "height = 100\n"
            "thickness = 10\n"
            "result = height - thickness / 2\n"
        )
        t = _translate(source)
        assert t.env["result"] == 95.0

    def test_multiplication(self):
        source = "a = 3\nb = 4\nc = a * b\n"
        t = _translate(source)
        assert t.env["c"] == 12

    def test_subtraction(self):
        source = "a = 100\nb = 30\nc = a - b\n"
        t = _translate(source)
        assert t.env["c"] == 70

    def test_unary_negation(self):
        source = "a = -5\n"
        t = _translate(source)
        assert t.env["a"] == -5

    def test_parenthesised_expression(self):
        source = (
            "height = 100\n"
            "thickness = 10\n"
            "result = (height - thickness) / 2\n"
        )
        t = _translate(source)
        assert t.env["result"] == 45.0


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

class TestTranslatorErrors:
    def test_undefined_variable(self):
        with pytest.raises(TranslatorError, match="Undefined variable"):
            _translate("x = y + 1\n")

    def test_division_by_zero(self):
        with pytest.raises(TranslatorError, match="Division by zero"):
            _translate("x = 10 / 0\n")

    def test_unknown_function(self):
        with pytest.raises(TranslatorError, match="Unknown function"):
            _translate("sketch:\n    s = hexagon(50)\n")

    def test_fillet_missing_radius(self):
        source = T_BEAM_NO_MODS + "fillet beam, 2\n"
        with pytest.raises(TranslatorError, match="r=radius"):
            _translate(source)

    def test_chamfer_missing_distance(self):
        source = T_BEAM_NO_MODS + "chamfer beam, 1\n"
        with pytest.raises(TranslatorError, match="d=distance"):
            _translate(source)


# ---------------------------------------------------------------------------
# For-loop
# ---------------------------------------------------------------------------

class TestForLoop:
    def test_accumulates_numbers(self):
        t = _translate("total = 0\nfor x in [1, 2, 3, 4]:\n    total = total + x\n")
        assert t.env["total"] == 10

    def test_loop_variable_leaks(self):
        t = _translate("for x in [1, 2, 3]:\n    y = x\n")
        assert t.env["x"] == 3
        assert t.env["y"] == 3

    def test_empty_list_is_noop(self):
        t = _translate("y = 42\nfor x in []:\n    y = 0\n")
        assert t.env["y"] == 42
        assert "x" not in t.env

    def test_non_list_iterable_errors(self):
        with pytest.raises(TranslatorError, match="must be a list"):
            _translate("for x in 5:\n    y = x\n")

    def test_iterate_vectors(self):
        source = (
            "where = [0, 0, 0]\n"
            "for p in [[10, 0, 0], [20, 0, 0], [30, 0, 0]]:\n"
            "    where = p\n"
        )
        t = _translate(source)
        assert t.env["where"] == [30, 0, 0]

    def test_nested_for_loops_produce_cartesian_accumulator(self):
        source = (
            "count = 0\n"
            "for i in [1, 2, 3]:\n"
            "    for j in [10, 20]:\n"
            "        count = count + 1\n"
        )
        t = _translate(source)
        assert t.env["count"] == 6

    def test_for_loop_drills_holes_into_beam(self):
        source = (
            "height = 100\nwidth = 80\nthickness = 10\nlength = 200\n"
            "sketch:\n"
            "    flange = rect(width, thickness) center at point(0, height - thickness / 2)\n"
            "    web = rect(thickness, height - thickness) center at point(0, (height - thickness) / 2)\n"
            "    profile = flange + web\n"
            "beam = extrude(profile, length)\n"
            "slug = rotate([90, 0, 0], cylinder(h=14, r=4, center=true))\n"
            "for p in [[-25, 95, 25], [25, 95, 25], [-25, 95, 175], [25, 95, 175]]:\n"
            "    beam = beam - translate(p, slug)\n"
        )
        t = _translate(source)
        bare_source = source.split("slug =")[0]
        bare = _translate(bare_source).env["beam"]
        drilled = t.env["beam"]
        assert drilled.volume < bare.volume
        # last_part() must still point at beam despite 4 reassignments in the loop
        name, _ = t.last_part()
        assert name == "beam"


# ---------------------------------------------------------------------------
# Comparison operators (numbers)
# ---------------------------------------------------------------------------

class TestComparisonOps:
    @pytest.mark.parametrize("src,expected", [
        ("x = 1 < 2\n", True),
        ("x = 2 < 1\n", False),
        ("x = 1 < 1\n", False),
        ("x = 2 > 1\n", True),
        ("x = 1 > 2\n", False),
        ("x = 1 <= 1\n", True),
        ("x = 2 <= 1\n", False),
        ("x = 1 >= 1\n", True),
        ("x = 1 >= 2\n", False),
        ("x = 3 == 3\n", True),
        ("x = 3 == 4\n", False),
        ("x = 3 != 4\n", True),
        ("x = 3 != 3\n", False),
    ])
    def test_number_comparisons(self, src, expected):
        t = _translate(src)
        assert t.env["x"] is expected

    def test_comparison_on_non_number_errors(self):
        with pytest.raises(TranslatorError):
            _translate('x = "a" < "b"\n')


# ---------------------------------------------------------------------------
# Logical operators — truthiness, short-circuit, bang
# ---------------------------------------------------------------------------

class TestLogicalOps:
    def test_and_short_circuit_skips_right_side(self):
        """`false && (1 / 0)` must NOT evaluate the divide-by-zero."""
        t = _translate("x = false && (1 / 0)\n")
        assert t.env["x"] is False

    def test_or_short_circuit_skips_right_side(self):
        """`true || (1 / 0)` must NOT evaluate the divide-by-zero."""
        t = _translate("x = true || (1 / 0)\n")
        assert t.env["x"] is True

    def test_and_evaluates_right_when_left_true(self):
        t = _translate("x = true && (2 > 1)\n")
        assert t.env["x"] is True

    def test_or_evaluates_right_when_left_false(self):
        t = _translate("x = false || (2 > 1)\n")
        assert t.env["x"] is True

    def test_bang_on_bool(self):
        t = _translate("a = !true\nb = !false\n")
        assert t.env["a"] is False
        assert t.env["b"] is True

    def test_bang_on_number(self):
        t = _translate("a = !0\nb = !1\nc = !5\n")
        assert t.env["a"] is True
        assert t.env["b"] is False
        assert t.env["c"] is False

    def test_bang_on_list(self):
        t = _translate("a = ![]\nb = ![1, 2]\n")
        assert t.env["a"] is True
        assert t.env["b"] is False

    def test_bang_on_shape(self):
        t = _translate("c = cube(5)\nx = !c\n")
        # shape is always truthy, so !shape is False
        assert t.env["x"] is False


# ---------------------------------------------------------------------------
# Truthiness in if / while
# ---------------------------------------------------------------------------

class TestTruthiness:
    def test_if_zero_is_falsy(self):
        t = _translate("x = 99\nif 0:\n    x = 1\n")
        assert t.env["x"] == 99

    def test_if_nonzero_int_is_truthy(self):
        t = _translate("x = 0\nif 1:\n    x = 1\n")
        assert t.env["x"] == 1

    def test_if_empty_list_is_falsy(self):
        t = _translate("x = 99\nif []:\n    x = 1\n")
        assert t.env["x"] == 99

    def test_if_nonempty_list_is_truthy(self):
        t = _translate("x = 0\nif [1]:\n    x = 1\n")
        assert t.env["x"] == 1

    def test_if_shape_is_truthy(self):
        t = _translate("c = cube(5)\nx = 0\nif c:\n    x = 1\n")
        assert t.env["x"] == 1

    def test_if_unsupported_type_raises(self):
        with pytest.raises(TranslatorError):
            _translate('if "hello":\n    x = 1\n')


# ---------------------------------------------------------------------------
# If / else branches + leaky scope
# ---------------------------------------------------------------------------

class TestIfStatement:
    def test_then_branch_runs(self):
        src = "x = 0\nif 1 < 2:\n    x = 1\nelse:\n    x = 2\n"
        t = _translate(src)
        assert t.env["x"] == 1

    def test_else_branch_runs(self):
        src = "x = 0\nif 2 < 1:\n    x = 1\nelse:\n    x = 2\n"
        t = _translate(src)
        assert t.env["x"] == 2

    def test_body_assignments_leak_to_outer_scope(self):
        """Same semantics as ``for``: no new scope frame."""
        src = "if true:\n    fresh = 42\n"
        t = _translate(src)
        assert t.env["fresh"] == 42

    def test_short_if_no_else_skipped(self):
        src = "x = 7\nif false:\n    x = 99\n"
        t = _translate(src)
        assert t.env["x"] == 7


# ---------------------------------------------------------------------------
# While loop
# ---------------------------------------------------------------------------

class TestWhileLoop:
    def test_fibonacci_via_while(self):
        """Mutates state across iterations; proves termination."""
        src = (
            "a = 0\n"
            "b = 1\n"
            "count = 0\n"
            "while count < 10:\n"
            "    tmp = a + b\n"
            "    a = b\n"
            "    b = tmp\n"
            "    count = count + 1\n"
        )
        t = _translate(src)
        # F(11) = 89, F(12) = 144 — after 10 iterations: a=F(10)=55, b=F(11)=89
        assert t.env["a"] == 55
        assert t.env["b"] == 89
        assert t.env["count"] == 10

    def test_while_zero_iterations(self):
        src = "x = 7\nwhile false:\n    x = 99\n"
        t = _translate(src)
        assert t.env["x"] == 7

    def test_while_iteration_cap_raises(self):
        src = "n = 0\nwhile true:\n    n = n + 1\n"
        with pytest.raises(TranslatorError) as exc:
            _translate(src)
        assert "10000" in str(exc.value)
        assert "while-loop" in str(exc.value).lower()


# ---------------------------------------------------------------------------
# Nested control flow
# ---------------------------------------------------------------------------

class TestNestedControlFlow:
    def test_if_inside_for(self):
        src = (
            "total = 0\n"
            "for i in [1, 2, 3, 4, 5]:\n"
            "    if i > 2:\n"
            "        total = total + i\n"
        )
        t = _translate(src)
        assert t.env["total"] == 3 + 4 + 5

    def test_while_inside_if(self):
        src = (
            "n = 0\n"
            "if true:\n"
            "    while n < 5:\n"
            "        n = n + 1\n"
        )
        t = _translate(src)
        assert t.env["n"] == 5

    def test_for_inside_if_else(self):
        src = (
            "total = 0\n"
            "if 2 > 1:\n"
            "    for i in [1, 2, 3]:\n"
            "        total = total + i\n"
            "else:\n"
            "    total = -1\n"
        )
        t = _translate(src)
        assert t.env["total"] == 6

    def test_complex_combined(self):
        """for -> if/else -> while with logical ops."""
        src = (
            "sum = 0\n"
            "for i in [1, 2, 3, 4]:\n"
            "    if i > 1 && i < 4:\n"
            "        n = 0\n"
            "        while n < i:\n"
            "            sum = sum + 1\n"
            "            n = n + 1\n"
        )
        t = _translate(src)
        # i=2 -> adds 2, i=3 -> adds 3 -> total 5
        assert t.env["sum"] == 5


# ---------------------------------------------------------------------------
# Bracket-index evaluation
# ---------------------------------------------------------------------------

class TestBracketIndex:
    def test_simple_index(self):
        t = _translate("x = [10, 20, 30][1]\n")
        assert t.env["x"] == 20

    def test_nested_index(self):
        t = _translate("x = [[1, 2], [3, 4]][1][0]\n")
        assert t.env["x"] == 3

    def test_computed_index(self):
        t = _translate("i = 2\nx = [10, 20, 30][i]\n")
        assert t.env["x"] == 30

    def test_non_list_target_raises(self):
        with pytest.raises(TranslatorError):
            _translate("x = 5[0]\n")

    def test_out_of_range_raises(self):
        with pytest.raises(TranslatorError, match=r"index 10 out of range for list of length 3"):
            _translate("x = [1, 2, 3][10]\n")

    def test_negative_index_raises(self):
        # -1 parses as UnaryOp("-", Number(1)) → int(-1) = -1 → range check catches it
        with pytest.raises(TranslatorError, match=r"out of range"):
            _translate("x = [1, 2, 3][-1]\n")

    def test_non_integer_float_raises(self):
        with pytest.raises(TranslatorError, match=r"integer-valued"):
            _translate("x = [1, 2, 3][1.5]\n")

    def test_bool_as_index_raises(self):
        with pytest.raises(TranslatorError, match=r"index must be an integer"):
            _translate("x = [1, 2, 3][true]\n")

    def test_string_target_raises(self):
        with pytest.raises(TranslatorError, match=r"strings aren't indexable"):
            _translate('x = "abc"[0]\n')


# ---------------------------------------------------------------------------
# User-defined modules
# ---------------------------------------------------------------------------

class TestUserModules:
    def test_arithmetic_module(self):
        """Basic arithmetic module returns the expected value."""
        src = (
            "module myadd(a, b):\n"
            "    return a + b\n"
            "x = myadd(2, 3)\n"
        )
        t = _translate(src)
        assert t.env["x"] == 5

    def test_default_parameter(self):
        """A defaulted parameter is used when the caller omits it."""
        src = (
            "module f(a, b=10):\n"
            "    return a + b\n"
            "y = f(5)\n"
        )
        t = _translate(src)
        assert t.env["y"] == 15

    def test_default_parameter_overridden(self):
        """Passing a positional value overrides the default."""
        src = (
            "module f(a, b=10):\n"
            "    return a + b\n"
            "y = f(5, 20)\n"
        )
        t = _translate(src)
        assert t.env["y"] == 25

    def test_kwarg_binding(self):
        src = (
            "module f(a, b=10):\n"
            "    return a + b\n"
            "y = f(1, b=2)\n"
        )
        t = _translate(src)
        assert t.env["y"] == 3

    def test_missing_required_arg_raises(self):
        src = (
            "module f(a, b):\n"
            "    return a + b\n"
            "y = f(1)\n"
        )
        with pytest.raises(TranslatorError, match=r"missing required argument"):
            _translate(src)

    def test_extra_positional_arg_raises(self):
        src = (
            "module f(a):\n"
            "    return a\n"
            "y = f(1, 2)\n"
        )
        with pytest.raises(TranslatorError, match=r"positional"):
            _translate(src)

    def test_unknown_kwarg_raises(self):
        src = (
            "module f(a):\n"
            "    return a\n"
            "y = f(1, bogus=5)\n"
        )
        with pytest.raises(TranslatorError, match=r"unexpected keyword"):
            _translate(src)

    def test_duplicate_positional_and_kwarg_raises(self):
        src = (
            "module f(a, b):\n"
            "    return a + b\n"
            "y = f(1, 2, a=3)\n"
        )
        with pytest.raises(TranslatorError, match=r"multiple values"):
            _translate(src)

    def test_scope_isolation_outer_unchanged(self):
        """A local binding in the module does NOT mutate an outer one."""
        src = (
            "x = 1\n"
            "module f():\n"
            "    x = 99\n"
            "    return x\n"
            "inner = f()\n"
        )
        t = _translate(src)
        assert t.env["x"] == 1
        assert t.env["inner"] == 99

    def test_scope_read_up(self):
        """A module body can read a variable bound in an enclosing scope."""
        src = (
            "y = 42\n"
            "module g():\n"
            "    return y + 1\n"
            "r = g()\n"
        )
        t = _translate(src)
        assert t.env["r"] == 43

    def test_module_returning_shape(self):
        """A module that constructs and returns a 3D shape works end-to-end."""
        src = (
            "module slug(r):\n"
            "    return cylinder(h=10, r=r)\n"
            "s = slug(3)\n"
        )
        t = _translate(src)
        s = t.env["s"]
        assert s.volume > 0

    def test_recursion_rejected(self):
        src = (
            "module f(n):\n"
            "    return f(n - 1)\n"
            "r = f(3)\n"
        )
        with pytest.raises(TranslatorError, match=r"recursion not supported in V1: f"):
            _translate(src)

    def test_body_without_return_raises(self):
        src = (
            "module f():\n"
            "    x = 1\n"
            "r = f()\n"
        )
        with pytest.raises(TranslatorError, match=r"module f did not return a value"):
            _translate(src)

    def test_nested_module_definition_rejected(self):
        """``module`` inside another module's body raises at translation."""
        src = (
            "module outer():\n"
            "    module inner():\n"
            "        return 1\n"
            "    return 2\n"
            "r = outer()\n"
        )
        with pytest.raises(TranslatorError, match=r"nested module definitions"):
            _translate(src)

    def test_defaults_evaluated_per_call(self):
        """Default expression is re-evaluated each call and sees current outer scope."""
        src = (
            "base = 100\n"
            "module f(a, b=base):\n"
            "    return a + b\n"
            "r1 = f(1)\n"
            "base = 200\n"
            "r2 = f(1)\n"
        )
        t = _translate(src)
        assert t.env["r1"] == 101
        assert t.env["r2"] == 201

    def test_module_call_inside_for_loop(self):
        """Modules work inside ``for`` loops (the common use case)."""
        src = (
            "module double(x):\n"
            "    return x * 2\n"
            "total = 0\n"
            "for i in [1, 2, 3]:\n"
            "    total = total + double(i)\n"
        )
        t = _translate(src)
        assert t.env["total"] == 12

    def test_recursion_stack_cleared_after_exception(self):
        """After a failing call, a fresh call of the same module must succeed
        (call-stack entry popped in ``finally``)."""
        src_bad = (
            "module f(a):\n"
            "    return a + 1\n"
            "bad = f()\n"
        )
        from mcad.parser import parse as _parse
        t = Translator()
        with pytest.raises(TranslatorError):
            t.translate(_parse(src_bad))
        # Now the same translator should be able to run a new module call
        # from scratch — env is still usable and _call_stack is empty.
        assert t._call_stack == []
        assert len(t._env_stack) == 1


# ---------------------------------------------------------------------------
# Generic edge enumeration (cube/sphere/cylinder/polyhedron/transforms/CSG)
# ---------------------------------------------------------------------------

# Schema fields required on every registry entry (extruded OR generic).
_REQUIRED_EDGE_FIELDS = {
    "id",
    "kind",
    "source_plane",
    "source_point",
    "start",
    "end",
    "midpoint",
    "axis",
    "length",
    "tags",
    "visible_in_views",
}


def _assert_schema(entry: dict) -> None:
    """Assert every registry entry has all required schema fields."""
    missing = _REQUIRED_EDGE_FIELDS - set(entry.keys())
    assert not missing, f"missing fields {missing} in entry {entry}"


class TestEnumerateEdgesHelper:
    """Direct tests for ``Translator._enumerate_edges`` against build123d shapes."""

    def test_box_yields_twelve_straight_edges_of_length_10(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert len(entries) == 12
        assert all(e["kind"] == "straight" for e in entries)
        assert all(abs(e["length"] - 10.0) < 1e-6 for e in entries)
        # IDs are 1..N
        assert [e["id"] for e in entries] == list(range(1, 13))
        for e in entries:
            _assert_schema(e)
            # Straight edges carry a unit axis vector.
            assert e["axis"] is not None
            ax, ay, az = e["axis"]
            assert abs((ax * ax + ay * ay + az * az) - 1.0) < 1e-6
            # Straight edges have no circle metadata.
            assert e["center"] is None
            assert e["radius"] is None
            assert e["normal"] is None
            # Generic entries: source_plane / source_point are null.
            assert e["source_plane"] is None
            assert e["source_point"] is None
            assert e["visible_in_views"] == [
                "Top", "Bottom", "Left", "Right", "Front", "Back",
            ]

    def test_cylinder_yields_two_rim_circles_seam_filtered(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=3, height=10))
        # Seam is filtered; only the two rim circles survive.
        assert len(entries) == 2
        assert all(e["kind"] == "circle" for e in entries)
        for c in entries:
            assert c["center"] is not None
            assert c["radius"] == pytest.approx(3.0)
            assert c["normal"] is not None

    def test_sphere_seam_is_filtered(self):
        from build123d import Sphere
        t = Translator()
        entries = t._enumerate_edges(Sphere(5))
        # Sphere has one CIRCLE edge (meridian seam) adjacent to 1 SPHERE
        # face — classified as seam and filtered out.
        assert entries == []


class TestEdgeRoleClassifier:
    """DCR 019d8fb3dbe6: geometric role derived from adjacent face types."""

    def test_cube_edges_are_all_corners(self):
        t = _translate("part = cube(10, center=true)\n")
        registry = t.get_edge_registry("part")
        assert len(registry) == 12
        assert {e["role"] for e in registry} == {"corner"}

    def test_cylinder_has_two_rims_seams_filtered(self):
        t = _translate("part = cylinder(h=10, r=3)\n")
        registry = t.get_edge_registry("part")
        role_counts: dict[str, int] = {}
        for e in registry:
            role_counts[e["role"]] = role_counts.get(e["role"], 0) + 1
        assert role_counts.get("rim", 0) == 2
        assert role_counts.get("seam", 0) == 0  # filtered

    def test_drilled_cube_has_hole_rims_seam_filtered(self):
        source = (
            "a = cube(20, center=true)\n"
            "b = cylinder(h=30, r=3, center=true)\n"
            "part = a - b\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("part")
        role_counts: dict[str, int] = {}
        for e in registry:
            role_counts[e["role"]] = role_counts.get(e["role"], 0) + 1
        assert role_counts.get("corner", 0) == 12
        assert role_counts.get("rim", 0) == 2
        assert role_counts.get("seam", 0) == 0  # filtered

    def test_matching_radii_cutter_produces_cone_cylinder_junction(self):
        source = (
            "a = cube(20, 20, 10, center=true)\n"
            "through = rotate([90, 0, 0], cylinder(h=14, r=3, center=true))\n"
            "csink = translate([0, 3.5, 0], rotate([90, 0, 0], "
            "cylinder(h=3, r1=6, r2=3, center=true)))\n"
            "slug = through + csink\n"
            "part = a - slug\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("part")
        role_counts: dict[str, int] = {}
        for e in registry:
            role_counts[e["role"]] = role_counts.get(e["role"], 0) + 1
        assert role_counts.get("cone_cylinder_junction", 0) >= 1

    def test_every_entry_has_role_field(self):
        source = (
            "a = cube(10, center=true)\n"
            "b = cylinder(h=20, r=2, center=true)\n"
            "part = a - b\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("part")
        for e in registry:
            assert "role" in e
            assert isinstance(e["role"], str)

    def test_extruded_registry_role_is_none_or_absent(self):
        # Extruded solids use _build_extruded_edge_registry and are NOT
        # reclassified — role either absent or None on those entries.
        source = (
            "height = 100\nwidth = 80\nthickness = 10\nlength = 200\n"
            "sketch:\n"
            "    flange = rect(width, thickness) center at point(0, height - thickness / 2)\n"
            "    web = rect(thickness, height - thickness) center at point(0, (height - thickness) / 2)\n"
            "    profile = flange + web\n"
            "beam = extrude(profile, length)\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("beam")
        assert len(registry) == 24
        for e in registry:
            assert e.get("role") in (None, "extrude_longitudinal", "extrude_cap_edge") or "role" not in e


class TestPrimitiveEdgeRegistry:
    """Task 2: primitives populate _logical_edge_registry via _eval_assignment."""

    def test_cube_registry_has_twelve_straight_edges(self):
        t = _translate("part = cube(10, center=true)\n")
        registry = t.get_edge_registry("part")
        assert len(registry) == 12
        assert all(e["kind"] == "straight" for e in registry)

    def test_cylinder_registry_has_at_least_two_circles(self):
        t = _translate("part = cylinder(h=10, r=3)\n")
        registry = t.get_edge_registry("part")
        circles = [e for e in registry if e["kind"] == "circle"]
        assert len(circles) >= 2

    def test_sphere_registry_is_empty_seam_filtered(self):
        t = _translate("part = sphere(r=5)\n")
        registry = t.get_edge_registry("part")
        # build123d returns 1 CIRCLE edge (meridian seam) adjacent to 1
        # SPHERE face — classified as seam and filtered from the registry.
        assert registry == []

    def test_tetrahedron_polyhedron_has_six_straight_edges(self):
        source = (
            "part = polyhedron("
            "points=[[0,0,0],[1,0,0],[0,1,0],[0,0,1]], "
            "faces=[[0,2,1],[0,1,3],[0,3,2],[1,2,3]])\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("part")
        assert len(registry) == 6
        assert all(e["kind"] == "straight" for e in registry)


class TestTransformEdgeRegistry:
    """Task 3: translate/rotate refresh the registry."""

    def test_translate_cube_registry_reflects_offset(self):
        t = _translate("part = translate([10, 0, 0], cube(5, center=true))\n")
        registry = t.get_edge_registry("part")
        assert len(registry) == 12
        assert all(e["kind"] == "straight" for e in registry)
        # At least one midpoint X is near 10 after translate.
        xs = [e["midpoint"][0] for e in registry]
        assert any(abs(x - 10.0) < 1e-6 for x in xs)

    def test_rotate_cube_registry_populated(self):
        t = _translate("part = rotate([0, 0, 90], cube(5, center=true))\n")
        registry = t.get_edge_registry("part")
        assert len(registry) == 12


class TestBooleanEdgeRegistry:
    """Task 4: CSG cut/fuse rebuild the registry."""

    def test_cube_minus_cube_registry_has_more_than_twelve_edges(self):
        source = (
            "a = cube(10, center=true)\n"
            "b = cube(4, center=true)\n"
            "part = a - b\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("part")
        # The cut introduces extra edges around the inner cavity.
        assert len(registry) > 12

    def test_extrude_minus_hole_registry_non_empty(self):
        """Pre-task this case left the registry empty after the cut — now
        it has entries (generic enumeration of the resulting solid)."""
        source = (
            "sketch:\n"
            "    p = rect(40, 40)\n"
            "block = extrude(p, 20)\n"
            "hole = translate([0, 0, -5], cylinder(h=30, r=5))\n"
            "block = block - hole\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("block")
        assert len(registry) > 0

    def test_csg_fuse_two_cubes_registry_populated(self):
        source = (
            "a = cube(10, center=true)\n"
            "b = translate([20, 0, 0], cube(5, center=true))\n"
            "part = a + b\n"
        )
        t = _translate(source)
        registry = t.get_edge_registry("part")
        assert len(registry) > 0


class TestFilletChamferOnCube:
    """Task 5: fillet/chamfer on a cube (generic-registry shape) succeeds and
    leaves a populated registry."""

    def test_chamfer_on_cube_edge_one_succeeds(self):
        source = (
            "part = cube(10, center=true)\n"
            "chamfer part, 1, d=1\n"
        )
        t = _translate(source)
        part = t.env["part"]
        assert part.volume > 0
        registry = t.get_edge_registry("part")
        assert len(registry) > 0

    def test_fillet_on_cube_edge_one_succeeds(self):
        source = (
            "part = cube(10, center=true)\n"
            "fillet part, 1, r=1\n"
        )
        t = _translate(source)
        part = t.env["part"]
        assert part.volume > 0
        registry = t.get_edge_registry("part")
        assert len(registry) > 0


class TestBatchFilletChamfer:
    """Task: list-form fillet/chamfer applies all edges in one OCCT op so
    sequential single-edge operations don't shuffle IDs underneath the agent.
    """

    def test_fillet_list_form_one_edge_succeeds(self):
        # List form with a single id should produce the same result as the
        # legacy scalar form — covers the [1] degenerate case.
        source = (
            "part = cube(10, center=true)\n"
            "fillet part, [1], r=1\n"
        )
        t = _translate(source)
        part = t.env["part"]
        assert part.volume > 0

    def test_fillet_list_form_four_edges_succeeds(self):
        # Motivating case: fillet 4 edges in one op. A plain cube has 12
        # edges total — pick 4 of them. The whole point of the batch form
        # is that all 4 IDs resolve against the same pre-fillet registry,
        # so we can count on 1, 4, 7, 10 all being valid.
        source = (
            "part = cube(25, 25, 12)\n"
            "fillet part, [1, 4, 7, 10], r=2\n"
        )
        t = _translate(source)
        part = t.env["part"]
        assert part.volume > 0
        # Volume should drop relative to the unfilleted cube by material
        # removed at the rounded corners. Sanity: less than 25*25*12 = 7500.
        assert part.volume < 25 * 25 * 12

    def test_chamfer_list_form_succeeds(self):
        source = (
            "part = cube(10, center=true)\n"
            "chamfer part, [1, 2], d=0.5\n"
        )
        t = _translate(source)
        part = t.env["part"]
        assert part.volume > 0

    def test_fillet_list_form_empty_raises(self):
        source = (
            "part = cube(10, center=true)\n"
            "fillet part, [], r=1\n"
        )
        with pytest.raises(TranslatorError, match="empty"):
            _translate(source)

    def test_fillet_list_form_non_int_raises(self):
        source = (
            "part = cube(10, center=true)\n"
            "fillet part, [1, \"two\"], r=1\n"
        )
        with pytest.raises(TranslatorError, match="integers"):
            _translate(source)

    def test_fillet_list_form_unknown_id_raises(self):
        # 999 is well past the cube's edge count; must surface as a clean error
        # rather than a silent miss.
        source = (
            "part = cube(10, center=true)\n"
            "fillet part, [1, 999], r=1\n"
        )
        with pytest.raises(TranslatorError):
            _translate(source)

    def test_batch_fillet_completes_when_serial_would_lose_ids(self):
        """The user-visible bug: a serial sequence of single-edge fillets
        re-numbers the registry between calls, so later IDs reference edges
        that didn't exist when the agent picked them. The batch form
        resolves all IDs from the pre-fillet registry in one shot.

        Test setup mirrors the user's reproducer: fillet four edges of a
        flat-ish box. The serial path is expected to either fail
        mid-sequence (out-of-range) or land on the wrong edges; the batch
        path always completes cleanly.
        """
        batch_source = (
            "part = cube(25, 25, 12)\n"
            "fillet part, [1, 4, 7, 10], r=2\n"
        )
        t_batch = _translate(batch_source)
        batch_part = t_batch.env["part"]
        assert batch_part.volume > 0
        assert batch_part.volume < 25 * 25 * 12

        # Sanity: a serial fillet sequence using the SAME starting IDs is
        # not guaranteed to succeed (edge 10 may not exist after fillets
        # 1, 4, 7 reshape the topology). We don't assert success or
        # failure — we just assert that the batch path is robust where the
        # serial path is fragile.
        serial_source = (
            "part = cube(25, 25, 12)\n"
            "fillet part, 1, r=2\n"
            "fillet part, 4, r=2\n"
            "fillet part, 7, r=2\n"
            "fillet part, 10, r=2\n"
        )
        try:
            _translate(serial_source)
        except (TranslatorError, ValueError):
            # Expected on this geometry: at least one ID drops out of range
            # (TranslatorError) OR build123d rejects an unexpected fillet
            # geometry (ValueError) after intermediate topology changes.
            # Batch form is the fix in both failure modes.
            pass


# ---------------------------------------------------------------------------
# Regression: edge IDs must survive boolean subtract (bug 019d99fa4520)
# ---------------------------------------------------------------------------

# DSL source for a T-beam with a small drilled hole in the flange.
# The drill is intentionally tiny so it does not touch the web-flange
# junction edges we are tracking (x=±5, y=90).
_T_BEAM_DRILLED = T_BEAM_NO_MODS + (
    "drill = translate([20, 95, 100], rotate([90, 0, 0], cylinder(h=20, r=3, center=true)))\n"
    "beam = beam - drill\n"
)

# Inner junction edges of the T-beam profile live at x=-5,y=90 and x=5,y=90.
# In the plain (no-boolean) build they are assigned IDs 3 and 4 by
# _build_xy_registry_entries.  After a boolean subtract the registry is
# rebuilt from scratch by _csg_cut, breaking that assignment.
_JUNCTION_SOURCE_POINTS = [(-5.0, 90.0), (5.0, 90.0)]
_JUNCTION_IDS_PLAIN = {3, 4}


def _find_junction_entries(registry: list) -> list:
    """Return registry entries whose source_point is near (±5, 90)."""
    results = []
    for entry in registry:
        sp = entry.get("source_point")
        if sp is None or len(sp) < 2:
            continue
        for tx, ty in _JUNCTION_SOURCE_POINTS:
            if abs(sp[0] - tx) < 0.5 and abs(sp[1] - ty) < 0.5:
                results.append(entry)
                break
    return results


class TestEdgeIdStabilityAcrossBoolean:
    """Regression guard for bug 019d99fa4520.

    The inner web-flange junction edges of a T-beam (source_point ≈ (±5, 90))
    should keep the same logical IDs after a boolean subtract as they have in
    the plain (no-boolean) build.  Currently _csg_cut overwrites
    _pending_edge_registry unconditionally, so IDs shift.
    """

    def test_plain_tbeam_has_inner_junction_edges_3_and_4(self):
        """Baseline: plain T-beam assigns IDs 3 and 4 to the junction edges.

        This test must PASS — it establishes the reference state that the
        xfail tests below expect to be preserved after a boolean.
        """
        t = _translate(T_BEAM_NO_MODS)
        registry = t.get_edge_registry("beam")
        junction = _find_junction_entries(registry)
        assert len(junction) == 2, (
            f"Expected 2 junction entries near (±5, 90), got {len(junction)}; "
            f"full registry source_points: {[e.get('source_point') for e in registry]}"
        )
        ids = {e["id"] for e in junction}
        assert ids == _JUNCTION_IDS_PLAIN, (
            f"Plain T-beam junction edge IDs should be {{3, 4}}, got {ids}"
        )

    def test_inner_junction_edges_keep_ids_across_boolean_subtract(self):
        """After drilling a hole, junction edges at (±5, 90) should still be
        IDs 3 and 4.  Currently _csg_cut overwrites the registry so they
        receive fresh (wrong) IDs."""
        t_plain = _translate(T_BEAM_NO_MODS)
        t_drilled = _translate(_T_BEAM_DRILLED)

        plain_registry = t_plain.get_edge_registry("beam")
        drilled_registry = t_drilled.get_edge_registry("beam")

        plain_junction = _find_junction_entries(plain_registry)
        drilled_junction = _find_junction_entries(drilled_registry)

        # Both builds must expose the junction edges.
        assert len(drilled_junction) == 2, (
            f"Expected 2 junction entries in drilled build, got {len(drilled_junction)}"
        )

        plain_ids = {e["id"] for e in plain_junction}
        drilled_ids = {e["id"] for e in drilled_junction}

        assert plain_ids == drilled_ids, (
            f"Junction edge IDs shifted after boolean subtract: "
            f"plain={plain_ids}, drilled={drilled_ids}"
        )

    def test_inner_junction_edges_findable_by_id_after_boolean(self):
        """_find_edge_by_number(beam, 'beam', 3) must still return an edge
        near (±5, 90, 100) after the drill.  Currently the registry maps
        ID 3 to a different geometric edge post-boolean, so either the wrong
        edge is returned or a TranslatorError is raised."""
        t = _translate(_T_BEAM_DRILLED)
        shape = t.env["beam"]

        # Edge 3 in the plain build is the junction at (-5, 90).  After the
        # boolean the registry is regenerated; ID 3 may map to a totally
        # different edge.  Either a wrong midpoint or an exception counts as
        # the bug manifesting — both are xfail outcomes.
        edge3 = t._find_edge_by_number(shape, "beam", 3)
        mid = edge3.center()

        # The junction edge midpoint Z should be near 100 (half of length=200).
        # X should be near ±5, Y near 90.
        is_junction = (
            abs(mid.Y - 90.0) < 1.0
            and abs(mid.Z - 100.0) < 1.0
            and (abs(mid.X - (-5.0)) < 1.0 or abs(mid.X - 5.0) < 1.0)
        )
        assert is_junction, (
            f"Edge 3 after boolean drill points to wrong geometry: "
            f"mid=({mid.X:.2f}, {mid.Y:.2f}, {mid.Z:.2f}), "
            f"expected near (±5, 90, 100)"
        )
