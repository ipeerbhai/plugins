class_name Cad_CADPanel
extends MinervaPluginPanel
## CAD editor panel — Round 1 scaffold.
##
## Mirrors the lifecycle pattern of Helloscene_HelloPanel (hello_scene plugin):
##   _ready()                    → build annotation substrate
##   _on_panel_loaded(ctx)       → receive context, register host
##   _on_panel_unload()          → deregister host, disconnect signals
##   _on_panel_save_request()    → serialize state (stub for Round 1)
##   _on_panel_load_request(doc) → restore state (stub for Round 1)
##
## Four-viewport 3-D CAD layout (Top / Front / Right / Iso) with a right-side
## annotation sidebar. Real mesh data and IPC wiring are Round 2+.
##
## class_name prefix "Cad" = canonical_prefix("cad")
## per design §6.1: plugin_id.replace("_","").lower() → first-upper.
##
## Off-tree note: this plugin lives at ~/github/plugins/cad/, OUTSIDE Minerva's
## res:// tree, so Godot's class_name parser cache can't see Cad_AnnotationHost.
## We use preload() with a script-relative path (works regardless of res://-or-not)
## and type the field with the Minerva-side base class AnnotationHost (which IS
## class_name-registered) instead of the plugin's own subclass.

const _CadAnnotationHostScript: Script = preload("CadAnnotationHost.gd")

# ── Node references (set in _ready) ────────────────────────────────────────

## SubViewportContainers for the four CAD views.
var _top_view_container: SubViewportContainer = null
var _front_view_container: SubViewportContainer = null
var _right_view_container: SubViewportContainer = null
var _iso_view_container: SubViewportContainer = null

# ── Annotation substrate ────────────────────────────────────────────────────

var _annotation_registry: AnnotationRegistry = null
var _annotation_host: AnnotationHost = null  # actual class is Cad_AnnotationHost; see preload above

## Editor name under which we registered our host with AnnotationHostRegistry.
## Tracked so _on_panel_unload can deregister the same key even if the tab is
## later renamed. Empty string when not registered.
var _registered_editor_name: String = ""

# ── Plugin context ──────────────────────────────────────────────────────────

var _ctx: Dictionary = {}


# ── Godot lifecycle ─────────────────────────────────────────────────────────

func _ready() -> void:
	# Wire node references from the scene tree.
	_top_view_container   = $HSplitContainer/VBoxContainer/GridContainer/TopView
	_front_view_container = $HSplitContainer/VBoxContainer/GridContainer/FrontView
	_right_view_container = $HSplitContainer/VBoxContainer/GridContainer/RightView
	_iso_view_container   = $HSplitContainer/VBoxContainer/GridContainer/IsoView

	# Configure each OrbitCamera to its view preset. Cameras default to
	# "Perspective" in orbit_camera.gd's var declaration; we override here
	# rather than storing private vars in the .tscn (which would cause
	# unknown-property warnings since they are not @export).
	var top_cam: Camera3D =$HSplitContainer/VBoxContainer/GridContainer/TopView/SubViewport/OrbitCamera
	var front_cam: Camera3D =$HSplitContainer/VBoxContainer/GridContainer/FrontView/SubViewport/OrbitCamera
	var right_cam: Camera3D =$HSplitContainer/VBoxContainer/GridContainer/RightView/SubViewport/OrbitCamera
	# IsoView camera stays at "Perspective" default — no call needed.
	if top_cam != null:
		top_cam.set_view_preset("Top")
		top_cam.set_show_helpers(false)
	if front_cam != null:
		front_cam.set_view_preset("Front")
		front_cam.set_show_helpers(false)
	if right_cam != null:
		right_cam.set_view_preset("Right")
		right_cam.set_show_helpers(false)

	# Load a stub cube into every viewport so all four views have visible
	# content on first open. The cube is a 50-unit box centred at the origin.
	# TODO(round-2): replace with actual .mcad IPC data.
	var stub_data := _make_unit_cube_mesh_data(50.0)
	for vp_path in [
		"HSplitContainer/VBoxContainer/GridContainer/TopView/SubViewport/MeshRoot",
		"HSplitContainer/VBoxContainer/GridContainer/FrontView/SubViewport/MeshRoot",
		"HSplitContainer/VBoxContainer/GridContainer/RightView/SubViewport/MeshRoot",
		"HSplitContainer/VBoxContainer/GridContainer/IsoView/SubViewport/MeshRoot",
	]:
		var mesh_root: Node = get_node_or_null(vp_path)
		if mesh_root != null and mesh_root.has_method("update_mesh"):
			mesh_root.call("update_mesh", stub_data)

	# Build annotation substrate.
	_annotation_registry = AnnotationRegistry.new()

	# TODO(scaffold-round-2): call BuiltinKinds.register_all(_annotation_registry)
	# once the annotation substrate autoloads are reachable from this plugin's
	# project context. BuiltinKinds is defined at:
	#   ~/github/Minerva/src/Scripts/Services/Annotations/BuiltinKinds.gd
	# It is a class_name'd script (no autoload), so it will be available
	# after Unit D wires this plugin into the Minerva project.

	_annotation_host = _CadAnnotationHostScript.new()
	_annotation_host._registry = _annotation_registry

	# TODO(scaffold-round-2): create one AnnotationCanvas per viewport,
	# call canvas.set_host(_annotation_host) for each, and store references
	# so _on_panel_unload can call canvas.set_host(null).


