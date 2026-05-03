class_name Presentation_SlideListPanel
extends VBoxContainer
## Left pane of the slide editor — scrollable list of slides + reorder controls.
##
## Builds its UI in code (matches PCBEditor convention; see memory
## project_minerva_ui_conventions.md).
##
## Owns no model state — the parent panel hands it the deck via set_deck()
## and the selected index via set_selected_index(). Mutation happens on the
## parent via signals.

signal slide_selected(index: int)
signal add_slide_requested
signal delete_slide_requested(index: int)
signal move_slide_requested(from_index: int, to_index: int)

const _SlideModel: Script = preload("slide_model.gd")

const PANEL_MIN_WIDTH: int = 200

var _scroll: ScrollContainer = null
var _list_box: VBoxContainer = null
var _add_btn: Button = null
var _del_btn: Button = null
var _up_btn: Button = null
var _down_btn: Button = null

var _deck: Dictionary = {}
var _selected_index: int = -1
# Buttons-per-row, indexed by slide index; rebuilt when the deck changes.
var _row_buttons: Array[Button] = []


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_MIN_WIDTH, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()


func _build_ui() -> void:
	var header := Label.new()
	header.text = "Slides"
	add_child(header)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list_box)

	# Reorder + add/delete controls.
	var ctrls := HBoxContainer.new()
	ctrls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(ctrls)

	_add_btn = Button.new()
	_add_btn.text = "+ Slide"
	_add_btn.tooltip_text = "Add a new slide after the current one"
	_add_btn.pressed.connect(func() -> void: add_slide_requested.emit())
	ctrls.add_child(_add_btn)

	_del_btn = Button.new()
	_del_btn.text = "−"
	_del_btn.tooltip_text = "Delete the selected slide"
	_del_btn.pressed.connect(_on_delete_pressed)
	ctrls.add_child(_del_btn)

	_up_btn = Button.new()
	_up_btn.text = "↑"
	_up_btn.tooltip_text = "Move the selected slide up"
	_up_btn.pressed.connect(_on_up_pressed)
	ctrls.add_child(_up_btn)

	_down_btn = Button.new()
	_down_btn.text = "↓"
	_down_btn.tooltip_text = "Move the selected slide down"
	_down_btn.pressed.connect(_on_down_pressed)
	ctrls.add_child(_down_btn)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func set_deck(deck: Dictionary) -> void:
	_deck = deck
	_rebuild_list()
	_refresh_button_state()


func set_selected_index(index: int) -> void:
	_selected_index = index
	# Update visual highlight on the row buttons.
	for i in range(_row_buttons.size()):
		var b := _row_buttons[i]
		# Use button_pressed as a sticky toggle to indicate selection.
		b.button_pressed = (i == index)
	_refresh_button_state()


# ---------------------------------------------------------------------------
# UI building (data → controls)
# ---------------------------------------------------------------------------

func _rebuild_list() -> void:
	# Clean out the previous rows.
	for child in _list_box.get_children():
		child.queue_free()
	_row_buttons.clear()

	var slides: Array = _deck.get("slides", []) as Array
	for i in range(slides.size()):
		var slide: Dictionary = slides[i] as Dictionary
		var row := _build_row(i, slide)
		_list_box.add_child(row)


func _build_row(index: int, slide: Dictionary) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.text = _row_label(index, slide)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = "Click to view this slide"
	# Capture index by value (Godot lambdas close by reference; bind index).
	b.pressed.connect(func() -> void: _on_row_pressed(index))
	if index == _selected_index:
		b.button_pressed = true
	_row_buttons.append(b)
	return b


func _row_label(index: int, slide: Dictionary) -> String:
	var title: String = str(slide.get("title", ""))
	if title == "":
		return "Slide %d" % (index + 1)
	return "%d. %s" % [index + 1, title]


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_row_pressed(index: int) -> void:
	# Toggle button stays pressed; emit selection so parent updates state and
	# calls back into set_selected_index() with the canonical value.
	slide_selected.emit(index)


func _on_delete_pressed() -> void:
	if _selected_index < 0:
		return
	var slide_count: int = (_deck.get("slides", []) as Array).size()
	if slide_count <= 1:
		# Don't allow deleting the last slide; UI affordance only.
		return
	delete_slide_requested.emit(_selected_index)


func _on_up_pressed() -> void:
	if _selected_index <= 0:
		return
	move_slide_requested.emit(_selected_index, _selected_index - 1)


func _on_down_pressed() -> void:
	var slide_count: int = (_deck.get("slides", []) as Array).size()
	if _selected_index < 0 or _selected_index >= slide_count - 1:
		return
	move_slide_requested.emit(_selected_index, _selected_index + 1)


func _refresh_button_state() -> void:
	if _del_btn == null:
		return
	var slide_count: int = (_deck.get("slides", []) as Array).size()
	_del_btn.disabled = (_selected_index < 0 or slide_count <= 1)
	_up_btn.disabled = (_selected_index <= 0)
	_down_btn.disabled = (_selected_index < 0 or _selected_index >= slide_count - 1)
