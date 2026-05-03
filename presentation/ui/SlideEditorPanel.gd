class_name Presentation_SlideEditorPanel
extends MinervaPluginPanel
## Slide editor panel — round-2 single-slide-focused UX.
##
## Layout: toolbar on top (tool palette + slide nav + fullscreen) and the
## slide canvas underneath taking the entire body. No persistent slide list,
## no inspector pane — direct manipulation on the canvas + a Background…
## popover handle the cases the inspector used to.
##
## Tool palette: Select / Text / Image / Spreadsheet (toggle group). Click +
## drag in a non-Select tool places a tile of that kind sized to the rubber
## band; auto-switches back to Select after placement. Text tiles auto-open
## an inline TextEdit on creation; double-click to re-edit.
##
## Other affordances:
##   Wheel scroll      — cursor-anchored zoom on the canvas
##   Middle-drag       — pan when zoomed in
##   Reset zoom button — back to fit-canvas view
##   Fullscreen button — pops a near-fullscreen preview Window of the slide
##   Del / Backspace   — delete the selected tile
##   Prev/Next + N/M   — navigate slides without a persistent list
##
## See memory: project_minerva_ui_conventions.md, project_plugin_host_owned_schema.md.

const _SlideModel: Script = preload("slide_model.gd")
const _SlideCanvas: Script = preload("slide_canvas.gd")

var _ctx: Dictionary = {}

var _deck: Dictionary = {}
var _selected_slide_index: int = 0

# Toolbar widgets.
var _tool_btns: Dictionary = {}     # Tool enum int → Button
var _prev_btn: Button = null
var _next_btn: Button = null
var _slide_label: Label = null
var _add_slide_btn: Button = null
var _del_slide_btn: Button = null
var _bg_btn: Button = null
var _fullscreen_btn: Button = null
var _zoom_label: Label = null
var _reset_zoom_btn: Button = null

var _canvas: Control = null   # Presentation_SlideCanvas
var _bg_popup: AcceptDialog = null
var _bg_color_edit: LineEdit = null
var _fullscreen_window: Window = null

# Editor name we registered the host under in AnnotationHostRegistry, so we can
# unregister cleanly on panel unload.
var _registered_editor_name: String = ""


func _ready() -> void:
	if _deck.is_empty():
		_deck = _SlideModel.make_deck()
	_build_ui()
	_refresh_all()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	root.add_child(_build_toolbar())

	_canvas = _SlideCanvas.new()
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_canvas)
	_canvas.tile_selected.connect(_on_tile_selected)
	_canvas.tile_added.connect(func(_id: String) -> void: _emit_modified())
	_canvas.tile_deleted.connect(func(_id: String) -> void: _emit_modified())
	_canvas.tile_moved.connect(func(_id: String, _x: float, _y: float) -> void: _emit_modified())
	_canvas.tile_resized.connect(func(_id: String, _x: float, _y: float, _w: float, _h: float) -> void: _emit_modified())
	_canvas.content_mutated.connect(_emit_modified)
	_canvas.tool_changed.connect(_on_canvas_tool_changed)


