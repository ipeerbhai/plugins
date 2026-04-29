extends "res://Scripts/Services/Annotations/AnnotationAuthorTool.gd"
## CAD edge-number authoring tool.
##
## Click-to-add workflow for cad_edge_number annotations:
##   1. Toolbar activates the tool (on_activate called).
##   2. The canvas overlay's mouse_filter is flipped to STOP so clicks land here.
##   3. User clicks anywhere in the panel.
##   4. Tool resolves which pane was clicked (via host.get_panes() rects).
##   5. For that pane, it projects every registered edge's 3-D midpoint into
##      screen space and picks the nearest one within 30 px.
##   6. If a near-enough edge is found, an annotation envelope is built and
##      annotation_ready is emitted. The toolbar's handler calls host.add_annotation.
##   7. The tool then calls on_deactivate (restoring mouse_filter) and emits
##      cancelled (so the toolbar un-toggles the button).
##
## ESC / right-click: cancel without adding annotation.
##
## Mouse filter contract:
##   on_activate  → saves _canvas_overlay.mouse_filter → sets STOP.
##   on_deactivate → restores saved filter.
##   commit (after placing) → on_deactivate() followed by cancelled.emit().
##
## Off-tree class_name discipline:
##   This file lives outside Minerva's res:// tree (~/github/plugins/cad/).
##   It MUST NOT declare a class_name. AnnotationAuthorTool is the base class
##   and is referenced via the extends path above. All plugin cross-script
##   references use preload() or the extends string form.

## Maximum screen-space distance (px) for an edge midpoint to be considered
## "clicked". Clicks farther than this from every edge midpoint are ignored.
const EDGE_PICK_THRESHOLD_PX: float = 30.0

## State for this one-shot tool (IDLE while waiting for click, DONE after placing).
enum _State { IDLE, DONE }

var _state: int = _State.IDLE
var _host: Object = null           # AnnotationHost (duck-typed; Cad_AnnotationHost actual)
var _canvas_overlay: Object = null # Control node whose mouse_filter we temporarily flip
var _saved_mouse_filter: int = 0   # restored on deactivate
var _schema_version: int = 1


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = _State.IDLE

	# Locate the _canvas_overlay via the host. In practice the host is a
	# Cad_AnnotationHost and CADPanel pushes _canvas_overlay into it as
	# _panel_root (set via host.set_panel_root(_canvas_overlay)). We walk
	# the two available routes using duck typing:
	#   1. host.get_canvas_overlay() — if the host exposes it explicitly.
	#   2. host._panel_root — the fallback already wired by CADPanel._ready().
	_canvas_overlay = null
	if _host != null:
		if _host.has_method("get_canvas_overlay"):
			_canvas_overlay = _host.get_canvas_overlay()
		elif "_panel_root" in _host:
			_canvas_overlay = _host._panel_root

	# Flip mouse_filter → STOP (0) so clicks land on the canvas overlay (and
	# therefore on the canvas's _gui_input) rather than passing through to the
	# SubViewports beneath. MOUSE_FILTER_STOP = 0.
	if _canvas_overlay != null and "mouse_filter" in _canvas_overlay:
		_saved_mouse_filter = _canvas_overlay.mouse_filter
		_canvas_overlay.mouse_filter = 0


func on_deactivate() -> void:
	# Restore canvas overlay mouse_filter unconditionally.
	if _canvas_overlay != null and "mouse_filter" in _canvas_overlay:
		_canvas_overlay.mouse_filter = _saved_mouse_filter
	_canvas_overlay = null
	_host = null
	_state = _State.IDLE


# ── Pointer / input ────────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	# ESC (surfaced as KEY_ESCAPE in the mods channel by Cad_AnnotationCanvas) → cancel.
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
		# No edge within threshold — consume the click so SubViewports don't
		# misinterpret it, but don't cancel the tool.
		return true

	# Build the annotation envelope.
	var annotation := _build_annotation(result)

	# Mark DONE before emitting to guard against re-entrant calls.
	_state = _State.DONE

	# Emit annotation_ready → the toolbar's _on_annotation_ready handler calls
	# host.add_annotation(). We do NOT call it directly (design §11.2).
	annotation_ready.emit(annotation)

	# Deactivate (restores mouse_filter) then signal cancelled so the toolbar
	# un-toggles the button. This is the post-commit cancel pattern for one-shot
	# tools — same approach as AnnotationTextAuthorTool after dialog OK.
	on_deactivate()
	cancelled.emit()
	return true


func on_pointer_move(_pos: Vector2) -> void:
	pass  # One-shot tool: no live preview.


func on_pointer_up(_pos: Vector2, _button: int, _mods: int) -> bool:
	return false  # Click-to-place, not drag.


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
##
## host must respond to:
##   get_panes()         → Array[{name, camera, viewport_rect}]
##   get_edge_registry() → Array[{id, start, end, ...}]
static func resolve_click(panel_pos: Vector2, host: Object) -> Dictionary:
	if host == null:
		return {}

	# 1. Find the pane whose viewport_rect contains the click.
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

	# 2. Compute pane-local click coords (subtract pane top-left corner).
	var pane_rect: Rect2 = clicked_pane.get("viewport_rect", Rect2())
	var pane_local: Vector2 = panel_pos - pane_rect.position
	var camera: Object = clicked_pane.get("camera", null)
	if camera == null or not camera.has_method("unproject_position"):
		return {}

	# 3. Project every edge's midpoint and find the nearest within threshold.
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
##   Prefers worker-emitted `midpoint` when present (matches MCPCadTools path
##   and worker translator's emission). Falls back to geometric reconstruction:
##   Straight edges: midpoint of start→end segment.
##   Circle edges:   the center point (geometric center of the arc/loop).
##   Fallback:       Vector3.ZERO when no usable fields are present.
static func _edge_midpoint(edge_info: Dictionary) -> Vector3:
	var midpoint_raw: Variant = edge_info.get("midpoint", null)
	if midpoint_raw != null:
		return _raw_to_v3(midpoint_raw)

	var kind: String = str(edge_info.get("kind", ""))
	if kind == "circle":
		var center_raw: Variant = edge_info.get("center", null)
		if center_raw != null:
			return _raw_to_v3(center_raw)
		# Fall through to start/end midpoint if center is missing.

	var start_raw: Variant = edge_info.get("start", null)
	var end_raw: Variant = edge_info.get("end", null)
	if start_raw != null and end_raw != null:
		var s := _raw_to_v3(start_raw)
		var e := _raw_to_v3(end_raw)
		return s.lerp(e, 0.5)

	return Vector3.ZERO


## Convert a raw Variant (Array of floats or a Vector3) to a Vector3.
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

func _build_annotation(result: Dictionary) -> Dictionary:
	var edge_id: int = int(result.get("edge_id", 0))
	var pane_name: String = str(result.get("pane_name", ""))
	var world_pos: Vector3 = result.get("world_pos", Vector3.ZERO)

	var view_ctx := ""
	if _host != null and _host.has_method("get_view_context"):
		view_ctx = str(_host.get_view_context())

	return {
		"kind":           "cad_edge_number",
		"schema_version": _schema_version,
		"author":         "human",
		"view_context":   view_ctx,
		"payload": {
			"edge_id": edge_id,
			"label":   str(edge_id),
		},
		"primitives": [{
			"kind": "point",
			"at":   [world_pos.x, world_pos.y, world_pos.z],
		}],
		"metadata": {
			"visible_in_views": [pane_name],
		},
	}


# ── Internal ───────────────────────────────────────────────────────────────────

func _cancel_authoring() -> void:
	on_deactivate()
	cancelled.emit()
