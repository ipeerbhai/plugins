## edge_overlay.gd
## Control drawn over a SubViewportContainer that projects 3-D edge geometry
## into 2-D screen space for hover/selection labelling.
##
## Ported verbatim from ~/gitlab/ccsandbox/experiments/CAD/mcad-app/scripts/edge_overlay.gd.
## No dependency on backend_client.gd — data is delivered via Minerva plugin IPC
## (PluginEventBroker) in Round 2+.
##
## TODO(scaffold-round-2): wire to plugin IPC instead of HTTP backend.
## In Round 2+, CADPanel._on_ipc_mesh_ready(data) calls
## edge_overlay.set_overlay_data(camera, edge_registry, view_preset, model_center, mesh_data).

extends Control
class_name EdgeOverlay

signal edge_selected(edge_id: int)

const LABEL_FONT_SIZE := 15
const PICK_RADIUS := 9.0
const OUTLINE_COLOR := Color(0.02, 0.02, 0.03, 0.95)
const ORTHO_BACKGROUND := Color(0.94, 0.95, 0.97, 1.0)
const ORTHO_EDGE_COLOR := Color(0.18, 0.19, 0.22, 1.0)
const HOVER_EDGE_COLOR := Color(0.18, 0.54, 0.9, 0.95)
const SELECTED_EDGE_COLOR := Color(0.62, 0.08, 0.08, 1.0)
const CHOOSER_BG := Color(0.08, 0.09, 0.11, 0.96)
const CHOOSER_ROW_BG := Color(0.13, 0.15, 0.18, 0.96)
const CHOOSER_TEXT := Color(0.92, 0.94, 0.97, 1.0)
const CHOOSER_ROW_HEIGHT := 22.0
const FEATURE_EDGE_ANGLE_DEGREES := 24.0
const EDGE_QUANTIZE_SCALE := 1000.0
const CIRCLE_PROJECTION_SEGMENTS := 48
const POINTLIKE_THRESHOLD_PX := 0.75
const MIN_MARKER_WIDTH := 1.5
const MAX_MARKER_WIDTH_RATIO := 0.32

var _camera: Camera3D
var _edge_registry: Array = []
var _edge_lookup: Dictionary = {}
var _raw_verts: Array = []
var _raw_faces: Array = []
var _view_preset: String = "Front"
var _selected_edge_id: int = -1
var _hovered_edge_ids: Array = []
var _chooser_edge_ids: Array = []
var _chooser_position: Vector2 = Vector2.ZERO
var _chooser_rects: Dictionary = {}
var _projected_edges: Dictionary = {}
# Cached feature-edge adjacency from the raw mesh. View-independent; built
# once per mesh in set_overlay_data. Each entry: {"a": Vector3, "b": Vector3,
# "normals": [Vector3, ...]}.
var _feature_edge_cache: Array = []
# Last camera transform / control size seen. Used to skip redraws when
# nothing changed (the previous implementation rebuilt + redrew every frame).
var _last_camera_transform: Transform3D
var _last_size: Vector2 = Vector2.ZERO
var _dirty: bool = true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(true)


func _process(_delta: float) -> void:
	if not visible:
		return
	# Only redraw when something changed (camera moved, control resized, or
	# data was updated). The old "queue_redraw every frame" caused the full
	# face-silhouette rebuild + 34×48 circle projections to run per frame,
	# which stuttered badly on dense post-boolean models.
	var camera_xf: Transform3D
	if _camera != null:
		camera_xf = _camera.global_transform
	if _dirty or camera_xf != _last_camera_transform or size != _last_size:
		_last_camera_transform = camera_xf
		_last_size = size
		_dirty = false
		_rebuild_projected_edges()
		queue_redraw()


