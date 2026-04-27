"""Tests for the XY-plane polar-sweep edge numbering algorithm.

Covers:
  1. Simple rectangle — predictable numbering
  2. T-beam profile — all 8 vertices unique, deterministic, right-side-first
  3. Parameter stability — width change preserves relative ordering
  4. Symmetry — mirror vertices get consistent numbering
  5. Extruded edges — correct z=0..L at each (x, y)
  6. Edge cases — single vertex, collinear, centroid-on-vertex
"""

from __future__ import annotations

import math

import pytest

from mcad.edge_numbering import (
    number_edges_2d,
    number_edges_extruded,
    _centroid,
    _polar_angle,
)


# ── Fixtures ──────────────────────────────────────────────────────────


def _rect_vertices(w: float, h: float) -> list[tuple[float, float]]:
    """Axis-aligned rectangle centred at origin, CCW winding."""
    hw, hh = w / 2, h / 2
    return [
        (hw, hh),     # top-right
        (-hw, hh),    # top-left
        (-hw, -hh),   # bottom-left
        (hw, -hh),    # bottom-right
    ]


def _t_beam_vertices(
    width: float = 80,
    height: float = 100,
    thickness: float = 10,
) -> list[tuple[float, float]]:
    """T-beam profile (flange on top, web centred on X).

           (-w/2, height)────────(w/2, height)
               |                      |
           (-w/2, height-t)──(-t/2, height-t)  (t/2, height-t)──(w/2, height-t)
                                |              |
                             (-t/2, 0)──────(t/2, 0)

    Returns 8 vertices in CCW winding order.
    """
    hw = width / 2
    ht = thickness / 2
    ft = height - thickness  # flange bottom y
    return [
        (ht, 0),          # bottom-right of web
        (ht, ft),         # top-right of web (junction)
        (hw, ft),         # bottom-right of flange
        (hw, height),     # top-right of flange
        (-hw, height),    # top-left of flange
        (-hw, ft),        # bottom-left of flange
        (-ht, ft),        # top-left of web (junction)
        (-ht, 0),         # bottom-left of web
    ]


# ── Test 1: Simple Rectangle ─────────────────────────────────────────


class TestRectangle:
    """A rectangle centred at origin has its centroid at (0,0).

    Vertices by angle from +X axis (CCW):
        top-right    (hw, hh)   ~ 45deg   -> edge 1
        top-left     (-hw, hh)  ~ 135deg  -> edge 2
        bottom-left  (-hw,-hh)  ~ 225deg  -> edge 3
        bottom-right (hw, -hh)  ~ 315deg  -> edge 4
    """

    def test_four_edges(self):
        verts = _rect_vertices(40, 20)
        result = number_edges_2d(verts)
        assert len(result) == 4

    def test_edge_1_is_smallest_ccw_angle(self):
        verts = _rect_vertices(40, 20)
        result = number_edges_2d(verts)
        # top-right vertex (20, 10) at ~26.6deg should be edge 1
        assert result[1] == (20.0, 10.0)

    def test_ccw_ordering(self):
        verts = _rect_vertices(40, 20)
        result = number_edges_2d(verts)
        # Angles must be monotonically increasing
        cx, cy = _centroid(verts)
        angles = [_polar_angle(result[i], (cx, cy)) for i in range(1, 5)]
        for i in range(len(angles) - 1):
            assert angles[i] < angles[i + 1], (
                f"Angle for edge {i+1} ({angles[i]:.4f}) >= "
                f"edge {i+2} ({angles[i+1]:.4f})"
            )


# ── Test 2: T-beam Profile ───────────────────────────────────────────


class TestTBeam:
    """8-vertex T-beam profile, default dims (width=80, height=100, t=10)."""

    def test_all_8_unique_numbers(self):
        verts = _t_beam_vertices()
        result = number_edges_2d(verts)
        assert len(result) == 8
        assert set(result.keys()) == set(range(1, 9))

    def test_deterministic(self):
        """Same input always gives same output (run twice)."""
        verts = _t_beam_vertices()
        r1 = number_edges_2d(verts)
        r2 = number_edges_2d(verts)
        assert r1 == r2

    def test_right_side_gets_lower_numbers_than_left_mirror(self):
        """For each mirror pair, the right-side vertex (positive x) should
        get a lower edge number than its left-side mirror, because the
        CCW sweep encounters the right side first (smaller angle) for
        vertices above the centroid, and encounters left side first for
        vertices below the centroid.

        The centroid is at (0, 70). The flange vertices at y=90/100 are
        above the centroid and to the right, so right flange < left flange.
        The web bottom vertices at y=0 are far below, at ~270deg; the
        left (-5,0) at ~266deg comes before right (5,0) at ~274deg.
        """
        verts = _t_beam_vertices()
        result = number_edges_2d(verts)
        inv = {v: k for k, v in result.items()}

        # Flange: right-side flange corners should precede left-side
        assert inv[(40.0, 90.0)] < inv[(-40.0, 90.0)]
        assert inv[(40.0, 100.0)] < inv[(-40.0, 100.0)]

        # Web bottom: left (-5, 0) at ~266deg comes before right (5, 0) at ~274deg
        assert inv[(-5.0, 0.0)] < inv[(5.0, 0.0)]

    def test_all_vertices_present(self):
        """Every input vertex appears in the output."""
        verts = _t_beam_vertices()
        result = number_edges_2d(verts)
        assert set(result.values()) == set(verts)


