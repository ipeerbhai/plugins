class_name Presentation_TileInspector
extends VBoxContainer
## Right pane of the slide editor — property inspector for the selected tile.
##
## Shows a kind-specific set of editable fields. Mutations emit
## `tile_property_changed(tile_id, key, value)` so the parent panel can
## update the deck dict and trigger save tracking. The inspector itself
## holds no model state beyond the currently-selected tile dict.
##
## v1 affordances:
##   - text:        text_mode dropdown + multi-line content (BBCode passes through)
##   - image:       src preview + "Replace…" file picker → base64 embed
##   - spreadsheet: rows/cols spinboxes + header_row/header_col toggles
##                  ("Edit cells…" modal is deferred — see stretch task)
##
## Slide-level controls:
##   - Slide title text field (omit-when-empty)
##   - Background kind + value (color hex or image src)

signal tile_property_changed(tile_id: String, key: String, value: Variant)
signal slide_property_changed(slide_id: String, key: String, value: Variant)
signal slide_background_changed(slide_id: String, bg: Dictionary)

const _SlideModel: Script = preload("slide_model.gd")

const PANEL_MIN_WIDTH: int = 240

var _slide: Dictionary = {}
var _tile_id: String = ""
var _suppress_signals: bool = false   # while populating fields

# Sections: each one is a VBoxContainer that we show/hide based on context.
var _slide_section: VBoxContainer = null
var _slide_title_edit: LineEdit = null
var _bg_kind_option: OptionButton = null
var _bg_value_edit: LineEdit = null
var _bg_pick_image_btn: Button = null

var _tile_section: VBoxContainer = null
var _no_selection_label: Label = null

# Text-tile fields.
var _text_section: VBoxContainer = null
var _text_mode_option: OptionButton = null
var _text_content_edit: TextEdit = null

# Image-tile fields.
var _image_section: VBoxContainer = null
var _image_replace_btn: Button = null
var _image_status_label: Label = null

# Spreadsheet-tile fields.
var _sheet_section: VBoxContainer = null
var _sheet_rows_spin: SpinBox = null
var _sheet_cols_spin: SpinBox = null
var _sheet_header_row_check: CheckBox = null
var _sheet_header_col_check: CheckBox = null
var _sheet_edit_btn: Button = null

# File pickers (lazy).
var _image_picker: FileDialog = null
var _bg_image_picker: FileDialog = null


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_MIN_WIDTH, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()
	_refresh()


func _build_ui() -> void:
	# Slide section (always visible).
	_slide_section = VBoxContainer.new()
	_slide_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_slide_section)

	var slide_header := Label.new()
	slide_header.text = "Slide"
	_slide_section.add_child(slide_header)

	var title_row := HBoxContainer.new()
	title_row.add_child(_make_label("Title:"))
	_slide_title_edit = LineEdit.new()
	_slide_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slide_title_edit.placeholder_text = "(untitled)"
	_slide_title_edit.text_changed.connect(_on_title_changed)
	title_row.add_child(_slide_title_edit)
	_slide_section.add_child(title_row)

	var bg_row := HBoxContainer.new()
	bg_row.add_child(_make_label("BG kind:"))
	_bg_kind_option = OptionButton.new()
	_bg_kind_option.add_item("color", 0)
	_bg_kind_option.add_item("image", 1)
	_bg_kind_option.item_selected.connect(_on_bg_kind_selected)
	bg_row.add_child(_bg_kind_option)
	_slide_section.add_child(bg_row)

	var bg_val_row := HBoxContainer.new()
	bg_val_row.add_child(_make_label("BG value:"))
	_bg_value_edit = LineEdit.new()
	_bg_value_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bg_value_edit.placeholder_text = "#hex (color) or base64 (image)"
	_bg_value_edit.text_changed.connect(_on_bg_value_changed)
	bg_val_row.add_child(_bg_value_edit)
	_slide_section.add_child(bg_val_row)

	_bg_pick_image_btn = Button.new()
	_bg_pick_image_btn.text = "Choose background image…"
	_bg_pick_image_btn.pressed.connect(_on_bg_pick_image_pressed)
	_slide_section.add_child(_bg_pick_image_btn)

	_slide_section.add_child(HSeparator.new())

	# Tile section (visible when a tile is selected).
	_tile_section = VBoxContainer.new()
	_tile_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_tile_section)

	var tile_header := Label.new()
	tile_header.text = "Tile"
	_tile_section.add_child(tile_header)

	_no_selection_label = Label.new()
	_no_selection_label.text = "(no tile selected)"
	_no_selection_label.modulate = Color(1, 1, 1, 0.6)
	_tile_section.add_child(_no_selection_label)

	_text_section = _build_text_section()
	_tile_section.add_child(_text_section)

	_image_section = _build_image_section()
	_tile_section.add_child(_image_section)

	_sheet_section = _build_sheet_section()
	_tile_section.add_child(_sheet_section)


