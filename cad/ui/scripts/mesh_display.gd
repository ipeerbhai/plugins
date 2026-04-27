## mesh_display.gd
## Attached to the MeshRoot Node3D in the scene.
## Receives parsed mesh data from the backend and renders it as an ArrayMesh.
##
## Ported verbatim from ~/gitlab/ccsandbox/experiments/CAD/mcad-app/scripts/mesh_display.gd.
## No dependency on backend_client.gd — data is delivered via Minerva plugin IPC
## (PluginEventBroker) in Round 2+.

extends Node3D
class_name MeshDisplay

const DEFAULT_MESH_COLOR := Color(0.78, 0.62, 0.12)
const DEFAULT_EDGE_COLOR := Color(0.16, 0.11, 0.02, 0.95)
const DEFAULT_EDGE_LABEL_COLOR := Color(0.97, 0.97, 0.99, 0.98)
const ORTHO_EDGE_COLOR := Color(0.08, 0.09, 0.11, 1.0)
const FEATURE_EDGE_ANGLE_DEGREES := 28.0
const FEATURE_EDGE_QUANTIZE_SCALE := 1000.0
const EDGE_LABEL_OUTWARD_OFFSET := 16.0
const EDGE_LABEL_VERTICAL_OFFSET := 10.0
const EDGE_LABEL_DEPTH_STAGGER := 10.0
const EDGE_LABEL_PIXEL_SIZE := 0.0026
const EDGE_LABEL_FONT_SIZE := 24
# Above this edge count, skip auto-rendering all labels + leader lines.
# Keeps the T-beam (24 edges) usable while preventing stutter on dense
# post-boolean models like the bolt-flange plate (~68 edges), where the
# label cloud is both visually noisy and slow to render.
const MAX_AUTO_LABEL_EDGES := 32

var _mesh_instance: MeshInstance3D
var _edge_instance: MeshInstance3D
var _edge_leader_instance: MeshInstance3D
var _edge_label_root: Node3D
var _wireframe_only: bool = false
var _model_center: Vector3 = Vector3.ZERO
var _feature_edge_count: int = 0


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MeshInstance"
	add_child(_mesh_instance)

	_edge_instance = MeshInstance3D.new()
	_edge_instance.name = "FeatureEdges"
	add_child(_edge_instance)

	_edge_leader_instance = MeshInstance3D.new()
	_edge_leader_instance.name = "EdgeLeaders"
	add_child(_edge_leader_instance)

	_edge_label_root = Node3D.new()
	_edge_label_root.name = "EdgeLabels"
	add_child(_edge_label_root)


# -------------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------------

## Update the displayed mesh from backend response data.
##
## Expected format:
##   {
##     "vertices": [[x, y, z], ...],
##     "faces":    [[i, j, k], ...],   # triangle indices
##     "normals":  [[x, y, z], ...],   # optional, per-vertex
##     "color":    [r, g, b]           # optional, 0..1
##   }
##
## TODO(scaffold-round-2): wire to plugin IPC instead of HTTP backend.
## In Round 2+, CADPanel._on_ipc_mesh_ready(data) calls update_mesh(data, edge_registry).
func update_mesh(mesh_data: Dictionary, edge_registry: Variant = []) -> void:
	clear_mesh()

	var raw_verts = mesh_data.get("vertices", [])
	var raw_faces = mesh_data.get("faces", [])
	var raw_normals = mesh_data.get("normals", [])
	var raw_color: Variant = mesh_data.get("color", null)

	if raw_verts is Array and raw_faces is Array \
			and raw_verts.size() > 0 and raw_faces.size() > 0:
		var aabb := _compute_aabb(raw_verts)
		_model_center = aabb.get_center()
		if _wireframe_only:
			_mesh_instance.mesh = null
			_mesh_instance.visible = false
		else:
			var arr_mesh := _build_array_mesh(raw_verts, raw_faces, raw_normals, raw_color)
			if arr_mesh != null:
				_mesh_instance.mesh = arr_mesh
				_mesh_instance.visible = true
		_edge_instance.mesh = _build_feature_edge_mesh(raw_verts, raw_faces)
		var label_registry: Variant = edge_registry
		if edge_registry is Array and edge_registry.size() > MAX_AUTO_LABEL_EDGES:
			# Too many edges for an ID-label cloud to be useful — hide the
			# labels + leader lines. Picking/hover/selection still work via
			# EdgeOverlay; the feature-edge mesh still shows outlines.
			label_registry = []
		if _wireframe_only:
			_edge_leader_instance.mesh = null
		else:
			_edge_leader_instance.mesh = _build_edge_label_leaders(label_registry, aabb.get_center())
		if _wireframe_only:
			_render_edge_labels([], aabb.get_center())
		else:
			_render_edge_labels(label_registry, aabb.get_center())
		_auto_frame(raw_verts, aabb)


