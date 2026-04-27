"""Main dispatcher loop for the Go-Python bridge worker.

Startup sequence (per design §5):
  1. Import mcad package.
  2. Import build123d.
  3. Run 1 mm-cube tessellation to confirm OCCT initialised.
  4. Emit `worker.ready` notification.
  5. Loop: read_frame → decode JSON → dispatch → write_frame.

Errors in the loop are caught and returned as structured error responses
so the Go parent can continue rather than restarting. Fatal startup errors
propagate to stderr and cause a non-zero exit.
"""

from __future__ import annotations

import io
import json
import logging
import sys
import traceback

log = logging.getLogger(__name__)

WORKER_VERSION = "0.1.0"


def _get_version(module_name: str) -> str:
    """Return the ``__version__`` string of *module_name* or ``"unknown"``."""
    try:
        import importlib
        mod = importlib.import_module(module_name)
        return getattr(mod, "__version__", "unknown")
    except Exception:
        return "unknown"


def _get_occt_version() -> str:
    """Best-effort OCCT version string."""
    try:
        import OCP  # type: ignore[import]
        return getattr(OCP, "__version__", "unknown")
    except Exception:
        pass
    try:
        import OCC.Core.BRep  # type: ignore[import]
        return "7.x"
    except Exception:
        pass
    return "unknown"


def _cold_start() -> tuple[str, str]:
    """Run the cold-start sequence and return (build123d_version, occt_version).

    Raises on import or tessellation failure — caller should treat this as
    fatal and exit non-zero after logging to stderr.
    """
    log.info("cold start: importing mcad")
    import mcad  # noqa: F401 — imported for side-effects / OCCT init

    log.info("cold start: importing build123d")
    import build123d  # type: ignore[import]
    b123d_version = getattr(build123d, "__version__", "unknown")

    log.info("cold start: running 1mm-cube tessellation smoke test")
    from build123d import Box  # type: ignore[import]
    cube = Box(1, 1, 1)
    # tessellate() is on the underlying OCCT shape; access via .wrapped or
    # call Shape.tessellate directly if available.
    try:
        # build123d Shape exposes tessellate() directly.
        cube.tessellate(0.1)
    except AttributeError:
        # Fallback: use a face's underlying compound.
        list(cube.faces())[0].tessellate(0.1)

    occt_version = _get_occt_version()
    log.info("cold start complete: build123d=%s occt=%s", b123d_version, occt_version)
    return b123d_version, occt_version


def _write_notification(stream: io.RawIOBase, method: str, params: dict) -> None:
    """Write a framed notification (no id) to *stream*."""
    from .framing import write_frame
    body = json.dumps({"method": method, "params": params}).encode("utf-8")
    write_frame(stream, body)


def _write_response(stream: io.RawIOBase, response: dict) -> None:
    """Write a framed response dict to *stream*."""
    from .framing import write_frame
    body = json.dumps(response).encode("utf-8")
    write_frame(stream, body)


def run(stdin: io.RawIOBase, stdout: io.RawIOBase) -> None:
    """Run the worker: cold-start, emit ready, then loop until shutdown.

    Args:
        stdin:  Binary stream to read framed requests from.
        stdout: Binary stream to write framed responses/notifications to.
    """
    from .framing import FramingError, read_frame
    from . import methods

    # --- Cold start ---
    try:
        b123d_version, occt_version = _cold_start()
    except Exception as exc:
        log.critical("cold start failed: %s\n%s", exc, traceback.format_exc())
        sys.exit(1)

    # --- Emit worker.ready ---
    _write_notification(stdout, "worker.ready", {
        "version": WORKER_VERSION,
        "build123d": b123d_version,
        "occt": occt_version,
    })
    log.info("emitted worker.ready; entering request loop")

    # --- Request loop ---
    while True:
        try:
            raw = read_frame(stdin)
        except FramingError as exc:
            log.error("framing error (fatal): %s", exc)
            sys.exit(1)

        try:
            req = json.loads(raw)
        except json.JSONDecodeError as exc:
            log.error("JSON decode error: %s", exc)
            # Can't echo back an id — send a best-effort error and continue.
            _write_response(stdout, {
                "id": None,
                "ok": False,
                "error": {
                    "kind": "internal",
                    "message": f"JSON decode error: {exc}",
                },
            })
            continue

        method: str = req.get("method", "")
        req_id = req.get("id")
        log.info("dispatch: method=%s id=%s", method, req_id)

        # Handle shutdown at the dispatcher level — don't delegate to methods.
        if method == "shutdown":
            log.info("shutdown requested; exiting cleanly")
            _write_response(stdout, {
                "id": req_id,
                "ok": True,
                "result": {},
            })
            sys.exit(0)

        try:
            response = methods.handle_request(req)
        except Exception as exc:
            tb = traceback.format_exc()
            log.error("unhandled exception in handle_request: %s\n%s", exc, tb)
            response = {
                "id": req_id,
                "ok": False,
                "error": {
                    "kind": "python",
                    "message": str(exc),
                    "traceback": tb,
                },
            }

        if response is not None:
            _write_response(stdout, response)
