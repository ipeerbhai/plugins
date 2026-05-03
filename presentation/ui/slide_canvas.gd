class_name Presentation_SlideCanvas
extends Control
## Center pane of the slide editor — renders the current slide and hosts
## tile placement / drag / resize / inline text edit. Inner content area
## locked to the deck's aspect ratio (16:9 for v1).
##
## Tool modes (PowerPoint convention):
##   SELECT  — click selects tile; drag body moves; corner handles resize.
##             Double-click text tile → inline edit. Del key → delete.
##   TEXT    — click+drag draws a rubber-band rect; on release a text tile
##             is placed with those bounds and inline edit opens. Auto-switch
##             back to SELECT on completion.
##   IMAGE   — same drag-to-place; on release a file picker opens and only
##             commits the tile if a file is chosen.
##   SHEET   — drag-to-place; tile created with default 3×3 cells.
##
## Drag math, resize-handle math, and selection halo follow the PCBCanvas
## convention. See memory: project_minerva_ui_conventions.md.

signal tile_selected(tile_id: String)            # "" = cleared
signal tile_moved(tile_id: String, x: float, y: float)
signal tile_resized(tile_id: String, x: float, y: float, w: float, h: float)
signal tile_added(tile_id: String)               # newly-created tile (panel notifies model)
signal tile_deleted(tile_id: String)
signal content_mutated                           # any change worth marking the doc dirty
signal tool_changed(tool: int)                   # so the panel toolbar can reflect active tool

const _SlideModel: Script = preload("slide_model.gd")
const _Host: Script = preload("presentation_tile_annotation_host.gd")

const ASPECT_RATIO: float = 16.0 / 9.0
const MIN_TILE_NORM: float = 0.02
const CLICK_PLACE_NORM_W: float = 0.35           # default size when user just clicks (no drag) in a tool
const CLICK_PLACE_NORM_H: float = 0.20

# Tool modes (public — panel toolbar uses these).
enum Tool { SELECT, TEXT, IMAGE, SHEET }

# Drag mode states. SELECT-mode movement (translate/scale/rotate of tiles) is
# now driven by the substrate AnnotationTransformTool via AnnotationOverlay; the
# canvas only owns PLACE for the TEXT/IMAGE/SHEET rubber-band placement flow.
enum DragMode { NONE, PLACE }

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _slide: Dictionary = {}
var _selected_tile_id: String = ""
var _tool: int = Tool.SELECT
var _slide_rect: Rect2 = Rect2()

# Zoom + pan. Zoom = 1.0 fits the slide to the canvas (auto-fit); >1 zooms in,
# <1 zooms out. Pan is an offset (in canvas-local pixels) from the natural
# centered position; only useful at zoom > 1.
var _zoom: float = 1.0
var _pan: Vector2 = Vector2.ZERO
const ZOOM_MIN: float = 0.25
const ZOOM_MAX: float = 5.0
const ZOOM_STEP: float = 1.10

# Preview mode: when true, the canvas is read-only — no tools, no selection
# halo, no input handling. Used by the fullscreen preview Window.
var _preview_mode: bool = false

var _drag_mode: int = DragMode.NONE
var _drag_start_mouse: Vector2 = Vector2.ZERO

# Middle-mouse pan state (separate from tile drag).
var _pan_drag_active: bool = false
var _pan_drag_start_mouse: Vector2 = Vector2.ZERO
var _pan_drag_start_pan: Vector2 = Vector2.ZERO

# Rubber-band rect in CANVAS-LOCAL coords during PLACE drag.
var _place_rect_local: Rect2 = Rect2()
# Whether the user actually moved during PLACE — distinguishes click vs. drag.
var _place_dragged: bool = false

# Tile-id → child Control rendering it.
var _tile_views: Dictionary = {}
var _bg_view: Control = null
var _content_layer: Control = null

# Inline text editor (TextEdit overlay). Created lazily.
var _inline_edit: TextEdit = null
var _inline_edit_tile_id: String = ""

