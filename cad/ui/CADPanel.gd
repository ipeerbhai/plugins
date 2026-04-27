class_name Cad_CADPanel
extends MinervaPluginPanel
## CAD editor panel — Round 2 layout integration.
##
## Cycle 2 R2 adopts platform widgets:
##   * ResponsiveContainer wraps the panel content. width_class drives a
##     stack-style swap between WideLayout (4-view + sidebar HSplit) and
##     NarrowLayout (single-view + projection dropdown + tools).
##   * AnnotationToolbar (real platform widget, not the R1 stub) is built at
##     runtime, bound to the registry/host, and rebuilt with the matching
##     presentation_mode whenever width_class changes.
##   * Cad_AnnotationCanvas is overlaid on whichever SubViewportContainer is
##     currently the "active" viewport (Iso in wide mode, the dropdown
##     selection in narrow mode). One canvas, repointed across mode changes.
##
## Off-tree class_name gotcha:
##   This plugin lives at ~/github/plugins/cad/, OUTSIDE Minerva's res:// tree,
##   so Godot's parser cache cannot statically resolve plugin or platform
##   class_names from typed field declarations in this file. Fields whose
##   types are platform classes (ResponsiveContainer, AnnotationToolbar) are
##   typed with the platform BASE class (Container, VBoxContainer) or kept
##   untyped, and assigned via preload(...).new(). Property access and signal
##   subscription works via duck typing.

const _CadAnnotationHostScript: Script = preload("CadAnnotationHost.gd")
const _CadAnnotationCanvasScript: Script = preload("CadAnnotationCanvas.gd")
const _ResponsiveContainerScript: Script = preload("res://Scripts/UI/Controls/responsive_container.gd")
const _AnnotationToolbarScript: Script = preload("res://Scripts/Services/Annotations/AnnotationToolbar.gd")
const _BuiltinKindsScript: Script = preload("res://Scripts/Services/Annotations/BuiltinKinds.gd")

# ── Node references (set in _ready) ────────────────────────────────────────

## ResponsiveContainer wrapping both layouts. Typed Container (base class) so
## the parser doesn't try to resolve ResponsiveContainer from off-tree.
var _responsive: Container = null

## Wide-layout (4-view + sidebar) and narrow-layout (single-view) roots.
var _wide_layout: Control = null
var _narrow_layout: Control = null

## SubViewportContainers for the four CAD views in WIDE layout.
var _top_view_container: SubViewportContainer = null
var _front_view_container: SubViewportContainer = null
var _right_view_container: SubViewportContainer = null
var _iso_view_container: SubViewportContainer = null

## Single SubViewportContainer used in NARROW layout. Its OrbitCamera's preset
## is updated by the projection dropdown.
## Camera typed as Camera3D (base) — OrbitCamera class_name is plugin-local and
## not resolvable from off-tree. set_view_preset() called via duck typing.
var _single_view_container: SubViewportContainer = null
var _single_view_camera: Camera3D = null

## Projection dropdown used to switch the single-view camera preset.
var _projection_dropdown: OptionButton = null

## Wide-layout sidebar (where the toolbar is parented in wide mode).
var _wide_sidebar: VBoxContainer = null

## AnnotationToolbar instance — built at runtime; reparented across mode
## changes. Untyped because off-tree scripts can't type fields as
## AnnotationToolbar.
var _toolbar = null

## Cad_AnnotationCanvas instance — single canvas, overlaid on the active
## viewport's SubViewportContainer. Untyped for the same reason.
var _canvas = null

## Currently active viewport id, one of: "top","front","right","iso" (wide mode)
## or "perspective","top","bottom","front","back","left","right" (narrow mode).
## In wide mode the canvas is overlaid on the Iso quadrant by default.
var _active_viewport_id: String = "iso"

# ── Annotation substrate ────────────────────────────────────────────────────

var _annotation_registry: AnnotationRegistry = null
var _annotation_host: AnnotationHost = null  # actual class is Cad_AnnotationHost

## Editor name under which we registered our host with AnnotationHostRegistry.
var _registered_editor_name: String = ""

# ── Plugin context ──────────────────────────────────────────────────────────

var _ctx: Dictionary = {}

