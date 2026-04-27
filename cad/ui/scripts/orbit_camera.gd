## orbit_camera.gd
## Reusable CAD camera for perspective and orthographic pane presets.
## Perspective pane: middle-drag orbit, shift+middle-drag pan, scroll zoom.
##
## Ported verbatim from ~/gitlab/ccsandbox/experiments/CAD/mcad-app/scripts/orbit_camera.gd.
## No dependency on backend_client.gd.

extends Camera3D
class_name OrbitCamera

# -------------------------------------------------------------------------
# Defaults
# -------------------------------------------------------------------------
const DEFAULT_DISTANCE    := 300.0
const DEFAULT_YAW         := -45.0   # degrees, horizontal angle
const DEFAULT_PITCH       := 30.0    # degrees above horizon
const DEFAULT_TARGET      := Vector3.ZERO

const MIN_DISTANCE        := 5.0
const MAX_DISTANCE        := 2000.0
const ORBIT_SENSITIVITY   := 0.4     # degrees per pixel
const PAN_SENSITIVITY     := 0.5     # world units per pixel
const ZOOM_STEP           := 0.12    # fraction of current distance
const ORTHO_SIZE_FACTOR   := 0.85

# -------------------------------------------------------------------------
# State
# -------------------------------------------------------------------------
var _target    : Vector3 = DEFAULT_TARGET
var _distance  : float   = DEFAULT_DISTANCE
var _yaw       : float   = DEFAULT_YAW    # degrees
var _pitch     : float   = DEFAULT_PITCH  # degrees
var _view_preset: String = "Perspective"
var _interactive: bool = true
var _show_helpers: bool = true

var _dragging_orbit : bool = false
var _dragging_pan   : bool = false
var _last_mouse_pos : Vector2 = Vector2.ZERO
var _grid_floor: MeshInstance3D
var _axis_gizmo: MeshInstance3D


func _ready() -> void:
	current = true
	_apply_transform()
	_ensure_helpers()
	_apply_helper_visibility()


# -------------------------------------------------------------------------
# Input
# -------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	handle_pointer_input(event)


func handle_pointer_input(event: InputEvent) -> bool:
	if not _interactive:
		return false

	var handled := false

	# Middle mouse button: start/stop drag
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		if mbe.button_index == MOUSE_BUTTON_MIDDLE:
			handled = true
			if mbe.pressed:
				_last_mouse_pos = mbe.position
				if _view_preset != "Perspective" or mbe.shift_pressed:
					_dragging_pan = true
					_dragging_orbit = false
				else:
					_dragging_orbit = true
					_dragging_pan = false
			else:
				_dragging_orbit = false
				_dragging_pan = false

		# Scroll wheel zoom
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_UP and mbe.pressed:
			handled = true
			_distance = clamp(_distance * (1.0 - ZOOM_STEP), MIN_DISTANCE, MAX_DISTANCE)
			_apply_transform()
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN and mbe.pressed:
			handled = true
			_distance = clamp(_distance * (1.0 + ZOOM_STEP), MIN_DISTANCE, MAX_DISTANCE)
			_apply_transform()

	# Mouse motion: orbit or pan
	if event is InputEventMouseMotion:
		var mme := event as InputEventMouseMotion
		if _dragging_orbit and _view_preset == "Perspective":
			handled = true
			_yaw   -= mme.relative.x * ORBIT_SENSITIVITY
			_pitch += mme.relative.y * ORBIT_SENSITIVITY
			_pitch = clamp(_pitch, -89.0, 89.0)
			_apply_transform()
		elif _dragging_pan:
			handled = true
			# Pan in the camera's local right/up plane
			var right := transform.basis.x
			var up    := transform.basis.y
			_target -= right * mme.relative.x * PAN_SENSITIVITY * (_distance / DEFAULT_DISTANCE)
			_target += up   * mme.relative.y * PAN_SENSITIVITY * (_distance / DEFAULT_DISTANCE)
			_apply_transform()

	return handled


# -------------------------------------------------------------------------
# Camera placement
# -------------------------------------------------------------------------

func _apply_transform() -> void:
	if _view_preset != "Perspective":
		_apply_orthographic_transform()
		return

	projection = Camera3D.PROJECTION_PERSPECTIVE
	var yaw_rad   := deg_to_rad(_yaw)
	var pitch_rad := deg_to_rad(_pitch)

	# Spherical to Cartesian (Y-up)
	var offset := Vector3(
		_distance * cos(pitch_rad) * sin(yaw_rad),
		_distance * sin(pitch_rad),
		_distance * cos(pitch_rad) * cos(yaw_rad)
	)

	position = _target + offset
	look_at(_target, Vector3.UP)