# Substrate annotation integration (Round 3 of universal-select DRY refactor).
# AnnotationHost owns selection state + tile-as-annotation synthesis. AnnotationOverlay
# routes input to the active AnnotationAuthorTool and writes mutations back through
# the host. SELECT tool = AnnotationTransformTool (corner scale / edge axis-lock /
# rotate-ring / inside translate). TEXT/IMAGE/SHEET keep the canvas-local PLACE drag.
var _host: AnnotationHost = null
var _overlay: AnnotationOverlay = null
var _active_select_tool: AnnotationAuthorTool = null
# Set true when we are emitting a tile_selected signal in response to the host's
# selection_changed; prevents the host's setter from re-firing the round trip.
var _suppress_selection_signal: bool = false


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	focus_mode = Control.FOCUS_ALL              # so we receive key input for Del
	resized.connect(_recompute_slide_rect)

	_content_layer = Control.new()
	_content_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content_layer)

	# Substrate AnnotationHost + AnnotationOverlay. The overlay sits above
	# tile content (added after _content_layer) and consumes mouse input ONLY
	# while a SELECT-style tool is active. Wheel zoom, middle-pan, Del key, and
	# double-click-to-edit-text are routed through _input/_unhandled_key_input
	# so they bypass the overlay regardless of its mouse_filter.
	_host = _Host.new()
	_overlay = AnnotationOverlay.new()
	add_child(_overlay)
	_overlay.set_host(_host)
	_host.selection_changed.connect(_on_host_selection_changed)
	_host.annotations_changed.connect(_on_host_annotations_changed)
	# Bootstrap the SELECT tool — set_tool early-returns when the requested
	# tool equals the current one, and SELECT is the default.
	if _tool == Tool.SELECT:
		_active_select_tool = AnnotationTransformTool.new()
		_overlay.set_active_tool(_active_select_tool)

	_recompute_slide_rect()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func set_slide(slide: Dictionary) -> void:
	# Commit any in-progress inline edit before swapping slides.
	_commit_inline_edit()
	_slide = slide
	if _selected_tile_id != "" and _SlideModel.find_tile(_slide, _selected_tile_id) == null:
		_selected_tile_id = ""
	_rebuild_views()
	if _host != null:
		_host.set_slide(_slide)
	queue_redraw()


func set_selected_tile_id(tile_id: String) -> void:
	_selected_tile_id = tile_id
	if _host != null and not _suppress_selection_signal:
		_host.set_selected_annotation_id(tile_id)
	queue_redraw()


func set_tool(tool: int) -> void:
	if tool == _tool:
		return
	# Cancel any in-progress drag when switching tools.
	_drag_mode = DragMode.NONE
	_commit_inline_edit()
	_tool = tool
	# Swap the overlay's active tool. SELECT activates the substrate
	# AnnotationTransformTool (corner scale / edge axis-lock / rotate-ring /
	# inside translate). Non-SELECT tools clear the active tool so the
	# overlay's mouse_filter goes IGNORE and canvas _gui_input handles PLACE.
	if _overlay != null:
		if _tool == Tool.SELECT:
			_active_select_tool = AnnotationTransformTool.new()
			_overlay.set_active_tool(_active_select_tool)
		else:
			_overlay.clear_active_tool()
			_active_select_tool = null
	# In a non-SELECT tool, deselecting any current tile reduces accidental edits.
	if _tool != Tool.SELECT:
		_selected_tile_id = ""
		if _host != null:
			_host.set_selected_annotation_id("")
		tile_selected.emit("")
	tool_changed.emit(_tool)
	queue_redraw()


func get_tool() -> int:
	return _tool


func update_tile_view(tile_id: String) -> void:
	if tile_id == "":
		return
	var existing: Variant = _tile_views.get(tile_id, null)
	if existing == null:
		return
	var view: Control = existing
	var tile_v: Variant = _SlideModel.find_tile(_slide, tile_id)
	if tile_v == null:
		view.queue_free()
		_tile_views.erase(tile_id)
		queue_redraw()
		return
	var t: Dictionary = tile_v
	var idx: int = view.get_index()
	view.queue_free()
	var new_view: Control = _build_tile_view(t)
	_content_layer.add_child(new_view)
	_content_layer.move_child(new_view, idx)
	_tile_views[tile_id] = new_view
	var px: Rect2 = _norm_to_local(t)
	new_view.position = px.position
	new_view.size = px.size
	queue_redraw()


func delete_selected() -> void:
	if _selected_tile_id == "":
		return
	if _slide.is_empty():
		return
	var tiles: Array = _slide.get("tiles", []) as Array
	var deleted_id: String = _selected_tile_id
	for i in range(tiles.size()):
		if (tiles[i] as Dictionary).get("id", "") == deleted_id:
			tiles.remove_at(i)
			break
	_selected_tile_id = ""
	if _host != null:
		_host.set_selected_annotation_id("")
		_host.notify_changed()
	tile_selected.emit("")
	tile_deleted.emit(deleted_id)
	content_mutated.emit()
	_rebuild_views()
	queue_redraw()