func _build_text_section() -> VBoxContainer:
	var s := VBoxContainer.new()
	var mode_row := HBoxContainer.new()
	mode_row.add_child(_make_label("Mode:"))
	_text_mode_option = OptionButton.new()
	_text_mode_option.add_item("plain", 0)
	_text_mode_option.add_item("bullet", 1)
	_text_mode_option.add_item("numbered", 2)
	_text_mode_option.item_selected.connect(_on_text_mode_selected)
	mode_row.add_child(_text_mode_option)
	s.add_child(mode_row)

	s.add_child(_make_label("Content (BBCode: [b][/b] [i][/i] [s][/s]):"))
	_text_content_edit = TextEdit.new()
	_text_content_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_content_edit.custom_minimum_size = Vector2(0, 120)
	_text_content_edit.text_changed.connect(_on_text_content_changed)
	s.add_child(_text_content_edit)
	return s


func _build_image_section() -> VBoxContainer:
	var s := VBoxContainer.new()
	_image_status_label = Label.new()
	_image_status_label.text = "(no image set)"
	s.add_child(_image_status_label)
	_image_replace_btn = Button.new()
	_image_replace_btn.text = "Replace image…"
	_image_replace_btn.pressed.connect(_on_image_replace_pressed)
	s.add_child(_image_replace_btn)
	return s


func _build_sheet_section() -> VBoxContainer:
	var s := VBoxContainer.new()
	var rows_row := HBoxContainer.new()
	rows_row.add_child(_make_label("Rows:"))
	_sheet_rows_spin = SpinBox.new()
	_sheet_rows_spin.min_value = 1
	_sheet_rows_spin.max_value = 100
	_sheet_rows_spin.step = 1
	_sheet_rows_spin.value_changed.connect(_on_sheet_rows_changed)
	rows_row.add_child(_sheet_rows_spin)
	s.add_child(rows_row)

	var cols_row := HBoxContainer.new()
	cols_row.add_child(_make_label("Cols:"))
	_sheet_cols_spin = SpinBox.new()
	_sheet_cols_spin.min_value = 1
	_sheet_cols_spin.max_value = 26
	_sheet_cols_spin.step = 1
	_sheet_cols_spin.value_changed.connect(_on_sheet_cols_changed)
	cols_row.add_child(_sheet_cols_spin)
	s.add_child(cols_row)

	_sheet_header_row_check = CheckBox.new()
	_sheet_header_row_check.text = "Bold first row (header)"
	_sheet_header_row_check.toggled.connect(_on_sheet_header_row_toggled)
	s.add_child(_sheet_header_row_check)

	_sheet_header_col_check = CheckBox.new()
	_sheet_header_col_check.text = "Bold first column (header)"
	_sheet_header_col_check.toggled.connect(_on_sheet_header_col_toggled)
	s.add_child(_sheet_header_col_check)

	_sheet_edit_btn = Button.new()
	_sheet_edit_btn.text = "Edit cells… (coming soon)"
	_sheet_edit_btn.disabled = true
	_sheet_edit_btn.tooltip_text = "Modal SpreadsheetEditor wiring is deferred to a stretch task"
	s.add_child(_sheet_edit_btn)
	return s


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func set_slide(slide: Dictionary) -> void:
	_slide = slide
	# Selection persists if the same tile id still exists; otherwise clear.
	if _tile_id != "" and _SlideModel.find_tile(_slide, _tile_id) == null:
		_tile_id = ""
	_refresh()