## Projection dropdown options (id → preset string accepted by orbit_camera).
const _PROJECTION_OPTIONS: Array = [
	{"id": 0, "label": "Perspective", "preset": "Perspective"},
	{"id": 1, "label": "Top",         "preset": "Top"},
	{"id": 2, "label": "Bottom",      "preset": "Bottom"},
	{"id": 3, "label": "Front",       "preset": "Front"},
	{"id": 4, "label": "Back",        "preset": "Back"},
	{"id": 5, "label": "Left",        "preset": "Left"},
	{"id": 6, "label": "Right",       "preset": "Right"},
]


# ── Godot lifecycle ─────────────────────────────────────────────────────────

func _ready() -> void:
	# ── Wire layout container references ───────────────────────────────────
	_responsive = $ResponsiveContainer as Container
	_wide_layout = $ResponsiveContainer/WideLayout as Control
	_narrow_layout = $ResponsiveContainer/NarrowLayout as Control
	_wide_sidebar = $ResponsiveContainer/WideLayout/WideSidebar as VBoxContainer

	# ── Wide-layout viewport containers ────────────────────────────────────
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	_top_view_container   = get_node(grid + "/TopView")   as SubViewportContainer
	_front_view_container = get_node(grid + "/FrontView") as SubViewportContainer
	_right_view_container = get_node(grid + "/RightView") as SubViewportContainer
	_iso_view_container   = get_node(grid + "/IsoView")   as SubViewportContainer

	# Configure each OrbitCamera to its view preset (wide mode).
	var top_cam: Camera3D   = get_node(grid + "/TopView/SubViewport/OrbitCamera")
	var front_cam: Camera3D = get_node(grid + "/FrontView/SubViewport/OrbitCamera")
	var right_cam: Camera3D = get_node(grid + "/RightView/SubViewport/OrbitCamera")
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

	# ── Narrow-layout single viewport ──────────────────────────────────────
	_single_view_container = $ResponsiveContainer/NarrowLayout/SingleView as SubViewportContainer
	_single_view_camera = $ResponsiveContainer/NarrowLayout/SingleView/SubViewport/OrbitCamera as Camera3D

	# ── Projection dropdown ────────────────────────────────────────────────
	_projection_dropdown = $ResponsiveContainer/NarrowLayout/ProjectionRow/ProjectionDropdown as OptionButton
	_projection_dropdown.clear()
	for opt in _PROJECTION_OPTIONS:
		_projection_dropdown.add_item(opt["label"], opt["id"])
	_projection_dropdown.select(0)  # Perspective by default
	_projection_dropdown.item_selected.connect(_on_projection_selected)

	# ── Stub mesh: load into every MeshRoot (4 wide + 1 narrow) ────────────
	var stub_data := _make_unit_cube_mesh_data(50.0)
	var mesh_paths: Array = [
		grid + "/TopView/SubViewport/MeshRoot",
		grid + "/FrontView/SubViewport/MeshRoot",
		grid + "/RightView/SubViewport/MeshRoot",
		grid + "/IsoView/SubViewport/MeshRoot",
		"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot",
	]
	for vp_path in mesh_paths:
		var mesh_root: Node = get_node_or_null(vp_path)
		if mesh_root != null and mesh_root.has_method("update_mesh"):
			mesh_root.call("update_mesh", stub_data)

	# ── Annotation substrate ───────────────────────────────────────────────
	_annotation_registry = AnnotationRegistry.new()
	# Register built-in 2D kinds (arrow, text, region, polyline, highlight,
	# measure_distance, measure_angle, measure_radius). CAD-specific 3-D kinds
	# are a later grandchild (`019dd017d9df`).
	_BuiltinKindsScript.register_all(_annotation_registry)

	_annotation_host = _CadAnnotationHostScript.new()
	_annotation_host._registry = _annotation_registry

	# ── Register SubViewports with the host so render_content_to_image can
	# capture the correct pane for AI vision composites. The mapping is
	# layout-dependent (wide vs narrow share the "top"/"front"/"right" ids,
	# but they refer to different SubViewports). _register_host_viewports()
	# is re-called on every width-class transition so the active map always
	# matches the visible layout.
	_register_host_viewports(false)  # wide by default; corrected below in _apply_width_class

	# ── Build AnnotationToolbar (parented in the wide sidebar by default) ──
	_toolbar = _AnnotationToolbarScript.new()
	_toolbar.name = "AnnotationToolbar"
	_wide_sidebar.add_child(_toolbar)
	_toolbar.set_registry(_annotation_registry)
	_toolbar.set_host(_annotation_host)
	_toolbar.active_tool_changed.connect(_on_toolbar_active_tool_changed)

	# ── Build single AnnotationCanvas, overlay on Iso (wide default) ───────
	_canvas = _CadAnnotationCanvasScript.new()
	_canvas.name = "AnnotationCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.set_host(_annotation_host)
	# Initial parent = Iso quadrant in wide mode. _on_width_class_changed will
	# move it to the single-view in narrow mode.
	_iso_view_container.add_child(_canvas)
	_annotation_host.set_active_viewport(_active_viewport_id)

	# ── Connect ResponsiveContainer width-class signal & apply initial mode
	_responsive.width_class_changed.connect(_on_width_class_changed)
	# Apply the initial layout state so toolbar/canvas are correctly placed
	# even before the first resize transition fires.
	_apply_width_class(_responsive.width_class)


