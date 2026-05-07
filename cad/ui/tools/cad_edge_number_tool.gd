extends "res://Scripts/Services/Annotations/AnnotationAuthorTool.gd"
## CAD edge-number authoring tool (Phase B2 form).
##
## Workflows:
##
##   Pre-selected fast-path (Phase B2):
##     1. Toolbar activates the tool (on_activate called).
##     2. on_activate queries host.get_current_selection_anchor("cad/edge").
##     3. If an edge is already selected, build an envelope with that edge id
##        and a default world-space box_offset from the perspective Camera3D
##        basis, emit annotation_ready, deactivate.
##
##   Click-to-place (legacy path, kept for "tool active, no edge selected"):
##     1. Toolbar activates the tool.
##     2. The canvas overlay's mouse_filter is flipped to STOP so clicks land here.
##     3. User clicks anywhere in the panel.
##     4. Tool resolves which pane was clicked (via host.get_panes() rects).
##     5. For that pane, projects every registered edge midpoint and picks
##        the nearest within EDGE_PICK_THRESHOLD_PX.
##     6. If a near-enough edge is found, emit annotation_ready (envelope
##        carries anchor + default box_offset). Deactivate.
##
## ESC / right-click: cancel without adding annotation.
##
## Off-tree class_name discipline:
##   This file lives outside Minerva's res:// tree (~/github/plugins/cad/).
##   It MUST NOT declare a class_name. AnnotationAuthorTool is referenced via
##   the extends path above; cross-script references use preload().

## Maximum screen-space distance (px) for an edge midpoint to be considered
## "clicked". Clicks farther than this from every edge midpoint are ignored.
const EDGE_PICK_THRESHOLD_PX: float = 30.0

## Default screen-space pixel offset from edge midpoint to text-box center
## at placement time. Back-projected to world space at the edge's depth so
## the stored Vector3 box_offset puts the box at this screen distance for
## the placement-time camera view. Camera-orbit changes the apparent angle
## (cost of world-space attachment), but placement is always visually clean
## regardless of model scale. (150, -120) puts the box up-and-right of the
## edge with enough clearance for the 200-px-wide callout.
const DEFAULT_BOX_SCREEN_OFFSET: Vector2 = Vector2(150.0, -120.0)

## State for this one-shot tool. AWAITING_TEXT spans the time the modal text
## dialog is open — the tool is committed to a particular edge but waiting on
## the user to type (or cancel) the annotation body.
enum _State { IDLE, AWAITING_TEXT, DONE }

var _state: int = _State.IDLE
var _host: Object = null
var _schema_version: int = 2

## Annotation envelope held during AWAITING_TEXT. payload.text is patched in
## from the dialog's LineEdit before annotation_ready.emit().
var _pending_annotation: Dictionary = {}

## Reference to the open AcceptDialog so on_deactivate can tear it down without
## firing confirmed/canceled (silent cleanup on tool-switch / host-rebind).
var _active_dialog: AcceptDialog = null


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = _State.IDLE
	# Fast-path: if an edge is already selected, open the text dialog directly.
	if host == null:
		return
	if not host.has_method("get_current_selection_anchor"):
		return
	var anchor: Dictionary = host.get_current_selection_anchor("cad/edge")
	if anchor.is_empty():
		return
	# Resolve to edge midpoint so we can compute a screen-relative offset.
	if not host.has_method("_resolve_edge_anchor"):
		return
	var resolved: Variant = host._resolve_edge_anchor(anchor)
	if not (resolved is Dictionary):
		return
	var edge_world: Vector3 = (resolved as Dictionary).get("position", Vector3.ZERO)
	var camera: Camera3D = _find_perspective_camera(host)
	var box_offset: Vector3 = (
		_compute_default_box_offset(camera, edge_world) if camera != null else Vector3.ZERO
	)
	var annotation := _build_annotation(int(anchor.get("id", -1)), box_offset)
	_open_text_dialog(annotation)