func set_selected_tile_id(tile_id: String) -> void:
	_tile_id = tile_id
	_refresh()


# ---------------------------------------------------------------------------
# Refresh — populate fields from the current slide/tile dict
# ---------------------------------------------------------------------------

func _refresh() -> void:
	_suppress_signals = true
	_refresh_slide_section()
	_refresh_tile_section()
	_suppress_signals = false


func _refresh_slide_section() -> void:
	if _slide.is_empty():
		_slide_title_edit.editable = false
		_slide_title_edit.text = ""
		_bg_kind_option.disabled = true
		_bg_value_edit.editable = false
		_bg_pick_image_btn.disabled = true
		return
	_slide_title_edit.editable = true
	_slide_title_edit.text = str(_slide.get("title", ""))
	_bg_kind_option.disabled = false
	_bg_value_edit.editable = true
	_bg_pick_image_btn.disabled = false

	var bg: Dictionary = _slide.get("background", _SlideModel.BG_DEFAULT) as Dictionary
	var kind: String = str(bg.get("kind", _SlideModel.BG_COLOR))
	_bg_kind_option.select(0 if kind == _SlideModel.BG_COLOR else 1)
	# Don't echo the full base64 of an image bg into the LineEdit — too long.
	if kind == _SlideModel.BG_IMAGE:
		_bg_value_edit.text = "<base64 image>" if str(bg.get("value", "")) != "" else ""
		_bg_value_edit.editable = false
	else:
		_bg_value_edit.text = str(bg.get("value", "#ffffff"))
		_bg_value_edit.editable = true


func _refresh_tile_section() -> void:
	# Hide everything; the active branch turns its section back on.
	_text_section.visible = false
	_image_section.visible = false
	_sheet_section.visible = false
	_no_selection_label.visible = (_tile_id == "")

	if _tile_id == "":
		return
	var tile: Variant = _SlideModel.find_tile(_slide, _tile_id)
	if tile == null:
		return
	var t: Dictionary = tile
	match str(t.get("kind", "")):
		_SlideModel.TILE_TEXT:
			_text_section.visible = true
			var mode: String = str(t.get("text_mode", _SlideModel.TEXT_MODE_PLAIN))
			var idx: int = 0
			if mode == _SlideModel.TEXT_MODE_BULLET: idx = 1
			elif mode == _SlideModel.TEXT_MODE_NUMBERED: idx = 2
			_text_mode_option.select(idx)
			_text_content_edit.text = str(t.get("content", ""))
		_SlideModel.TILE_IMAGE:
			_image_section.visible = true
			# Post-phase-5 R3: src is a blob envelope, not a bare base64 String.
			var src_b64: String = _SlideModel.envelope_base64(t.get("src", {}))
			_image_status_label.text = "(no image set)" if src_b64.is_empty() else "Image set (%d chars base64)" % src_b64.length()
		_SlideModel.TILE_SPREADSHEET:
			_sheet_section.visible = true
			_sheet_rows_spin.value = float(t.get("rows", 1))
			_sheet_cols_spin.value = float(t.get("cols", 1))
			_sheet_header_row_check.button_pressed = bool(t.get("header_row", false))
			_sheet_header_col_check.button_pressed = bool(t.get("header_col", false))


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_title_changed(new_text: String) -> void:
	if _suppress_signals or _slide.is_empty():
		return
	slide_property_changed.emit(str(_slide.get("id", "")), "title", new_text)


