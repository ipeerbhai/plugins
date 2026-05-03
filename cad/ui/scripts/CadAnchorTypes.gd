# CadAnchorTypes.gd — anchor schema constants for the CAD plugin.
# No class_name: off-tree plugin scripts cannot use class_name for cross-script
# type references (see feedback_off_tree_plugin_class_names.md).
# Consumers: preload("scripts/CadAnchorTypes.gd")

## Plugin identifier used in anchor envelopes: { "plugin": PLUGIN, ... }
const PLUGIN: String = "cad"

## Anchor type for a CAD edge: { "plugin": "cad", "type": EDGE_TYPE, "id": N }
const EDGE_TYPE: String = "edge"

## Full anchor key used with register_anchor_resolver / resolve_anchor.
## Format: "<plugin>/<type>" — matches AnnotationHost._anchor_key() output.
const EDGE_ANCHOR_KEY: String = "cad/edge"
