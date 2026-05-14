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

## Emitted when a file row is dropped onto a folder row in this tree.
## drag_data: the Dictionary returned by _get_drag_data on the source tree.
## target_key: the key of the folder item that received the drop.
## target_kind: always "folder" (only folder rows accept drops).
signal file_dropped(drag_data: Dictionary, target_key: String, target_kind: String)

## W5b: Emitted when one of the inline row buttons on a top-level destination row
## is clicked.  dest_id is the "dest:<id>" key without the prefix stripped, and
## action is one of "remove", "reprocess", or "lock_toggle".
signal dest_button_pressed(dest_id: String, action: String)

# Column indices.
const COL_CHECK := 0
const COL_NAME := 1
const COL_DATE := 2

const COLOR_FOLDER := Color(0.9, 0.85, 0.6)   # warm yellow
const COLOR_FILE := Color(0.78, 0.85, 0.78)   # soft green

# W5b/W5d: inline button IDs for destination and document rows.
const BTN_ID_REMOVE     := 0
const BTN_ID_REPROCESS  := 1
const BTN_ID_LOCK       := 2
## W5d: additional button IDs.
const BTN_ID_OPEN       := 3
const BTN_ID_SETTINGS   := 4
# W5h: encrypt/decrypt toggle on document rows.
const BTN_ID_ENCRYPT    := 5

var _provider: Object = null

## Set by ScansortPanel after construction: "source" or "vault".
## Used in drag data so the drop handler can distinguish the origin.
var tree_role: String = ""


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
	# Accept drops only directly onto items (folder rows).
	drop_mode_flags = Tree.DROP_MODE_ON_ITEM
	item_selected.connect(_on_item_selected)
	item_edited.connect(_on_item_edited)
	gui_input.connect(_on_gui_input)
	# W5b: inline destination row buttons.
	button_clicked.connect(_on_button_clicked)


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
		# W5b/W5d: add inline action buttons on top-level destination rows.
		# A destination row carries a "dest_id" field in its node dict.
		# W5d: node_role ("vault_dest" / "dir_dest") controls which buttons appear.
		# If node_role is absent (legacy test data), fall back to the old 3-button set.
		var dest_id: String = str(node.get("dest_id", ""))
		if not dest_id.is_empty():
			var is_locked: bool = bool(node.get("locked", false))
			var node_role: String = str(node.get("node_role", ""))
			item.set_meta("dest_id", dest_id)
			item.set_meta("dest_locked", is_locked)
			item.set_meta("node_role", node_role)
			if node_role == "vault_dest":
				# Vault destination: [Settings] + [Remove]
				item.add_button(COL_DATE, _make_icon_settings(), BTN_ID_SETTINGS, false, "Vault settings")
				item.add_button(COL_DATE, _make_icon_remove(), BTN_ID_REMOVE, false, "Remove destination")
			elif node_role == "dir_dest":
				# Directory destination: [Reprocess] + [Lock] + [Remove]
				item.add_button(COL_DATE, _make_icon_reprocess(), BTN_ID_REPROCESS, false, "Reprocess destination")
				item.add_button(COL_DATE, _make_icon_lock(is_locked), BTN_ID_LOCK, false,
					"Locked — click to unlock" if is_locked else "Unlocked — click to lock")
				item.add_button(COL_DATE, _make_icon_remove(), BTN_ID_REMOVE, false, "Remove destination")
			else:
				# Legacy / untagged: keep old 3-button set so existing tests pass.
				item.add_button(COL_DATE, _make_icon_remove(),    BTN_ID_REMOVE,    false, "Remove destination")
				item.add_button(COL_DATE, _make_icon_reprocess(), BTN_ID_REPROCESS, false, "Reprocess destination")
				item.add_button(COL_DATE, _make_icon_lock(is_locked), BTN_ID_LOCK,  false,
					"Locked — click to unlock" if is_locked else "Unlocked — click to lock")
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
		# W5d: document rows get an [Open] button; clicking it fires file_activated.
		var file_node_role: String = str(node.get("node_role", ""))
		if file_node_role == "document":
			item.add_button(COL_DATE, _make_icon_open(), BTN_ID_OPEN, false, "Open document")
			# W5h: a lock toggle to encrypt/decrypt the document at rest; the
			# icon reflects the document's current encryption state.
			var is_encrypted: bool = bool(node.get("encrypted", false))
			item.add_button(COL_DATE, _make_icon_lock(is_encrypted), BTN_ID_ENCRYPT, false,
				"Decrypt document" if is_encrypted else "Encrypt document")
			item.set_meta("encrypted", is_encrypted)
			# vault_path needed by the panel to call extract_document.
			item.set_meta("vault_path", str(node.get("vault_path", "")))


