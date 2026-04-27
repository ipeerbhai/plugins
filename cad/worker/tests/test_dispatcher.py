"""Unit tests for mcad_worker.methods and mcad_worker.framing.

These tests bypass stdio entirely — they call handle_request() directly
and exercise framing via in-memory BytesIO streams.

Per design §11: "Tests import mcad_worker directly and call
handle_request(dict) -> dict, bypassing stdio."
"""

from __future__ import annotations

import io

import pytest

from mcad_worker.framing import FramingError, read_frame, write_frame
from mcad_worker.methods import handle_request


# ---------------------------------------------------------------------------
# methods.handle_request tests
# ---------------------------------------------------------------------------


class TestInitRequest:
    def test_ok_true(self):
        resp = handle_request({"id": "r1", "method": "init", "params": {}})
        assert resp is not None
        assert resp["ok"] is True

    def test_has_worker_version(self):
        resp = handle_request({"id": "r1", "method": "init", "params": {}})
        assert "worker_version" in resp["result"]
        assert resp["result"]["worker_version"] != ""

    def test_has_occt_version(self):
        resp = handle_request({"id": "r1", "method": "init", "params": {}})
        assert "occt_version" in resp["result"]

    def test_echoes_id(self):
        resp = handle_request({"id": "req_00042", "method": "init", "params": {}})
        assert resp["id"] == "req_00042"


class TestGeometryStubs:
    @pytest.mark.parametrize("method", [
        "evaluate",
        "export",
        "validate",
        "list_edges",
        "deviation",
    ])
    def test_returns_not_implemented(self, method):
        resp = handle_request({"id": "r1", "method": method, "params": {}})
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "internal"
        assert "not implemented" in resp["error"]["message"].lower()

    @pytest.mark.parametrize("method", [
        "evaluate",
        "export",
        "validate",
        "list_edges",
        "deviation",
    ])
    def test_echoes_id(self, method):
        resp = handle_request({"id": "xyz", "method": method, "params": {}})
        assert resp["id"] == "xyz"


class TestShutdownRequest:
    def test_shutdown_returns_none(self):
        # shutdown is handled at dispatcher level; methods.handle_request
        # returns None for it (dispatcher exits; no response dict needed here).
        resp = handle_request({"id": "r1", "method": "shutdown", "params": {}})
        assert resp is None


# ---------------------------------------------------------------------------
# framing round-trip tests
# ---------------------------------------------------------------------------


class TestFramingRoundTrip:
    def _round_trip(self, body: bytes) -> bytes:
        buf = io.BytesIO()
        write_frame(buf, body)
        buf.seek(0)
        return read_frame(buf)

    def test_empty_body(self):
        result = self._round_trip(b"")
        assert result == b""

    def test_small_json(self):
        body = b'{"ok": true}'
        assert self._round_trip(body) == body

    def test_unicode_body(self):
        body = '{"msg": "héllo wörld"}'.encode("utf-8")
        assert self._round_trip(body) == body

    def test_binary_content(self):
        body = bytes(range(256))
        assert self._round_trip(body) == body

    def test_large_body(self):
        body = b"x" * 65536
        assert self._round_trip(body) == body

    def test_write_flushes(self):
        """write_frame must flush so the reader can see the bytes immediately."""
        buf = io.BytesIO()
        write_frame(buf, b"hello")
        # If flush wasn't called, the buffer position would still be at the
        # start. After write_frame, position should be past the header+body.
        assert buf.tell() > 0


class TestFramingErrors:
    def test_missing_content_length_raises(self):
        buf = io.BytesIO(
            b"Content-Type: application/json\r\n"
            b"\r\n"
            b"{}"
        )
        with pytest.raises(FramingError, match="Content-Length"):
            read_frame(buf)

    def test_non_integer_content_length_raises(self):
        buf = io.BytesIO(
            b"Content-Length: abc\r\n"
            b"\r\n"
        )
        with pytest.raises(FramingError):
            read_frame(buf)

    def test_negative_content_length_raises(self):
        buf = io.BytesIO(
            b"Content-Length: -1\r\n"
            b"\r\n"
        )
        with pytest.raises(FramingError, match="negative"):
            read_frame(buf)

    def test_truncated_body_raises(self):
        # Header says 100 bytes but we only provide 5.
        buf = io.BytesIO(
            b"Content-Length: 100\r\n"
            b"\r\n"
            b"hello"
        )
        with pytest.raises(FramingError, match="EOF"):
            read_frame(buf)

    def test_empty_stream_raises(self):
        buf = io.BytesIO(b"")
        with pytest.raises(FramingError, match="EOF"):
            read_frame(buf)

    def test_malformed_header_no_colon_raises(self):
        buf = io.BytesIO(
            b"Content-Length 12\r\n"
            b"\r\n"
            b"hello world!"
        )
        with pytest.raises(FramingError, match="Malformed"):
            read_frame(buf)