# ---------------------------------------------------------------------------
# Slide-rect computation (aspect-locked)
# ---------------------------------------------------------------------------

func _recompute_slide_rect() -> void:
	var avail: Vector2 = size
	if avail.x <= 0 or avail.y <= 0:
		return
	# Natural fit at zoom=1 (aspect-letterboxed to the canvas).
	var avail_aspect: float = avail.x / avail.y
	var nat_w: float
	var nat_h: float
	if avail_aspect > ASPECT_RATIO:
		nat_h = avail.y; nat_w = nat_h * ASPECT_RATIO
	else:
		nat_w = avail.x; nat_h = nat_w / ASPECT_RATIO
	# Apply zoom + pan.
	var w: float = nat_w * _zoom
	var h: float = nat_h * _zoom
	var x: float = (avail.x - w) / 2.0 + _pan.x
	var y: float = (avail.y - h) / 2.0 + _pan.y
	_slide_rect = Rect2(x, y, w, h)
	_content_layer.position = Vector2(x, y)
	_content_layer.size = Vector2(w, h)
	_layout_views()
	_layout_inline_edit()
	if _host != null:
		_host.set_slide_rect(_slide_rect)
	queue_redraw()


## Returns the slide_rect that an unzoomed/unpanned canvas would have. Used
## to keep cursor-anchored zoom math stable.
func _natural_slide_rect() -> Rect2:
	var avail: Vector2 = size
	if avail.x <= 0 or avail.y <= 0:
		return Rect2()
	var avail_aspect: float = avail.x / avail.y
	var w: float
	var h: float
	if avail_aspect > ASPECT_RATIO:
		h = avail.y; w = h * ASPECT_RATIO
	else:
		w = avail.x; h = w / ASPECT_RATIO
	return Rect2(Vector2((avail.x - w) / 2.0, (avail.y - h) / 2.0), Vector2(w, h))


## Set zoom. If `anchor_canvas_pos` is given, keeps the slide-relative point
## under that canvas-local position fixed (cursor-anchored zoom). Pass null
## for a plain center-anchored zoom.
func set_zoom(new_zoom: float, anchor_canvas_pos: Variant = null) -> void:
	new_zoom = clampf(new_zoom, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, _zoom):
		return
	if anchor_canvas_pos != null and _slide_rect.size.x > 0 and _slide_rect.size.y > 0:
		var anchor: Vector2 = anchor_canvas_pos
		# Slide-normalized point currently under the cursor.
		var anchor_norm: Vector2 = (anchor - _slide_rect.position) / _slide_rect.size
		# After applying new_zoom (without changing pan first), where would
		# anchor_norm land? Compute the natural rect, then derive the pan that
		# keeps anchor_norm under `anchor`.
		var nat: Rect2 = _natural_slide_rect()
		var new_size: Vector2 = nat.size * new_zoom
		var nat_centered_pos: Vector2 = (size - new_size) / 2.0
		var desired_pos: Vector2 = anchor - anchor_norm * new_size
		_pan = desired_pos - nat_centered_pos
	_zoom = new_zoom
	# Clamp pan so the slide can't fly entirely off-canvas. At zoom <= 1 just
	# re-center; at zoom > 1, allow pan within a sensible margin.
	if _zoom <= 1.0:
		_pan = Vector2.ZERO
	else:
		var nat: Rect2 = _natural_slide_rect()
		var max_pan: Vector2 = (nat.size * (_zoom - 1.0)) / 2.0 + nat.size * 0.25
		_pan.x = clampf(_pan.x, -max_pan.x, max_pan.x)
		_pan.y = clampf(_pan.y, -max_pan.y, max_pan.y)
	_recompute_slide_rect()


func reset_zoom() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	_recompute_slide_rect()


func get_zoom() -> float:
	return _zoom


func set_preview_mode(on: bool) -> void:
	_preview_mode = on
	if on:
		_tool = Tool.SELECT
		_selected_tile_id = ""
		_drag_mode = DragMode.NONE
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		focus_mode = Control.FOCUS_NONE
	else:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_ALL
	queue_redraw()


# ---------------------------------------------------------------------------
# View rebuild
# ---------------------------------------------------------------------------

