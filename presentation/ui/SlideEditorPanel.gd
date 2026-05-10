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
const _Host: Script = preload("presentation_tile_annotation_host.gd")

# Icon UIDs reused from Minerva's annotation toolbar / graphics editor / pcb
# editor asset library. See AnnotationToolbar.gd:94-99 for the same pattern.
const _ICON_UID_SELECT: String       = "uid://eckoinneympm"  # graphics_editor/select_tool_icon_24.png
const _ICON_UID_TEXT: String         = "uid://obermhq5hkgs"  # graphics_editor/text_tool_icon_24.png
const _ICON_UID_IMAGE: String        = "uid://cfi5hr0xyb2lw"  # generate_image/generate_image_icon_24.png
const _ICON_UID_SPREADSHEET: String  = "uid://cu670w2c46b66"  # spreadsheet/spreadsheet_icon_white_no_bg_24.png
const _ICON_UID_PREV: String         = "uid://dbeu0c8yh5jg2"  # arrow_left.svg
const _ICON_UID_NEXT: String         = "uid://dr5q0d4id5wst"  # arrow_right.svg
const _ICON_UID_ADD: String          = "uid://cnudc2tu7nyln"  # plus_icons/add_24.svg
const _ICON_UID_REMOVE: String       = "uid://cnvsja4y7kp1m"  # remove_minus.png
const _ICON_UID_BACKGROUND: String   = "uid://b05e37s8h1cni"  # color_picker_pipette.svg
const _ICON_UID_RESET_ZOOM: String   = "uid://1q2kkovqy5qk"  # pcb_editor/expand-arrows_white_24.png
const _ICON_UID_FULLSCREEN: String   = "uid://cb4ksle4s2pci"  # fullscreen.png

# ResponsiveContainer is a Minerva-core Control. Use a string-path preload so
# the off-tree plugin parser doesn't choke on the class_name reference.
const _ResponsiveContainer: Script = preload("res://Scripts/UI/Controls/responsive_container.gd")

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
var _annotation_host: AnnotationHost = null
var _bg_popup: AcceptDialog = null
var _bg_color_edit: LineEdit = null
var _fullscreen_window: Window = null
var _fullscreen_preview: Control = null   # Presentation_SlideCanvas inside the fullscreen Window

# Editor name we registered the host under in AnnotationHostRegistry, so we can
# unregister cleanly on panel unload.
var _registered_editor_name: String = ""


func _ready() -> void:
	if _deck.is_empty():
		_deck = _SlideModel.make_deck()
	_build_ui()
	_refresh_all()


## Public read-only accessor for the slide currently shown in the canvas.
## Used by the MCP get_state tool so external observers (agents, HITL) can
## answer "what slide is the user on?".
func get_selected_slide_index() -> int:
	return _selected_slide_index


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
	_canvas.slide_rect_changed.connect(func(_rect: Rect2) -> void: _sync_annotation_host_rect())

	_annotation_host = _Host.new()
	_annotation_host.configure_surface(false, true)
	_annotation_host.selection_changed.connect(_on_annotation_selection_changed)


