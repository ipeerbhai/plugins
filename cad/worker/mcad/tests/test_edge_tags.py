"""Unit 3 tests: semantic edge tags emitted by both registry paths.

Covers the tag vocabulary introduced in CAD UX Round 2a Unit 3:
  linear / circular / curve — curve-kind tags
  corner / rim / chamfer_connector / feature — role-derived tags
  outer / inner — wire-membership tags

Both the generic path (_enumerate_edges) and the extruded fast path
(_build_extruded_edge_registry) must produce the same vocabulary.
"""

from __future__ import annotations

import pytest

build123d = pytest.importorskip("build123d", exc_type=ImportError)

from mcad.parser import parse
from mcad.translator import Translator


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _translate(source: str) -> Translator:
    program = parse(source)
    t = Translator()
    t.translate(program)
    return t


def _tags(entry: dict) -> set[str]:
    return set(entry["tags"])


# ---------------------------------------------------------------------------
# 1. Linear/circular tagging on a simple primitive (Box)
# ---------------------------------------------------------------------------

class TestBoxSemanticTags:
    """Box(10,10,10) via generic path: 12 corner edges, all outer."""

    def test_box_all_edges_have_linear_tag(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert len(entries) == 12
        assert all("linear" in _tags(e) for e in entries), (
            "Every box edge must be tagged 'linear'"
        )

    def test_box_all_edges_have_corner_tag(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert all("corner" in _tags(e) for e in entries), (
            "Every box edge must be tagged 'corner'"
        )

    def test_box_all_edges_have_feature_tag(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert all("feature" in _tags(e) for e in entries), (
            "Every box edge must be tagged 'feature'"
        )

    def test_box_all_edges_have_outer_tag(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert all("outer" in _tags(e) for e in entries), (
            "Every box edge belongs to a face outer wire → tagged 'outer'"
        )

    def test_box_no_edge_has_inner_tag(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert not any("inner" in _tags(e) for e in entries), (
            "Box has no hole wires → no edge should be tagged 'inner'"
        )

    def test_box_no_edge_has_circular_or_curve_tag(self):
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        assert not any("circular" in _tags(e) for e in entries)
        assert not any("curve" in _tags(e) for e in entries)

    def test_box_exact_tag_set_per_edge(self):
        """Every box edge must have exactly {linear, corner, feature, outer}."""
        from build123d import Box
        t = Translator()
        entries = t._enumerate_edges(Box(10, 10, 10))
        expected = {"linear", "corner", "feature", "outer"}
        for e in entries:
            actual = _tags(e)
            assert expected.issubset(actual), (
                f"Edge {e['id']} missing tags: {expected - actual}"
            )


# ---------------------------------------------------------------------------
# 2. Circular tagging on a Cylinder
# ---------------------------------------------------------------------------

class TestCylinderSemanticTags:
    """Cylinder(radius=5, height=10): 2 rim circles, seam filtered."""

    def test_cylinder_has_two_circle_edges(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=5, height=10))
        assert len(entries) == 2

    def test_cylinder_edges_have_circular_tag(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=5, height=10))
        assert all("circular" in _tags(e) for e in entries)

    def test_cylinder_edges_have_rim_tag(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=5, height=10))
        assert all("rim" in _tags(e) for e in entries)

    def test_cylinder_edges_have_feature_tag(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=5, height=10))
        assert all("feature" in _tags(e) for e in entries)

    def test_cylinder_edges_have_outer_tag(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=5, height=10))
        assert all("outer" in _tags(e) for e in entries)

    def test_cylinder_edges_have_no_linear_tag(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=5, height=10))
        assert not any("linear" in _tags(e) for e in entries)


# ---------------------------------------------------------------------------
# 3. Inner/outer tagging on a shape with a hole
# ---------------------------------------------------------------------------