func _build_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ── Tool palette ────────────────────────────────────────────────────
	for entry in [
		[_SlideCanvas.Tool.SELECT, "Select"],
		[_SlideCanvas.Tool.TEXT, "Text"],
		[_SlideCanvas.Tool.IMAGE, "Image"],
		[_SlideCanvas.Tool.SHEET, "Spreadsheet"],
	]:
		var tool_id: int = entry[0]
		var label: String = entry[1]
		var b := Button.new()
		b.text = label
		b.toggle_mode = true
		b.pressed.connect(func() -> void: _canvas.set_tool(tool_id))
		bar.add_child(b)
		_tool_btns[tool_id] = b

	bar.add_child(VSeparator.new())

	# ── Slide nav ────────────────────────────────────────────────────────
	_prev_btn = Button.new()
	_prev_btn.text = "◀"
	_prev_btn.tooltip_text = "Previous slide"
	_prev_btn.pressed.connect(_on_prev_slide)
	bar.add_child(_prev_btn)

	_slide_label = Label.new()
	_slide_label.text = "0 / 0"
	_slide_label.custom_minimum_size = Vector2(80, 0)
	_slide_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_slide_label)

	_next_btn = Button.new()
	_next_btn.text = "▶"
	_next_btn.tooltip_text = "Next slide"
	_next_btn.pressed.connect(_on_next_slide)
	bar.add_child(_next_btn)

	_add_slide_btn = Button.new()
	_add_slide_btn.text = "+ Slide"
	_add_slide_btn.tooltip_text = "Add a new slide after the current one"
	_add_slide_btn.pressed.connect(_on_add_slide)
	bar.add_child(_add_slide_btn)

	_del_slide_btn = Button.new()
	_del_slide_btn.text = "− Slide"
	_del_slide_btn.tooltip_text = "Delete the current slide"
	_del_slide_btn.pressed.connect(_on_del_slide)
	bar.add_child(_del_slide_btn)

	bar.add_child(VSeparator.new())

	# ── Slide-level actions ─────────────────────────────────────────────
	_bg_btn = Button.new()
	_bg_btn.text = "Background…"
	_bg_btn.tooltip_text = "Set the slide background color or image"
	_bg_btn.pressed.connect(_on_bg_pressed)
	bar.add_child(_bg_btn)

	# ── Spacer ───────────────────────────────────────────────────────────
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	# ── Zoom controls ────────────────────────────────────────────────────
	_zoom_label = Label.new()
	_zoom_label.text = "100%"
	_zoom_label.custom_minimum_size = Vector2(48, 0)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_zoom_label)

	_reset_zoom_btn = Button.new()
	_reset_zoom_btn.text = "Reset zoom"
	_reset_zoom_btn.tooltip_text = "Fit slide to canvas (resets pan + zoom)"
	_reset_zoom_btn.pressed.connect(_on_reset_zoom_pressed)
	bar.add_child(_reset_zoom_btn)

	# ── Fullscreen ───────────────────────────────────────────────────────
	_fullscreen_btn = Button.new()
	_fullscreen_btn.text = "Fullscreen"
	_fullscreen_btn.tooltip_text = "Open a near-fullscreen preview of the current slide (Esc to close)"
	_fullscreen_btn.pressed.connect(_on_fullscreen_pressed)
	bar.add_child(_fullscreen_btn)

	return bar


# ---------------------------------------------------------------------------
# Lifecycle hooks (MinervaPluginPanel contract)
# ---------------------------------------------------------------------------

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	# Register the host with AnnotationHostRegistry so MCP tools and the
	# editor chrome can resolve it by tab name (mirror CAD CADPanel.gd:226-231).
	var host: RefCounted = get_annotation_host()
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, host)
			_registered_editor_name = ed_name
	_refresh_all()


func _on_panel_unload() -> void:
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""
	if _fullscreen_window != null and is_instance_valid(_fullscreen_window):
		_fullscreen_window.queue_free()
		_fullscreen_window = null


## Editor-chrome hook (MinervaPluginPanel virtual). Returning a non-null host
## causes Editor.gd:704 to mount the annotations dock-pane around this panel
## and surface the standard editor controls. The host is owned by
## Presentation_SlideCanvas (created in its _ready); we forward.
func get_annotation_host() -> RefCounted:
	if _canvas == null or not _canvas.has_method("get_host"):
		return null
	return _canvas.get_host()


func _on_panel_save_request() -> Dictionary:
	# Save-on-error is intentional — surface a warning but preserve work.
	var errors: Array = _SlideModel.validate_deck(_deck)
	if errors.size() > 0:
		push_warning("[presentation] save: deck has %d validation errors; saving anyway: %s" % [errors.size(), str(errors)])
	return _deck


