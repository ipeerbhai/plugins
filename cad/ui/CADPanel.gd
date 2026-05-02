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
const _ResponsiveContainerScript: Script = preload("res://Scripts/UI/Controls/responsive_container.gd")
const _AnnotationToolbarScript: Script = preload("res://Scripts/Services/Annotations/AnnotationToolbar.gd")
const _BuiltinKindsScript: Script = preload("res://Scripts/Services/Annotations/BuiltinKinds.gd")
const _CadEdgeNumberKindScript: Script = preload("kinds/cad_edge_number_kind.gd")

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

## Currently active viewport id, one of: "top","front","right","iso" (wide mode)
## or "perspective","top","bottom","front","back","left","right" (narrow mode).
## In wide mode the canvas is overlaid on the Iso quadrant by default.
var _active_viewport_id: String = "iso"

## Full-rect overlay Control that spans all 4 SubViewportContainers.
## mouse_filter=IGNORE so all clicks pass through to SubViewports.
## Used as panel_root reference so host.get_panes() can compute panel-relative rects.
var _canvas_overlay: Control = null

# ── Annotation substrate ────────────────────────────────────────────────────

var _annotation_registry: AnnotationRegistry = null
var _annotation_host: AnnotationHost = null  # actual class is Cad_AnnotationHost

## Editor name under which we registered our host with AnnotationHostRegistry.
var _registered_editor_name: String = ""

# ── Plugin context ──────────────────────────────────────────────────────────

var _ctx: Dictionary = {}

# ── Edge enumeration / overlay state ────────────────────────────────────────

## Per-pane Cad_GeometryOverlay refs. Map view_id (str) → Control.
var _geometry_overlays: Dictionary = {}

## Last-known edge registry (Array of edge dicts). Built either from the IPC
## mcad_list_edges reply or synthesised from the stub cube in _ready().
var _edge_registry: Array = []

## Last-known mesh data (passed to EdgeOverlay so it can rebuild silhouettes
## on camera moves).
var _last_mesh_data: Dictionary = {}

## Currently selected edge id (mirrored to host + Tree). -1 = none.
var _selected_edge_id: int = -1

## Tree node in the wide sidebar listing all edges. Built in _ready().
var _edge_tree: Tree = null

## Map edge_id → TreeItem so we can sync selection both directions.
var _edge_tree_items: Dictionary = {}