func _rebuild_views() -> void:
	for child in _content_layer.get_children():
		child.queue_free()
	_tile_views.clear()
	_bg_view = null
	if _slide.is_empty():
		return
	_build_background()
	for t in _slide.get("tiles", []) as Array:
		var view: Control = _build_tile_view(t as Dictionary)
		_content_layer.add_child(view)
		_tile_views[(t as Dictionary)["id"]] = view
	_layout_views()


func _build_background() -> void:
	var bg: Dictionary = _slide.get("background", _SlideModel.BG_DEFAULT) as Dictionary
	var kind: String = str(bg.get("kind", _SlideModel.BG_COLOR))
	var value: String = str(bg.get("value", "#ffffff"))
	if kind == _SlideModel.BG_IMAGE and not value.is_empty():
		var tex: Texture2D = _texture_from_base64(value)
		if tex != null:
			var tr := TextureRect.new()
			tr.texture = tex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_bg_view = tr
	if _bg_view == null:
		var cr := ColorRect.new()
		cr.color = _color_from_hex(value)
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bg_view = cr
	_content_layer.add_child(_bg_view)
	_content_layer.move_child(_bg_view, 0)


func _build_tile_view(tile: Dictionary) -> Control:
	var kind: String = str(tile.get("kind", ""))
	match kind:
		_SlideModel.TILE_TEXT:
			return _build_text_view(tile)
		_SlideModel.TILE_IMAGE:
			return _build_image_view(tile)
		_SlideModel.TILE_SPREADSHEET:
			return _build_spreadsheet_view(tile)
	push_warning("[presentation] unknown tile kind '%s' in tile %s" % [kind, str(tile.get("id", "?"))])
	var c := ColorRect.new()
	c.color = Color(0.8, 0.2, 0.2, 0.4)
	return c


func _build_text_view(tile: Dictionary) -> Control:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = false
	rtl.scroll_active = false
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Slide content stays readable regardless of Godot's theme. Default text
	# color = near-black; users override per-tile via BBCode color tags later.
	rtl.add_theme_color_override("default_color", Color(0.08, 0.08, 0.08))
	rtl.text = _format_text_content(
		str(tile.get("content", "")),
		str(tile.get("text_mode", _SlideModel.TEXT_MODE_PLAIN))
	)
	return rtl


func _format_text_content(content: String, mode: String) -> String:
	if mode == _SlideModel.TEXT_MODE_PLAIN:
		return content
	var lines: PackedStringArray = content.split("\n")
	var out: PackedStringArray = PackedStringArray()
	for i in range(lines.size()):
		var prefix: String = ""
		if mode == _SlideModel.TEXT_MODE_BULLET:
			prefix = "• "
		elif mode == _SlideModel.TEXT_MODE_NUMBERED:
			prefix = "%d. " % (i + 1)
		out.append("%s%s" % [prefix, lines[i]])
	return "\n".join(out)


func _build_image_view(tile: Dictionary) -> Control:
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex: Texture2D = _texture_from_base64(str(tile.get("src", "")))
	if tex != null:
		tr.texture = tex
	return tr


func _build_spreadsheet_view(tile: Dictionary) -> Control:
	var rows: int = int(tile.get("rows", 1))
	var cols: int = int(tile.get("cols", 1))
	var header_row: bool = bool(tile.get("header_row", false))
	var header_col: bool = bool(tile.get("header_col", false))
	var grid := GridContainer.new()
	grid.columns = cols
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cells: Array = tile.get("cells", []) as Array
	for r in range(rows):
		var row: Array = (cells[r] as Array) if r < cells.size() else []
		for c in range(cols):
			var cell: Dictionary = (row[c] as Dictionary) if c < row.size() else {}
			var is_header: bool = (header_row and r == 0) or (header_col and c == 0)
			grid.add_child(_build_cell_view(cell, is_header))
	return grid


func _build_cell_view(cell: Dictionary, is_header: bool) -> Control:
	var lbl := Label.new()
	lbl.text = _cell_display_text(cell)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Same contrast fix as text tiles — default Label color tracks the editor
	# theme which can be invisible on a white slide.
	lbl.add_theme_color_override("font_color", Color(0.08, 0.08, 0.08))
	# Header cells get a tinted background so the header axis is visually
	# distinguishable even though we can't easily swap fonts in v1.
	if is_header:
		var holder := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.85, 0.85, 0.9, 1.0)
		holder.add_theme_stylebox_override("panel", sb)
		holder.add_child(lbl)
		holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return holder
	var bg_hex: String = str(cell.get("bg_color", ""))
	if bg_hex != "":
		var holder2 := PanelContainer.new()
		var sb2 := StyleBoxFlat.new()
		sb2.bg_color = _color_from_hex(bg_hex)
		holder2.add_theme_stylebox_override("panel", sb2)
		holder2.add_child(lbl)
		holder2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		holder2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return holder2
	return lbl


