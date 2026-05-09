extends Control
class_name Cad_GeometryOverlay
## CAD geometry overlay: silhouette + selected-edge highlight + click-to-pick.
##
## Lives one-per-pane (Top / Front / Right / Iso / narrow-single). Responsibilities:
##   - Ortho panes: paint a clean blueprint background + draw silhouette edges
##     projected from the 3-D mesh.
##   - All panes (incl. perspective): draw a marker for the selected edge so
##     tree clicks and edge-tool selections show up visually.
##   - All panes: hit-test left clicks against projected edges within PICK_RADIUS
##     and emit `edge_selected` so the panel can update host + sidebar tree.
##
## CAD-specific geometry visualisation — NOT annotation territory.
##
## Phase A R2a originally extracted only the silhouette path here, dropping
## background fill + selection rendering + click picking. Restored after HITL
## flagged "mesh-colored silhouette" (mesh visible behind silhouette = no bg
## paint) and "edge highlight doesn't work" (no marker + no click pickup).

signal edge_selected(edge_id: int)

const ORTHO_BACKGROUND := Color(0.94, 0.95, 0.97, 1.0)
const ORTHO_EDGE_COLOR := Color(0.18, 0.19, 0.22, 1.0)
const SELECTED_EDGE_COLOR := Color(0.62, 0.08, 0.08, 1.0)
const OUTLINE_COLOR := Color(0.02, 0.02, 0.03, 0.95)
const CHOOSER_BG := Color(0.08, 0.09, 0.11, 0.96)
const CHOOSER_ROW_BG := Color(0.13, 0.15, 0.18, 0.96)
const CHOOSER_TEXT := Color(0.92, 0.94, 0.97, 1.0)
const CHOOSER_ROW_HEIGHT := 22.0
const CHOOSER_WIDTH := 190.0
const LABEL_FONT_SIZE := 15
const FEATURE_EDGE_ANGLE_DEGREES := 24.0
const EDGE_QUANTIZE_SCALE := 1000.0
const PICK_RADIUS := 9.0
const CIRCLE_PROJECTION_SEGMENTS := 48
const POINTLIKE_THRESHOLD_PX := 0.75
const MIN_MARKER_WIDTH := 1.5
const MAX_MARKER_WIDTH_RATIO := 0.32

var _raw_verts: Array = []
var _raw_faces: Array = []
var _feature_edge_cache: Array = []
var _camera: Camera3D = null
# Per-edge registry from the worker (id, start, end, kind, center, radius, …).
# Used for hit-testing and selected-edge highlight rendering — distinct from
# the silhouette feature edges which are derived purely from face adjacency.
var _edge_registry: Array = []
var _edge_lookup: Dictionary = {}
# id → projected polyline data (rebuilt on camera move). Each entry:
#   {kind: "straight"|"circle", start: Vector2, end: Vector2,
#    anchor: Vector2, pointlike: bool, polyline?: PackedVector2Array}
var _projected_edges: Dictionary = {}
var _selected_edge_id: int = -1
# Disambiguation chooser. When a click hits multiple co-projected edges (common
# in ortho views where parallel edges align), we surface a small popup listing
# all candidates so the user can pick. _chooser_edge_ids is the list shown,
# _chooser_position is the click point used to anchor the popup, and
# _chooser_rects is the per-row hit-test cache (id → on-screen rect) rebuilt
# every draw and consumed by the next click.
var _chooser_edge_ids: Array = []
var _chooser_position: Vector2 = Vector2.ZERO
var _chooser_rects: Dictionary = {}
# Last-seen camera transform — drives both redraw and projected-edge rebuild
# when OrbitCamera mutates the camera. Without this, both silhouette and
# selection marker stay frozen at the transform active during set_camera.
var _last_camera_xform: Transform3D = Transform3D.IDENTITY
# Last-seen Control size. unproject_position depends on the current viewport
# size, so when the pane resizes (e.g. AnnotationDockPane opens and reflows
# the layout) the cached _projected_edges go stale even though the camera
# transform is unchanged. Without this guard, the silhouette (drawn live)
# and the selection marker (drawn from cache) drift apart.
var _last_size: Vector2 = Vector2.ZERO
var _projection_dirty: bool = true


func _ready() -> void:
	# MOUSE_FILTER_PASS so left clicks reach _gui_input for picking but still
	# fall through to underlying SubViewport input (camera orbit/pan) when we
	# don't consume them. Set in _ready (not the .tscn) so the contract lives
	# next to the input handler.
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# ── Public API ───────────────────────────────────────────────────────────────

func set_mesh_data(mesh_data: Dictionary) -> void:
	_raw_verts = mesh_data.get("vertices", []) if mesh_data.get("vertices", []) is Array else []
	_raw_faces = mesh_data.get("faces", []) if mesh_data.get("faces", []) is Array else []
	_rebuild_feature_edge_cache()
	queue_redraw()


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	if camera != null:
		_last_camera_xform = camera.global_transform
	_projection_dirty = true
	queue_redraw()


