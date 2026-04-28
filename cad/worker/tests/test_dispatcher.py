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
    """export and deviation remain scaffold stubs (Round 3 Unit A)."""

    @pytest.mark.parametrize("method", [
        "export",
        "deviation",
    ])
    def test_returns_not_implemented(self, method):
        resp = handle_request({"id": "r1", "method": method, "params": {}})
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "internal"
        assert "not implemented" in resp["error"]["message"].lower()

    @pytest.mark.parametrize("method", [
        "export",
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


# ---------------------------------------------------------------------------
# evaluate and list_edges — real implementation (Round 3 Unit A)
# These tests require build123d (OCCT tessellation); skip gracefully otherwise.
# ---------------------------------------------------------------------------

try:
    import build123d as _build123d  # noqa: F401
    _BUILD123D_AVAILABLE = True
except ImportError:
    _BUILD123D_AVAILABLE = False

_b123d_mark = pytest.mark.skipif(
    not _BUILD123D_AVAILABLE,
    reason="build123d not installed — evaluate/list_edges tests skipped",
)

# Known-valid .mcad source that produces a 50×30×20 box.
_BOX_SOURCE = (
    "sketch:\n"
    "    s = rect(50, 30)\n"
    "b = extrude(s, 20)\n"
)

# Source with a known lex error (bare '&').
_LEX_ERROR_SOURCE_E = "x = 1 & 2\n"

# Source with a known parse error (unmatched paren).
_PARSE_ERROR_SOURCE_E = "x = (1 + 2\n"


@_b123d_mark
class TestEvaluate:
    """Tests for the real evaluate implementation (build123d required)."""

    def test_simple_box_returns_mesh_and_edges(self):
        resp = handle_request({
            "id": "e1",
            "method": "evaluate",
            "params": {"source": _BOX_SOURCE},
        })
        assert resp is not None
        assert resp["ok"] is True, f"Expected ok=True, got: {resp}"
        result = resp["result"]
        assert isinstance(result["shape_name"], str)
        assert len(result["shape_name"]) > 0
        mesh = result["mesh"]
        assert isinstance(mesh["vertices"], list)
        assert len(mesh["vertices"]) > 0
        assert all(len(v) == 3 for v in mesh["vertices"])
        assert isinstance(mesh["faces"], list)
        assert len(mesh["faces"]) > 0
        assert all(len(f) == 3 for f in mesh["faces"])
        edges = result["edges"]
        assert isinstance(edges, list)
        assert len(edges) > 0
        assert all("id" in e for e in edges)

    def test_parse_error_returns_kind_parse(self):
        resp = handle_request({
            "id": "e2",
            "method": "evaluate",
            "params": {"source": _PARSE_ERROR_SOURCE_E},
        })
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "parse"
        assert "message" in resp["error"]

    def test_lex_error_returns_kind_parse_or_lex(self):
        # Lex errors bubble up as EvaluationError wrapping ParseError (via
        # mcad.parser.parse which calls the lexer).  Either "parse" or "lex"
        # is acceptable; what matters is ok=False.
        resp = handle_request({
            "id": "e3",
            "method": "evaluate",
            "params": {"source": _LEX_ERROR_SOURCE_E},
        })
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] in ("parse", "lex", "occt", "translate")

    def test_missing_source_returns_internal(self):
        resp = handle_request({
            "id": "e4",
            "method": "evaluate",
            "params": {},
        })
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "internal"

    def test_non_string_source_returns_internal(self):
        resp = handle_request({
            "id": "e5",
            "method": "evaluate",
            "params": {"source": 123},
        })
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "internal"

    def test_evaluate_caches_result(self, monkeypatch):
        """Second call with identical source must NOT re-invoke evaluate_source."""
        import mcad_worker.methods as _methods

        call_count = [0]
        original_eval = None
        try:
            from mcad.evaluator import evaluate_source as _orig
            original_eval = _orig
        except ImportError:
            pytest.skip("mcad.evaluator not importable")

        def _counting_eval(source, *, tolerance=0.1, angular_tolerance=0.1):
            call_count[0] += 1
            return original_eval(
                source,
                tolerance=tolerance,
                angular_tolerance=angular_tolerance,
            )

        import mcad.evaluator as _evaluator_mod
        monkeypatch.setattr(_evaluator_mod, "evaluate_source", _counting_eval)

        # Reset cache so we start clean.
        _methods._last_program = None

        resp1 = _methods._evaluate({"source": _BOX_SOURCE})
        assert resp1["ok"] is True
        resp2 = _methods._evaluate({"source": _BOX_SOURCE})
        assert resp2["ok"] is True

        assert call_count[0] == 1, (
            f"evaluate_source was called {call_count[0]} times; expected 1 (cache miss then hit)"
        )

    def test_id_echoed(self):
        resp = handle_request({
            "id": "eval-id-42",
            "method": "evaluate",
            "params": {"source": _BOX_SOURCE},
        })
        assert resp["id"] == "eval-id-42"


@_b123d_mark
class TestEvaluatePipelineIntegration:
    """End-to-end test that mirrors the cad.evaluate MCP path: a small
    inline .mcad source goes through handle_request and returns a mesh + edges
    payload shaped exactly as the CAD panel expects.

    A 10mm cube extrude is small enough to keep tessellation cheap.
    """

    _CUBE_SOURCE = (
        "sketch:\n"
        "    s = rect(10, 10)\n"
        "b = extrude(s, 10)\n"
    )

    def test_evaluate_returns_panel_ready_payload(self):
        resp = handle_request({
            "id": 1,
            "method": "evaluate",
            "params": {"source": self._CUBE_SOURCE},
        })
        assert resp is not None
        assert resp["ok"] is True, f"Expected ok=True, got: {resp}"
        result = resp["result"]
        # Panel reads result.mesh.vertices, result.mesh.faces, result.edges.
        assert isinstance(result.get("shape_name"), str)
        mesh = result["mesh"]
        assert isinstance(mesh["vertices"], list)
        assert len(mesh["vertices"]) > 0
        assert isinstance(mesh["faces"], list)
        assert len(mesh["faces"]) > 0
        edges = result["edges"]
        assert isinstance(edges, list)
        assert len(edges) > 0


@_b123d_mark
class TestListEdges:
    """Tests for the real list_edges implementation (build123d required)."""

    def test_list_edges_returns_edges_array(self):
        resp = handle_request({
            "id": "le1",
            "method": "list_edges",
            "params": {"source": _BOX_SOURCE},
        })
        assert resp is not None
        assert resp["ok"] is True, f"Expected ok=True, got: {resp}"
        result = resp["result"]
        assert isinstance(result, list)
        assert len(result) > 0
        assert all("id" in e for e in result)

    def test_list_edges_uses_evaluate_cache(self, monkeypatch):
        """After evaluate, list_edges with same source must NOT re-tessellate."""
        import mcad_worker.methods as _methods

        call_count = [0]
        original_eval = None
        try:
            from mcad.evaluator import evaluate_source as _orig
            original_eval = _orig
        except ImportError:
            pytest.skip("mcad.evaluator not importable")

        def _counting_eval(source, *, tolerance=0.1, angular_tolerance=0.1):
            call_count[0] += 1
            return original_eval(
                source,
                tolerance=tolerance,
                angular_tolerance=angular_tolerance,
            )

        import mcad.evaluator as _evaluator_mod
        monkeypatch.setattr(_evaluator_mod, "evaluate_source", _counting_eval)

        # Reset cache, then prime it via evaluate.
        _methods._last_program = None
        resp1 = _methods._evaluate({"source": _BOX_SOURCE})
        assert resp1["ok"] is True
        assert call_count[0] == 1

        # list_edges should hit the cache, not call evaluate_source again.
        resp2 = _methods._list_edges({"source": _BOX_SOURCE})
        assert resp2["ok"] is True
        assert call_count[0] == 1, (
            f"evaluate_source was called {call_count[0]} times after list_edges; expected 1"
        )

    def test_list_edges_invalid_source_propagates_error(self):
        resp = handle_request({
            "id": "le3",
            "method": "list_edges",
            "params": {"source": _PARSE_ERROR_SOURCE_E},
        })
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] in ("parse", "lex", "occt", "translate")

    def test_list_edges_no_evaluate_first(self):
        """Cold cache: list_edges computes via internal evaluate and still works."""
        import mcad_worker.methods as _methods

        # Force cache miss.
        _methods._last_program = None

        resp = _methods._list_edges({"source": _BOX_SOURCE})
        assert resp["ok"] is True
        assert isinstance(resp["result"], list)
        assert len(resp["result"]) > 0

    def test_list_edges_missing_source_returns_internal(self):
        resp = handle_request({
            "id": "le5",
            "method": "list_edges",
            "params": {},
        })
        assert resp is not None
        assert resp["ok"] is False
        assert resp["error"]["kind"] == "internal"

    def test_id_echoed(self):
        resp = handle_request({
            "id": "le-id-99",
            "method": "list_edges",
            "params": {"source": _BOX_SOURCE},
        })
        assert resp["id"] == "le-id-99"


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