func _cell_display_text(cell: Dictionary) -> String:
	if cell.is_empty():
		return ""
	if cell.has("display_value"):
		return str(cell["display_value"])
	var v: Variant = cell.get("value", "")
	if v == null:
		return ""
	return str(v)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _layout_views() -> void:
	if _bg_view != null:
		_bg_view.position = Vector2.ZERO
		_bg_view.size = _slide_rect.size
	for tile in _slide.get("tiles", []) as Array:
		var t: Dictionary = tile as Dictionary
		var view: Control = _tile_views.get(t.get("id", ""), null) as Control
		if view == null:
			continue
		var px := _norm_to_local(t)
		view.position = px.position
		view.size = px.size


func _norm_to_local(tile: Dictionary) -> Rect2:
	var nx: float = float(tile.get("x", 0.0))
	var ny: float = float(tile.get("y", 0.0))
	var nw: float = float(tile.get("w", 0.0))
	var nh: float = float(tile.get("h", 0.0))
	return Rect2(
		Vector2(nx * _slide_rect.size.x, ny * _slide_rect.size.y),
		Vector2(nw * _slide_rect.size.x, nh * _slide_rect.size.y)
	)


# ---------------------------------------------------------------------------
# Input — tool-dependent
# ---------------------------------------------------------------------------

## Canvas-level mouse input — only handles PLACE drag for non-SELECT tools. SELECT
## input is handled by the AnnotationOverlay → AnnotationTransformTool. Wheel zoom,
## middle pan, and double-click-to-edit are intercepted in `_input` so they keep
## working even when the overlay is mouse_filter STOP.
func _gui_input(event: InputEvent) -> void:
	if _preview_mode:
		return
	if _tool == Tool.SELECT:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			grab_focus()
			_handle_press(mb.position)
		else:
			_handle_release(mb.position)
		accept_event()
		return
	if event is InputEventMouseMotion and _drag_mode == DragMode.PLACE:
		var mm: InputEventMouseMotion = event
		_handle_motion(mm.position)
		accept_event()


## Pre-GUI input hook: wheel zoom + middle pan + double-click. These run before
## any Control's _gui_input so the AnnotationOverlay (which STOPs mouse events
## while SELECT-active) doesn't block them. Gated by global_rect to avoid firing
## when the cursor is outside the canvas.
func _input(event: InputEvent) -> void:
	if _preview_mode:
		return
	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	# Resolve cursor position in our local space; bail if outside canvas.
	var global_pos: Vector2 = (event as InputEventMouse).global_position
	if not get_global_rect().has_point(global_pos):
		# Still need to release pan if we lose focus mid-drag.
		if _pan_drag_active and event is InputEventMouseButton:
			var mb_out: InputEventMouseButton = event
			if mb_out.button_index == MOUSE_BUTTON_MIDDLE and not mb_out.pressed:
				_pan_drag_active = false
		return
	var local_pos: Vector2 = global_pos - global_position
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			set_zoom(_zoom * ZOOM_STEP, local_pos)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			set_zoom(_zoom / ZOOM_STEP, local_pos)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_pan_drag_active = true
				_pan_drag_start_mouse = local_pos
				_pan_drag_start_pan = _pan
			else:
				_pan_drag_active = false
			get_viewport().set_input_as_handled()
			return
		# Double-click on a text tile in SELECT mode opens the inline editor. We
		# steal this from the overlay so the substrate transform tool only sees
		# single-click selection.
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click \
				and _tool == Tool.SELECT:
			grab_focus()
			_handle_double_click(local_pos)
			get_viewport().set_input_as_handled()
			return
	if _pan_drag_active and event is InputEventMouseMotion:
		_pan = _pan_drag_start_pan + (local_pos - _pan_drag_start_mouse)
		set_zoom(_zoom, null)   # re-clamp + recompute
		get_viewport().set_input_as_handled()