func _apply_orthographic_transform() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	size = max(_distance * ORTHO_SIZE_FACTOR, 20.0)

	var direction := Vector3(0, 0, 1)
	var up := Vector3.UP

	match _view_preset:
		"Top":
			direction = Vector3(0, -1, 0)
			up = Vector3(0, 0, 1)
		"Bottom":
			direction = Vector3(0, 1, 0)
			up = Vector3(0, 0, 1)
		"Front":
			direction = Vector3(0, 0, 1)
			up = Vector3.UP
		"Back":
			direction = Vector3(0, 0, -1)
			up = Vector3.UP
		"Right":
			direction = Vector3(1, 0, 0)
			up = Vector3.UP
		"Left":
			direction = Vector3(-1, 0, 0)
			up = Vector3.UP

	position = _target + direction * _distance
	look_at(_target, up)


# -------------------------------------------------------------------------
# Public API (for tests / future scripted movement)
# -------------------------------------------------------------------------

func set_target(t: Vector3) -> void:
	_target = t
	_apply_transform()


func set_distance(d: float) -> void:
	_distance = clamp(d, MIN_DISTANCE, MAX_DISTANCE)
	_apply_transform()


func set_orbit(yaw_deg: float, pitch_deg: float) -> void:
	_yaw   = yaw_deg
	_pitch = clamp(pitch_deg, -89.0, 89.0)
	_apply_transform()


func set_view_preset(preset: String) -> void:
	_view_preset = preset
	_interactive = true
	_apply_transform()
	_apply_helper_visibility()


func set_interactive(value: bool) -> void:
	_interactive = value


func set_show_helpers(value: bool) -> void:
	_show_helpers = value
	_ensure_helpers()
	_apply_helper_visibility()


func get_target()   -> Vector3: return _target
func get_distance() -> float:   return _distance
func get_yaw()      -> float:   return _yaw
func get_pitch()    -> float:   return _pitch


# -------------------------------------------------------------------------
# Grid floor
# -------------------------------------------------------------------------

func _build_grid() -> MeshInstance3D:
	var grid := _make_grid_mesh()
	var mi   := MeshInstance3D.new()
	mi.name = "GridFloor"
	mi.mesh = grid

	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.35, 0.35, 0.4, 0.6)
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = false
	mi.material_override = mat

	return mi


func _make_grid_mesh() -> ImmediateMesh:
	var mesh  := ImmediateMesh.new()
	var half  := 250
	var step  := 25

	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-half, half + step, step):
		# Lines parallel to Z
		mesh.surface_add_vertex(Vector3(i, 0, -half))
		mesh.surface_add_vertex(Vector3(i, 0,  half))
		# Lines parallel to X
		mesh.surface_add_vertex(Vector3(-half, 0, i))
		mesh.surface_add_vertex(Vector3( half, 0, i))
	mesh.surface_end()

	return mesh


# -------------------------------------------------------------------------
# Axis gizmo  (small XYZ arrows near camera, drawn in world space at origin)
# -------------------------------------------------------------------------

func _build_axis_gizmo() -> MeshInstance3D:
	var mesh := ImmediateMesh.new()
	var size := 20.0

	mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	# X axis — red
	mesh.surface_set_color(Color(1, 0, 0))
	mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_set_color(Color(1, 0, 0))
	mesh.surface_add_vertex(Vector3(size, 0, 0))

	# Y axis — green
	mesh.surface_set_color(Color(0, 1, 0))
	mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_set_color(Color(0, 1, 0))
	mesh.surface_add_vertex(Vector3(0, size, 0))

	# Z axis — blue
	mesh.surface_set_color(Color(0.2, 0.4, 1))
	mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_set_color(Color(0.2, 0.4, 1))
	mesh.surface_add_vertex(Vector3(0, 0, size))

	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.name = "AxisGizmo"
	mi.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat

	return mi


func _ensure_helpers() -> void:
	var parent := get_parent()
	if parent == null:
		return

	if _grid_floor == null:
		_grid_floor = _build_grid()
		parent.add_child.call_deferred(_grid_floor)

	if _axis_gizmo == null:
		_axis_gizmo = _build_axis_gizmo()
		parent.add_child.call_deferred(_axis_gizmo)


func _apply_helper_visibility() -> void:
	var visible := _show_helpers and _view_preset == "Perspective"
	if _grid_floor != null:
		_grid_floor.visible = visible
	if _axis_gizmo != null:
		_axis_gizmo.visible = visible


func get_debug_state() -> Dictionary:
	return {
		"view_preset": _view_preset,
		"interactive": _interactive,
		"show_helpers": _show_helpers,
		"grid_exists": _grid_floor != null,
		"grid_visible": _grid_floor.visible if _grid_floor != null else false,
		"axis_exists": _axis_gizmo != null,
		"axis_visible": _axis_gizmo.visible if _axis_gizmo != null else false,
	}
