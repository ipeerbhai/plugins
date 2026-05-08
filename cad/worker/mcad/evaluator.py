"""High-level MCAD source evaluation helpers for the Flask API."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .parser import ParseError, parse
from .translator import Translator, TranslatorError, export_shape


@dataclass
class EvaluationResult:
    mesh: dict[str, list]
    edges: list[dict[str, Any]]
    shape_name: str


class EvaluationError(Exception):
    """Raised when MCAD source cannot be evaluated into mesh output."""


class ExportError(Exception):
    """Raised when MCAD source cannot be exported."""


def evaluate_source(
    source: str,
    *,
    tolerance: float = 0.1,
    angular_tolerance: float = 0.1,
) -> EvaluationResult:
    """Parse source, build geometry, and return a tessellated mesh."""
    try:
        program = parse(source)
        translator = Translator()
        translator.translate(program)
    except (ParseError, TranslatorError) as exc:
        raise EvaluationError(str(exc)) from exc

    shape_name, shape = translator.last_part()
    if shape_name is None or shape is None:
        raise EvaluationError(
            "No 3D part produced. Define a shape with extrude(...) before evaluating."
        )

    vertices, faces = shape.tessellate(
        tolerance=float(tolerance),
        angular_tolerance=float(angular_tolerance),
    )
    if not vertices or not faces:
        raise EvaluationError("Tessellation produced no mesh data")

    mesh = {
        "vertices": [[v.X, v.Y, v.Z] for v in vertices],
        "faces": [list(face) for face in faces],
    }
    edge_registry = translator.get_edge_registry(shape_name)

    return EvaluationResult(
        mesh=mesh,
        edges=edge_registry,
        shape_name=shape_name,
    )


def export_source(source: str, *, format: str, path: str) -> str:
    """Parse source, build geometry, and export the final solid."""
    try:
        program = parse(source)
        translator = Translator()
        translator.translate(program)
    except (ParseError, TranslatorError) as exc:
        raise ExportError(str(exc)) from exc

    shape_name, shape = translator.last_part()
    if shape_name is None or shape is None:
        raise ExportError(
            "No 3D part produced. Define a shape with extrude(...) or another 3D primitive before exporting."
        )

    export_format = format.strip().lower()
    if export_format not in {"step", "stp", "stl", "3mf"}:
        raise ExportError(f"Unsupported export format: {format}")

    if path.strip() == "":
        raise ExportError("Export request must include non-empty string field 'path'")

    # Path resolution rules (must match the §8 skill prompt contract):
    #   - absolute (``/foo``, ``C:\foo``) → used as-is
    #   - ``~``-prefixed → expanded to the user's home directory
    #   - bare relative (``test.stl``, ``temp/test.stl``) → resolved against home
    # Without this, ``~/temp/test.stl`` is treated as a literal directory named
    # ``~`` under the worker's CWD — file lands somewhere the user can't find.
    requested_path = Path(path).expanduser()
    if not requested_path.is_absolute():
        requested_path = Path.home() / requested_path
    if requested_path.suffix == "":
        requested_path = requested_path.with_suffix("." + export_format)

    try:
        return export_shape(shape, str(requested_path))
    except TranslatorError as exc:
        raise ExportError(str(exc)) from exc
