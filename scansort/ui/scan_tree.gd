extends Tree
## Unified nested-tree component for scansort panes.
##
## Renders a nested folder/file hierarchy from a pluggable provider
## (see scan_tree_provider.gd). The same component is used in three places —
## the source pane, the vault destination pane, and the disk destination
## pane — the only difference is which provider is bound.
##
## Columns: 0 = checkbox (file rows only), 1 = name, 2 = date.
##
## Folder rows are structural: not checkable, not selectable for action.
## File rows are checkable (for bulk operations) and selectable.
##
## No class_name — off-tree plugin script; loaded via preload() from
## ScansortPanel.gd.

## Emitted on double-click of a file row. key is the node's stable key.
signal file_activated(key: String)

## Emitted when the single-selected row changes to a file row.
signal selection_changed(key: String)

## Emitted whenever any checkbox is toggled.
signal check_toggled

# Column indices.
const COL_CHECK := 0
const COL_NAME := 1
const COL_DATE := 2

const COLOR_FOLDER := Color(0.9, 0.85, 0.6)   # warm yellow
const COLOR_FILE := Color(0.78, 0.85, 0.78)   # soft green

var _provider: Object = null


func _ready() -> void:
	hide_root = true
	columns = 3
	set_column_expand(COL_CHECK, false)
	set_column_custom_minimum_width(COL_CHECK, 30)
	set_column_expand(COL_NAME, true)
	set_column_clip_content(COL_NAME, true)
	set_column_expand(COL_DATE, false)
	set_column_custom_minimum_width(COL_DATE, 84)
	select_mode = Tree.SELECT_ROW
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_selected.connect(_on_item_selected)
	item_edited.connect(_on_item_edited)
	gui_input.connect(_on_gui_input)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Bind a provider (see scan_tree_provider.gd). Call refresh() to populate.
func set_provider(provider: Object) -> void:
	_provider = provider


## Repopulate from the bound provider. Async — awaits the provider's
## get_tree_data(), which may itself await MCP calls.
func refresh() -> void:
	if _provider == null:
		populate([])
		return
	populate(await _provider.get_tree_data())


## Render the tree directly from a node-list, bypassing the provider.
## Public so callers (and tests) with data already in hand can populate
## without constructing a provider.
func populate(data: Array) -> void:
	clear()
	var root: TreeItem = create_item()  # hidden root
	for node: Dictionary in data:
		_add_node(root, node)


## Return the keys of every checked file row (recursive).
func get_checked_keys() -> Array:
	var result: Array = []
	_collect_checked(get_root(), result)
	return result


## The bound provider's source label, or "" if none.
func get_source_label() -> String:
	if _provider != null and _provider.has_method("get_source_label"):
		return str(_provider.get_source_label())
	return ""


# ---------------------------------------------------------------------------
# Tree construction
# ---------------------------------------------------------------------------

func _add_node(parent: TreeItem, node: Dictionary) -> void:
	var item: TreeItem = create_item(parent)
	var kind: String = str(node.get("kind", "file"))
	var node_name: String = str(node.get("name", ""))
	var key: String = str(node.get("key", ""))

	item.set_text(COL_NAME, node_name)
	item.set_metadata(COL_NAME, key)
	item.set_meta("kind", kind)

	if kind == "folder":
		item.set_custom_color(COL_NAME, COLOR_FOLDER)
		item.set_selectable(COL_CHECK, false)
		item.set_selectable(COL_NAME, false)
		item.set_selectable(COL_DATE, false)
		var children: Array = node.get("children", []) if node.get("children") is Array else []
		for child: Dictionary in children:
			_add_node(item, child)
	else:
		item.set_cell_mode(COL_CHECK, TreeItem.CELL_MODE_CHECK)
		item.set_checked(COL_CHECK, false)
		item.set_editable(COL_CHECK, true)
		item.set_custom_color(COL_NAME, COLOR_FILE)
		item.set_text(COL_DATE, str(node.get("date", "")))
		item.set_custom_color(COL_DATE, Color(0.6, 0.6, 0.6))
		var tooltip: String = str(node.get("tooltip", ""))
		if not tooltip.is_empty():
			item.set_tooltip_text(COL_NAME, tooltip)


func _collect_checked(item: TreeItem, result: Array) -> void:
	if item == null:
		return
	if item.get_cell_mode(COL_CHECK) == TreeItem.CELL_MODE_CHECK and item.is_checked(COL_CHECK):
		var key: String = str(item.get_metadata(COL_NAME))
		if not key.is_empty():
			result.append(key)
	var child: TreeItem = item.get_first_child()
	while child != null:
		_collect_checked(child, result)
		child = child.get_next()


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_item_selected() -> void:
	var sel: TreeItem = get_selected()
	if sel == null:
		return
	if str(sel.get_meta("kind", "file")) == "folder":
		return
	selection_changed.emit(str(sel.get_metadata(COL_NAME)))


func _on_item_edited() -> void:
	# A checkbox toggle is the only editable cell in this tree.
	check_toggled.emit()


func _on_gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	var mb: InputEventMouseButton = event
	if not mb.pressed or not mb.double_click or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var item: TreeItem = get_item_at_position(mb.position)
	if item == null:
		return
	if str(item.get_meta("kind", "file")) == "folder":
		return
	if get_column_at_position(mb.position) != COL_NAME:
		return
	file_activated.emit(str(item.get_metadata(COL_NAME)))