func set_overlay_data(
	camera_ref: Camera3D,
	edge_registry: Variant,
	view_preset: String,
	_model_center: Vector3,
	mesh_data: Variant = null
) -> void:
	_camera = camera_ref
	_view_preset = view_preset
	if edge_registry is Array:
		_edge_registry = edge_registry.duplicate(true)
	else:
		_edge_registry = []
	_edge_lookup.clear()
	for edge_info in _edge_registry:
		if edge_info is Dictionary:
			_edge_lookup[int(edge_info.get("id", 0))] = edge_info

	_raw_verts = []
	_raw_faces = []
	if mesh_data is Dictionary:
		_raw_verts = mesh_data.get("vertices", []) if mesh_data.get("vertices", []) is Array else []
		_raw_faces = mesh_data.get("faces", []) if mesh_data.get("faces", []) is Array else []

	_rebuild_feature_edge_cache()
	_rebuild_projected_edges()
	_update_visibility()
	_dirty = true
	queue_redraw()


func clear_overlay() -> void:
	_edge_registry.clear()
	_edge_lookup.clear()
	_raw_verts.clear()
	_raw_faces.clear()
	_hovered_edge_ids.clear()
	_chooser_edge_ids.clear()
	_projected_edges.clear()
	_feature_edge_cache.clear()
	visible = false
	_dirty = true
	queue_redraw()


func set_selected_edge(edge_id: int) -> void:
	_selected_edge_id = edge_id
	_chooser_edge_ids.clear()
	_update_visibility()
	queue_redraw()


func get_label_count() -> int:
	return 0


func is_selected_edge_visible() -> bool:
	return _selected_edge_id != -1 and _projected_edges.has(_selected_edge_id)


func get_chooser_candidates() -> Array:
	return _chooser_edge_ids.duplicate()


func reset_label_layout() -> void:
	pass


func get_viewport_center() -> Vector2:
	return size * 0.5


func simulate_input(event: InputEvent) -> bool:
	return _handle_pointer_event(event)


func simulate_pick_edge(edge_id: int) -> Dictionary:
	_refresh_projected_edges()
	if not _projected_edges.has(edge_id):
		return {"ok": false, "error": "Edge is not visible in this pane", "edge_id": edge_id}
	var projected: Dictionary = _projected_edges[edge_id]
	var click_position: Vector2 = projected["anchor"]
	var candidates: Array = _edge_ids_at_position(click_position)
	if candidates.is_empty():
		return {"ok": false, "error": "No pick candidates at projected edge position", "edge_id": edge_id}
	if candidates.size() == 1:
		_select_edge(int(candidates[0]))
	else:
		_chooser_edge_ids = candidates.duplicate()
		_chooser_position = click_position
		queue_redraw()
	return {
		"ok": true,
		"edge_id": edge_id,
		"candidates": candidates,
		"chooser_open": _chooser_edge_ids.size() > 1,
		"selected_edge_id": _selected_edge_id,
	}


func simulate_choose_candidate(edge_id: int) -> Dictionary:
	if not _chooser_edge_ids.has(edge_id):
		return {"ok": false, "error": "Edge is not in chooser candidates", "edge_id": edge_id}
	_chooser_edge_ids.clear()
	_select_edge(edge_id)
	return {"ok": true, "selected_edge_id": _selected_edge_id}


func _draw() -> void:
	if _camera == null:
		return
	# _process already rebuilds projections on camera/size changes and sets
	# _dirty before queuing a redraw; don't rebuild again here.
	_chooser_rects.clear()

	if _view_preset != "Perspective":
		draw_rect(Rect2(Vector2.ZERO, size), ORTHO_BACKGROUND, true)
		_draw_projected_mesh_edges()

	_draw_hover_highlight()
	_draw_selected_highlight()
	if not _chooser_edge_ids.is_empty():
		var font: Font = ThemeDB.fallback_font
		if font != null:
			_draw_chooser(font)


func _draw_hover_highlight() -> void:
	if _hovered_edge_ids.is_empty():
		return
	var edge_id := int(_hovered_edge_ids[0])
	if edge_id == _selected_edge_id:
		return
	_draw_edge_marker(edge_id, HOVER_EDGE_COLOR, 3.0)


func _draw_selected_highlight() -> void:
	if _selected_edge_id == -1:
		return
	_draw_edge_marker(_selected_edge_id, SELECTED_EDGE_COLOR, 4.0)