func _on_bg_kind_selected(idx: int) -> void:
	if _suppress_signals or _slide.is_empty():
		return
	var kind: String = _SlideModel.BG_COLOR if idx == 0 else _SlideModel.BG_IMAGE
	var bg: Dictionary = (_slide.get("background", _SlideModel.BG_DEFAULT) as Dictionary).duplicate(true)
	bg["kind"] = kind
	if kind == _SlideModel.BG_COLOR and not (str(bg.get("value", "")).begins_with("#")):
		bg["value"] = "#ffffff"
	slide_background_changed.emit(str(_slide.get("id", "")), bg)


func _on_bg_value_changed(text: String) -> void:
	if _suppress_signals or _slide.is_empty():
		return
	var bg: Dictionary = (_slide.get("background", _SlideModel.BG_DEFAULT) as Dictionary).duplicate(true)
	if str(bg.get("kind", _SlideModel.BG_COLOR)) == _SlideModel.BG_COLOR:
		# Only emit when the field is a syntactically valid hex; partial typing
		# (e.g. "#1") otherwise spams the canvas with bad parses.
		if text.begins_with("#") and (text.length() == 4 or text.length() == 7 or text.length() == 9):
			bg["value"] = text
			slide_background_changed.emit(str(_slide.get("id", "")), bg)


func _on_bg_pick_image_pressed() -> void:
	_open_image_picker(true)


func _on_text_mode_selected(idx: int) -> void:
	if _suppress_signals or _tile_id == "":
		return
	var mode: String = _SlideModel.TEXT_MODE_PLAIN
	if idx == 1: mode = _SlideModel.TEXT_MODE_BULLET
	elif idx == 2: mode = _SlideModel.TEXT_MODE_NUMBERED
	tile_property_changed.emit(_tile_id, "text_mode", mode)


func _on_text_content_changed() -> void:
	if _suppress_signals or _tile_id == "":
		return
	tile_property_changed.emit(_tile_id, "content", _text_content_edit.text)


func _on_image_replace_pressed() -> void:
	_open_image_picker(false)


func _on_sheet_rows_changed(v: float) -> void:
	if _suppress_signals or _tile_id == "":
		return
	tile_property_changed.emit(_tile_id, "rows", int(v))


func _on_sheet_cols_changed(v: float) -> void:
	if _suppress_signals or _tile_id == "":
		return
	tile_property_changed.emit(_tile_id, "cols", int(v))


func _on_sheet_header_row_toggled(on: bool) -> void:
	if _suppress_signals or _tile_id == "":
		return
	tile_property_changed.emit(_tile_id, "header_row", on)


func _on_sheet_header_col_toggled(on: bool) -> void:
	if _suppress_signals or _tile_id == "":
		return
	tile_property_changed.emit(_tile_id, "header_col", on)


# ---------------------------------------------------------------------------
# File pickers — single-shot, base64-encode result, emit appropriate signal
# ---------------------------------------------------------------------------

func _open_image_picker(is_background: bool) -> void:
	var picker: FileDialog = FileDialog.new()
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.filters = PackedStringArray(["*.png ; PNG", "*.jpg ; JPEG", "*.jpeg ; JPEG"])
	picker.title = "Choose background image" if is_background else "Choose tile image"
	picker.size = Vector2i(640, 480)
	add_child(picker)
	picker.file_selected.connect(func(path: String) -> void:
		_handle_image_picked(path, is_background)
		picker.queue_free()
	)
	picker.canceled.connect(func() -> void: picker.queue_free())
	picker.popup_centered()


func _handle_image_picked(path: String, is_background: bool) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[presentation] could not open image at %s" % path)
		return
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.size() == 0:
		push_warning("[presentation] image at %s is empty" % path)
		return
	var b64: String = Marshalls.raw_to_base64(bytes)
	var ct: String = _SlideModel.sniff_image_content_type(bytes)
	var envelope: Dictionary = _SlideModel.make_blob_envelope(b64, ct)
	if is_background:
		var bg: Dictionary = {"kind": _SlideModel.BG_IMAGE, "value": envelope}
		slide_background_changed.emit(str(_slide.get("id", "")), bg)
	else:
		if _tile_id != "":
			tile_property_changed.emit(_tile_id, "src", envelope)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(70, 0)
	return l