## Worker edge registry — array of dicts with id/start/end and optional
## kind/center/radius/normal for circle edges. Drives picking + highlight.
func set_edge_registry(edge_registry: Variant) -> void:
	if edge_registry is Array:
		_edge_registry = (edge_registry as Array).duplicate(true)
	else:
		_edge_registry = []
	_edge_lookup.clear()
	for edge_info in _edge_registry:
		if edge_info is Dictionary:
			_edge_lookup[int((edge_info as Dictionary).get("id", 0))] = edge_info
	_projection_dirty = true
	queue_redraw()


## Mark `edge_id` as the currently selected edge across this pane (-1 to clear).
## Triggers highlight redraw without affecting the worker registry or feature cache.
func set_selected_edge(edge_id: int) -> void:
	if _selected_edge_id == edge_id:
		return
	_selected_edge_id = edge_id
	queue_redraw()


# ── Frame-driven redraw ──────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _camera == null:
		return
	var xform := _camera.global_transform
	var current_size := size
	var camera_moved := xform != _last_camera_xform
	var size_changed := current_size != _last_size
	if camera_moved or size_changed:
		_last_camera_xform = xform
		_last_size = current_size
		_projection_dirty = true
		queue_redraw()


# ── Drawing ──────────────────────────────────────────────────────────────────

func _draw() -> void:
	if _camera == null:
		return

	# Each draw rebuilds the chooser-row hit-test cache from scratch — clear
	# stale entries first so a chooser that just closed doesn't leave ghost
	# rects answering hits.
	_chooser_rects.clear()

	var is_perspective := _camera.projection == Camera3D.PROJECTION_PERSPECTIVE

	# Ortho panes paint an opaque blueprint background to hide the 3-D mesh
	# behind the SubViewport (the panel hides MeshInstance but not the whole
	# Node3D, so without this fill the gold mesh shows through the silhouette).
	# Perspective panes leave the background alone — the shaded mesh IS the
	# intended visualisation in iso/Perspective.
	if not is_perspective:
		draw_rect(Rect2(Vector2.ZERO, size), ORTHO_BACKGROUND, true)
		_draw_projected_mesh_edges()

	# Refresh projected-edge lookup before highlight + future hit-tests. The
	# rebuild is camera-dependent and cheap (linear in edge count); we only do
	# it when something actually moved.
	if _projection_dirty:
		_rebuild_projected_edges()
		_projection_dirty = false

	_draw_selected_highlight()
	if not _chooser_edge_ids.is_empty():
		var font: Font = ThemeDB.fallback_font
		if font != null:
			_draw_chooser(font)


## Render the disambiguation popup at _chooser_position with one row per
## candidate edge id. Populates _chooser_rects so the next click can hit-test.
## Each row label format: "<id>  <role-or-source-plane>  <kind>".
func _draw_chooser(font: Font) -> void:
	var chooser_height := CHOOSER_ROW_HEIGHT * float(_chooser_edge_ids.size())
	var origin := _chooser_position + Vector2(10, 10)
	# Clamp into the overlay rect so the popup never lands off-screen for
	# clicks near the right/bottom edge of the pane.
	origin.x = clamp(origin.x, 4.0, max(4.0, size.x - CHOOSER_WIDTH - 4.0))
	origin.y = clamp(origin.y, 4.0, max(4.0, size.y - chooser_height - 4.0))
	var chooser_rect := Rect2(origin, Vector2(CHOOSER_WIDTH, chooser_height))
	draw_rect(chooser_rect, CHOOSER_BG, true)
	draw_rect(chooser_rect.grow(1.0), OUTLINE_COLOR, false, 1.0)

	for index in range(_chooser_edge_ids.size()):
		var edge_id := int(_chooser_edge_ids[index])
		var row_rect := Rect2(
			origin + Vector2(0, float(index) * CHOOSER_ROW_HEIGHT),
			Vector2(CHOOSER_WIDTH, CHOOSER_ROW_HEIGHT)
		)
		var row_bg := CHOOSER_ROW_BG if index % 2 == 0 else CHOOSER_BG
		draw_rect(row_rect, row_bg, true)
		draw_rect(row_rect, OUTLINE_COLOR, false, 1.0)
		_chooser_rects[edge_id] = row_rect

		var edge_info: Dictionary = _edge_lookup.get(edge_id, {})
		var role_raw: Variant = edge_info.get("role", null)
		var plane := str(edge_info.get("source_plane", ""))
		var kind := str(edge_info.get("kind", "edge"))
		var label := str(role_raw) if role_raw != null else plane
		var text := "%d  %s  %s" % [edge_id, label, kind]
		var text_position := row_rect.position + Vector2(8, CHOOSER_ROW_HEIGHT - 7)
		draw_string(
			font, text_position, text,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			LABEL_FONT_SIZE, CHOOSER_TEXT
		)


func _draw_projected_mesh_edges() -> void:
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