func _draw_chooser(font: Font) -> void:
	if _chooser_edge_ids.is_empty():
		return

	var chooser_width := 190.0
	var chooser_height := CHOOSER_ROW_HEIGHT * float(_chooser_edge_ids.size())
	var origin := _chooser_position + Vector2(10, 10)
	origin.x = clamp(origin.x, 4.0, max(4.0, size.x - chooser_width - 4.0))
	origin.y = clamp(origin.y, 4.0, max(4.0, size.y - chooser_height - 4.0))
	var chooser_rect := Rect2(origin, Vector2(chooser_width, chooser_height))
	draw_rect(chooser_rect, CHOOSER_BG, true)
	draw_rect(chooser_rect.grow(1.0), OUTLINE_COLOR, false, 1.0)

	for index in range(_chooser_edge_ids.size()):
		var edge_id := int(_chooser_edge_ids[index])
		var row_rect := Rect2(origin + Vector2(0, float(index) * CHOOSER_ROW_HEIGHT), Vector2(chooser_width, CHOOSER_ROW_HEIGHT))
		draw_rect(row_rect, CHOOSER_ROW_BG if index % 2 == 0 else CHOOSER_BG, true)
		draw_rect(row_rect, OUTLINE_COLOR, false, 1.0)
		_chooser_rects[edge_id] = row_rect
		var edge_info: Dictionary = _edge_lookup.get(edge_id, {})
		var role_raw: Variant = edge_info.get("role", null)
		var plane := str(edge_info.get("source_plane", ""))
		var kind := str(edge_info.get("kind", "edge"))
		var label := str(role_raw) if role_raw != null else plane
		var text := "%d  %s  %s" % [edge_id, label, kind]
		var text_position := row_rect.position + Vector2(8, CHOOSER_ROW_HEIGHT - 7)
		draw_string(font, text_position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, LABEL_FONT_SIZE, CHOOSER_TEXT)


func _draw_edge_marker(edge_id: int, color: Color, width: float) -> void:
	if not _projected_edges.has(edge_id):
		return
	var projected: Dictionary = _projected_edges[edge_id]
	var marker_width := _marker_width_for_projected_edge(projected, width)
	if str(projected.get("kind", "")) == "circle" and projected.has("polyline"):
		var polyline: PackedVector2Array = projected["polyline"]
		if polyline.size() >= 2:
			draw_polyline(polyline, color, marker_width, true)
			return
	var start: Vector2 = projected["start"]
	var end: Vector2 = projected["end"]
	var is_point: bool = bool(projected["pointlike"])
	if is_point:
		draw_circle(start, 4.5, color)
		draw_arc(start, 7.5, 0.0, TAU, 24, color, 1.5, true)
	else:
		draw_line(start, end, color, marker_width, true)
		var endpoint_radius: float = max(1.8, marker_width * 0.7)
		draw_circle(start, endpoint_radius, color)
		draw_circle(end, endpoint_radius, color)


func _rebuild_feature_edge_cache() -> void:
	# Build the face-adjacency edge map ONCE per mesh. Silhouette classification
	# is view-dependent, so it still runs per-frame — but the dictionary build
	# (O(faces * 3)) does not.
	_feature_edge_cache.clear()
	if _raw_verts.is_empty() or _raw_faces.is_empty():
		return

	var edge_map := {}
	for face in _raw_faces:
		if not (face is Array and face.size() >= 3):
			continue
		var a := _vector3_from_raw(_raw_verts[int(face[0])])
		var b := _vector3_from_raw(_raw_verts[int(face[1])])
		var c := _vector3_from_raw(_raw_verts[int(face[2])])
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.000001:
			continue
		normal = normal.normalized()
		_add_projected_edge(edge_map, a, b, normal)
		_add_projected_edge(edge_map, b, c, normal)
		_add_projected_edge(edge_map, c, a, normal)
	_feature_edge_cache = edge_map.values()