func clear_mesh() -> void:
	_mesh_instance.mesh = null
	_mesh_instance.visible = false
	_edge_instance.mesh = null
	_edge_leader_instance.mesh = null
	_model_center = Vector3.ZERO
	_feature_edge_count = 0
	for child in _edge_label_root.get_children():
		child.queue_free()


func set_wireframe_only(value: bool) -> void:
	_wireframe_only = value
	if _mesh_instance != null:
		_mesh_instance.visible = not value


# -------------------------------------------------------------------------
# Internal — mesh construction
# -------------------------------------------------------------------------

func _build_array_mesh(
	raw_verts: Array,
	raw_faces: Array,
	raw_normals: Array,
	raw_color: Variant
) -> ArrayMesh:
	# Build flat triangle arrays (one entry per face corner)
	var positions := PackedVector3Array()
	var normals   := PackedVector3Array()
	var indices   := PackedInt32Array()

	# Collect vertex positions
	var vertices := PackedVector3Array()
	for v in raw_verts:
		if v is Array and v.size() >= 3:
			vertices.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
		else:
			return null  # Malformed data

	# Collect per-vertex normals if supplied
	var has_normals := raw_normals is Array and raw_normals.size() == raw_verts.size()
	var vert_normals := PackedVector3Array()
	if has_normals:
		for n in raw_normals:
			if n is Array and n.size() >= 3:
				vert_normals.append(Vector3(float(n[0]), float(n[1]), float(n[2])))
			else:
				has_normals = false
				break

	# Build index list and expanded per-face arrays
	for face in raw_faces:
		if not (face is Array and face.size() >= 3):
			return null

		var i0: int = int(face[0])
		var i1: int = int(face[1])
		var i2: int = int(face[2])

		if i0 >= vertices.size() or i1 >= vertices.size() or i2 >= vertices.size():
			return null

		var idx_base := positions.size()
		positions.append(vertices[i0])
		positions.append(vertices[i1])
		positions.append(vertices[i2])
		indices.append(idx_base)
		indices.append(idx_base + 1)
		indices.append(idx_base + 2)

		if has_normals:
			normals.append(vert_normals[i0])
			normals.append(vert_normals[i1])
			normals.append(vert_normals[i2])

	# Compute flat normals if not supplied
	if not has_normals:
		normals = _compute_flat_normals(positions, indices)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX]  = indices

	var mat := StandardMaterial3D.new()
	mat.albedo_color  = _parse_color(raw_color)
	mat.metallic      = 0.0
	mat.roughness     = 0.92
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# CAD tessellation may contain mixed winding on some triangles; render both
	# sides so the preview reads as a closed solid instead of a patchy shell.
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arr_mesh.surface_set_material(0, mat)

	return arr_mesh


func _build_feature_edge_mesh(raw_verts: Array, raw_faces: Array) -> ImmediateMesh:
	var edge_map := {}

	for face in raw_faces:
		if not (face is Array and face.size() >= 3):
			continue

		var a := _vector3_from_raw(raw_verts[int(face[0])])
		var b := _vector3_from_raw(raw_verts[int(face[1])])
		var c := _vector3_from_raw(raw_verts[int(face[2])])
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.000001:
			continue
		normal = normal.normalized()

		_accumulate_edge(edge_map, a, b, normal)
		_accumulate_edge(edge_map, b, c, normal)
		_accumulate_edge(edge_map, c, a, normal)

	var line_mesh := ImmediateMesh.new()
	var line_count := 0
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge_info in edge_map.values():
		if _is_feature_edge(edge_info["normals"]):
			line_mesh.surface_add_vertex(edge_info["a"])
			line_mesh.surface_add_vertex(edge_info["b"])
			line_count += 1
	line_mesh.surface_end()

	if line_count == 0:
		_feature_edge_count = 0
		return null
	_feature_edge_count = line_count

	var line_material := StandardMaterial3D.new()
	line_material.albedo_color = ORTHO_EDGE_COLOR if _wireframe_only else DEFAULT_EDGE_COLOR
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	line_material.no_depth_test = false
	line_mesh.surface_set_material(0, line_material)
	return line_mesh