func on_deactivate() -> void:
	# Silent dialog tear-down — fires when the toolbar switches tools, the
	# host is rebound, or the panel goes away. We do NOT want the dialog's
	# confirmed/canceled signals to leak into the post-deactivate state.
	_close_dialog_silently()
	_pending_annotation = {}
	_host = null
	_state = _State.IDLE


# ── Pointer / input ────────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	# ESC (surfaced as KEY_ESCAPE in the mods channel) → cancel.
	if mods == KEY_ESCAPE:
		_cancel_authoring()
		return true

	# Right-click → cancel.
	if button == MOUSE_BUTTON_RIGHT:
		_cancel_authoring()
		return true

	if button != MOUSE_BUTTON_LEFT:
		return false

	if _state != _State.IDLE:
		return false

	if _host == null:
		return false

	# Resolve nearest edge from the click position.
	var result := resolve_click(pos, _host)
	if result.is_empty():
		# No edge within threshold — consume the click but don't cancel.
		return true

	var camera: Camera3D = _find_perspective_camera(_host)
	var edge_world: Vector3 = result.get("world_pos", Vector3.ZERO)
	var box_offset: Vector3 = (
		_compute_default_box_offset(camera, edge_world) if camera != null else Vector3.ZERO
	)
	var annotation := _build_annotation(int(result.get("edge_id", -1)), box_offset)
	_open_text_dialog(annotation)
	return true


func on_pointer_move(_pos: Vector2) -> void:
	pass


func on_pointer_up(_pos: Vector2, _button: int, _mods: int) -> bool:
	return false


# ── Click resolution (static helper, extracted for testability) ───────────────

## Resolve which edge (if any) is nearest to a panel-root click position.
##
## Returns a Dictionary with keys:
##   edge_id    : int     — the matched edge id
##   pane_name  : String  — which pane the user clicked in
##   world_pos  : Vector3 — the edge midpoint in 3-D world space
##
## Returns an empty Dictionary when:
##   - No pane's viewport_rect contains the click position.
##   - No edge midpoint projects within EDGE_PICK_THRESHOLD_PX of the pane-local click.
static func resolve_click(panel_pos: Vector2, host: Object) -> Dictionary:
	if host == null:
		return {}

	var panes: Array = host.get_panes() if host.has_method("get_panes") else []
	var clicked_pane: Dictionary = {}
	for pane in panes:
		if not (pane is Dictionary):
			continue
		var rect: Rect2 = (pane as Dictionary).get("viewport_rect", Rect2())
		if rect.has_point(panel_pos):
			clicked_pane = pane
			break

	if clicked_pane.is_empty():
		return {}

	var pane_rect: Rect2 = clicked_pane.get("viewport_rect", Rect2())
	var pane_local: Vector2 = panel_pos - pane_rect.position
	var camera: Object = clicked_pane.get("camera", null)
	if camera == null or not camera.has_method("unproject_position"):
		return {}

	var edge_registry: Array = (
		host.get_edge_registry() if host.has_method("get_edge_registry") else []
	)

	var best_edge_id: int = -1
	var best_dist: float = EDGE_PICK_THRESHOLD_PX
	var best_world_pos: Vector3 = Vector3.ZERO

	for edge_info in edge_registry:
		if not (edge_info is Dictionary):
			continue
		var edge_id: int = int((edge_info as Dictionary).get("id", -1))
		if edge_id < 0:
			continue

		var midpoint_3d: Vector3 = _edge_midpoint(edge_info as Dictionary)
		var screen_pos: Vector2 = camera.unproject_position(midpoint_3d)
		var dist: float = pane_local.distance_to(screen_pos)

		if dist < best_dist:
			best_dist = dist
			best_edge_id = edge_id
			best_world_pos = midpoint_3d

	if best_edge_id < 0:
		return {}

	return {
		"edge_id":   best_edge_id,
		"pane_name": str(clicked_pane.get("name", "")),
		"world_pos": best_world_pos,
	}