# ── Plugin platform lifecycle hooks (override MinervaPluginPanel virtuals) ──

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx

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

	# Disconnect toolbar signal and detach canvas from host.
	if _toolbar != null and _toolbar.active_tool_changed.is_connected(_on_toolbar_active_tool_changed):
		_toolbar.active_tool_changed.disconnect(_on_toolbar_active_tool_changed)
	if _canvas != null:
		_canvas.set_host(null)
		_canvas.set_active_tool(null)


# ── Save/load contract (overrides MinervaPluginPanel virtuals) ──────────────

func _on_panel_save_request() -> Dictionary:
	# TODO(later): include annotations + camera states.
	return {"version": 1}


func _on_panel_load_request(_document: Dictionary) -> void:
	pass


# ── Width-class handling ────────────────────────────────────────────────────

## Called whenever the ResponsiveContainer crosses a breakpoint.
func _on_width_class_changed(new_class: StringName) -> void:
	_apply_width_class(new_class)


## Apply the layout for the given width class. Idempotent.
##   xs / sm  → narrow (single view + projection dropdown), toolbar = COMPACT
##   md / lg / xl → wide (4-view + sidebar), toolbar = LABELED
func _apply_width_class(cls: StringName) -> void:
	var is_narrow := (cls == _ResponsiveContainerScript.CLASS_XS or cls == _ResponsiveContainerScript.CLASS_SM)

	if _wide_layout != null:
		_wide_layout.visible = not is_narrow
	if _narrow_layout != null:
		_narrow_layout.visible = is_narrow

	# Reparent toolbar into the appropriate layout's tools area.
	if _toolbar != null:
		_reparent_toolbar(is_narrow)
		# Set presentation_mode AFTER reparent so the rebuild lays out under
		# the new parent. Use the platform enum constants by name on the
		# toolbar instance (off-tree consumers can't reference the enum from
		# the type itself, but enum values on the instance are fine).
		# COMPACT = 1, LABELED = 0 per AnnotationToolbar.PresentationMode.
		var compact: int = 1
		var labeled: int = 0
		_toolbar.set_presentation_mode(compact if is_narrow else labeled)

	# Reparent the canvas to the appropriate viewport container.
	_reparent_canvas(is_narrow)

	# Re-register SubViewports with the host so render_content_to_image
	# captures the visible layout's panes (the "top"/"front"/"right" ids
	# overlap between layouts but resolve to different SubViewports).
	_register_host_viewports(is_narrow)


## Populate Cad_AnnotationHost's viewport map for the active layout. Called
## from _ready() (initial state) and _apply_width_class() (transitions).
func _register_host_viewports(is_narrow: bool) -> void:
	if _annotation_host == null:
		return
	if is_narrow:
		var single_vp: SubViewport = _single_view_container.get_node("SubViewport") as SubViewport
		# In narrow mode every projection id (incl. "iso") resolves to the
		# single SubViewport whose camera preset the dropdown drives.
		for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
			_annotation_host.set_viewport_for(proj, single_vp)
	else:
		var iso_vp: SubViewport   = _iso_view_container.get_node("SubViewport") as SubViewport
		var top_vp: SubViewport   = _top_view_container.get_node("SubViewport") as SubViewport
		var front_vp: SubViewport = _front_view_container.get_node("SubViewport") as SubViewport
		var right_vp: SubViewport = _right_view_container.get_node("SubViewport") as SubViewport
		_annotation_host.set_viewport_for("iso", iso_vp)
		_annotation_host.set_viewport_for("top", top_vp)
		_annotation_host.set_viewport_for("front", front_vp)
		_annotation_host.set_viewport_for("right", right_vp)
		# Narrow-only ids unset in wide mode (they'd be unreachable anyway).
		for proj in ["perspective", "bottom", "back", "left"]:
			_annotation_host.set_viewport_for(proj, null)