## Key shortcuts. Bypasses overlay mouse_filter — keys are not routed through
## GUI mouse dispatch.
func _unhandled_key_input(event: InputEvent) -> void:
	if _preview_mode or not (event is InputEventKey):
		return
	var k: InputEventKey = event
	if not k.pressed:
		return
	if k.keycode == KEY_DELETE or k.keycode == KEY_BACKSPACE:
		if _inline_edit == null and _selected_tile_id != "":
			delete_selected()
			get_viewport().set_input_as_handled()
			return
	if k.keycode == KEY_ESCAPE:
		if _inline_edit != null:
			_commit_inline_edit()
			get_viewport().set_input_as_handled()
			return


func _handle_press(local_pos: Vector2) -> void:
	# SELECT-mode press is handled by the AnnotationOverlay → AnnotationTransformTool;
	# this path is only reached for TEXT/IMAGE/SHEET (overlay is mouse_filter IGNORE).
	if _tool == Tool.SELECT:
		return
	if not _slide_rect.has_point(local_pos):
		return
	_drag_mode = DragMode.PLACE
	_drag_start_mouse = local_pos
	_place_rect_local = Rect2(local_pos - _slide_rect.position, Vector2.ZERO)
	_place_dragged = false
	queue_redraw()


func _handle_double_click(local_pos: Vector2) -> void:
	# Double-click on a text tile in SELECT mode → enter inline edit.
	# Image/spreadsheet handle their own re-edit affordances later.
	var hit_id: String = _hit_test_tiles(local_pos)
	if hit_id == "":
		return
	var t_v: Variant = _SlideModel.find_tile(_slide, hit_id)
	if t_v == null:
		return
	var t: Dictionary = t_v
	_selected_tile_id = hit_id
	tile_selected.emit(hit_id)
	queue_redraw()
	if str(t.get("kind", "")) == _SlideModel.TILE_TEXT:
		_open_inline_edit(hit_id)


func _handle_motion(local_pos: Vector2) -> void:
	if _drag_mode != DragMode.PLACE:
		return
	if _slide_rect.size.x <= 0 or _slide_rect.size.y <= 0:
		return
	var origin: Vector2 = _drag_start_mouse
	var x: float = min(origin.x, local_pos.x)
	var y: float = min(origin.y, local_pos.y)
	var w: float = abs(local_pos.x - origin.x)
	var h: float = abs(local_pos.y - origin.y)
	_place_rect_local = Rect2(Vector2(x, y) - _slide_rect.position, Vector2(w, h))
	if w > 2.0 or h > 2.0:
		_place_dragged = true
	queue_redraw()


func _handle_release(_local_pos: Vector2) -> void:
	if _drag_mode != DragMode.PLACE:
		return
	var rect_norm := _place_rect_to_norm()
	_drag_mode = DragMode.NONE
	_place_rect_local = Rect2()
	queue_redraw()
	_finish_placement(rect_norm)


# Translate the live PLACE rect into normalized coords; if user just clicked
# (no meaningful drag), fall back to a default-sized rect at the click point.
func _place_rect_to_norm() -> Rect2:
	var sw: float = _slide_rect.size.x
	var sh: float = _slide_rect.size.y
	if sw <= 0 or sh <= 0:
		return Rect2()
	if not _place_dragged:
		# Click without drag → default-sized rect, centered on the click.
		var click_local: Vector2 = _drag_start_mouse - _slide_rect.position
		var nx: float = clampf(click_local.x / sw - CLICK_PLACE_NORM_W / 2.0, 0.0, 1.0 - CLICK_PLACE_NORM_W)
		var ny: float = clampf(click_local.y / sh - CLICK_PLACE_NORM_H / 2.0, 0.0, 1.0 - CLICK_PLACE_NORM_H)
		return Rect2(nx, ny, CLICK_PLACE_NORM_W, CLICK_PLACE_NORM_H)
	var nx: float = clampf(_place_rect_local.position.x / sw, 0.0, 1.0)
	var ny: float = clampf(_place_rect_local.position.y / sh, 0.0, 1.0)
	var nw: float = clampf(_place_rect_local.size.x / sw, MIN_TILE_NORM, 1.0 - nx)
	var nh: float = clampf(_place_rect_local.size.y / sh, MIN_TILE_NORM, 1.0 - ny)
	return Rect2(nx, ny, nw, nh)