## Re-entrancy guard for tree → panel selection routing.
var _suppress_tree_selection: bool = false

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

	# Mesh is intentionally empty until a .mcad source is evaluated by the
	# worker and pushed in via the future DSL→mesh bridge. Showing a stub
	# cube here was misleading because it implied the panel had geometry
	# without DSL backing it; the empty state is the honest state.

	# ── Annotation substrate ───────────────────────────────────────────────
	_annotation_registry = AnnotationRegistry.new()
	# Register built-in 2D kinds (arrow, text, region, polyline, highlight,
	# measure_distance, measure_angle, measure_radius). CAD-specific 3-D kinds
	# are a later grandchild (`019dd017d9df`).
	_BuiltinKindsScript.register_all(_annotation_registry)
	# Register cad_edge_number: numbered callout bubbles for LLM/user edge disambiguation.
	_annotation_registry.register_annotation_kind(_CadEdgeNumberKindScript.new())

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
	# ── Build panel-root overlay Control spanning all SubViewportContainers ──
	# Used as the panel_root reference so host.get_panes() can compute
	# panel-relative rects for multi-pane annotation projection. The platform's
	# PlatformAnnotationOverlay (auto-mounted via get_annotation_host()) handles
	# all annotation drawing; this Control is purely a coordinate anchor.
	_canvas_overlay = Control.new()
	_canvas_overlay.name = "AnnotationCanvasOverlay"
	_canvas_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas_overlay.z_index = 1
	add_child(_canvas_overlay)

	if _annotation_host.has_method("set_panel_root"):
		_annotation_host.set_panel_root(_canvas_overlay)
	_annotation_host.set_active_viewport(_active_viewport_id)

	# ── Geometry overlay wiring (one Cad_GeometryOverlay per SubViewport) ────
	# Resolve and store refs to all five EdgeOverlayRoot Control nodes that
	# already live in the .tscn under each SubViewport.
	_geometry_overlays["top"]   = get_node_or_null(grid + "/TopView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["front"] = get_node_or_null(grid + "/FrontView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["right"] = get_node_or_null(grid + "/RightView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["iso"]   = get_node_or_null(grid + "/IsoView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["single"] = get_node_or_null(
		"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/EdgeOverlayRoot")

	# ── Wide-mode sidebar: edge Tree + Prev/Next/Clear buttons ─────────────
	_build_edge_sidebar()
	_render_edge_tree(_edge_registry)

	# ── Connect ResponsiveContainer width-class signal & apply initial mode
	_responsive.width_class_changed.connect(_on_width_class_changed)
	# Apply the initial layout state so toolbar/canvas are correctly placed
	# even before the first resize transition fires.
	_apply_width_class(_responsive.width_class)


func get_annotation_host() -> RefCounted:
	return _annotation_host


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


# ── Save/load contract (overrides MinervaPluginPanel virtuals) ──────────────

func _on_panel_save_request() -> Dictionary:
	# TODO(later): include annotations + camera states.
	return {"version": 1}


func _on_panel_load_request(document: Dictionary) -> void:
	# Round 3: live `.mcad` → CAD panel pipeline. The host loads the file path
	# from the editor; we read the DSL text off disk and round-trip it through
	# the worker's `evaluate` method. The reply carries {shape_name, mesh, edges}
	# which we push to all 5 MeshDisplay instances + the edge overlays + the
	# sidebar Tree.
	var file_path: String = str(document.get("file_path", ""))
	if file_path.is_empty():
		return

	var fa := FileAccess.open(file_path, FileAccess.READ)
	if fa == null:
		push_warning(
			"[CADPanel] _on_panel_load_request: cannot open '%s' (err=%d)"
			% [file_path, FileAccess.get_open_error()]
		)
		return
	var dsl_text: String = fa.get_as_text()
	fa.close()

	# Push document source into host so MCP can read it without IPC.
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(file_path, dsl_text)

	_evaluate_and_render(dsl_text)


## Round-trip a DSL string through the worker's evaluate method and update the
## panel state (meshes, edges, sidebar) with the result. Centralised so a future
## bottom-split editor (`019dd0211893`) can call the same path on save/run.
func _evaluate_and_render(dsl_text: String) -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		push_warning("[CADPanel] _evaluate_and_render: MinervaIPC helper not attached; cannot dispatch cad.evaluate")
		return

	var reply_id := "cad.evaluate:" + str(Time.get_ticks_usec())
	request.emit("cad.evaluate", {"source": dsl_text}, reply_id)

	# 30s timeout: build123d cold-start can take ~10s on first invocation; the
	# default 10s is too tight for first-open of a fresh worker process.
	var result: Dictionary = await ipc.await_reply(reply_id, 30000)

	if not bool(result.get("success", false)):
		var err_code: String = str(result.get("error_code", "unknown"))
		var err_msg: String = str(result.get("error_message", ""))
		push_warning(
			"[CADPanel] cad.evaluate transport failure: %s — %s"
			% [err_code, err_msg]
		)
		return

	# PluginScenePanelBroker wraps the worker payload in PluginErrors.success(),
	# so the visible shape is:
	#   result = {success:true, result: <worker_payload>}
	# where <worker_payload> is the raw worker dict {ok, result|error}.
	var worker_payload: Dictionary = result.get("result", {})
	if not (worker_payload is Dictionary):
		push_warning("[CADPanel] cad.evaluate: missing worker payload")
		return

	if not bool(worker_payload.get("ok", false)):
		var err: Dictionary = worker_payload.get("error", {}) as Dictionary
		var kind: String = str(err.get("kind", "unknown"))
		var msg: String = str(err.get("message", ""))
		push_warning("[CADPanel] cad.evaluate worker error [%s]: %s" % [kind, msg])
		return

	var eval_result: Dictionary = worker_payload.get("result", {}) as Dictionary
	var mesh_data: Dictionary = eval_result.get("mesh", {}) as Dictionary
	var edges_var: Variant = eval_result.get("edges", [])
	var edges: Array = edges_var if edges_var is Array else []

	# Push mesh into all 5 MeshDisplay instances. The MeshRoot Node3D in each
	# SubViewport has scripts/mesh_display.gd attached, exposing update_mesh().
	var mesh_root_paths := [
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView/SubViewport/MeshRoot",
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/FrontView/SubViewport/MeshRoot",
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/RightView/SubViewport/MeshRoot",
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/SubViewport/MeshRoot",
		"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot",
	]
	for path in mesh_root_paths:
		var mr := get_node_or_null(path)
		if mr != null and mr.has_method("update_mesh"):
			mr.call("update_mesh", mesh_data, edges)

	# Update panel state and re-push edge overlays + sidebar tree.
	_last_mesh_data = mesh_data
	_edge_registry = edges
	# Mirror into host so MCP introspection tools can read without reaching into the panel.
	if _annotation_host != null:
		if _annotation_host.has_method("set_mesh_data"):
			_annotation_host.set_mesh_data(mesh_data)
		if _annotation_host.has_method("set_edge_registry"):
			_annotation_host.set_edge_registry(edges)
	_push_mesh_to_geometry_overlays()
	_render_edge_tree(_edge_registry)
	# Re-apply mesh visibility (ortho panes hide the shaded mesh; iso shows it).
	_apply_mesh_visibility()


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

	# Ortho x-ray for the narrow single view depends on the current dropdown selection.
	_apply_mesh_visibility()


## Populate Cad_AnnotationHost's viewport map for the active layout. Called
## from _ready() (initial state) and _apply_width_class() (transitions).
func _register_host_viewports(is_narrow: bool) -> void:
	if _annotation_host == null:
		return
	# Resolve cameras used in wide mode.
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	var iso_cam: Camera3D   = get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera")   as Camera3D
	var top_cam: Camera3D   = get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera")   as Camera3D
	var front_cam: Camera3D = get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D
	var right_cam: Camera3D = get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D
	if is_narrow:
		var single_vp: SubViewport = _single_view_container.get_node("SubViewport") as SubViewport
		# In narrow mode every projection id (incl. "iso") resolves to the
		# single SubViewport whose camera preset the dropdown drives.
		for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
			_annotation_host.set_viewport_for(proj, single_vp)
		# Register the single-view camera under the active viewport id.
		if _annotation_host.has_method("set_camera_for"):
			for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
				_annotation_host.set_camera_for(proj, _single_view_camera)
		# Register the single container for all narrow-mode pane ids so
		# viewport_rect computation finds the right container.
		if _annotation_host.has_method("set_container_for"):
			for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
				_annotation_host.set_container_for(proj, _single_view_container)
	else:
		var iso_vp: SubViewport   = _iso_view_container.get_node("SubViewport") as SubViewport
		var top_vp: SubViewport   = _top_view_container.get_node("SubViewport") as SubViewport
		var front_vp: SubViewport = _front_view_container.get_node("SubViewport") as SubViewport
		var right_vp: SubViewport = _right_view_container.get_node("SubViewport") as SubViewport
		_annotation_host.set_viewport_for("iso", iso_vp)
		_annotation_host.set_viewport_for("top", top_vp)
		_annotation_host.set_viewport_for("front", front_vp)
		_annotation_host.set_viewport_for("right", right_vp)
		# Register per-pane cameras for multi-pane annotation projection (Round 2a-Unit2).
		if _annotation_host.has_method("set_camera_for"):
			_annotation_host.set_camera_for("iso", iso_cam)
			_annotation_host.set_camera_for("top", top_cam)
			_annotation_host.set_camera_for("front", front_cam)
			_annotation_host.set_camera_for("right", right_cam)
		# Register per-pane containers for viewport_rect computation (Round 2b-α Unit 1).
		if _annotation_host.has_method("set_container_for"):
			_annotation_host.set_container_for("iso",   _iso_view_container)
			_annotation_host.set_container_for("top",   _top_view_container)
			_annotation_host.set_container_for("front", _front_view_container)
			_annotation_host.set_container_for("right", _right_view_container)
		# Narrow-only ids unset in wide mode (they'd be unreachable anyway).
		for proj in ["perspective", "bottom", "back", "left"]:
			_annotation_host.set_viewport_for(proj, null)
			if _annotation_host.has_method("set_camera_for"):
				_annotation_host.set_camera_for(proj, null)
			if _annotation_host.has_method("set_container_for"):
				_annotation_host.set_container_for(proj, null)


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


## Update the active viewport id when the layout changes.
##
## Round 2b-α Unit 1: the canvas is permanently parented to _canvas_overlay
## (a full-rect Control above ALL SubViewportContainers), so we no longer
## reparent it on wide↔narrow transitions. We only update the host's active
## viewport id so MCP queries and render_content_to_image target the right pane.
## (Previously this method moved the canvas between iso and single-view containers;
## that approach caused leaders for non-iso panes to draw at wrong positions.)
func _reparent_canvas(narrow: bool) -> void:
	if narrow:
		_active_viewport_id = _projection_preset_to_viewport_id(_current_projection_preset())
	else:
		_active_viewport_id = "iso"
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
	# Update the single-view geometry overlay camera and toggle mesh visibility.
	var single_ov: Control = _geometry_overlays.get("single", null) as Control
	if single_ov != null and single_ov.has_method("set_camera"):
		single_ov.call("set_camera", _single_view_camera)
	_apply_mesh_visibility()


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


# ── Edge overlay / sidebar wiring ───────────────────────────────────────────

## Build the wide-mode edge Tree under WideSidebar (below AnnotationToolbar).
## Three buttons (Prev / Next / Clear) sit beneath the tree. Both the tree
## and the buttons live in the same VBoxContainer as the toolbar, so the
## sidebar shows toolbar-then-edges in wide mode.
func _build_edge_sidebar() -> void:
	if _wide_sidebar == null:
		return

	var hr := HSeparator.new()
	hr.name = "EdgeSidebarSeparator"
	_wide_sidebar.add_child(hr)

	var label := Label.new()
	label.name = "EdgeSidebarHeader"
	label.text = "Edge Markers"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wide_sidebar.add_child(label)

	_edge_tree = Tree.new()
	_edge_tree.name = "EdgeTree"
	_edge_tree.focus_mode = Control.FOCUS_NONE
	_edge_tree.hide_root = true
	_edge_tree.columns = 3
	_edge_tree.set_column_title(0, "id")
	_edge_tree.set_column_title(1, "len/r")
	_edge_tree.set_column_title(2, "kind")
	_edge_tree.set_column_titles_visible(true)
	_edge_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edge_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_edge_tree.custom_minimum_size = Vector2(0, 180)
	_edge_tree.item_selected.connect(_on_edge_tree_item_selected)
	_wide_sidebar.add_child(_edge_tree)

	var btn_row := HBoxContainer.new()
	btn_row.name = "EdgeButtons"
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wide_sidebar.add_child(btn_row)

	var prev_btn := Button.new()
	prev_btn.text = "Prev"
	prev_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prev_btn.pressed.connect(_on_prev_edge_pressed)
	btn_row.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "Next"
	next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_btn.pressed.connect(_on_next_edge_pressed)
	btn_row.add_child(next_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(_on_clear_edge_pressed)
	btn_row.add_child(clear_btn)


## Populate the edge Tree from the current edge_registry.
func _render_edge_tree(edges: Array) -> void:
	if _edge_tree == null:
		return
	_edge_tree.clear()
	_edge_tree_items.clear()
	var root := _edge_tree.create_item()
	if edges.is_empty():
		var empty_item := _edge_tree.create_item(root)
		empty_item.set_text(0, "")
		empty_item.set_text(1, "(no edges)")
		empty_item.set_text(2, "")
		return
	# Sort by edge id ascending.
	var sorted: Array = edges.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)
	for edge_info in sorted:
		if not (edge_info is Dictionary):
			continue
		var edge_id := int(edge_info.get("id", 0))
		var kind := str(edge_info.get("kind", "straight"))
		var measure_text := ""
		if kind == "circle":
			measure_text = "%.1f" % float(edge_info.get("radius", 0.0))
		else:
			measure_text = "%.1f" % float(edge_info.get("length", 0.0))
		var item := _edge_tree.create_item(root)
		item.set_text(0, str(edge_id))
		item.set_metadata(0, edge_id)
		item.set_text(1, measure_text)
		item.set_text(2, kind)
		_edge_tree_items[edge_id] = item


## Push the current mesh data + per-pane cameras to every Cad_GeometryOverlay.
## Called whenever a new mesh arrives from the DSL→mesh bridge.
func _push_mesh_to_geometry_overlays() -> void:
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	var view_cameras := {
		"top":   get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D,
		"front": get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D,
		"right": get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D,
		"iso":   get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D,
		"single": _single_view_camera,
	}
	for ov_id in _geometry_overlays.keys():
		var ov: Control = _geometry_overlays[ov_id] as Control
		if ov == null:
			continue
		if ov.has_method("set_mesh_data"):
			ov.call("set_mesh_data", _last_mesh_data)
		var cam: Camera3D = view_cameras.get(ov_id, null)
		if ov.has_method("set_camera"):
			ov.call("set_camera", cam)
	_apply_mesh_visibility()


## Hide the shaded mesh in ortho-only panes (Top/Front/Right; narrow non-
## perspective) so the edge overlay is the only visualisation. Iso /
## Perspective keeps the mesh visible for shaded 3-D context.
func _apply_mesh_visibility() -> void:
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	# Wide-layout panes: Top/Front/Right hide mesh; Iso shows it.
	_set_pane_mesh_visible(grid + "/TopView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/FrontView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/RightView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/IsoView/SubViewport/MeshRoot", true)
	# Narrow single view: hide mesh unless the projection is Perspective.
	var single_path := "ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot"
	var preset := _current_projection_preset()
	_set_pane_mesh_visible(single_path, preset == "Perspective")


## Toggle the MeshInstance3D inside a MeshRoot. Found by the well-known child
## name "MeshInstance" set in mesh_display.gd._ready().
func _set_pane_mesh_visible(mesh_root_path: String, visible_flag: bool) -> void:
	var mesh_root := get_node_or_null(mesh_root_path)
	if mesh_root == null:
		return
	var mi := mesh_root.get_node_or_null("MeshInstance")
	if mi != null and "visible" in mi:
		mi.visible = visible_flag


## Edge selection routing — called from EdgeOverlay clicks, from the Tree, and
## from Prev/Next buttons. Highlights all panes, syncs the Tree, and pushes
## the new id to Cad_AnnotationHost so MCP queries can read it.
func _set_selected_edge_id(edge_id: int, sync_tree: bool = true) -> void:
	if _selected_edge_id == edge_id:
		if sync_tree:
			_sync_tree_selection()
		return
	_selected_edge_id = edge_id
	for ov_id in _geometry_overlays.keys():
		var ov: Control = _geometry_overlays[ov_id] as Control
		if ov != null and ov.has_method("set_selected_edge"):
			ov.call("set_selected_edge", edge_id)
	# Mirror to host for MCP visibility.
	if _annotation_host != null and _annotation_host.has_method("set_selected_edge_id"):
		_annotation_host.set_selected_edge_id(edge_id)
	if sync_tree:
		_sync_tree_selection()


func _on_edge_selected(edge_id: int) -> void:
	_set_selected_edge_id(edge_id)


func _on_edge_tree_item_selected() -> void:
	if _suppress_tree_selection or _edge_tree == null:
		return
	var item: TreeItem = _edge_tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta == null:
		return
	_set_selected_edge_id(int(meta), false)


func _sync_tree_selection() -> void:
	if _edge_tree == null:
		return
	_suppress_tree_selection = true
	if _selected_edge_id != -1 and _edge_tree_items.has(_selected_edge_id):
		var item: TreeItem = _edge_tree_items[_selected_edge_id]
		_edge_tree.set_selected(item, 0)
		_edge_tree.scroll_to_item(item, true)
	else:
		_edge_tree.deselect_all()
	_suppress_tree_selection = false


func _on_prev_edge_pressed() -> void:
	_step_selected_edge(-1)


func _on_next_edge_pressed() -> void:
	_step_selected_edge(1)


func _on_clear_edge_pressed() -> void:
	_set_selected_edge_id(-1)


func _step_selected_edge(delta: int) -> void:
	var ids: Array = []
	for edge_info in _edge_registry:
		if edge_info is Dictionary:
			ids.append(int(edge_info.get("id", 0)))
	ids.sort()
	if ids.is_empty():
		_set_selected_edge_id(-1)
		return
	if _selected_edge_id == -1:
		_set_selected_edge_id(ids[0] if delta >= 0 else ids[ids.size() - 1])
		return
	var idx := ids.find(_selected_edge_id)
	if idx == -1:
		_set_selected_edge_id(ids[0])
		return
	var next_idx := posmod(idx + delta, ids.size())
	_set_selected_edge_id(ids[next_idx])