## Move the toolbar between the wide sidebar and the narrow VBox.
func _reparent_toolbar(narrow: bool) -> void:
	if _toolbar == null:
		return
	var current_parent: Node = _toolbar.get_parent()
	var target_parent: Node = _narrow_layout if narrow else _wide_sidebar
	if current_parent == target_parent:
		return
	if current_parent != null:
		current_parent.remove_child(_toolbar)
	target_parent.add_child(_toolbar)


## Move the AnnotationCanvas overlay between the active wide quadrant (Iso) and
## the narrow single-view container.
func _reparent_canvas(narrow: bool) -> void:
	if _canvas == null:
		return
	var current_parent: Node = _canvas.get_parent()
	var target_parent: Node
	if narrow:
		target_parent = _single_view_container
		_active_viewport_id = _projection_preset_to_viewport_id(_current_projection_preset())
	else:
		target_parent = _iso_view_container
		_active_viewport_id = "iso"
	if current_parent != target_parent:
		if current_parent != null:
			current_parent.remove_child(_canvas)
		target_parent.add_child(_canvas)
		_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	if _annotation_host != null and _annotation_host.has_method("set_active_viewport"):
		_annotation_host.set_active_viewport(_active_viewport_id)


# ── Projection dropdown handling (narrow mode) ──────────────────────────────

## Called when the user picks an item from the narrow-layout projection
## dropdown. Updates the single-view camera preset.
func _on_projection_selected(index: int) -> void:
	if _single_view_camera == null:
		return
	var preset: String = "Perspective"
	if index >= 0 and index < _PROJECTION_OPTIONS.size():
		preset = String(_PROJECTION_OPTIONS[index]["preset"])
	_single_view_camera.set_view_preset(preset)
	# Update the host's active viewport id so MCP queries get the right context.
	_active_viewport_id = _projection_preset_to_viewport_id(preset)
	if _annotation_host != null and _annotation_host.has_method("set_active_viewport"):
		_annotation_host.set_active_viewport(_active_viewport_id)


## Return the preset string ("Perspective", "Top", ...) currently selected in
## the dropdown. Defaults to "Perspective" if the dropdown is missing/unset.
func _current_projection_preset() -> String:
	if _projection_dropdown == null:
		return "Perspective"
	var idx: int = _projection_dropdown.selected
	if idx < 0 or idx >= _PROJECTION_OPTIONS.size():
		return "Perspective"
	return String(_PROJECTION_OPTIONS[idx]["preset"])


## Map an orbit-camera preset string to the lower-case viewport-id used by
## Cad_AnnotationHost.get_view_context().
func _projection_preset_to_viewport_id(preset: String) -> String:
	return preset.to_lower()


# ── Toolbar → canvas plumbing ──────────────────────────────────────────────

## Called when the AnnotationToolbar emits active_tool_changed. Forwards the
## new tool to the canvas so it can route pointer events / draw previews.
func _on_toolbar_active_tool_changed(tool: AnnotationAuthorTool) -> void:
	if _canvas != null:
		_canvas.set_active_tool(tool)


# ── Stub mesh helpers ───────────────────────────────────────────────────────

## Build mesh_data dict for an axis-aligned cube of side `size` centred at the
## origin. Format matches MeshDisplay.update_mesh() expectations.
func _make_unit_cube_mesh_data(size: float) -> Dictionary:
	var h := size * 0.5
	var verts := [
		[-h, -h, -h], [ h, -h, -h], [ h, -h,  h], [-h, -h,  h],
		[-h,  h, -h], [ h,  h, -h], [ h,  h,  h], [-h,  h,  h],
	]
	var faces := [
		[0, 2, 1], [0, 3, 2],
		[4, 5, 6], [4, 6, 7],
		[3, 6, 2], [3, 7, 6],
		[0, 1, 5], [0, 5, 4],
		[1, 2, 6], [1, 6, 5],
		[0, 4, 7], [0, 7, 3],
	]
	return {
		"vertices": verts,
		"faces":    faces,
		"color":    [0.78, 0.62, 0.12],
	}