func _accumulate_edge(edge_map: Dictionary, a: Vector3, b: Vector3, normal: Vector3) -> void:
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
	normals.append(normal)


func _is_feature_edge(normals: Array) -> bool:
	if normals.size() <= 1:
		return true

	var cosine_threshold := cos(deg_to_rad(FEATURE_EDGE_ANGLE_DEGREES))
	var minimum_dot := 1.0
	for i in range(normals.size()):
		for j in range(i + 1, normals.size()):
			var dot_value := (normals[i] as Vector3).dot(normals[j] as Vector3)
			minimum_dot = min(minimum_dot, dot_value)
	return minimum_dot < cosine_threshold


func _parse_color(raw_color: Variant) -> Color:
	if raw_color is Array and raw_color.size() >= 3:
		var color_array: Array = raw_color
		var alpha := 1.0
		if color_array.size() >= 4:
			alpha = float(color_array[3])
		return Color(
			float(color_array[0]),
			float(color_array[1]),
			float(color_array[2]),
			alpha
		)
	return DEFAULT_MESH_COLOR


func _render_edge_labels(edge_registry: Variant, model_center: Vector3) -> void:
	if not (edge_registry is Array):
		return
	if edge_registry.is_empty():
		return

	for edge_info in edge_registry:
		if not (edge_info is Dictionary):
			continue
		if not edge_info.has("id") or not edge_info.has("midpoint"):
			continue

		var label_position := _edge_label_position(edge_info, model_center)

		var label := Label3D.new()
		label.text = str(int(edge_info["id"]))
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = EDGE_LABEL_PIXEL_SIZE
		label.font_size = EDGE_LABEL_FONT_SIZE
		label.outline_size = 6
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.modulate = DEFAULT_EDGE_LABEL_COLOR
		label.no_depth_test = false
		label.render_priority = 1
		label.position = label_position
		_edge_label_root.add_child(label)


func _build_edge_label_leaders(edge_registry: Variant, model_center: Vector3) -> ImmediateMesh:
	if not (edge_registry is Array):
		return null
	if edge_registry.is_empty():
		return null

	var line_mesh := ImmediateMesh.new()
	var line_count := 0
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge_info in edge_registry:
		if not (edge_info is Dictionary):
			continue
		if not edge_info.has("id") or not edge_info.has("midpoint"):
			continue

		var anchor_point := _vector3_from_raw(edge_info["midpoint"])
		var label_position := _edge_label_position(edge_info, model_center)
		var elbow_point := anchor_point.lerp(label_position, 0.55)
		line_mesh.surface_add_vertex(anchor_point)
		line_mesh.surface_add_vertex(elbow_point)
		line_mesh.surface_add_vertex(elbow_point)
		line_mesh.surface_add_vertex(label_position)
		line_count += 1
	line_mesh.surface_end()

	if line_count == 0:
		return null

	var line_material := StandardMaterial3D.new()
	line_material.albedo_color = ORTHO_EDGE_COLOR if _wireframe_only else DEFAULT_EDGE_LABEL_COLOR
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	line_material.no_depth_test = false
	line_mesh.surface_set_material(0, line_material)
	return line_mesh


