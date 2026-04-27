class_name Cad_AnnotationCanvas
extends Control
## Drawing surface for CAD plugin annotations.
##
## Modeled after Helloscene_AnnotationCanvas. Owns no annotation state itself —
## reads from a Cad_AnnotationHost via host.get_annotations() each _draw, and
## forwards pointer/key events to the active AnnotationAuthorTool (provided by
## the AnnotationToolbar through set_active_tool()).
##
## Coordinate model:
##   Round 2 still uses identity transforms — local widget coords ARE document
##   coords. The 3-D camera projection mapping is a later grandchild
##   (`019dd017d9df`). For now the canvas overlays a single SubViewportContainer
##   and draws 2-D annotations over it.
##
## Off-tree note: this script lives outside Minerva's res:// tree. We type the
## host field with the platform base class `AnnotationHost` (class_name-registered
## under res://) instead of `Cad_AnnotationHost` so Godot's parser is happy when
## the plugin's project context isn't yet aware of plugin scripts. We rely on
## duck typing for any Cad-specific methods.

# ── State ──────────────────────────────────────────────────────────────────────

var _host: AnnotationHost = null  # actual: Cad_AnnotationHost
var _active_tool: AnnotationAuthorTool = null


# ── Public API ─────────────────────────────────────────────────────────────────

## Bind this canvas to the panel's annotation host.
## Connects to host.annotations_changed so the canvas redraws when an annotation
## is added (or the list is bulk-replaced via set_annotations). Also connects to
## host.selection_changed so the selection halo refreshes whenever the user
## selects/deselects an annotation.
func set_host(host: AnnotationHost) -> void:
	if _host != null:
		# Cad_AnnotationHost defines its own annotations_changed signal locally;
		# we duck-type the connect/disconnect via has_signal checks so this
		# script also works against a vanilla AnnotationHost during tests.
		if _host.has_signal("annotations_changed") and _host.annotations_changed.is_connected(_on_annotations_changed):
			_host.annotations_changed.disconnect(_on_annotations_changed)
		if _host.selection_changed.is_connected(queue_redraw):
			_host.selection_changed.disconnect(queue_redraw)
	_host = host
	if _host != null:
		if _host.has_signal("annotations_changed"):
			_host.annotations_changed.connect(_on_annotations_changed)
		_host.selection_changed.connect(queue_redraw)
	queue_redraw()


## Set or clear the active authoring tool. The toolbar pushes this on tool
## activation/deactivation via its active_tool_changed signal.
func set_active_tool(tool: AnnotationAuthorTool) -> void:
	if _active_tool != null:
		if _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.disconnect(_on_tool_annotation_modified)
	_active_tool = tool
	if _active_tool != null:
		if not _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.connect(_on_tool_annotation_modified)
	queue_redraw()


# ── Drawing ────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if _host == null:
		return
	var registry: AnnotationRegistry = _host.get_registry()
	var ctx := AnnotationRenderContext.create(
		get_canvas_item(),
		Transform2D.IDENTITY,
		Rect2(Vector2.ZERO, size),
		theme,
		1.0,
		_host.get_view_context()
	)

	for ann in _host.get_annotations():
		if registry != null:
			registry.dispatch_render(ctx, ann)

	if _active_tool != null:
		_active_tool.draw_preview(ctx)


# ── Input ──────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if _active_tool == null:
		return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		var mods := _mods_from_event(mb)
		if mb.pressed:
			var consumed := _active_tool.on_pointer_down(mb.position, mb.button_index, mods)
			if consumed:
				accept_event()
		else:
			var consumed_up := _active_tool.on_pointer_up(mb.position, mb.button_index, mods)
			if consumed_up:
				accept_event()
		queue_redraw()
		return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		_active_tool.on_pointer_move(mm.position)
		queue_redraw()
		return

	if event is InputEventKey:
		var ek: InputEventKey = event
		if ek.pressed and not ek.is_echo():
			if ek.keycode == KEY_ESCAPE:
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)
				if consumed:
					accept_event()
				queue_redraw()
			elif ek.keycode == KEY_DELETE:
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
				if consumed:
					accept_event()
				queue_redraw()


# ── Helpers ────────────────────────────────────────────────────────────────────

func _mods_from_event(event: InputEventWithModifiers) -> int:
	var mods := 0
	if event.shift_pressed:
		mods |= KEY_MASK_SHIFT
	if event.ctrl_pressed:
		mods |= KEY_MASK_CTRL
	if event.alt_pressed:
		mods |= KEY_MASK_ALT
	if event.meta_pressed:
		mods |= KEY_MASK_META
	return mods


# ── Signal handlers ────────────────────────────────────────────────────────────

func _on_annotations_changed() -> void:
	queue_redraw()


func _on_tool_annotation_modified(annotation_id: String, new_annotation: Dictionary) -> void:
	if _host == null:
		return
	_host.update_annotation(annotation_id, new_annotation)
	queue_redraw()