func _draw_selected_highlight() -> void:
	if _selected_edge_id == -1:
		return
	if not _projected_edges.has(_selected_edge_id):
		return
	_draw_edge_marker(_selected_edge_id, SELECTED_EDGE_COLOR, 4.0)


func _draw_edge_marker(edge_id: int, color: Color, width: float) -> void:
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


# ── Picking (left click → emit edge_selected) ────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _projection_dirty:
		_rebuild_projected_edges()
		_projection_dirty = false

	# 1. Click on an open chooser row → commit that selection.
	var chooser_hit := _chooser_edge_at_position(mb.position)
	if chooser_hit != -1:
		_chooser_edge_ids.clear()
		_chooser_rects.clear()
		_selected_edge_id = chooser_hit
		queue_redraw()
		edge_selected.emit(chooser_hit)
		accept_event()
		return

	# 2. Click on geometry → may match 0, 1, or many co-projected edges.
	var candidates := _edges_at_position(mb.position)
	if candidates.size() == 1:
		_chooser_edge_ids.clear()
		_chooser_rects.clear()
		_selected_edge_id = int(candidates[0])
		queue_redraw()
		edge_selected.emit(_selected_edge_id)
		accept_event()
		return
	if candidates.size() > 1:
		# Surface the chooser; selection commits on the chooser-row click.
		_chooser_edge_ids = candidates.duplicate()
		_chooser_position = mb.position
		queue_redraw()
		accept_event()
		return

	# 3. Empty space: close any open chooser, then clear selection if any.
	var had_chooser := not _chooser_edge_ids.is_empty()
	_chooser_edge_ids.clear()
	_chooser_rects.clear()
	if _selected_edge_id != -1:
		_selected_edge_id = -1
		queue_redraw()
		edge_selected.emit(-1)
		accept_event()
		return
	if had_chooser:
		queue_redraw()
		accept_event()


## Hit-test against an open chooser popup's row rects (rebuilt by _draw_chooser).
## Returns the edge id of the row under `pos`, or -1 when no row is hit.
func _chooser_edge_at_position(pos: Vector2) -> int:
	for edge_id in _chooser_rects.keys():
		var rect: Rect2 = _chooser_rects[edge_id]
		if rect.has_point(pos):
			return int(edge_id)
	return -1


## Return ALL edge ids whose projected geometry is within PICK_RADIUS of `pos`,
## sorted by distance ascending then id ascending for stable chooser order.
## Multi-hit is the common case in ortho views (parallel edges co-project),
## hence the chooser flow above.
func _edges_at_position(pos: Vector2) -> Array:
	var hits: Array = []
	for edge_id in _projected_edges.keys():
		var projected: Dictionary = _projected_edges[edge_id]
		var d := _distance_to_projected_edge(pos, projected)
		if d <= PICK_RADIUS:
			hits.append({"id": int(edge_id), "distance": d})
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if abs(float(a["distance"]) - float(b["distance"])) > 0.001:
			return float(a["distance"]) < float(b["distance"])
		return int(a["id"]) < int(b["id"])
	)
	var result: Array = []
	for hit in hits:
		result.append(int(hit["id"]))
	return result


# ── Projection rebuild (camera-dependent) ────────────────────────────────────

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
	# `seed_vec` (not `seed`) — `seed` shadows Godot's seed() global.
	var seed_vec := Vector3.UP if abs(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := seed_vec.cross(normal).normalized() * radius
	var v := normal.cross(u).normalized() * radius

	var polyline: PackedVector2Array = PackedVector2Array()
	var any_in_front := false
	var is_perspective := _camera.projection == Camera3D.PROJECTION_PERSPECTIVE
	for i in range(CIRCLE_PROJECTION_SEGMENTS + 1):
		var t := TAU * float(i) / float(CIRCLE_PROJECTION_SEGMENTS)
		var p3 := center_3d + u * cos(t) + v * sin(t)
		# Ortho cameras can "see" points formally behind the projection plane;
		# only perspective should cull-by-behind, otherwise circles in a top
		# view collapse to a single point.
		if is_perspective and _camera.is_position_behind(p3):
			continue
		any_in_front = true
		polyline.append(_camera.unproject_position(p3))
	if not any_in_front or polyline.size() < 2:
		return {}
	return {
		"kind": "circle",
		"start": polyline[0],
		"end": polyline[polyline.size() - 1],
		"anchor": polyline[0],
		"pointlike": false,
		"polyline": polyline,
	}


# ── Silhouette feature-edge cache (mesh-derived, view-independent build) ─────

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
		_add_silhouette_edge(edge_map, a, b, normal)
		_add_silhouette_edge(edge_map, b, c, normal)
		_add_silhouette_edge(edge_map, c, a, normal)
	_feature_edge_cache = edge_map.values()


func _add_silhouette_edge(edge_map: Dictionary, a: Vector3, b: Vector3, normal: Vector3) -> void:
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


# ── Geometry helpers ─────────────────────────────────────────────────────────

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