func _edge_label_position(edge_info: Dictionary, model_center: Vector3) -> Vector3:
	var midpoint := _vector3_from_raw(edge_info["midpoint"])
	var source_point := midpoint
	if edge_info.has("source_point"):
		var source_xy: Variant = edge_info["source_point"]
		if source_xy is Array and source_xy.size() >= 2:
			source_point = Vector3(float(source_xy[0]), float(source_xy[1]), midpoint.z)

	var offset_dir := source_point - Vector3(model_center.x, model_center.y, midpoint.z)
	if offset_dir.length_squared() <= 0.000001:
		offset_dir = Vector3.UP
	else:
		offset_dir = offset_dir.normalized()

	var edge_id := int(edge_info["id"])
	var depth_sign := -1.0 if edge_id % 2 == 0 else 1.0
	return midpoint \
		+ offset_dir * EDGE_LABEL_OUTWARD_OFFSET \
		+ Vector3.UP * EDGE_LABEL_VERTICAL_OFFSET \
		+ Vector3(0, 0, depth_sign * EDGE_LABEL_DEPTH_STAGGER)


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
		roundi(point.x * FEATURE_EDGE_QUANTIZE_SCALE),
		roundi(point.y * FEATURE_EDGE_QUANTIZE_SCALE),
		roundi(point.z * FEATURE_EDGE_QUANTIZE_SCALE),
	]


func _edge_key(point_a: String, point_b: String) -> String:
	if point_a < point_b:
		return point_a + "|" + point_b
	return point_b + "|" + point_a


func _compute_flat_normals(
	positions: PackedVector3Array,
	indices: PackedInt32Array
) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(positions.size())

	var i := 0
	while i + 2 < indices.size():
		var a := positions[indices[i]]
		var b := positions[indices[i + 1]]
		var c := positions[indices[i + 2]]
		var n := (b - a).cross(c - a).normalized()
		normals[indices[i]]     = n
		normals[indices[i + 1]] = n
		normals[indices[i + 2]] = n
		i += 3

	return normals


# -------------------------------------------------------------------------
# Internal — camera framing
# -------------------------------------------------------------------------

## Re-target the OrbitCamera so the mesh fits the view.
## Walks up the scene tree to find OrbitCamera by class name.
func _auto_frame(raw_verts: Array, aabb: AABB = AABB()) -> void:
	if aabb == AABB():
		aabb = _compute_aabb(raw_verts)
	if aabb.size == Vector3.ZERO:
		return

	var center := aabb.get_center()
	var radius := aabb.size.length() * 0.5

	# The camera lives at a fixed path relative to MeshRoot's grandparent (Scene3D)
	var cam = _find_orbit_camera()
	if cam == null:
		return

	cam.set_target(center)
	# Reasonable distance: cover the bounding sphere with some margin
	cam.set_distance(radius * 2.5)


func _compute_aabb(raw_verts: Array) -> AABB:
	if raw_verts.is_empty():
		return AABB()
	var first: Variant = raw_verts[0]
	if not (first is Array and first.size() >= 3):
		return AABB()
	var mn := Vector3(float(first[0]), float(first[1]), float(first[2]))
	var mx := mn
	for v in raw_verts:
		if not (v is Array and v.size() >= 3):
			continue
		var p := Vector3(float(v[0]), float(v[1]), float(v[2]))
		mn = mn.min(p)
		mx = mx.max(p)
	return AABB(mn, mx - mn)


func _find_orbit_camera():
	# MeshRoot → SubViewport parent → OrbitCamera sibling
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child.get_script() != null and child.get_script().get_global_name() == "OrbitCamera":
			return child
		# Fallback: match by node name
		if child.name == "OrbitCamera":
			return child
	return null


func get_model_center() -> Vector3:
	return _model_center


func is_wireframe_only() -> bool:
	return _wireframe_only


func is_mesh_visible() -> bool:
	return _mesh_instance != null and _mesh_instance.visible and _mesh_instance.mesh != null


func get_feature_edge_count() -> int:
	return _feature_edge_count


func get_debug_state() -> Dictionary:
	return {
		"mesh_instance_visible": _mesh_instance != null and _mesh_instance.visible,
		"mesh_instance_has_mesh": _mesh_instance != null and _mesh_instance.mesh != null,
		"edge_instance_visible": _edge_instance != null and _edge_instance.visible,
		"edge_instance_has_mesh": _edge_instance != null and _edge_instance.mesh != null,
		"edge_leader_visible": _edge_leader_instance != null and _edge_leader_instance.visible,
		"edge_leader_has_mesh": _edge_leader_instance != null and _edge_leader_instance.mesh != null,
		"label3d_count": _edge_label_root.get_child_count() if _edge_label_root != null else 0,
	}