func _build_toolbar() -> Control:
	# Wrap the toolbar HBox in a ResponsiveContainer so we can hide the verbose
	# slide-N/N and zoom-% labels at narrow widths without touching the buttons.
	# Explicit Container type — `:=` can't infer through preloaded Script .new().
	var responsive: Container = _ResponsiveContainer.new()
	responsive.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	responsive.custom_minimum_size = Vector2(0, 32)
	# String-based connect: parser only sees Container, not the subclass signal.
	responsive.connect("width_class_changed", _on_toolbar_width_class_changed)

	var bar := HBoxContainer.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	responsive.add_child(bar)

	# ── Tool palette ────────────────────────────────────────────────────
	for entry in [
		[_SlideCanvas.Tool.SELECT, "Select", _ICON_UID_SELECT],
		[_SlideCanvas.Tool.TEXT, "Text", _ICON_UID_TEXT],
		[_SlideCanvas.Tool.IMAGE, "Image", _ICON_UID_IMAGE],
		[_SlideCanvas.Tool.SHEET, "Spreadsheet", _ICON_UID_SPREADSHEET],
	]:
		var tool_id: int = entry[0]
		var label: String = entry[1]
		var icon_uid: String = entry[2]
		var b := Button.new()
		_apply_icon(b, icon_uid, label)
		b.toggle_mode = true
		b.pressed.connect(func() -> void: _on_tool_button_pressed(tool_id))
		bar.add_child(b)
		_tool_btns[tool_id] = b

	bar.add_child(VSeparator.new())

	# ── Slide nav ────────────────────────────────────────────────────────
	_prev_btn = Button.new()
	_apply_icon(_prev_btn, _ICON_UID_PREV, "Previous slide")
	_prev_btn.pressed.connect(_on_prev_slide)
	bar.add_child(_prev_btn)

	_slide_label = Label.new()
	_slide_label.text = "0 / 0"
	_slide_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_slide_label)

	_next_btn = Button.new()
	_apply_icon(_next_btn, _ICON_UID_NEXT, "Next slide")
	_next_btn.pressed.connect(_on_next_slide)
	bar.add_child(_next_btn)

	_add_slide_btn = Button.new()
	_apply_icon(_add_slide_btn, _ICON_UID_ADD, "Add a new slide after the current one")
	_add_slide_btn.pressed.connect(_on_add_slide)
	bar.add_child(_add_slide_btn)

	_del_slide_btn = Button.new()
	_apply_icon(_del_slide_btn, _ICON_UID_REMOVE, "Delete the current slide")
	_del_slide_btn.pressed.connect(_on_del_slide)
	bar.add_child(_del_slide_btn)

	bar.add_child(VSeparator.new())

	# ── Slide-level actions ─────────────────────────────────────────────
	_bg_btn = Button.new()
	_apply_icon(_bg_btn, _ICON_UID_BACKGROUND, "Set the slide background color or image")
	_bg_btn.pressed.connect(_on_bg_pressed)
	bar.add_child(_bg_btn)

	# ── Spacer ───────────────────────────────────────────────────────────
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	# ── Zoom controls ────────────────────────────────────────────────────
	_zoom_label = Label.new()
	_zoom_label.text = "100%"
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_zoom_label)

	_reset_zoom_btn = Button.new()
	_apply_icon(_reset_zoom_btn, _ICON_UID_RESET_ZOOM, "Fit slide to canvas (resets pan + zoom)")
	_reset_zoom_btn.pressed.connect(_on_reset_zoom_pressed)
	bar.add_child(_reset_zoom_btn)

	# ── Fullscreen ───────────────────────────────────────────────────────
	_fullscreen_btn = Button.new()
	_apply_icon(_fullscreen_btn, _ICON_UID_FULLSCREEN, "Open a near-fullscreen preview of the current slide (Esc to close)")
	_fullscreen_btn.pressed.connect(_on_fullscreen_pressed)
	bar.add_child(_fullscreen_btn)

	return responsive


## Apply an icon to a button. Sets tooltip_text from the human label so hover
## still discloses the action. Falls back to text if the icon UID fails to load.
func _apply_icon(btn: Button, uid: String, tooltip: String) -> void:
	btn.tooltip_text = tooltip
	var tex := load(uid) as Texture2D
	if tex != null:
		btn.icon = tex
	else:
		# Fallback: keep the text so the button is still usable.
		btn.text = tooltip


## ResponsiveContainer signal: hide verbose labels when the panel is narrow so
## the icon-only toolbar fits without horizontal overflow.
func _on_toolbar_width_class_changed(new_class: StringName) -> void:
	var compact: bool = (new_class == _ResponsiveContainer.CLASS_XS or new_class == _ResponsiveContainer.CLASS_SM)
	if _slide_label != null:
		_slide_label.visible = not compact
	if _zoom_label != null:
		_zoom_label.visible = not compact


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


## Editor-chrome hook (MinervaPluginPanel virtual). This returns an annotation-only
## host; the canvas keeps a separate tile-only host for presentation object
## transforms so the annotation panel cannot select slide tiles.
func get_annotation_host() -> RefCounted:
	return _annotation_host


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
# Editable plugin notes — DCR 019df4dc365f
# ---------------------------------------------------------------------------

## Plugin → Note: emit a plugin_data shape that round-trips back into this
## panel via _on_panel_restore_from_note. Host backfills preview_image with
## a panel screenshot if we omit it (see Editor._create_plugin_scene_note).
func _on_panel_create_note_request(ctx: Dictionary) -> Dictionary:
	var slides_count: int = (_deck.get("slides", []) as Array).size()
	var alt_text: String = "Presentation deck"
	if slides_count > 0:
		alt_text = "Slide %d of %d" % [_selected_slide_index + 1, slides_count]
	return {
		"kind": "plugin_data",
		"plugin_id": "presentation",
		"panel_name": String(ctx.get("panel_name", "SlideEditorPanel")),
		"payload": {
			"version": 1,
			"deck": _deck.duplicate(true),
			"selected_slide": _selected_slide_index,
		},
		"preview_alt_text": alt_text,
	}