func _on_panel_load_request(doc: Dictionary) -> void:
	var errors: Array = _SlideModel.validate_deck(doc)
	if errors.size() > 0:
		push_warning("[presentation] load: doc has validation errors, falling back to fresh deck: %s" % str(errors))
		_deck = _SlideModel.make_deck()
	else:
		_deck = doc
	_selected_slide_index = 0
	_refresh_all()


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func _refresh_all() -> void:
	if _canvas == null:
		return
	var slides: Array = _deck.get("slides", []) as Array
	if _selected_slide_index < 0:
		_selected_slide_index = 0
	if _selected_slide_index >= slides.size():
		_selected_slide_index = max(0, slides.size() - 1)

	var slide: Dictionary = {}
	if _selected_slide_index < slides.size():
		slide = slides[_selected_slide_index] as Dictionary
	_canvas.set_slide(slide)

	_slide_label.text = "%d / %d" % [_selected_slide_index + 1, slides.size()] if slides.size() > 0 else "0 / 0"
	_prev_btn.disabled = (_selected_slide_index <= 0)
	_next_btn.disabled = (_selected_slide_index >= slides.size() - 1)
	_del_slide_btn.disabled = (slides.size() <= 1)
	# Reflect current canvas tool on the toolbar.
	_on_canvas_tool_changed(_canvas.get_tool())
	_on_canvas_tool_changed(_canvas.get_tool())   # idempotent
	_zoom_label.text = "%d%%" % round(_canvas.get_zoom() * 100.0)


func _emit_modified() -> void:
	emit_signal("content_changed")
	if _canvas != null:
		_zoom_label.text = "%d%%" % round(_canvas.get_zoom() * 100.0)


# ---------------------------------------------------------------------------
# Toolbar handlers
# ---------------------------------------------------------------------------

func _on_canvas_tool_changed(tool: int) -> void:
	for tool_id in _tool_btns.keys():
		(_tool_btns[tool_id] as Button).button_pressed = (tool_id == tool)


func _on_prev_slide() -> void:
	if _selected_slide_index > 0:
		_selected_slide_index -= 1
		_refresh_all()


func _on_next_slide() -> void:
	var slides: Array = _deck.get("slides", []) as Array
	if _selected_slide_index < slides.size() - 1:
		_selected_slide_index += 1
		_refresh_all()


func _on_add_slide() -> void:
	var slides: Array = _deck["slides"] as Array
	# Explicit type — `:=` can't infer through a preloaded Script's static method.
	var new_slide: Dictionary = _SlideModel.make_slide()
	var insert_at: int = clampi(_selected_slide_index + 1, 0, slides.size())
	slides.insert(insert_at, new_slide)
	_selected_slide_index = insert_at
	_emit_modified()
	_refresh_all()


func _on_del_slide() -> void:
	var slides: Array = _deck["slides"] as Array
	if slides.size() <= 1:
		return
	slides.remove_at(_selected_slide_index)
	_selected_slide_index = clampi(_selected_slide_index, 0, slides.size() - 1)
	_emit_modified()
	_refresh_all()


func _on_reset_zoom_pressed() -> void:
	_canvas.reset_zoom()
	_zoom_label.text = "%d%%" % round(_canvas.get_zoom() * 100.0)


# ---------------------------------------------------------------------------
# Background popover
# ---------------------------------------------------------------------------

func _on_bg_pressed() -> void:
	if _selected_slide_index < 0:
		return
	if _bg_popup == null:
		_bg_popup = AcceptDialog.new()
		_bg_popup.title = "Slide background"
		_bg_popup.dialog_hide_on_ok = true
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(360, 0)
		_bg_popup.add_child(box)

		var color_row := HBoxContainer.new()
		var lbl := Label.new(); lbl.text = "Color (hex):"
		color_row.add_child(lbl)
		_bg_color_edit = LineEdit.new()
		_bg_color_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_bg_color_edit.placeholder_text = "#ffffff"
		color_row.add_child(_bg_color_edit)
		var apply_color := Button.new()
		apply_color.text = "Apply color"
		apply_color.pressed.connect(_on_bg_apply_color)
		color_row.add_child(apply_color)
		box.add_child(color_row)

		var image_row := HBoxContainer.new()
		var image_lbl := Label.new(); image_lbl.text = "Image:"
		image_row.add_child(image_lbl)
		var pick_image := Button.new()
		pick_image.text = "Choose image…"
		pick_image.pressed.connect(_on_bg_pick_image)
		image_row.add_child(pick_image)
		box.add_child(image_row)

		add_child(_bg_popup)
	# Pre-fill with current background hex if it's a color.
	var slide := _current_slide()
	var bg: Dictionary = slide.get("background", _SlideModel.BG_DEFAULT) as Dictionary
	if str(bg.get("kind", "")) == _SlideModel.BG_COLOR:
		_bg_color_edit.text = str(bg.get("value", "#ffffff"))
	else:
		_bg_color_edit.text = "#ffffff"
	_bg_popup.popup_centered()