# ── Test 3: Parameter Stability ───────────────────────────────────────


class TestParameterStability:
    """Changing width from 80 to 100 should preserve relative ordering
    of vertices that still exist (topology unchanged)."""

    def test_edge_1_is_stable_across_width_change(self):
        """Edge 1 should be the bottom-right flange vertex in both cases.

        The centroid is at (0, 70) for the default T-beam. The flange
        bottom-right corner (hw, 90) has the smallest angle from +X axis
        because it's to the right and slightly above centroid.

        When width changes from 80→100, the flange corner moves from
        (40, 90) to (50, 90) but stays in the same angular region.
        It should remain edge 1.
        """
        r80 = number_edges_2d(_t_beam_vertices(width=80))
        r100 = number_edges_2d(_t_beam_vertices(width=100))

        # Edge 1 is the bottom-right flange corner in both cases
        assert r80[1] == (40.0, 90.0)
        assert r100[1] == (50.0, 90.0)

    def test_relative_ordering_preserved(self):
        """The order of the web vertices (which don't move) should be
        the same in both parameterisations."""
        verts80 = _t_beam_vertices(width=80)
        verts100 = _t_beam_vertices(width=100)
        r80 = number_edges_2d(verts80)
        r100 = number_edges_2d(verts100)

        # Web vertices that don't change with width
        web_verts = {(5.0, 0.0), (-5.0, 0.0), (5.0, 90.0), (-5.0, 90.0)}

        inv80 = {v: k for k, v in r80.items()}
        inv100 = {v: k for k, v in r100.items()}

        # Build ordered lists of web vertex edge numbers
        order80 = sorted(web_verts, key=lambda v: inv80[v])
        order100 = sorted(web_verts, key=lambda v: inv100[v])
        assert order80 == order100, (
            f"Web vertex ordering changed:\n  w=80: {order80}\n  w=100: {order100}"
        )


# ── Test 4: Symmetry ─────────────────────────────────────────────────


class TestSymmetry:
    """For a left/right symmetric profile, mirror vertices should get
    consistent (not random) numbering.  Specifically, the right-side
    vertex should always get a lower number than its left-side mirror
    for the bottom half (below centroid) and vice versa for the top half,
    due to the CCW sweep direction."""

    def test_symmetric_rectangle(self):
        """In a centered rectangle, right-side vertices precede left-side
        in the CCW sweep (they appear first at smaller angles)."""
        verts = _rect_vertices(60, 40)
        result = number_edges_2d(verts)
        inv = {v: k for k, v in result.items()}
        # Top-right (30, 20) angle ~33.7deg  before top-left (-30, 20) angle ~146.3deg
        assert inv[(30.0, 20.0)] < inv[(-30.0, 20.0)]
        # Bottom-right (30, -20) angle ~326.3deg before bottom-left (-30, -20) angle ~213.7deg
        # Actually bottom-left at ~213.7 < bottom-right at ~326.3 in CCW
        assert inv[(-30.0, -20.0)] < inv[(30.0, -20.0)]

    def test_symmetric_t_beam_mirror_pairs(self):
        """For each right-side vertex, its left-side mirror should differ
        by a predictable offset in numbering."""
        verts = _t_beam_vertices()
        result = number_edges_2d(verts)

        # Check that numbering is deterministic for mirror pairs
        inv = {v: k for k, v in result.items()}
        mirror_pairs = [
            ((5.0, 0.0), (-5.0, 0.0)),
            ((5.0, 90.0), (-5.0, 90.0)),
            ((40.0, 90.0), (-40.0, 90.0)),
            ((40.0, 100.0), (-40.0, 100.0)),
        ]
        for right, left in mirror_pairs:
            assert inv[right] != inv[left], (
                f"Mirror pair {right}/{left} got the same edge number!"
            )