## Compute the 3-D midpoint of an edge dict.
static func _edge_midpoint(edge_info: Dictionary) -> Vector3:
	var midpoint_raw: Variant = edge_info.get("midpoint", null)
	if midpoint_raw != null:
		return _raw_to_v3(midpoint_raw)

	var kind: String = str(edge_info.get("kind", ""))
	if kind == "circle":
		var center_raw: Variant = edge_info.get("center", null)
		if center_raw != null:
			return _raw_to_v3(center_raw)

	var start_raw: Variant = edge_info.get("start", null)
	var end_raw: Variant = edge_info.get("end", null)
	if start_raw != null and end_raw != null:
		var s := _raw_to_v3(start_raw)
		var e := _raw_to_v3(end_raw)
		return s.lerp(e, 0.5)

	return Vector3.ZERO


static func _raw_to_v3(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw as Vector3
	if raw is Array:
		var arr: Array = raw as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
		if arr.size() >= 2:
			return Vector3(float(arr[0]), float(arr[1]), 0.0)
	return Vector3.ZERO


# ── Annotation builder ─────────────────────────────────────────────────────────

func _build_annotation(edge_id: int, box_offset: Vector3) -> Dictionary:
	var view_ctx := ""
	if _host != null and _host.has_method("get_view_context"):
		view_ctx = str(_host.get_view_context())

	return {
		"kind":           "cad_edge_number",
		"schema_version": _schema_version,
		"author":         "human",
		"view_context":   view_ctx,
		"anchor": {
			"plugin": "cad",
			"type":   "edge",
			"id":     edge_id,
		},
		"payload": {
			"text":       "",
			"box_offset": [box_offset.x, box_offset.y, box_offset.z],
		},
	}


# ── Camera helpers ─────────────────────────────────────────────────────────────

## Locate the perspective Camera3D among the host's panes. Returns null when
## no perspective pane exists (e.g. all panes ortho, or panes empty).
static func _find_perspective_camera(host: Object) -> Camera3D:
	if host == null or not host.has_method("get_panes"):
		return null
	var panes: Array = host.get_panes()
	for pane in panes:
		if not (pane is Dictionary):
			continue
		var camera: Variant = (pane as Dictionary).get("camera", null)
		if camera == null:
			continue
		if not (camera is Camera3D):
			continue
		var cam3 := camera as Camera3D
		if cam3.projection == Camera3D.PROJECTION_PERSPECTIVE:
			return cam3
	return null


## Compute a default box_offset in world-space such that, at the placement-time
## camera view, the box center projects to (edge_screen + DEFAULT_BOX_SCREEN_OFFSET).
##
## Approach: project edge_world to its screen position, add the screen offset,
## back-project a ray through that screen target, walk the ray to the same
## camera-z depth as edge_world, return (world_target - edge_world).
##
## The result is a world-space Vector3, so the stored offset attaches the box
## to the part (it follows re-evaluation). Only the placement-time view
## determines the offset's magnitude/direction in world space — camera orbit
## later changes the apparent angle but not the world relationship.
##
## Returns Vector3.ZERO when projection is degenerate (edge behind camera,
## ray nearly parallel to view plane). Caller should treat ZERO as fallback
## ("box overlaps edge"); rare in practice.
static func _compute_default_box_offset(camera: Camera3D, edge_world: Vector3) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var cam_origin: Vector3 = camera.global_transform.origin
	var look_dir: Vector3 = -camera.global_transform.basis.z.normalized()
	var edge_depth: float = look_dir.dot(edge_world - cam_origin)
	if edge_depth < 0.001:
		return Vector3.ZERO

	var screen_edge: Vector2 = camera.unproject_position(edge_world)
	var screen_target: Vector2 = screen_edge + DEFAULT_BOX_SCREEN_OFFSET

	var ray_origin: Vector3 = camera.project_ray_origin(screen_target)
	var ray_dir: Vector3 = camera.project_ray_normal(screen_target)
	var dz: float = look_dir.dot(ray_dir)
	if abs(dz) < 0.001:
		return Vector3.ZERO

	var t: float = (edge_depth - look_dir.dot(ray_origin - cam_origin)) / dz
	var world_target: Vector3 = ray_origin + ray_dir * t
	return world_target - edge_world


# ── Text-input dialog ─────────────────────────────────────────────────────────

## Open a modal AcceptDialog with a LineEdit for the annotation body. On OK /
## Enter the dialog confirms with the typed text → annotation_ready emits with
## payload.text patched in. On Cancel / Escape the dialog cancels → annotation
## is dropped, cancelled.emit() un-toggles the toolbar button.
##
## Single-shot fire guard mirrors AnnotationTextAuthorTool — confirmed and
## canceled may both arrive (dialog hide order), so we ensure exactly one of
## _emit_pending_with_text or _cancel_pending runs.
func _open_text_dialog(annotation: Dictionary) -> void:
	_pending_annotation = annotation
	_state = _State.AWAITING_TEXT

	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		# Headless / no-tree path: emit with empty text and bail. Keeps tests
		# that drive the tool without a SceneTree from hanging.
		_emit_pending_with_text("")
		return
	var tree: SceneTree = loop
	var root: Window = tree.root
	if root == null:
		_emit_pending_with_text("")
		return

	var dialog := AcceptDialog.new()
	dialog.title = "Edge annotation"
	dialog.dialog_hide_on_ok = true
	dialog.add_cancel_button("Cancel")

	var line_edit := LineEdit.new()
	line_edit.placeholder_text = "e.g. Fillet this edge"
	line_edit.custom_minimum_size = Vector2(280, 0)
	dialog.add_child(line_edit)

	var fired: Array = [false]
	var finish := func(text_or_null: Variant) -> void:
		if fired[0]:
			return
		fired[0] = true
		_active_dialog = null
		dialog.queue_free()
		if text_or_null == null:
			_cancel_pending()
		else:
			_emit_pending_with_text(str(text_or_null))

	dialog.confirmed.connect(func() -> void:
		finish.call(line_edit.text)
	)
	dialog.canceled.connect(func() -> void:
		finish.call(null)
	)
	# Enter inside the LineEdit submits without forcing the user to mouse the OK.
	line_edit.text_submitted.connect(func(submitted: String) -> void:
		finish.call(submitted)
	)

	_active_dialog = dialog
	root.add_child(dialog)
	dialog.popup_centered()
	line_edit.grab_focus()


## Tear down the active dialog without firing its confirmed / canceled signals.
## Used by on_deactivate when the toolbar swaps tools mid-typing. queue_free
## stops the dialog without dispatching its hide signals to our finish lambda
## as long as we clear _active_dialog first (the lambda's `fired` guard then
## ensures any in-flight signal is a no-op).
func _close_dialog_silently() -> void:
	if _active_dialog == null:
		return
	var dialog := _active_dialog
	_active_dialog = null
	dialog.queue_free()


## Patch the pending envelope's payload.text and emit. Mirrors the legacy
## annotation_ready → on_deactivate → cancelled.emit() commit pattern.
func _emit_pending_with_text(text: String) -> void:
	if _pending_annotation.is_empty():
		_finalize_post_emit()
		return
	var annotation: Dictionary = _pending_annotation
	if annotation.has("payload") and annotation.payload is Dictionary:
		(annotation.payload as Dictionary)["text"] = text
	_state = _State.DONE
	annotation_ready.emit(annotation)
	_finalize_post_emit()


## User canceled the dialog — drop the pending annotation, un-toggle the
## toolbar button via cancelled.emit().
func _cancel_pending() -> void:
	_pending_annotation = {}
	_state = _State.IDLE
	on_deactivate()
	cancelled.emit()


func _finalize_post_emit() -> void:
	_pending_annotation = {}
	on_deactivate()
	cancelled.emit()


# ── Internal ───────────────────────────────────────────────────────────────────

func _cancel_authoring() -> void:
	on_deactivate()
	cancelled.emit()
