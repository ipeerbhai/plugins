"""Request handlers for the Go-Python bridge worker.

This module is pure (no I/O apart from the explicit `export` method, which
writes a single user-named file) so it can be tested directly without stdio.
Callers pass a decoded request dict and receive a response dict.

Per design §8, only `init` and `shutdown` are real in Round 1 (scaffold).
Round 2 Unit A adds a real `validate` implementation.
Round 3 Unit A adds real `evaluate` and `list_edges` implementations.
Round 4 adds `export` (STL binary / 3MF / STEP AP214) atop the existing
``mcad.evaluator.export_source`` helper. The remaining stub is `deviation`.
"""

from __future__ import annotations

import os
import traceback
from pathlib import Path
from typing import Optional, Tuple

WORKER_VERSION = "0.1.0"

# Module-level last-program cache (design §5).
# Keyed by hash(source); holds the last evaluation result as a plain dict.
# Size 1: replaced on each new source. Threadsafe is not required — the worker
# is single-threaded by design (§2 process model).
_last_program: Optional[Tuple[int, dict]] = None

# Best-effort OCCT version string, resolved once at module import.
_OCCT_VERSION: str = "unknown"
try:
    import OCP  # type: ignore[import]
    _OCCT_VERSION = getattr(OCP, "__version__", "unknown")
except Exception:
    try:
        # cadquery-ocp exposes the version differently on some installs.
        import OCC.Core.BRep  # type: ignore[import]
        _OCCT_VERSION = "7.x"
    except Exception:
        pass

# Best-effort build123d version, resolved once at module import.
_BUILD123D_VERSION: str = "unknown"
try:
    import build123d  # type: ignore[import]
    _BUILD123D_VERSION = getattr(build123d, "__version__", "unknown")
except Exception:
    pass


def _evaluate(params: dict) -> dict:
    """Run the full mcad pipeline (lex → parse → translate → tessellate).

    Returns {ok: True, result: {shape_name, mesh: {vertices, faces}, edges}}
    or {ok: False, error: {kind, message, ...}}.

    Maintains the module-level ``_last_program`` cache (design §5): if the
    same source is evaluated twice, the second call returns the cached dict
    without re-tessellating.
    """
    global _last_program

    source = params.get("source")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "evaluate requires params.source: str",
            },
        }

    tolerance: float = float(params.get("tolerance", 0.1))
    angular_tolerance: float = float(params.get("angular_tolerance", 0.1))

    h = hash(source)
    if _last_program is not None and _last_program[0] == h:
        return {"ok": True, "result": _last_program[1]}

    try:
        from mcad.evaluator import EvaluationError, evaluate_source
        from mcad.lexer import LexError
        from mcad.parser import ParseError
        from mcad.translator import TranslatorError
    except ImportError as exc:
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": f"mcad package unavailable: {exc}",
            },
        }

    try:
        result = evaluate_source(
            source,
            tolerance=tolerance,
            angular_tolerance=angular_tolerance,
        )
    except LexError as exc:
        # LexError is not wrapped by EvaluationError; lex is conceptually part
        # of the parse phase per design §7. Surface as kind: "parse" with
        # line/col from the exception attributes.
        return {
            "ok": False,
            "error": {
                "kind": "parse",
                "message": str(exc),
                "details": {
                    "line": getattr(exc, "line", 0),
                    "col": getattr(exc, "col", 0),
                },
            },
        }
    except EvaluationError as exc:
        # EvaluationError wraps both ParseError and TranslatorError (and plain
        # "no 3D part produced" / "tessellation produced no mesh data" messages).
        # We inspect the __cause__ to pick the right kind.
        cause = exc.__cause__
        if isinstance(cause, ParseError):
            kind = "parse"
            tok = getattr(cause, "token", None)
            detail: dict = {}
            if tok is not None:
                detail = {"line": tok.line, "col": tok.col}
            return {
                "ok": False,
                "error": {
                    "kind": kind,
                    "message": str(exc),
                    "details": detail,
                },
            }
        if isinstance(cause, TranslatorError):
            return {
                "ok": False,
                "error": {
                    "kind": "translate",
                    "message": str(exc),
                },
            }
        # No typed cause or unrecognised cause → treat as OCCT/build123d error.
        return {
            "ok": False,
            "error": {
                "kind": "occt",
                "message": str(exc),
            },
        }
    except Exception as exc:
        return {
            "ok": False,
            "error": {
                "kind": "python",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            },
        }

    result_dict: dict = {
        "shape_name": result.shape_name,
        "mesh": result.mesh,
        "edges": result.edges,
    }
    _last_program = (h, result_dict)
    return {"ok": True, "result": result_dict}


