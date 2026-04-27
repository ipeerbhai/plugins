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
        "list_edges",
        "deviation",
    ])
    def test_echoes_id(self, method):
        resp = handle_request({"id": "xyz", "method": method, "params": {}})
        assert resp["id"] == "xyz"


# ---------------------------------------------------------------------------
# validate — real implementation (Round 2 Unit A)
# ---------------------------------------------------------------------------

# Minimal valid .mcad source: a single variable assignment.
_VALID_SOURCE = "height = 100\n"

# A slightly richer but still valid source with sketch + extrude syntax.
_VALID_SOURCE_SKETCH = (
    "sketch:\n"
    "    s = rect(50, 30)\n"
    "b = extrude(s, 20)\n"
)

# Source with a known lex error: bare '&' (should be '&&').
_LEX_ERROR_SOURCE = "x = 1 & 2\n"

# Source with a known parse error: 'else:' without a matching 'if:'.
_PARSE_ERROR_SOURCE = "else:\n    x = 1\n"

# Source with an unmatched paren (parse error).
_UNMATCHED_PAREN_SOURCE = "x = (1 + 2\n"


class TestValidate:
    """Tests for the real validate implementation."""

    # -- Response shape -------------------------------------------------------

    def test_valid_source_ok_true(self):
        resp = handle_request({"id": "r1", "method": "validate",
                               "params": {"source": _VALID_SOURCE}})
        assert resp is not None
        assert resp["ok"] is True
        assert resp["result"]["ok"] is True
        assert resp["result"]["errors"] == []
        assert resp["result"]["warnings"] == []

    def test_valid_source_sketch_ok_true(self):
        resp = handle_request({"id": "r2", "method": "validate",
                               "params": {"source": _VALID_SOURCE_SKETCH}})
        assert resp is not None
        assert resp["ok"] is True
        assert resp["result"]["ok"] is True
        assert resp["result"]["errors"] == []

    def test_id_echoed(self):
        resp = handle_request({"id": "validate-42", "method": "validate",
                               "params": {"source": _VALID_SOURCE}})
        assert resp["id"] == "validate-42"

    # -- Parse / lex errors are data, not bridge errors -----------------------

    def test_lex_error_is_data_not_bridge_error(self):
        resp = handle_request({"id": "r3", "method": "validate",
                               "params": {"source": _LEX_ERROR_SOURCE}})
        # Bridge-level ok must be True (request succeeded)
        assert resp["ok"] is True
        # Inner result ok is False because of the error
        assert resp["result"]["ok"] is False
        assert len(resp["result"]["errors"]) >= 1

    def test_lex_error_has_line_col_message(self):
        resp = handle_request({"id": "r4", "method": "validate",
                               "params": {"source": _LEX_ERROR_SOURCE}})
        err = resp["result"]["errors"][0]
        assert "line" in err
        assert "col" in err
        assert "message" in err
        assert isinstance(err["line"], int)
        assert isinstance(err["col"], int)
        assert isinstance(err["message"], str)
        assert err["line"] >= 1  # lex error is on line 1

    def test_parse_error_is_data_not_bridge_error(self):
        resp = handle_request({"id": "r5", "method": "validate",
                               "params": {"source": _PARSE_ERROR_SOURCE}})
        assert resp["ok"] is True
        assert resp["result"]["ok"] is False
        assert len(resp["result"]["errors"]) >= 1

    def test_parse_error_has_line_col_message(self):
        resp = handle_request({"id": "r6", "method": "validate",
                               "params": {"source": _PARSE_ERROR_SOURCE}})
        err = resp["result"]["errors"][0]
        assert "line" in err
        assert "col" in err
        assert "message" in err

    def test_unmatched_paren_parse_error(self):
        resp = handle_request({"id": "r7", "method": "validate",
                               "params": {"source": _UNMATCHED_PAREN_SOURCE}})
        assert resp["ok"] is True
        assert resp["result"]["ok"] is False
        assert len(resp["result"]["errors"]) >= 1

    # -- Non-string source is an internal (bridge-level) error ----------------

    def test_non_string_source_is_internal_error(self):
        resp = handle_request({"id": "r8", "method": "validate",
                               "params": {"source": 42}})
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "internal"

    def test_missing_source_key_treats_as_empty_string(self):
        # Missing key → params.get("source", "") → "" → valid empty program
        resp = handle_request({"id": "r9", "method": "validate",
                               "params": {}})
        assert resp is not None
        assert resp["ok"] is True
        assert resp["result"]["ok"] is True

    # -- Empty source ---------------------------------------------------------

    def test_empty_string_source_is_valid(self):
        resp = handle_request({"id": "r10", "method": "validate",
                               "params": {"source": ""}})
        assert resp["ok"] is True
        assert resp["result"]["ok"] is True
        assert resp["result"]["errors"] == []


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
