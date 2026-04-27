"""Edge numbering via XY-plane polar sweep from centroid.

V1 implementation: numbers profile vertices (which become longitudinal edges
when extruded) using a CCW polar sweep around the centroid of the 2D profile.

Spec reference: experiments/cad/docs/spec.md section 5.
"""

from __future__ import annotations

import hashlib
import math


def _centroid(vertices: list[tuple[float, float]]) -> tuple[float, float]:
    """Compute the arithmetic mean of a set of 2D vertices."""
    n = len(vertices)
    if n == 0:
        raise ValueError("Cannot compute centroid of empty vertex list")
    cx = sum(v[0] for v in vertices) / n
    cy = sum(v[1] for v in vertices) / n
    return (cx, cy)


def _polar_angle(vertex: tuple[float, float], center: tuple[float, float]) -> float:
    """Compute the polar angle of *vertex* relative to *center*.

    Returns a value in [0, 2*pi).  Angle 0 is the positive X direction,
    increasing counter-clockwise.
    """
    dx = vertex[0] - center[0]
    dy = vertex[1] - center[1]
    angle = math.atan2(dy, dx)
    if angle < 0:
        angle += 2 * math.pi
    return angle


def _distance(vertex: tuple[float, float], center: tuple[float, float]) -> float:
    """Euclidean distance between two 2D points."""
    dx = vertex[0] - center[0]
    dy = vertex[1] - center[1]
    return math.hypot(dx, dy)


def _vertex_hash(vertex: tuple[float, float]) -> str:
    """Deterministic hash of a vertex for tie-breaking.

    Uses SHA-256 of the repr so the ordering is stable across runs
    (Python hash randomisation does NOT affect this).
    """
    raw = f"{vertex[0]:.15g},{vertex[1]:.15g}"
    return hashlib.sha256(raw.encode()).hexdigest()


def _sort_key(
    vertex: tuple[float, float],
    center: tuple[float, float],
) -> tuple[float, float, str]:
    """Sort key for polar sweep: (angle, distance, hash)."""
    return (
        _polar_angle(vertex, center),
        _distance(vertex, center),
        _vertex_hash(vertex),
    )


# ── Public API ────────────────────────────────────────────────────────


def number_edges_2d(
    vertices: list[tuple[float, float]],
) -> dict[int, tuple[float, float]]:
    """Number profile vertices by polar sweep from centroid.

    Returns ``{edge_number: (x, y)}`` starting from 1.

    Algorithm
    ---------
    1. Compute the centroid of all vertices.
    2. For each vertex compute polar angle (atan2, CCW from +X, [0, 2pi)).
    3. Sort by angle (primary), distance from centroid (secondary, smaller
       first), deterministic hash (tertiary).
    4. Assign edge numbers 1, 2, 3 ... in sorted order.
    """
    if not vertices:
        return {}

    center = _centroid(vertices)
    sorted_verts = sorted(vertices, key=lambda v: _sort_key(v, center))

    return {i + 1: v for i, v in enumerate(sorted_verts)}


def number_edges_extruded(
    vertices_2d: list[tuple[float, float]],
    extrusion_length: float,
) -> dict[int, dict]:
    """Number edges of an extruded profile.

    Each 2D profile vertex becomes a longitudinal edge running from
    ``z=0`` to ``z=extrusion_length`` at the vertex's (x, y) position.

    Returns::

        {edge_number: {
            "start": (x, y, 0.0),
            "end":   (x, y, extrusion_length),
            "vertex_2d": (x, y),
        }}
    """
    numbering_2d = number_edges_2d(vertices_2d)

    result: dict[int, dict] = {}
    for edge_num, (x, y) in numbering_2d.items():
        result[edge_num] = {
            "start": (x, y, 0.0),
            "end": (x, y, extrusion_length),
            "vertex_2d": (x, y),
        }
    return result