def _list_edges(params: dict) -> dict:
    """Return just the edges list for a given source (design §8.4).

    Reuses the ``_last_program`` cache when the source was evaluated recently,
    avoiding a redundant tessellation pass.
    """
    global _last_program

    source = params.get("source")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "list_edges requires params.source: str",
            },
        }

    h = hash(source)
    if _last_program is not None and _last_program[0] == h:
        return {"ok": True, "result": _last_program[1]["edges"]}

    # Cache miss — run the full evaluate pipeline.
    response = _evaluate({"source": source})
    if not response.get("ok"):
        return response  # propagate error unchanged

    return {"ok": True, "result": response["result"]["edges"]}


_SUPPORTED_EXPORT_FORMATS: frozenset[str] = frozenset({"stl", "step", "stp", "3mf"})


def _export(params: dict) -> dict:
    """Export the last 3D part of *source* to *path* in *format*.

    Params:
        source: str — full .mcad source text.
        format: str — "stl" | "step" | "stp" | "3mf" (case-insensitive).
        path:   str — absolute or ~-prefixed path; relative paths resolve
                against the user's home directory (delegated to evaluator).

    Returns:
        {ok: True, result: {path: str, bytes_written: int, format: str}}
        on success, or {ok: False, error: {kind, message, ...}} on failure.

    Failure kinds:
        - "internal" — bad params (missing/wrong type).
        - "parse"    — DSL syntax error (propagated from evaluator).
        - "translate" — DSL is well-formed but produces no shape, or the
                         export call rejected the result.
        - "io"       — disk write failed (permission, missing parent dir
                       even after mkdir, etc).
        - "python"   — unhandled exception; includes traceback.
    """
    source = params.get("source")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "export requires params.source: str",
            },
        }

    fmt_raw = params.get("format")
    if not isinstance(fmt_raw, str) or fmt_raw.strip() == "":
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "export requires params.format: str",
            },
        }
    fmt = fmt_raw.strip().lower()
    if fmt not in _SUPPORTED_EXPORT_FORMATS:
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": (
                    f"unsupported export format: {fmt_raw!r} "
                    f"(supported: {sorted(_SUPPORTED_EXPORT_FORMATS)})"
                ),
            },
        }

    path = params.get("path")
    if not isinstance(path, str) or path.strip() == "":
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "export requires params.path: non-empty str",
            },
        }

    try:
        from mcad.evaluator import ExportError, export_source
        from mcad.lexer import LexError
        from mcad.parser import ParseError
        from mcad.translator import TranslatorError
    except ImportError as exc:
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": f"mcad package unavailable: {exc}",
            },
        }

    try:
        written_path = export_source(source, format=fmt, path=path)
    except LexError as exc:
        # Lex errors aren't wrapped by ExportError (which only catches
        # ParseError/TranslatorError); surface as parse kind so callers
        # see a uniform "bad DSL" signal.
        return {
            "ok": False,
            "error": {
                "kind": "parse",
                "message": str(exc),
                "details": {
                    "line": getattr(exc, "line", 0),
                    "col": getattr(exc, "col", 0),
                },
            },
        }
    except ExportError as exc:
        cause = exc.__cause__
        if isinstance(cause, ParseError):
            kind = "parse"
        elif isinstance(cause, TranslatorError):
            kind = "translate"
        else:
            kind = "translate"
        return {
            "ok": False,
            "error": {"kind": kind, "message": str(exc)},
        }
    except OSError as exc:
        return {
            "ok": False,
            "error": {
                "kind": "io",
                "message": f"failed to write export: {exc}",
            },
        }
    except Exception as exc:
        return {
            "ok": False,
            "error": {
                "kind": "python",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            },
        }

    bytes_written = 0
    try:
        bytes_written = os.path.getsize(written_path)
    except OSError:
        # File should exist (export_source already wrote it); if stat fails
        # we still report ok=True with bytes_written=0 rather than spuriously
        # failing the export call.
        pass

    return {
        "ok": True,
        "result": {
            "path": str(Path(written_path)),
            "bytes_written": bytes_written,
            "format": fmt,
        },
    }