func _draw_projected_mesh_edges() -> void:
	if _camera == null:
		return
	if _feature_edge_cache.is_empty():
		return

	var view_dir := -_camera.global_transform.basis.z.normalized()
	var cosine_threshold := cos(deg_to_rad(FEATURE_EDGE_ANGLE_DEGREES))
	# Collect all segments into a flat packed array, then draw with a single
	# draw_multiline call. This is dramatically faster than draw_line-per-edge
	# for dense meshes (bolt-flange plate: ~5000 faces).
	var points: PackedVector2Array = PackedVector2Array()
	for edge_info in _feature_edge_cache:
		var normals: Array = edge_info["normals"]
		var should_draw := false
		if normals.size() == 1:
			should_draw = true
		else:
			var normal_a: Vector3 = normals[0]
			var normal_b: Vector3 = normals[1]
			var facing_a := normal_a.dot(view_dir)
			var facing_b := normal_b.dot(view_dir)
			var is_silhouette := facing_a * facing_b <= 0.0001
			var is_sharp := normal_a.dot(normal_b) < cosine_threshold
			should_draw = is_silhouette or is_sharp
		if not should_draw:
			continue

		var p0_3d: Vector3 = edge_info["a"]
		var p1_3d: Vector3 = edge_info["b"]
		if _camera.is_position_behind(p0_3d) and _camera.is_position_behind(p1_3d):
			continue
		points.append(_camera.unproject_position(p0_3d))
		points.append(_camera.unproject_position(p1_3d))

	if points.size() >= 2:
		draw_multiline(points, ORTHO_EDGE_COLOR, 1.4, true)


func _add_projected_edge(edge_map: Dictionary, a: Vector3, b: Vector3, normal: Vector3) -> void:
	var key_a := _point_key(a)
	var key_b := _point_key(b)
	var edge_key := _edge_key(key_a, key_b)
	if not edge_map.has(edge_key):
		var first := a
		var second := b
		if key_b < key_a:
			first = b
			second = a
		edge_map[edge_key] = {
			"a": first,
			"b": second,
			"normals": [normal],
		}
		return
	var normals: Array = edge_map[edge_key]["normals"]
	if normals.size() < 2:
		normals.append(normal)


func _rebuild_projected_edges() -> void:
	_projected_edges.clear()
	if _camera == null:
		return
	for edge_info in _edge_registry:
		if not (edge_info is Dictionary):
			continue
		if not (edge_info.has("id") and edge_info.has("start") and edge_info.has("end")):
			continue
		var kind := str(edge_info.get("kind", ""))
		# Circle edges have start == end (closed loop); project the full
		# circumference so hover/select shows a circle, not a collapsed point.
		if kind == "circle" and edge_info.has("center") and edge_info.has("radius"):
			var circle := _project_circle_edge(edge_info)
			if not circle.is_empty():
				_projected_edges[int(edge_info["id"])] = circle
				continue
		var start_3d := _vector3_from_raw(edge_info["start"])
		var end_3d := _vector3_from_raw(edge_info["end"])
		if _camera.is_position_behind(start_3d) and _camera.is_position_behind(end_3d):
			continue
		var start_2d := _camera.unproject_position(start_3d)
		var end_2d := _camera.unproject_position(end_3d)
		var pointlike := start_2d.distance_to(end_2d) <= POINTLIKE_THRESHOLD_PX
		var anchor := start_2d.lerp(end_2d, 0.5)
		if pointlike:
			anchor = start_2d
		_projected_edges[int(edge_info["id"])] = {
			"kind": "straight",
			"start": start_2d,
			"end": end_2d,
			"anchor": anchor,
			"pointlike": pointlike,
		}


