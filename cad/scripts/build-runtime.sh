#!/usr/bin/env bash
# Build per-platform PBS Python runtime tar.zst for embedding into the Go binary.
# Per Docs/design/Go-python-bridge-design.md §6 (in the Minerva repo).
#
# TODO(scaffold-round-2): implement per the bridge design doc.
#   1. Download PBS cpython-3.12.x for the current platform.
#   2. Create a venv, pip install build123d + cadquery-ocp into it.
#   3. Copy in worker/mcad/ source.
#   4. Compute SHA-256 manifest.
#   5. Tar+zstd compress to runtime-build/<platform>.tar.zst.

set -euo pipefail

echo "build-runtime.sh: not yet implemented (scaffold round 1)"
exit 1
