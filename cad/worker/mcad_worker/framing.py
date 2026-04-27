"""LSP-style length-prefixed framing for the Go-Python bridge.

Frame format (per design §3):
    Content-Length: NNNN\r\n
    Content-Type: application/json; charset=utf-8\r\n
    \r\n
    <NNNN bytes of body>

Only Content-Length is mandatory; Content-Type is included on write and
accepted-but-ignored on read. Any other header is silently skipped.
On parse failure a FramingError is raised — the caller should treat this
as a fatal protocol error and exit cleanly.
"""

from __future__ import annotations

import io


class FramingError(Exception):
    """Raised when the framing layer encounters a malformed header or EOF."""


def read_frame(stream: io.RawIOBase) -> bytes:
    """Read one framed message from *stream* and return the raw body bytes.

    Raises:
        FramingError: if headers are malformed, Content-Length is missing,
                      or the stream closes before delivering the full body.
    """
    headers: dict[str, str] = {}

    # Read header lines until the blank separator line.
    while True:
        line_bytes = _read_line(stream)
        if line_bytes is None:
            raise FramingError("Unexpected EOF while reading headers")
        line = line_bytes.decode("ascii").rstrip("\r\n")
        if line == "":
            # Blank line — end of headers.
            break
        if ":" not in line:
            raise FramingError(f"Malformed header line (no colon): {line!r}")
        key, _, value = line.partition(":")
        headers[key.strip().lower()] = value.strip()

    if "content-length" not in headers:
        raise FramingError("Missing Content-Length header")

    try:
        length = int(headers["content-length"])
    except ValueError:
        raise FramingError(
            f"Content-Length is not an integer: {headers['content-length']!r}"
        )

    if length < 0:
        raise FramingError(f"Content-Length is negative: {length}")

    # Read the exact body.
    body = _read_exactly(stream, length)
    if body is None or len(body) < length:
        raise FramingError(
            f"Unexpected EOF: expected {length} bytes, got {len(body) if body else 0}"
        )
    return body


def write_frame(stream: io.RawIOBase, body: bytes) -> None:
    """Write *body* as a framed message to *stream* and flush.

    Args:
        stream: A writable binary stream (e.g. sys.stdout.buffer).
        body:   Raw UTF-8 JSON bytes to send.
    """
    header = (
        f"Content-Length: {len(body)}\r\n"
        f"Content-Type: application/json; charset=utf-8\r\n"
        f"\r\n"
    ).encode("ascii")
    stream.write(header + body)
    stream.flush()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _read_line(stream: io.RawIOBase) -> bytes | None:
    """Read one CRLF- or LF-terminated line from *stream*.

    Returns None on immediate EOF (before any bytes of the line are read).
    The terminator is included in the returned bytes.
    """
    buf = bytearray()
    while True:
        ch = stream.read(1)
        if not ch:
            return None if not buf else bytes(buf)
        buf += ch
        if ch == b"\n":
            return bytes(buf)


def _read_exactly(stream: io.RawIOBase, n: int) -> bytes | None:
    """Read exactly *n* bytes from *stream*.

    Returns the bytes read (may be fewer than *n* on EOF) or None if n == 0.
    """
    if n == 0:
        return b""
    chunks: list[bytes] = []
    remaining = n
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)