func _finish_placement(rect_norm: Rect2) -> void:
	if _slide.is_empty() or rect_norm.size == Vector2.ZERO:
		set_tool(Tool.SELECT)
		return
	var kind: int = _tool
	# For IMAGE we run the file picker FIRST so we don't create an empty tile
	# if the user cancels.
	if kind == Tool.IMAGE:
		_run_image_picker_then_place(rect_norm)
		return
	var tile: Dictionary
	if kind == Tool.TEXT:
		tile = _SlideModel.make_text_tile(rect_norm.position.x, rect_norm.position.y,
			rect_norm.size.x, rect_norm.size.y, "", _SlideModel.TEXT_MODE_PLAIN)
	elif kind == Tool.SHEET:
		tile = _SlideModel.make_spreadsheet_tile(3, 3, [],
			rect_norm.position.x, rect_norm.position.y,
			rect_norm.size.x, rect_norm.size.y)
	else:
		set_tool(Tool.SELECT)
		return
	(_slide["tiles"] as Array).append(tile)
	_selected_tile_id = tile["id"]
	tile_added.emit(tile["id"])
	tile_selected.emit(tile["id"])
	content_mutated.emit()
	_rebuild_views()
	if _host != null:
		_host.notify_changed()
		_host.set_selected_annotation_id(tile["id"])
	set_tool(Tool.SELECT)
	queue_redraw()
	# Auto-enter inline edit for text tiles.
	if kind == Tool.TEXT:
		_open_inline_edit(tile["id"])


func _run_image_picker_then_place(rect_norm: Rect2) -> void:
	var picker := FileDialog.new()
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.filters = PackedStringArray(["*.png ; PNG", "*.jpg ; JPEG", "*.jpeg ; JPEG"])
	picker.title = "Choose tile image"
	picker.size = Vector2i(640, 480)
	add_child(picker)
	picker.file_selected.connect(func(path: String) -> void:
		var b64 := _read_file_as_base64(path)
		if b64 != "":
			var tile: Dictionary = _SlideModel.make_image_tile(b64,
				rect_norm.position.x, rect_norm.position.y,
				rect_norm.size.x, rect_norm.size.y)
			(_slide["tiles"] as Array).append(tile)
			_selected_tile_id = tile["id"]
			tile_added.emit(tile["id"])
			tile_selected.emit(tile["id"])
			content_mutated.emit()
			_rebuild_views()
			if _host != null:
				_host.notify_changed()
				_host.set_selected_annotation_id(tile["id"])
			queue_redraw()
		picker.queue_free()
		set_tool(Tool.SELECT)
	)
	picker.canceled.connect(func() -> void:
		picker.queue_free()
		set_tool(Tool.SELECT)
	)
	picker.popup_centered()