# ── Plugin platform lifecycle hooks (override MinervaPluginPanel virtuals) ──

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx

	# Register our live host so MCP annotation queries can answer
	# "what did the user draw?" without requiring a save first.
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name


func _on_panel_unload() -> void:
	# Symmetric teardown for the AnnotationHostRegistry entry.
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""

	# TODO(scaffold-round-2): disconnect toolbar active_tool_changed signal
	# and call canvas.set_host(null) for each of the four canvases.


# ── Save/load contract (overrides MinervaPluginPanel virtuals) ──────────────
# Used for both host_owned file save (Ctrl+S → .mcad sidecar) and
# project-state capture (.minproj entry).

## Capture panel state. Round 1 stub returns an empty versioned dict.
## TODO(scaffold-round-2): include annotation list, four-camera states,
## and any plugin-server-side state needed for round-trip.
func _on_panel_save_request() -> Dictionary:
	# Intended Round-2 payload:
	#   {
	#     "version": 1,
	#     "annotations": _annotation_host.get_annotations(),
	#     "cameras": { "top": {...}, "front": {...}, "right": {...}, "iso": {...} },
	#   }
	return {"version": 1}


## Restore panel state captured by _on_panel_save_request.
## Round 1 stub — no-op.
## TODO(scaffold-round-2): restore annotations and camera states from document.
func _on_panel_load_request(_document: Dictionary) -> void:
	pass


# ── Stub mesh helpers ───────────────────────────────────────────────────────

## Build mesh_data dict for an axis-aligned cube of side `size` centred at
## the origin. Format matches MeshDisplay.update_mesh() expectations:
##   vertices: [[x,y,z], ...]   (8 corners)
##   faces:    [[i,j,k], ...]   (12 triangles, CCW outward winding)
##   color:    [r, g, b]
## Used as a scaffold stub until real .mcad IPC data arrives in Round 2.
func _make_unit_cube_mesh_data(size: float) -> Dictionary:
	var h := size * 0.5
	var verts := [
		# Bottom face (y = -h): 0..3
		[-h, -h, -h], [ h, -h, -h], [ h, -h,  h], [-h, -h,  h],
		# Top face    (y = +h): 4..7
		[-h,  h, -h], [ h,  h, -h], [ h,  h,  h], [-h,  h,  h],
	]
	# 6 faces × 2 triangles each = 12 triangles.
	# Winding: counter-clockwise when viewed from outside.
	var faces := [
		# Bottom  (-Y)
		[0, 2, 1], [0, 3, 2],
		# Top     (+Y)
		[4, 5, 6], [4, 6, 7],
		# Front   (+Z)
		[3, 6, 2], [3, 7, 6],
		# Back    (-Z)
		[0, 1, 5], [0, 5, 4],
		# Right   (+X)
		[1, 2, 6], [1, 6, 5],
		# Left    (-X)
		[0, 4, 7], [0, 7, 3],
	]
	return {
		"vertices": verts,
		"faces":    faces,
		"color":    [0.78, 0.62, 0.12],  # CAD gold
	}


# Note: the cad.collect_export / cad.apply_export channels declared in the
# manifest are server-side concerns handled by the Go MCP shim's tools/call
# dispatch. They do not require panel-side hooks; hello_scene follows the
# same pattern. See the Go shim's internal/tools/ for the export handlers.