func _on_bg_apply_color() -> void:
	var hex: String = _bg_color_edit.text.strip_edges()
	if hex == "":
		return
	if not hex.begins_with("#"):
		hex = "#" + hex
	var slide := _current_slide()
	if slide.is_empty():
		return
	slide["background"] = {"kind": _SlideModel.BG_COLOR, "value": hex}
	_emit_modified()
	_canvas.set_slide(slide)
	if _bg_popup != null:
		_bg_popup.hide()


func _on_bg_pick_image() -> void:
	var picker := FileDialog.new()
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.filters = PackedStringArray(["*.png ; PNG", "*.jpg ; JPEG", "*.jpeg ; JPEG"])
	picker.title = "Choose background image"
	picker.size = Vector2i(640, 480)
	add_child(picker)
	picker.file_selected.connect(func(path: String) -> void:
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var bytes: PackedByteArray = f.get_buffer(f.get_length())
			f.close()
			if bytes.size() > 0:
				var b64: String = Marshalls.raw_to_base64(bytes)
				var slide := _current_slide()
				if not slide.is_empty():
					slide["background"] = {"kind": _SlideModel.BG_IMAGE, "value": b64}
					_emit_modified()
					_canvas.set_slide(slide)
		picker.queue_free()
		if _bg_popup != null:
			_bg_popup.hide()
	)
	picker.canceled.connect(func() -> void: picker.queue_free())
	picker.popup_centered()


# ---------------------------------------------------------------------------
# Fullscreen preview window
# ---------------------------------------------------------------------------

func _on_fullscreen_pressed() -> void:
	if _fullscreen_window != null and is_instance_valid(_fullscreen_window):
		_fullscreen_window.grab_focus()
		return
	var slide := _current_slide()
	if slide.is_empty():
		return
	var win := Window.new()
	win.title = "Slide preview — Esc to close"
	# Near-fullscreen size; user can resize.
	var screen_size: Vector2i = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	win.size = Vector2i(int(screen_size.x * 0.9), int(screen_size.y * 0.9))
	win.transient = true
	win.exclusive = false
	win.unresizable = false
	# Explicit Control type — `:=` can't infer through preloaded Script .new().
	var preview: Control = _SlideCanvas.new()
	preview.set_preview_mode(true)
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The Window's root will be our SlideCanvas; we anchor it full-rect.
	preview.anchor_right = 1.0
	preview.anchor_bottom = 1.0
	preview.set_slide(slide)
	win.add_child(preview)
	# Esc / WM-close → free.
	win.close_requested.connect(func() -> void:
		win.queue_free()
		_fullscreen_window = null
	)
	# Also bind Esc explicitly because Window doesn't always intercept it.
	win.window_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
			win.queue_free()
			_fullscreen_window = null
	)
	add_child(win)
	_fullscreen_window = win
	win.popup_centered()


# ---------------------------------------------------------------------------
# Canvas signal handlers
# ---------------------------------------------------------------------------

func _on_tile_selected(_tile_id: String) -> void:
	# Inspector-less; nothing to surface beyond what the canvas already shows.
	pass


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _current_slide() -> Dictionary:
	var slides: Array = _deck.get("slides", []) as Array
	if _selected_slide_index < 0 or _selected_slide_index >= slides.size():
		return {}
	return slides[_selected_slide_index] as Dictionary


# ---------------------------------------------------------------------------
# Public accessors (tests + future T7 wiring)
# ---------------------------------------------------------------------------

func get_deck() -> Dictionary:
	return _deck


func set_deck(deck: Dictionary) -> void:
	_deck = deck
	_selected_slide_index = 0
	_refresh_all()
