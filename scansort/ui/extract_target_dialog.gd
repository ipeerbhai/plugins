extends AcceptDialog
## Extract-target picker dialog — W5g.
##
## Shows registered directory destinations as the only valid targets. Emits
## `target_chosen` with the resolved absolute directory path, or `cancelled`
## if the user dismisses without choosing.
##
## Usage:
##   var dlg = preload("extract_target_dialog.gd").new()
##   dlg.set_destinations(dir_destinations_array)   # [{id, path, label, ...}]
##   add_child(dlg)
##   dlg.target_chosen.connect(_on_extract_target_chosen)
##   dlg.cancelled.connect(...)
##   dlg.popup_centered()
##
## No class_name — off-tree plugin script; use preload().

## Emitted when the user picks a registered target directory.
## path: absolute filesystem directory path.
signal target_chosen(path: String)

## Emitted when the user cancels without choosing.
signal cancelled

const _UiScale: Script = preload("ui_scale.gd")

## Registered directory destinations passed by the panel.
var _destinations: Array = []

## The currently chosen path (empty = nothing chosen yet).
var _chosen_path: String = ""

## Widgets.
var _list: ItemList         = null
var _path_label: Label      = null
var _ok_btn: Button         = null


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Extract To…"
	min_size = Vector2i(480, 280)
	ok_button_text = "Extract"
	_ok_btn = get_ok_button()
	if _ok_btn != null:
		_ok_btn.disabled = true

	confirmed.connect(_on_confirmed)
	canceled.connect(_on_cancelled)

	_build_ui()


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Choose a directory destination:"
	vbox.add_child(lbl)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(440, 140)
	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(func(_idx: int) -> void:
		if _ok_btn != null and not _ok_btn.disabled:
			_on_confirmed()
			hide()
	)
	vbox.add_child(_list)

	_path_label = Label.new()
	_path_label.text = ""
	_path_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55, 1.0))
	_path_label.clip_text = true
	vbox.add_child(_path_label)

	# Populate from any destinations set before _ready() ran (set_destinations
	# is documented as call-before-popup, which is typically before _ready).
	_populate_list()


## Populate the destination list.  Safe to call before OR after _ready();
## if set before the list widget exists, _build_ui() repopulates from the
## stored _destinations once the widget is built.
func set_destinations(dests: Array) -> void:
	_destinations = dests
	_populate_list()


## Fill _list from _destinations.  No-op until the list widget exists.
func _populate_list() -> void:
	if _list == null:
		return
	_list.clear()
	if _destinations.is_empty():
		_list.add_item("No directory destinations registered")
		_list.set_item_disabled(0, true)
		return
	for dest: Dictionary in _destinations:
		var label: String = str(dest.get("label", dest.get("path", str(dest.get("id", "?")))))
		var path: String  = str(dest.get("path", ""))
		_list.add_item("%s  [%s]" % [label, path])


func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _destinations.size():
		return
	_chosen_path = str(_destinations[idx].get("path", ""))
	_path_label.text = _chosen_path
	if _ok_btn != null:
		_ok_btn.disabled = _chosen_path.is_empty()


func _on_confirmed() -> void:
	if _chosen_path.is_empty():
		return
	target_chosen.emit(_chosen_path)


func _on_cancelled() -> void:
	cancelled.emit()


## Synchronous helper for tests: directly set the chosen path and fire target_chosen.
## Not called in production code — only used by the smoke test mock.
func _test_pick(path: String) -> void:
	_chosen_path = path
	target_chosen.emit(path)
