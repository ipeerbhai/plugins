"""Entrypoint for `python -m mcad_worker`.

Wires stdin.buffer / stdout.buffer into the dispatcher loop.
All logging goes to stderr only — stdout is exclusively framed JSON.
"""

import logging
import sys

# Stderr-only logging — stdout is framed protocol bytes.
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="[mcad_worker] %(levelname)s %(message)s",
)

# Ensure stdout is in raw binary mode with no extra buffering layer.
# Python may add a TextIOWrapper on stdout; we want the underlying buffer.
# If reconfigure is available (Python 3.7+), disable line-buffering so we
# control flushing explicitly (write_frame always flushes after each frame).
try:
    sys.stdout.reconfigure(line_buffering=False)
except AttributeError:
    pass

from .dispatcher import run  # noqa: E402

run(sys.stdin.buffer, sys.stdout.buffer)
