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

## Default world-space distance for the text-box offset from the edge midpoint.
## Direction is (camera_right + camera_up).normalized() at placement time.
## Pragmatic v1 default; bbox-relative scaling is a future refinement.
const DEFAULT_BOX_OFFSET_WORLD: float = 30.0

## State for this one-shot tool.
enum _State { IDLE, DONE }

var _state: int = _State.IDLE
var _host: Object = null
var _schema_version: int = 2


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = _State.IDLE
	# Fast-path: if an edge is already selected, emit immediately.
	if host == null:
		return
	if not host.has_method("get_current_selection_anchor"):
		return
	var anchor: Dictionary = host.get_current_selection_anchor("cad/edge")
	if anchor.is_empty():
		return
	var camera: Camera3D = _find_perspective_camera(host)
	if camera == null:
		return
	var resolved: Variant = (
		host._resolve_edge_anchor(anchor) if host.has_method("_resolve_edge_anchor") else null
	)
	if not (resolved is Dictionary):
		return
	var edge_pos: Vector3 = (resolved as Dictionary).get("position", Vector3.ZERO)
	var box_offset: Vector3 = _compute_default_box_offset(camera)
	var annotation := _build_annotation(int(anchor.get("id", -1)), box_offset)

	_state = _State.DONE
	annotation_ready.emit(annotation)
	on_deactivate()
	cancelled.emit()


func on_deactivate() -> void:
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
	var box_offset: Vector3 = (
		_compute_default_box_offset(camera) if camera != null else Vector3.ZERO
	)
	var annotation := _build_annotation(int(result.get("edge_id", -1)), box_offset)

	_state = _State.DONE
	annotation_ready.emit(annotation)
	on_deactivate()
	cancelled.emit()
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


## Compute a default box_offset in world-space using the camera's basis.
## Direction: (camera_right + camera_up).normalized(). Magnitude:
## DEFAULT_BOX_OFFSET_WORLD. Pragmatic v1; bbox-relative is future work.
static func _compute_default_box_offset(camera: Camera3D) -> Vector3:
	var basis := camera.global_transform.basis
	var right: Vector3 = basis.x.normalized()
	var up: Vector3 = basis.y.normalized()
	var dir: Vector3 = right + up
	if dir.length_squared() < 0.0001:
		return Vector3(DEFAULT_BOX_OFFSET_WORLD, DEFAULT_BOX_OFFSET_WORLD, 0.0)
	return dir.normalized() * DEFAULT_BOX_OFFSET_WORLD


# ── Internal ───────────────────────────────────────────────────────────────────

func _cancel_authoring() -> void:
	on_deactivate()
	cancelled.emit()