def _stub_not_implemented(req: dict) -> dict:
    """Return the standard scaffold stub error response."""
    return {
        "id": req.get("id"),
        "ok": False,
        "error": {
            "kind": "internal",
            "message": "not implemented in scaffold",
        },
    }


def _validate(params: dict) -> dict:
    """Validate .mcad source: lex + parse, but skip tessellation.

    Returns {ok: bool, errors: [...], warnings: [...]}. Lex and parse
    errors populate the errors list as data; they do NOT raise to the
    bridge layer. Only catastrophic Python failures (unhandled exceptions)
    propagate to the bridge as {ok: false, error: {kind: ...}}.

    Per design §8.3 and the constraint that translator.py imports build123d
    at module level (which requires OCCT), validate deliberately stops after
    the parse phase.  Lex + parse catches all syntax errors and is OCCT-free,
    which is exactly what makes validate cheap for the LLM inner loop.
    """
    source = params.get("source", "")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "validate requires params.source: str",
            },
        }

    errors: list[dict] = []
    warnings: list[dict] = []

    try:
        from mcad.lexer import LexError, tokenize
        from mcad.parser import ParseError, Parser

        # Phase 1: lex
        try:
            tokens = tokenize(source)
        except LexError as exc:
            errors.append({"line": exc.line, "col": exc.col, "message": str(exc)})
            return {
                "ok": True,
                "result": {"ok": False, "errors": errors, "warnings": warnings},
            }

        # Phase 2: parse
        try:
            parser = Parser(tokens)
            parser.parse()
        except ParseError as exc:
            tok = exc.token
            if tok is not None:
                errors.append({"line": tok.line, "col": tok.col, "message": str(exc)})
            else:
                errors.append({"line": 0, "col": 0, "message": str(exc)})
            return {
                "ok": True,
                "result": {"ok": False, "errors": errors, "warnings": warnings},
            }

    except Exception as exc:
        return {
            "ok": False,
            "error": {
                "kind": "python",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            },
        }

    return {
        "ok": True,
        "result": {
            "ok": len(errors) == 0,
            "errors": errors,
            "warnings": warnings,
        },
    }


def handle_request(req: dict) -> dict | None:
    """Dispatch a decoded request dict and return a response dict.

    Returns None only for inbound notifications (no id field and no
    expected response). For all recognised requests a dict is returned.

    Args:
        req: Decoded JSON request with at minimum a ``method`` key.

    Returns:
        Response dict with ``id``, ``ok``, and either ``result`` or
        ``error``; or None for pure notifications.
    """
    method: str = req.get("method", "")
    req_id = req.get("id")

    # Inbound notifications have no id and need no response.
    if req_id is None and method not in ("init", "shutdown"):
        return None

    if method == "init":
        return {
            "id": req_id,
            "ok": True,
            "result": {
                "worker_version": WORKER_VERSION,
                "occt_version": _OCCT_VERSION,
            },
        }

    if method == "shutdown":
        # Caller (dispatcher) uses the None sentinel to exit cleanly.
        return None  # dispatcher handles exit

    if method == "validate":
        result = _validate(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "evaluate":
        result = _evaluate(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "list_edges":
        result = _list_edges(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "export":
        result = _export(req.get("params") or {})
        result["id"] = req_id
        return result

    # Remaining geometry stub — filled in by per-tool grandchildren.
    if method == "deviation":
        return _stub_not_implemented(req)

    # Unknown method.
    return {
        "id": req_id,
        "ok": False,
        "error": {
            "kind": "internal",
            "message": f"unknown method: {method!r}",
        },
    }
