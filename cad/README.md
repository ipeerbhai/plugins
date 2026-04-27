# CAD Plugin for Minerva

## Overview

The CAD plugin brings parametric boundary representation modeling to Minerva via the `.mcad` domain-specific language. A Go MCP shim wraps a Python worker (build123d + OCCT) that evaluates CAD scripts and produces B-Rep geometry. The Godot-based CADPanel provides a 4-view editor and real-time mesh/annotation display.

## Status

Round 1 scaffold: plugin manifest, build stubs, and runtime structure only. No geometry evaluation yet.

## Architecture

- **Go shim** (`internal/bridge/`) — MCP stdio server that launches and supervises the Python worker process
- **Python worker** (`worker/mcad_worker/`) — build123d/OCCT evaluator; parses `.mcad` script, returns B-Rep mesh + metadata
- **Godot UI panel** (`ui/CADPanel.gd`) — 4-view canvas with orbit camera, mesh display, and CAD annotation host
- Full design: see `Docs/design/Go-python-bridge-design.md` in the Minerva repo (§1–9)

## Building

**TODO(scaffold-round-2):**
- Implement `scripts/build-runtime.sh` per bridge design §6 (download PBS cpython, venv, pip install build123d+cadquery-ocp, compress to `runtime-build/<platform>.tar.zst`)
- Implement `scripts/build-runtime.ps1` for Windows parity
- Implement Go shim build in top-level Minerva build flow (reference: `scripts/build-godot-cef.sh`)
- See task `019dc05964a5` for runtime builder spec

## Installing into Minerva

```gdscript
# In AISettings or plugin manager:
var manifest_path := "/abs/path/to/plugins/cad/manifest.json"
PluginDB.install(manifest_path)
```

The plugin will register the "New CAD Document" editor item and load UI panels into the Godot scene tree on first project open.

## License

This plugin is licensed under the terms in `../LICENSE.md` (repository root).