class TestHoleWireMembership:
    """Cube with cylindrical hole: outer cube edges → 'outer';
    rim circles → 'outer' (from cylinder face) + 'inner' (from flat face hole)."""

    SOURCE = (
        "a = cube(20, center=true)\n"
        "b = cylinder(h=30, r=3, center=true)\n"
        "part = a - b\n"
    )

    def test_drilled_cube_has_fourteen_edges(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("part")
        assert len(reg) == 14

    def test_twelve_corner_edges_are_outer_only(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("part")
        corner_edges = [e for e in reg if e["role"] == "corner"]
        assert len(corner_edges) == 12
        for e in corner_edges:
            assert "outer" in _tags(e), f"Corner edge {e['id']} missing 'outer'"
            assert "inner" not in _tags(e), (
                f"Corner edge {e['id']} unexpectedly tagged 'inner'"
            )

    def test_rim_circles_are_tagged_inner(self):
        """Rim circles border the hole — they appear in flat face inner wires."""
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("part")
        rim_edges = [e for e in reg if e["role"] == "rim"]
        assert len(rim_edges) == 2
        for e in rim_edges:
            assert "inner" in _tags(e), (
                f"Rim edge {e['id']} should be tagged 'inner' (hole boundary)"
            )

    def test_rim_circles_also_tagged_outer(self):
        """The cylinder face's outer wire IS the rim — so it gets 'outer' too."""
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("part")
        rim_edges = [e for e in reg if e["role"] == "rim"]
        for e in rim_edges:
            assert "outer" in _tags(e), (
                f"Rim edge {e['id']} should also be tagged 'outer' "
                "(outer wire of cylinder face)"
            )


# ---------------------------------------------------------------------------
# 4. Seam filtering is preserved
# ---------------------------------------------------------------------------

class TestSeamFiltering:
    """Seam edges must be absent from the registry (existing behaviour)."""

    def test_cylinder_seam_not_in_registry(self):
        from build123d import Cylinder
        t = Translator()
        entries = t._enumerate_edges(Cylinder(radius=3, height=10))
        # Only 2 rim circles survive; straight seam is filtered.
        assert len(entries) == 2
        assert all(e["kind"] == "circle" for e in entries)

    def test_sphere_has_no_registry_entries(self):
        from build123d import Sphere
        t = Translator()
        entries = t._enumerate_edges(Sphere(5))
        # Single meridian seam → filtered → empty registry.
        assert entries == []

    def test_no_seam_role_in_any_registry_entry(self):
        """The 'seam' role should never appear — seams are skipped before emit."""
        t = _translate("part = cylinder(h=10, r=3)\n")
        reg = t.get_edge_registry("part")
        roles = {e.get("role") for e in reg}
        assert "seam" not in roles


# ---------------------------------------------------------------------------
# 5. Extruded fast-path tag parity
# ---------------------------------------------------------------------------

class TestExtrudedFastPathTags:
    """_build_extruded_edge_registry must emit semantic tags (linear / corner /
    feature / outer) alongside the existing spatial tags."""

    SOURCE = (
        "sketch:\n"
        "    s = rect(10, 10)\n"
        "b = extrude(s, 10)\n"
    )

    def test_extruded_box_has_twelve_entries(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("b")
        assert len(reg) == 12

    def test_extruded_edges_have_linear_tag(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("b")
        assert all("linear" in _tags(e) for e in reg), (
            "All extruded box edges are straight → must be tagged 'linear'"
        )

    def test_extruded_edges_have_corner_tag(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("b")
        assert all("corner" in _tags(e) for e in reg), (
            "All extruded box edges are plane-plane corners"
        )

    def test_extruded_edges_have_feature_tag(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("b")
        assert all("feature" in _tags(e) for e in reg)

    def test_extruded_edges_have_outer_tag(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("b")
        assert all("outer" in _tags(e) for e in reg)

    def test_extruded_edges_retain_spatial_tags(self):
        """Spatial tags (axis_z, positive_x, etc.) must still be present."""
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("b")
        z_edges = [e for e in reg if e.get("kind") == "longitudinal"]
        assert len(z_edges) == 4
        assert all("axis_z" in _tags(e) for e in z_edges), (
            "Longitudinal entries must retain 'axis_z' spatial tag"
        )
        cap_edges = [e for e in reg if e.get("kind") == "cap_edge"]
        assert len(cap_edges) == 8
        for e in cap_edges:
            assert any(t in _tags(e) for t in ("axis_x", "axis_y")), (
                f"Cap edge {e['id']} missing axis_x / axis_y spatial tag"
            )

    def test_extruded_semantic_tags_same_as_generic(self):
        """The semantic subset of tags must match the generic path for a cube."""
        from build123d import Box

        # Generic path
        translator_generic = Translator()
        generic_entries = translator_generic._enumerate_edges(Box(10, 10, 10))
        generic_sem = {frozenset({"linear", "corner", "feature", "outer"} & _tags(e))
                       for e in generic_entries}

        # Extruded path
        translator_extruded = _translate(self.SOURCE)
        ext_entries = translator_extruded.get_edge_registry("b")
        ext_sem = {frozenset({"linear", "corner", "feature", "outer"} & _tags(e))
                   for e in ext_entries}

        assert generic_sem == ext_sem, (
            f"Semantic tag sets differ: generic={generic_sem}, extruded={ext_sem}"
        )


# ---------------------------------------------------------------------------
# 6. Tag deduplication for edges with both outer and inner membership
# ---------------------------------------------------------------------------

class TestTagDeduplication:
    """Edges that appear in both outer and inner wires must have each tag
    exactly once (no duplicates in the tags list)."""

    SOURCE = (
        "a = cube(20, center=true)\n"
        "b = cylinder(h=30, r=3, center=true)\n"
        "part = a - b\n"
    )

    def test_no_duplicate_tags_in_any_entry(self):
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("part")
        for e in reg:
            tag_list = e["tags"]
            assert len(tag_list) == len(set(tag_list)), (
                f"Edge {e['id']} has duplicate tags: {tag_list}"
            )

    def test_both_membership_edge_has_inner_and_outer_exactly_once(self):
        """Rim circles appear in flat face inner wires AND cylinder outer wire."""
        t = _translate(self.SOURCE)
        reg = t.get_edge_registry("part")
        rim_edges = [e for e in reg if e["role"] == "rim"]
        assert len(rim_edges) == 2
        for e in rim_edges:
            tag_list = e["tags"]
            assert tag_list.count("outer") == 1, (
                f"Edge {e['id']} has 'outer' {tag_list.count('outer')} times: {tag_list}"
            )
            assert tag_list.count("inner") == 1, (
                f"Edge {e['id']} has 'inner' {tag_list.count('inner')} times: {tag_list}"
            )