## W5d: programmatic 14×14 icons — visually distinct per action.
## Technique: draw shapes onto Image, convert to ImageTexture.

## Remove (X): two diagonal lines on a reddish background.
func _make_icon_remove() -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c := Color(0.9, 0.35, 0.35, 1.0)
	for i in range(14):
		img.set_pixel(i, i, c)
		img.set_pixel(i, 13 - i, c)
		if i > 0:
			img.set_pixel(i - 1, i, c)
			img.set_pixel(i - 1, 13 - i, c)
	return ImageTexture.create_from_image(img)


## Reprocess (circular arrow): arc of dots forming a clockwise sweep.
func _make_icon_reprocess() -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c := Color(0.4, 0.75, 0.95, 1.0)
	var cx: float = 6.5
	var cy: float = 6.5
	var r: float  = 5.0
	# Draw 270-degree arc (skip the bottom-right quadrant to suggest an open arrow).
	for deg in range(45, 315):
		var rad: float = deg * PI / 180.0
		var px: int = int(cx + r * cos(rad))
		var py: int = int(cy + r * sin(rad))
		if px >= 0 and px < 14 and py >= 0 and py < 14:
			img.set_pixel(px, py, c)
	# Arrowhead at the break (pointing clockwise = down-right at ~315°).
	img.set_pixel(11, 9, c)
	img.set_pixel(12, 8, c)
	img.set_pixel(11, 10, c)
	return ImageTexture.create_from_image(img)


## Lock (padlock): a rectangle body with an arc shackle on top.
## is_locked: true = filled shackle (closed), false = open shackle.
func _make_icon_lock(is_locked: bool) -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var body_col := Color(0.85, 0.75, 0.25, 1.0)   # gold body
	var shackle_col := Color(0.85, 0.75, 0.25, 1.0) if is_locked else Color(0.6, 0.6, 0.6, 1.0)
	# Body: 4×5 rectangle at bottom.
	for x in range(4, 10):
		for y in range(7, 13):
			img.set_pixel(x, y, body_col)
	# Keyhole: small dark dot in body centre.
	img.set_pixel(6, 9, Color(0.2, 0.2, 0.2, 1.0))
	img.set_pixel(7, 9, Color(0.2, 0.2, 0.2, 1.0))
	# Shackle: U-shape arc at top.
	img.set_pixel(4, 6, shackle_col)
	img.set_pixel(9, 6, shackle_col)
	img.set_pixel(4, 5, shackle_col)
	img.set_pixel(9, 5, shackle_col)
	if is_locked:
		img.set_pixel(4, 4, shackle_col)
		img.set_pixel(9, 4, shackle_col)
		img.set_pixel(5, 3, shackle_col)
		img.set_pixel(6, 3, shackle_col)
		img.set_pixel(7, 3, shackle_col)
		img.set_pixel(8, 3, shackle_col)
	else:
		# Open shackle: right side only.
		img.set_pixel(9, 4, shackle_col)
		img.set_pixel(9, 3, shackle_col)
		img.set_pixel(8, 2, shackle_col)
	return ImageTexture.create_from_image(img)


## Open / external-link (up-right arrow): diagonal arrow.
func _make_icon_open() -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c := Color(0.45, 0.85, 0.55, 1.0)  # green-ish
	# Arrow shaft: diagonal from bottom-left to top-right.
	for i in range(7):
		img.set_pixel(2 + i, 10 - i, c)
	# Arrowhead at top-right (8,3).
	img.set_pixel(8, 3, c)
	img.set_pixel(9, 3, c)
	img.set_pixel(10, 3, c)
	img.set_pixel(10, 4, c)
	img.set_pixel(10, 5, c)
	# Box outline (partial) for "external link" look.
	for x in range(3, 9):
		img.set_pixel(x, 11, c)
	for y in range(5, 12):
		img.set_pixel(3, y, c)
	return ImageTexture.create_from_image(img)