## Note → Plugin: restore the deck and selected slide from the saved payload.
## Returns false on version mismatch / invalid deck so the host can toast and
## leave the panel blank.
func _on_panel_restore_from_note(payload: Dictionary) -> bool:
	if int(payload.get("version", 0)) != 1:
		push_warning("[presentation] restore_from_note: unsupported payload version %s" % str(payload.get("version", null)))
		return false
	var deck_v: Variant = payload.get("deck", null)
	if not (deck_v is Dictionary):
		push_warning("[presentation] restore_from_note: payload.deck is not a Dictionary")
		return false
	var deck: Dictionary = deck_v as Dictionary
	var errors: Array = _SlideModel.validate_deck(deck)
	if errors.size() > 0:
		push_warning("[presentation] restore_from_note: deck failed validation: %s" % str(errors))
		return false
	_deck = deck
	var slides: Array = deck.get("slides", []) as Array
	var sel: int = int(payload.get("selected_slide", 0))
	_selected_slide_index = clampi(sel, 0, max(0, slides.size() - 1))
	_refresh_all()
	return true


## Plugin → LLM: emit canonical MultimodalPayload for chat injection. Per
## slide: one text part (title + outline), one image part per image tile,
## one text part per spreadsheet tile (CSV-ish — much cheaper than rasterising
## a whole grid). Provider adapters (work_item 019df4ebf896) translate this
## into per-provider wire formats.
func _on_panel_render_for_llm(_ctx: Dictionary) -> Array:
	var parts: Array = []
	var slides: Array = _deck.get("slides", []) as Array
	for i in range(slides.size()):
		var slide: Dictionary = slides[i] as Dictionary
		var slide_text: String = _slide_to_llm_text(i, slide)
		if not slide_text.is_empty():
			parts.append({"type": "text", "text": slide_text})
		var tiles: Array = slide.get("tiles", []) as Array
		for tile_v in tiles:
			if not (tile_v is Dictionary):
				continue
			var tile: Dictionary = tile_v as Dictionary
			# `match` patterns can't be const-references through preloaded
			# scripts (they bind as locals), so dispatch by string compare.
			var kind: String = String(tile.get("kind", ""))
			if kind == _SlideModel.TILE_IMAGE:
				var img: Image = _image_tile_to_image(tile)
				if img != null:
					var alt: String = "Image on slide %d" % (i + 1)
					parts.append({"type": "image", "image": img, "alt": alt})
			elif kind == _SlideModel.TILE_SPREADSHEET:
				var csv: String = _spreadsheet_tile_to_text(tile)
				if not csv.is_empty():
					parts.append({"type": "text", "text": "Spreadsheet on slide %d:\n%s" % [i + 1, csv]})
			# Text tiles fold into slide_text above; color/background tiles
			# aren't useful LLM context.
	return parts


