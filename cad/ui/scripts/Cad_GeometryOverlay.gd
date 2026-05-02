extends Control
class_name Cad_GeometryOverlay
## Ortho-mode silhouette renderer for CAD 2D panes (Top / Front / Right).
## Draws x-ray mesh-edge outlines projected from 3-D geometry.
## CAD-specific geometry visualisation — NOT annotation territory.

const ORTHO_EDGE_COLOR := Color(0.18, 0.19, 0.22, 1.0)
const FEATURE_EDGE_ANGLE_DEGREES := 24.0
const EDGE_QUANTIZE_SCALE := 1000.0

var _raw_verts: Array = []
var _raw_faces: Array = []
var _feature_edge_cache: Array = []
var _camera: Camera3D = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_mesh_data(mesh_data: Dictionary) -> void:
	_raw_verts = mesh_data.get("vertices", []) if mesh_data.get("vertices", []) is Array else []
	_raw_faces = mesh_data.get("faces", []) if mesh_data.get("faces", []) is Array else []
	_rebuild_feature_edge_cache()
	queue_redraw()


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	queue_redraw()


func _draw() -> void:
	_draw_projected_mesh_edges()


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