## Settings (gear): octagon with a filled centre.
func _make_icon_settings() -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c := Color(0.75, 0.75, 0.85, 1.0)  # light purple-grey
	# Gear teeth: 8 bumps around centre.
	var cx: float = 6.5
	var cy: float = 6.5
	for tooth in range(8):
		var a: float = tooth * PI / 4.0
		for r in [4.5, 5.5]:
			var px: int = int(cx + r * cos(a))
			var py: int = int(cy + r * sin(a))
			if px >= 0 and px < 14 and py >= 0 and py < 14:
				img.set_pixel(px, py, c)
	# Filled centre circle radius ~2.
	for x in range(4, 10):
		for y in range(4, 10):
			var dx: float = x - cx + 0.5
			var dy: float = y - cy + 0.5
			if dx * dx + dy * dy <= 6.5:
				img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


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


# ---------------------------------------------------------------------------
# W5b: Inline destination row button handler
# ---------------------------------------------------------------------------

func _on_button_clicked(item: TreeItem, _column: int, btn_id: int, _mouse_button: int) -> void:
	# W5d: [Open] button on document rows fires file_activated (same path as double-click).
	if btn_id == BTN_ID_OPEN:
		var file_key: String = str(item.get_metadata(COL_NAME))
		if not file_key.is_empty():
			file_activated.emit(file_key)
		return

	# W5h: [Encrypt/Decrypt] toggle on document rows. Emit with the doc key as
	# the id and an action reflecting the DESIRED new state so the panel can
	# dispatch without re-querying.
	if btn_id == BTN_ID_ENCRYPT:
		var doc_key: String = str(item.get_metadata(COL_NAME))
		if not doc_key.is_empty():
			var currently_enc: bool = bool(item.get_meta("encrypted", false))
			dest_button_pressed.emit(doc_key, "decrypt" if currently_enc else "encrypt")
		return

	var dest_id: String = str(item.get_meta("dest_id", ""))
	if dest_id.is_empty():
		return
	match btn_id:
		BTN_ID_REMOVE:
			dest_button_pressed.emit(dest_id, "remove")
		BTN_ID_REPROCESS:
			dest_button_pressed.emit(dest_id, "reprocess")
		BTN_ID_LOCK:
			dest_button_pressed.emit(dest_id, "lock_toggle")
		BTN_ID_SETTINGS:
			dest_button_pressed.emit(dest_id, "settings")


# ---------------------------------------------------------------------------
# Drag-and-drop (U6)
# ---------------------------------------------------------------------------

## Begin a drag when the user drags a file row.
## Returns null for folder rows (they are structural, not draggable).
func _get_drag_data(at_position: Vector2) -> Variant:
	var item := get_item_at_position(at_position)
	if item == null:
		return null
	if str(item.get_meta("kind", "file")) == "folder":
		return null
	var data := {
		"scan_tree_drag": true,
		"key":  str(item.get_metadata(COL_NAME)),
		"role": tree_role,
	}
	# W5g: include vault_path in drag data for vault document rows so the
	# drop handler can extract the correct doc without re-walking the tree.
	if item.has_meta("vault_path"):
		var vp: String = str(item.get_meta("vault_path", ""))
		if not vp.is_empty():
			data["vault_path"] = vp
	# Lightweight drag preview — just a label with the item's name text.
	var label := Label.new()
	label.text = item.get_text(COL_NAME)
	set_drag_preview(label)
	return data


## Accept drops only when: data is our dict AND the target row is a folder.
func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary and data.get("scan_tree_drag", false) == true):
		return false
	var target := get_item_at_position(at_position)
	if target == null:
		return false
	return str(target.get_meta("kind", "file")) == "folder"


## Emit file_dropped so ScansortPanel can handle classify / reclassify logic.
func _drop_data(at_position: Vector2, data: Variant) -> void:
	var target := get_item_at_position(at_position)
	if target == null or str(target.get_meta("kind", "file")) != "folder":
		return
	file_dropped.emit(
		data as Dictionary,
		str(target.get_metadata(COL_NAME)),
		"folder"
	)