## Compose the textual representation of a slide for LLM consumption: title
## (if present), then each text tile's content with its text_mode prefix
## already baked in. We don't re-derive bullet glyphs here — the renderer
## owns that — so the LLM sees the same ASCII the user typed.
func _slide_to_llm_text(idx: int, slide: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("Slide %d:" % (idx + 1))
	var title: String = String(slide.get("title", ""))
	if not title.is_empty():
		lines.append(title)
	var tiles: Array = slide.get("tiles", []) as Array
	for tile_v in tiles:
		if not (tile_v is Dictionary):
			continue
		var tile: Dictionary = tile_v as Dictionary
		if String(tile.get("kind", "")) == _SlideModel.TILE_TEXT:
			var content: String = String(tile.get("content", "")).strip_edges()
			if not content.is_empty():
				lines.append(content)
	if lines.size() <= 1:
		return ""
	return "\n".join(lines)


## Decode an image tile's base64 src into a Godot Image. Returns null on
## decode failure (LLM payload simply omits the image part).
func _image_tile_to_image(tile: Dictionary) -> Image:
	var src: String = String(tile.get("src", ""))
	if src.is_empty():
		return null
	var bytes: PackedByteArray = Marshalls.base64_to_raw(src)
	if bytes.is_empty():
		return null
	var img: = Image.new()
	if img.load_png_from_buffer(bytes) == OK:
		return img
	if img.load_jpg_from_buffer(bytes) == OK:
		return img
	if img.load_webp_from_buffer(bytes) == OK:
		return img
	return null


## Flatten a spreadsheet tile to a tab-separated grid (CSV-ish but tab-sep,
## which is friendlier in chat output and avoids quoting comma-bearing values).
func _spreadsheet_tile_to_text(tile: Dictionary) -> String:
	var cells_v: Variant = tile.get("cells", [])
	if not (cells_v is Array):
		return ""
	var rows: Array = cells_v as Array
	var lines: PackedStringArray = PackedStringArray()
	for row_v in rows:
		if not (row_v is Array):
			continue
		var row: Array = row_v as Array
		var fields: PackedStringArray = PackedStringArray()
		for cell_v in row:
			# str() (not String()) — cell.value can be int/float/bool, and the
			# String() constructor rejects non-String Variants in Godot 4.
			if cell_v is Dictionary:
				fields.append(str((cell_v as Dictionary).get("value", "")))
			else:
				fields.append(str(cell_v))
		lines.append("\t".join(fields))
	return "\n".join(lines)


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
	if _annotation_host != null:
		_annotation_host.set_slide(slide)
		_sync_annotation_host_rect()

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
	if _annotation_host != null:
		_annotation_host.notify_changed()


# ---------------------------------------------------------------------------
# Toolbar handlers
# ---------------------------------------------------------------------------

func _on_canvas_tool_changed(tool: int) -> void:
	for tool_id in _tool_btns.keys():
		(_tool_btns[tool_id] as Button).button_pressed = (tool_id == tool)


func _on_tool_button_pressed(tool: int) -> void:
	_clear_annotation_tool()
	_canvas.set_tool(tool)
	if tool == _SlideCanvas.Tool.SELECT:
		_canvas.set_selected_tile_id("")
	_on_canvas_tool_changed(_canvas.get_tool())


func _clear_annotation_tool() -> void:
	var overlay := find_child("PlatformAnnotationOverlay", false, false)
	if overlay != null and overlay.has_method("clear_active_tool"):
		overlay.clear_active_tool()
	var dock: Node = null
	var cursor: Node = self
	while cursor != null and dock == null:
		dock = cursor.find_child("AnnotationDockPane", true, false)
		cursor = cursor.get_parent()
	if dock != null and dock.has_method("clear_active_tool"):
		dock.clear_active_tool()


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
	win.title = "Slide preview — ←/→ navigate, Esc to close"
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
	# Defer set_slide until preview's _ready has run — _content_layer is built
	# there and set_slide → _rebuild_views() crashes on null otherwise.
	preview.ready.connect(preview.set_slide.bind(slide), CONNECT_ONE_SHOT)
	win.add_child(preview)
	# Esc / WM-close → free.
	win.close_requested.connect(func() -> void:
		win.queue_free()
		_fullscreen_window = null
		_fullscreen_preview = null
	)
	win.window_input.connect(_on_fullscreen_window_input)
	add_child(win)
	_fullscreen_window = win
	_fullscreen_preview = preview
	win.popup_centered()


func _on_fullscreen_window_input(event: InputEvent) -> void:
	if _fullscreen_window == null or not is_instance_valid(_fullscreen_window):
		return
	if event is InputEventKey and event.pressed:
		var key: int = (event as InputEventKey).keycode
		match key:
			KEY_ESCAPE:
				_fullscreen_window.queue_free()
				_fullscreen_window = null
				_fullscreen_preview = null
			KEY_RIGHT, KEY_DOWN, KEY_SPACE, KEY_PAGEDOWN, KEY_ENTER, KEY_KP_ENTER:
				_step_fullscreen_slide(1)
			KEY_LEFT, KEY_UP, KEY_PAGEUP, KEY_BACKSPACE:
				_step_fullscreen_slide(-1)
			KEY_HOME:
				_jump_fullscreen_slide(0)
			KEY_END:
				var last: int = (_deck.get("slides", []) as Array).size() - 1
				_jump_fullscreen_slide(last)
	elif event is InputEventMouseButton and event.pressed:
		var btn: int = (event as InputEventMouseButton).button_index
		match btn:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_WHEEL_DOWN:
				_step_fullscreen_slide(1)
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL_UP:
				_step_fullscreen_slide(-1)


func _step_fullscreen_slide(delta: int) -> void:
	var slides: Array = _deck.get("slides", []) as Array
	if slides.is_empty():
		return
	var target: int = clampi(_selected_slide_index + delta, 0, slides.size() - 1)
	_jump_fullscreen_slide(target)


func _jump_fullscreen_slide(target_index: int) -> void:
	var slides: Array = _deck.get("slides", []) as Array
	if slides.is_empty():
		return
	target_index = clampi(target_index, 0, slides.size() - 1)
	if target_index == _selected_slide_index:
		return
	_selected_slide_index = target_index
	if _fullscreen_preview != null and is_instance_valid(_fullscreen_preview):
		_fullscreen_preview.set_slide(slides[target_index] as Dictionary)
	# Keep the editor underneath in sync so closing fullscreen lands on the
	# same slide the presenter ended on.
	_refresh_all()


# ---------------------------------------------------------------------------
# Canvas signal handlers
# ---------------------------------------------------------------------------

func _on_tile_selected(_tile_id: String) -> void:
	# Inspector-less; nothing to surface beyond what the canvas already shows.
	if not _tile_id.is_empty() and _annotation_host != null:
		_annotation_host.set_selected_annotation_id("")


func _on_annotation_selection_changed(annotation_id: String) -> void:
	if annotation_id.is_empty() or _canvas == null:
		return
	_canvas.set_selected_tile_id("")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _current_slide() -> Dictionary:
	var slides: Array = _deck.get("slides", []) as Array
	if _selected_slide_index < 0 or _selected_slide_index >= slides.size():
		return {}
	return slides[_selected_slide_index] as Dictionary


func _sync_annotation_host_rect() -> void:
	if _annotation_host == null or _canvas == null or not _canvas.has_method("get_slide_rect"):
		return
	var canvas_global := _canvas.get_global_transform_with_canvas().origin
	var panel_global := get_global_transform_with_canvas().origin
	var canvas_in_panel := canvas_global - panel_global
	var canvas_rect: Rect2 = _canvas.get_slide_rect()
	_annotation_host.set_slide_rect(Rect2(canvas_in_panel + canvas_rect.position, canvas_rect.size))


# ---------------------------------------------------------------------------
# Public accessors (tests + future T7 wiring)
# ---------------------------------------------------------------------------

func get_deck() -> Dictionary:
	return _deck


## Replace the whole deck (used by MCP _commit_target after edits, and by
## host on initial load). Preserves the user's current slide selection where
## possible — MCP mutations would otherwise yank the panel back to slide 0
## on every edit. If the prior selection points past the new last slide
## (e.g. a slide was removed), clamp; otherwise leave it alone.
func set_deck(deck: Dictionary) -> void:
	_deck = deck
	var slides_count: int = (deck.get("slides", []) as Array).size()
	_selected_slide_index = clampi(_selected_slide_index, 0, max(0, slides_count - 1))
	_refresh_all()


# ---------------------------------------------------------------------------
# host_owned_save panel-state IPC responder (broker T6 R0)
# ---------------------------------------------------------------------------
#
# Minerva's PluginScenePanelBroker can request our state (so host capability
# host.documents.get_state works for plugin-scene editors that don't carry a
# canonical DocumentBuffer) and apply state back to us (host.documents.
# set_state). The contract is: receive("host_owned_save.get_request"|
# "set_request", payload), respond by emitting our `request` signal with
# channel="host_owned_save.response" and the matching request_id.

func receive(channel: String, payload: Dictionary) -> void:
	match channel:
		"host_owned_save.get_request":
			_handle_host_owned_save_get(payload)
		"host_owned_save.set_request":
			_handle_host_owned_save_set(payload)
		_:
			# Other channels handled by base class or ignored. Keep the
			# default behaviour rather than swallowing unknowns silently.
			pass


func _handle_host_owned_save_get(payload: Dictionary) -> void:
	var request_id: String = str(payload.get("request_id", ""))
	if request_id.is_empty():
		push_warning("[Presentation_SlideEditorPanel] host_owned_save.get_request missing request_id")
		return
	request.emit("host_owned_save.response", {
		"request_id": request_id,
		"success": true,
		"state": _deck.duplicate(true),
	}, "")


func _handle_host_owned_save_set(payload: Dictionary) -> void:
	var request_id: String = str(payload.get("request_id", ""))
	if request_id.is_empty():
		push_warning("[Presentation_SlideEditorPanel] host_owned_save.set_request missing request_id")
		return
	var state_v: Variant = payload.get("state", null)
	if not (state_v is Dictionary):
		request.emit("host_owned_save.response", {
			"request_id": request_id,
			"success": false,
			"error_code": "schema_validation_failed",
			"error_message": "state must be a Dictionary",
		}, "")
		return
	set_deck((state_v as Dictionary).duplicate(true))
	# Mark the tab dirty so host saves on next checkpoint — same contract as
	# the legacy MCP mutator path (panel.emit_signal("content_changed")).
	emit_signal("content_changed")
	request.emit("host_owned_save.response", {
		"request_id": request_id,
		"success": true,
	}, "")
