"""Request handlers for the Go-Python bridge worker.

This module is pure (no I/O) so it can be tested directly without stdio.
Callers pass a decoded request dict and receive a response dict.

Per design §8, only `init` and `shutdown` are real in Round 1 (scaffold).
The five geometry methods return stub errors; they will be filled in by
per-tool grandchildren.
"""

from __future__ import annotations

WORKER_VERSION = "0.1.0"

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

    # Five geometry stubs — filled in by per-tool grandchildren.
    if method in ("evaluate", "export", "validate", "list_edges", "deviation"):
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