func _read_file_as_base64(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[presentation] could not open %s" % path)
		return ""
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.size() == 0:
		return ""
	return Marshalls.raw_to_base64(bytes)


# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------

func _hit_test_tiles(local_pos: Vector2) -> String:
	var tiles: Array = _slide.get("tiles", []) as Array
	for i in range(tiles.size() - 1, -1, -1):
		var tile: Dictionary = tiles[i] as Dictionary
		var rect_local := _norm_to_local(tile)
		var rect_canvas := Rect2(_slide_rect.position + rect_local.position, rect_local.size)
		if rect_canvas.has_point(local_pos):
			return str(tile.get("id", ""))
	return ""


# ---------------------------------------------------------------------------
# Inline text edit
# ---------------------------------------------------------------------------

func _open_inline_edit(tile_id: String) -> void:
	_commit_inline_edit()
	var t_v: Variant = _SlideModel.find_tile(_slide, tile_id)
	if t_v == null:
		return
	var t: Dictionary = t_v
	if str(t.get("kind", "")) != _SlideModel.TILE_TEXT:
		return
	var view: Control = _tile_views.get(tile_id, null) as Control
	if view != null:
		view.visible = false   # hide the read-only RichTextLabel underneath
	_inline_edit_tile_id = tile_id
	_inline_edit = TextEdit.new()
	_inline_edit.text = str(t.get("content", ""))
	_inline_edit.placeholder_text = "Type here…  (BBCode: [b]bold[/b] [i]ital[/i] [s]strike[/s])"
	_inline_edit.scroll_smooth = true
	# Force light background + dark text so the editor stands out against
	# any slide background and matches the committed RichTextLabel look.
	_inline_edit.add_theme_color_override("font_color", Color(0.05, 0.05, 0.05))
	_inline_edit.add_theme_color_override("font_placeholder_color", Color(0.4, 0.4, 0.4))
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(1, 1, 1, 0.97)
	sb_normal.set_border_width_all(2)
	sb_normal.border_color = Color(0.3, 0.7, 1.0)
	sb_normal.set_corner_radius_all(2)
	_inline_edit.add_theme_stylebox_override("normal", sb_normal)
	_inline_edit.add_theme_stylebox_override("focus", sb_normal)
	add_child(_inline_edit)
	_layout_inline_edit()
	_inline_edit.grab_focus()
	_inline_edit.focus_exited.connect(_commit_inline_edit)


func _commit_inline_edit() -> void:
	if _inline_edit == null:
		return
	var tile_id: String = _inline_edit_tile_id
	var new_text: String = _inline_edit.text
	# Detach signal first so commit doesn't re-trigger via focus_exited.
	if _inline_edit.focus_exited.is_connected(_commit_inline_edit):
		_inline_edit.focus_exited.disconnect(_commit_inline_edit)
	_inline_edit.queue_free()
	_inline_edit = null
	_inline_edit_tile_id = ""
	# Re-show the RichTextLabel for this tile.
	var view: Control = _tile_views.get(tile_id, null) as Control
	if view != null:
		view.visible = true
	# Apply the edit.
	var t_v: Variant = _SlideModel.find_tile(_slide, tile_id)
	if t_v == null:
		return
	var t: Dictionary = t_v
	if str(t.get("content", "")) != new_text:
		t["content"] = new_text
		content_mutated.emit()
		update_tile_view(tile_id)


func _layout_inline_edit() -> void:
	if _inline_edit == null or _inline_edit_tile_id == "":
		return
	var t_v: Variant = _SlideModel.find_tile(_slide, _inline_edit_tile_id)
	if t_v == null:
		return
	var rect_local := _norm_to_local(t_v as Dictionary)
	_inline_edit.position = _slide_rect.position + rect_local.position
	_inline_edit.size = rect_local.size


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	# Slide letterbox border. Selection halo + handles are drawn by the
	# AnnotationOverlay → AnnotationTransformTool gizmo.
	draw_rect(_slide_rect.grow(0.5), Color(0.5, 0.5, 0.5, 1.0), false, 1.0)

	# Rubber-band rect during PLACE (TEXT/IMAGE/SHEET tools only).
	if _drag_mode == DragMode.PLACE and _place_dragged:
		var canvas_rect := Rect2(_slide_rect.position + _place_rect_local.position, _place_rect_local.size)
		draw_rect(canvas_rect, Color(0.3, 0.7, 1.0, 0.15), true)
		draw_rect(canvas_rect, Color(0.3, 0.7, 1.0, 0.95), false, 1.5)


# ---------------------------------------------------------------------------
# Host signal handlers (substrate-driven selection + writeback)
# ---------------------------------------------------------------------------

## The host's selected_id changed (typically because the user clicked a tile or
## empty space, routed via AnnotationTransformTool._do_selection). Mirror it
## into _selected_tile_id and re-emit tile_selected so the panel keeps working.
## The _suppress_selection_signal flag prevents set_selected_tile_id from
## bouncing back to the host.
func _on_host_selection_changed(annotation_id: String) -> void:
	if _selected_tile_id == annotation_id:
		return
	# Only mirror tile-kind ids — substrate annotations (callouts etc.) live in
	# slide.annotations[] and don't correspond to a tile. Tile ids are tile.id;
	# substrate annotation ids are "ann_<hex>".
	var maps_to_tile: bool = annotation_id == "" or _SlideModel.find_tile(_slide, annotation_id) != null
	if not maps_to_tile:
		return
	_suppress_selection_signal = true
	_selected_tile_id = annotation_id
	tile_selected.emit(annotation_id)
	_suppress_selection_signal = false
	queue_redraw()


## Host emitted annotations_changed — typically after the SRT tool wrote a new
## tile geometry through update_annotation. Re-layout tile views so the Control
## children move to match the updated tile.x/y/w/h. Also emit content_mutated so
## the panel marks the document dirty.
func _on_host_annotations_changed() -> void:
	_layout_views()
	_layout_inline_edit()
	# Best-effort tile_moved/tile_resized notification: we can't tell which tile
	# changed, but content_mutated is the dirty marker the panel needs.
	content_mutated.emit()
	queue_redraw()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _color_from_hex(hex: String) -> Color:
	if hex == "":
		return Color.WHITE
	if hex.begins_with("#"):
		return Color.html(hex)
	return Color.html("#" + hex)


func _texture_from_base64(b64: String) -> Texture2D:
	if b64 == "":
		return null
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.size() == 0:
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		img = Image.new()
		if img.load_jpg_from_buffer(bytes) != OK:
			return null
	return ImageTexture.create_from_image(img)
