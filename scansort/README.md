# Scansort Plugin

Scansort is a Minerva plugin for document classification. It is a paused migration
from the standalone Godot app at `~/gitlab/ccsandbox/experiments/scansort`.

## Status

T4 skeleton of DCR `019e1cdb451076ae8c344f6e6ec605e1`. Only the `minerva_scansort_probe`
smoke-test tool is implemented. Business logic (document scanning, classification,
result display) migrates in T5+.

## Build

```bash
cd ~/github/plugins/scansort
cargo build --release
cp target/release/scansort-plugin .
```

## Install in Minerva

Manifest path: `~/github/plugins/scansort/manifest.json`

In Minerva, use the Plugin Manager to install from that manifest path, or
run the smoke test:

```
godot --headless --path src --script test/test_scansort_plugin_smoke.gd
```

## Architecture

- `src/main.rs` — Rust JSON-RPC 2.0 MCP server (synchronous stdio transport)
- `ui/ScansortPanel.tscn` + `ui/ScansortPanel.gd` — Godot scene panel (placeholder)
- `manifest.json` — plugin manifest; entrypoint `./scansort-plugin`