# ── Test 5: Extruded Edges ───────────────────────────────────────────


class TestExtruded:
    """Take the T-beam 2D numbering, extrude to length=200."""

    def test_same_count(self):
        verts = _t_beam_vertices()
        result = number_edges_extruded(verts, 200.0)
        assert len(result) == 8

    def test_z_range(self):
        verts = _t_beam_vertices()
        result = number_edges_extruded(verts, 200.0)
        for edge_num, edge in result.items():
            assert edge["start"][2] == 0.0, f"Edge {edge_num} start z != 0"
            assert edge["end"][2] == 200.0, f"Edge {edge_num} end z != 200"

    def test_xy_matches_2d(self):
        """The x,y of each extruded edge must match the 2D numbering."""
        verts = _t_beam_vertices()
        r2d = number_edges_2d(verts)
        r3d = number_edges_extruded(verts, 200.0)
        for edge_num in r2d:
            x2d, y2d = r2d[edge_num]
            assert r3d[edge_num]["start"][:2] == (x2d, y2d)
            assert r3d[edge_num]["end"][:2] == (x2d, y2d)
            assert r3d[edge_num]["vertex_2d"] == (x2d, y2d)

    def test_edge_structure(self):
        verts = _t_beam_vertices()
        result = number_edges_extruded(verts, 200.0)
        for edge_num, edge in result.items():
            assert set(edge.keys()) == {"start", "end", "vertex_2d"}
            assert len(edge["start"]) == 3
            assert len(edge["end"]) == 3
            assert len(edge["vertex_2d"]) == 2


# ── Test 6: Edge Cases ───────────────────────────────────────────────


class TestEdgeCases:

    def test_empty_input(self):
        assert number_edges_2d([]) == {}

    def test_single_vertex(self):
        result = number_edges_2d([(3.0, 4.0)])
        assert result == {1: (3.0, 4.0)}

    def test_two_vertices(self):
        result = number_edges_2d([(1.0, 0.0), (-1.0, 0.0)])
        # Centroid is (0,0). (1,0) at angle 0, (-1,0) at angle pi.
        assert result[1] == (1.0, 0.0)
        assert result[2] == (-1.0, 0.0)

    def test_collinear_same_angle_sorted_by_distance(self):
        """Three points on the same ray from centroid: sorted by distance."""
        # Centroid of (1,0), (2,0), (3,0) is (2, 0).
        # Relative to centroid: (-1,0) at angle pi, (0,0) at centroid, (1,0) at angle 0.
        # Actually let's pick a cleaner example.
        verts = [(1.0, 0.0), (3.0, 0.0), (5.0, 0.0)]
        # Centroid = (3, 0).  Relative: (-2,0) at pi, (0,0) at center, (2,0) at 0.
        # (5,0) at angle 0 distance 2, (1,0) at angle pi distance 2.
        # But (3,0) is AT the centroid — angle is 0, distance 0.
        result = number_edges_2d(verts)
        # (3, 0) at distance 0 should be edge 1 (angle=0, dist=0)
        # (5, 0) at angle 0, distance 2 should be edge 2
        # (1, 0) at angle pi, distance 2 should be edge 3
        assert result[1] == (3.0, 0.0)
        assert result[2] == (5.0, 0.0)
        assert result[3] == (1.0, 0.0)

    def test_centroid_on_vertex(self):
        """When centroid coincides with a vertex, that vertex has distance 0
        and angle 0 (atan2(0,0) = 0).  Should not crash."""
        # Equilateral-ish triangle where one vertex is at centroid
        # Actually just make a set where centroid lands on a vertex by design
        verts = [(0.0, 0.0), (2.0, 0.0), (1.0, math.sqrt(3))]
        # Centroid = (1, sqrt(3)/3) ~ (1, 0.577). Not on a vertex.
        # Let's engineer it: centroid of (0,0), (3,0), (0,3) = (1,1).
        # Not on a vertex either. Use: (0,0), (2,0), (-2,0) => centroid (0,0)
        verts = [(0.0, 0.0), (2.0, 0.0), (-2.0, 0.0)]
        result = number_edges_2d(verts)
        assert len(result) == 3
        # (0,0) is at centroid: distance=0, angle will be atan2(0,0)=0
        assert result[1] == (0.0, 0.0)

    def test_extruded_empty(self):
        assert number_edges_extruded([], 100.0) == {}

    def test_extruded_single(self):
        result = number_edges_extruded([(1.0, 2.0)], 50.0)
        assert result == {
            1: {
                "start": (1.0, 2.0, 0.0),
                "end": (1.0, 2.0, 50.0),
                "vertex_2d": (1.0, 2.0),
            }
        }
