# plugins

A repo of plugins for [Minerva](https://github.com/ipeerbhai/Minerva) and other agentic platforms that speak the same plugin manifest contract.

## Layout

Each plugin lives in its own top-level directory containing a `manifest.json` and whatever code/assets the plugin needs.

```
plugins/
├── LICENSE.md
├── README.md
└── <plugin_id>/
    ├── manifest.json
    └── ...
```

## Installing a plugin into Minerva

Minerva discovers plugins by manifest path — no in-tree presence required:

```gdscript
PluginDB.install("/absolute/path/to/plugins/<plugin_id>/manifest.json")
```

The plugin's `data_directory` is derived from the manifest's parent directory.

## Plugins

_None yet — this repo is freshly initialized._

| Plugin | Status | Description |
| --- | --- | --- |
| `cad` | planned | Parametric B-Rep CAD via the `.mcad` DSL. Go MCP shim + Python (build123d/OCCT) worker; 4-view CADEditor panel. Tracking: Minerva DCR `019dc054a4`. |

## License

See [LICENSE.md](LICENSE.md).