func _project_circle_edge(edge_info: Dictionary) -> Dictionary:
	# Sample N points around the circle in 3D, project each to 2D, store as
	# a polyline. Uses center + radius + normal from the generic edge registry.
	var center_raw: Variant = edge_info["center"]
	if center_raw == null:
		return {}
	var center_3d := _vector3_from_raw(center_raw)
	var radius := float(edge_info.get("radius", 0.0))
	if radius <= 0.0001:
		return {}
	var normal_raw: Variant = edge_info.get("normal", null)
	var normal := _vector3_from_raw(normal_raw) if normal_raw != null else Vector3.UP
	if normal.length_squared() < 0.000001:
		normal = Vector3.UP
	normal = normal.normalized()
	# Build an orthonormal basis in the circle's plane.
	# Renamed from `seed` to avoid shadowing Godot's seed() global.
	var seed_vec := Vector3.UP if abs(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := seed_vec.cross(normal).normalized() * radius
	var v := normal.cross(u).normalized() * radius

	var polyline: PackedVector2Array = PackedVector2Array()
	var any_in_front := false
	for i in range(CIRCLE_PROJECTION_SEGMENTS + 1):
		var t := TAU * float(i) / float(CIRCLE_PROJECTION_SEGMENTS)
		var p3 := center_3d + u * cos(t) + v * sin(t)
		# Orthographic panes should always project the full loop. Treating
		# samples as "behind" in ortho collapses circles back to the legacy
		# start/end fallback, which renders as a point because closed circles
		# report coincident endpoints.
		if _should_skip_projected_point(p3):
			continue
		any_in_front = true
		polyline.append(_camera.unproject_position(p3))
	if not any_in_front or polyline.size() < 2:
		return {}
	# Use a point on the projected circumference, not the center, so
	# simulate_pick_edge lands on actual edge geometry in top view.
	var anchor: Vector2 = polyline[0]
	# `start`/`end` kept for legacy picking code that still reads them; the
	# polyline is the authoritative geometry for circle edges.
	return {
		"kind": "circle",
		"start": polyline[0],
		"end": polyline[polyline.size() - 1],
		"anchor": anchor,
		"pointlike": false,
		"polyline": polyline,
	}


func _should_skip_projected_point(point_3d: Vector3) -> bool:
	if _view_preset != "Perspective":
		return false
	return _camera.is_position_behind(point_3d)


func _marker_width_for_projected_edge(projected: Dictionary, requested_width: float) -> float:
	var span := _projected_edge_span(projected)
	if span <= 0.0001:
		return requested_width
	return min(requested_width, max(MIN_MARKER_WIDTH, span * MAX_MARKER_WIDTH_RATIO))


func _projected_edge_span(projected: Dictionary) -> float:
	if str(projected.get("kind", "")) == "circle" and projected.has("polyline"):
		var polyline: PackedVector2Array = projected["polyline"]
		if polyline.size() >= 2:
			var min_x := polyline[0].x
			var max_x := polyline[0].x
			var min_y := polyline[0].y
			var max_y := polyline[0].y
			for point in polyline:
				min_x = min(min_x, point.x)
				max_x = max(max_x, point.x)
				min_y = min(min_y, point.y)
				max_y = max(max_y, point.y)
			return max(max_x - min_x, max_y - min_y)
	var start: Vector2 = projected.get("start", Vector2.ZERO)
	var end: Vector2 = projected.get("end", start)
	return start.distance_to(end)


func _refresh_projected_edges() -> void:
	if _camera == null:
		return
	_rebuild_projected_edges()


func _update_visibility() -> void:
	visible = (_view_preset != "Perspective" and not _edge_registry.is_empty()) or _selected_edge_id != -1


func _vector3_from_raw(raw_vertex: Variant) -> Vector3:
	if raw_vertex is Array and raw_vertex.size() >= 3:
		return Vector3(
			float(raw_vertex[0]),
			float(raw_vertex[1]),
			float(raw_vertex[2])
		)
	return Vector3.ZERO


func _point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [
		roundi(point.x * EDGE_QUANTIZE_SCALE),
		roundi(point.y * EDGE_QUANTIZE_SCALE),
		roundi(point.z * EDGE_QUANTIZE_SCALE),
	]


func _edge_key(point_a: String, point_b: String) -> String:
	if point_a < point_b:
		return point_a + "|" + point_b
	return point_b + "|" + point_a

func _gui_input(event: InputEvent) -> void:
	if _handle_pointer_event(event):
		accept_event()


func _handle_pointer_event(event: InputEvent) -> bool:
	_refresh_projected_edges()
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed:
				var chooser_edge_id := _chooser_edge_at_position(mouse_button.position)
				if chooser_edge_id != -1:
					_chooser_edge_ids.clear()
					_select_edge(chooser_edge_id)
					return true
				var candidates := _edge_ids_at_position(mouse_button.position)
				if candidates.size() == 1:
					_select_edge(int(candidates[0]))
					return true
				if candidates.size() > 1:
					_chooser_edge_ids = candidates.duplicate()
					_chooser_position = mouse_button.position
					queue_redraw()
					return true
				# Left-click in empty space: close any open chooser and clear
				# the current selection so users can return to an unselected
				# state without hunting for the toolbar "Clear" button.
				var had_chooser := not _chooser_edge_ids.is_empty()
				_chooser_edge_ids.clear()
				if _selected_edge_id != -1:
					_select_edge(-1)
					return true
				if had_chooser:
					queue_redraw()
					return true
			return false

		# TODO(scaffold-round-2): wire to plugin IPC instead of HTTP backend.
		# _camera.handle_pointer_input forwarded to OrbitCamera in original view_pane.gd.
		# In CADPanel we do NOT forward camera input from EdgeOverlay — orbit is handled
		# directly by OrbitCamera's own _input() method on each SubViewport.
		return false

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_hovered_edge_ids = _edge_ids_at_position(motion.position)
		queue_redraw()
		return not _hovered_edge_ids.is_empty()

	return false


func _select_edge(edge_id: int) -> void:
	_selected_edge_id = edge_id
	hover_clear_if_selected()
	_update_visibility()
	queue_redraw()
	emit_signal("edge_selected", edge_id)


func hover_clear_if_selected() -> void:
	var filtered: Array = []
	for edge_id in _hovered_edge_ids:
		if int(edge_id) != _selected_edge_id:
			filtered.append(edge_id)
	_hovered_edge_ids = filtered


## `pos` not `position` — `position` shadows Control.position.
func _chooser_edge_at_position(pos: Vector2) -> int:
	for edge_id in _chooser_rects.keys():
		var rect: Rect2 = _chooser_rects[edge_id]
		if rect.has_point(pos):
			return int(edge_id)
	return -1


func _edge_ids_at_position(pos: Vector2) -> Array:
	var hits: Array = []
	for edge_id in _projected_edges.keys():
		var projected: Dictionary = _projected_edges[edge_id]
		var distance := _distance_to_projected_edge(pos, projected)
		if distance <= PICK_RADIUS:
			hits.append({"id": int(edge_id), "distance": distance})
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if abs(float(a["distance"]) - float(b["distance"])) > 0.001:
			return float(a["distance"]) < float(b["distance"])
		return int(a["id"]) < int(b["id"])
	)
	var result: Array = []
	for hit in hits:
		result.append(int(hit["id"]))
	return result


func _distance_to_projected_edge(pos: Vector2, projected: Dictionary) -> float:
	if str(projected.get("kind", "")) == "circle" and projected.has("polyline"):
		var polyline: PackedVector2Array = projected["polyline"]
		if polyline.size() >= 2:
			var best: float = INF
			for i in range(polyline.size() - 1):
				var d := _distance_point_to_segment(pos, polyline[i], polyline[i + 1])
				if d < best:
					best = d
			return best
	var start: Vector2 = projected["start"]
	var end: Vector2 = projected["end"]
	if bool(projected["pointlike"]):
		return pos.distance_to(start)
	return _distance_point_to_segment(pos, start, end)


func _distance_point_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var segment := b - a
	var length_squared := segment.length_squared()
	if length_squared <= 0.0001:
		return point.distance_to(a)
	var t: float = clamp((point - a).dot(segment) / length_squared, 0.0, 1.0)
	var nearest: Vector2 = a + segment * t
	return point.distance_to(nearest)
