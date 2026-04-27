"""End-to-end smoke test for the mcad_worker subprocess.

Skipped gracefully if build123d is not installed — Round 1 dev environments
may not have it; CI/release builds will.

Test sequence (per design §5):
  1. Spawn `python -m mcad_worker`.
  2. Write a framed `init` request.
  3. Read the framed `worker.ready` notification.
  4. Read the framed `init` response.
  5. Write a framed `shutdown` request.
  6. Wait for the process to exit cleanly (code 0).
"""

from __future__ import annotations

import io
import json
import subprocess
import sys

import pytest

# ---------------------------------------------------------------------------
# Skip guard — if build123d is missing this entire module is skipped.
# ---------------------------------------------------------------------------

try:
    import build123d  # type: ignore[import]  # noqa: F401
except ImportError:
    pytest.skip(
        "build123d not installed — smoke test skipped in this environment",
        allow_module_level=True,
    )

from mcad_worker.framing import read_frame, write_frame


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


TIMEOUT_SECONDS = 30  # generous cold-start budget (design says 5 s typical / 15 s hard)


def _make_frame(obj: dict) -> bytes:
    """Serialize *obj* to a framed bytes object (header + body)."""
    buf = io.BytesIO()
    write_frame(buf, json.dumps(obj).encode("utf-8"))
    return buf.getvalue()


def _read_one(proc: subprocess.Popen) -> dict:
    """Read one framed message from the worker's stdout."""
    return json.loads(read_frame(proc.stdout))  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------


def test_worker_lifecycle():
    """Full cold-start → init → worker.ready → shutdown round-trip."""
    proc = subprocess.Popen(
        [sys.executable, "-m", "mcad_worker"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        # 1. Send `init` request.
        init_req = _make_frame({
            "id": "req_00001",
            "method": "init",
            "params": {},
            "deadline_ms": 15000,
        })
        proc.stdin.write(init_req)  # type: ignore[union-attr]
        proc.stdin.flush()          # type: ignore[union-attr]

        # 2. Read `worker.ready` notification (arrives before the init response).
        ready_msg = _read_one(proc)
        assert ready_msg.get("method") == "worker.ready", (
            f"Expected worker.ready notification, got: {ready_msg!r}"
        )
        assert "version" in ready_msg["params"]
        assert "build123d" in ready_msg["params"]
        assert "occt" in ready_msg["params"]

        # 3. Read `init` response.
        init_resp = _read_one(proc)
        assert init_resp.get("id") == "req_00001"
        assert init_resp.get("ok") is True
        assert "worker_version" in init_resp["result"]
        assert "occt_version" in init_resp["result"]

        # 4. Send `shutdown` request.
        shutdown_req = _make_frame({
            "id": "req_00002",
            "method": "shutdown",
            "params": {},
            "deadline_ms": 5000,
        })
        proc.stdin.write(shutdown_req)  # type: ignore[union-attr]
        proc.stdin.flush()              # type: ignore[union-attr]

        # 5. Read shutdown response (worker sends ok before exiting).
        shutdown_resp = _read_one(proc)
        assert shutdown_resp.get("id") == "req_00002"
        assert shutdown_resp.get("ok") is True

        # 6. Wait for clean exit.
        proc.stdin.close()  # type: ignore[union-attr]
        exit_code = proc.wait(timeout=TIMEOUT_SECONDS)
        assert exit_code == 0, (
            f"Worker exited with code {exit_code}; "
            f"stderr: {proc.stderr.read().decode(errors='replace')}"  # type: ignore[union-attr]
        )

    except Exception:
        proc.kill()
        proc.wait()
        raise
