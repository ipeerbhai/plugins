extends Control
## Scansort vault document view — T7 R2.
##
## Right-pane detail viewer: lists documents and shows metadata when selected.
##
## No class_name — off-tree script; loaded via preload() from ScansortPanel.gd.
##
## Dropped from experiment's vault_panel.gd (out of R2 scope):
##   - VaultStore direct calls (GDExtension) — all ops via conn.call_tool()
##   - _CategoryDropTarget inner class (drag-from-incoming) — R3
##   - Upload/mark-for-upload bar + bulk encrypt/decrypt buttons — R3
##   - _show_move_to_vault / vault registry popup — R5
##   - _open_document (shell_open temp extract) — R4
##   - _show_save_as / FileDialog save — R4
##   - Collapsible category sections (full section rebuild) — simplified to
##     flat ItemList for R2; rich section UI deferred to R4 polish
##   - Search + debounce timer — R4
##   - Sort buttons — R4
##   - Expand / Collapse All buttons — R4
##   - cleanup_temp_files — R4
##   - lock_toggled / encrypt-decrypt per-row — R4
##   - edit_details_requested signal wiring — R4 (stub only)
##   - cross_drop_completed / move_to_vault_requested signals — R3/R5
##
## call_tool is async: every conn.call_tool() MUST be awaited.

signal edit_details_requested(doc_id: int)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _conn: Object = null
var _vault_path: String = ""
var _all_docs: Array = []
var _selected_doc_id: int = -1

# ---------------------------------------------------------------------------
# UI widgets
# ---------------------------------------------------------------------------

var _header: Label = null
var _doc_list: ItemList = null
var _detail_panel: VBoxContainer = null
var _detail_fields: Dictionary = {}   # field_name -> Label widget

# Detail field keys shown in order.
const DETAIL_FIELDS: Array = [
	["Category",    "category"],
	["Sender",      "sender"],
	["Description", "description"],
	["Date",        "doc_date"],
	["SHA-256",     "sha256"],
	["Tags",        "tags"],
	["Status",      "status"],
]

# ---------------------------------------------------------------------------
# Initialisation
# ---------------------------------------------------------------------------

func _ready() -> void:
	size_flags_vertical  = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_ui()


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	# --- Header ---
	_header = Label.new()
	_header.text = "Documents"
	_header.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_header)

	# --- VSplit: list (top) + detail (bottom) ---
	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(vsplit)

	# Document list.
	_doc_list = ItemList.new()
	_doc_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_doc_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_doc_list.select_mode = ItemList.SELECT_SINGLE
	_doc_list.item_selected.connect(_on_list_item_selected)
	vsplit.add_child(_doc_list)

	# Detail area (scrollable).
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 120
	vsplit.add_child(scroll)

	_detail_panel = VBoxContainer.new()
	_detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_detail_panel)

	# Build static detail rows.
	for pair in DETAIL_FIELDS:
		var label_name: String = pair[0]
		var field_key: String  = pair[1]
		var row := HBoxContainer.new()
		var lbl_key := Label.new()
		lbl_key.text = "%s:" % label_name
		lbl_key.custom_minimum_size.x = 90
		lbl_key.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(lbl_key)
		var lbl_val := Label.new()
		lbl_val.text = ""
		lbl_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl_val.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(lbl_val)
		_detail_panel.add_child(row)
		_detail_fields[field_key] = lbl_val

	# Edit / Delete button row (stubs — wired in R4).
	var btn_row := HBoxContainer.new()
	var edit_btn := Button.new()
	edit_btn.text = "Edit Details"
	edit_btn.pressed.connect(_on_edit_pressed)
	btn_row.add_child(edit_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.pressed.connect(_on_delete_pressed)
	btn_row.add_child(del_btn)
	_detail_panel.add_child(btn_row)

	_clear_detail()


## Attach vault connection + path, then populate. Called by ScansortPanel.
func init(conn: Object, vault_path: String, _password: String) -> void:
	_conn = conn
	_vault_path = vault_path
	refresh()


## Repopulate document list from vault.
func refresh() -> void:
	if _doc_list == null:
		return
	_doc_list.clear()
	_all_docs.clear()
	_selected_doc_id = -1
	_clear_detail()

	if _conn == null or _vault_path.is_empty():
		if _header != null:
			_header.text = "Documents"
		return

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": _vault_path}
	)
	if not result.get("ok", false):
		push_warning("[VaultView] query_documents failed: %s" % result.get("error", "unknown"))
		if _header != null:
			_header.text = "Documents (error)"
		return

	_all_docs = result.get("documents", [])
	_populate_list(_all_docs)


## Clear view and reset state (called on vault close).
func clear() -> void:
	if _doc_list != null:
		_doc_list.clear()
	_all_docs.clear()
	_selected_doc_id = -1
	_conn = null
	_vault_path = ""
	_clear_detail()
	if _header != null:
		_header.text = "Documents"


## Called by ScansortPanel when file_tree emits document_selected.
func on_document_selected(doc_id: int) -> void:
	_selected_doc_id = doc_id
	# Sync highlight in own list.
	for i in range(_doc_list.item_count):
		var meta: Variant = _doc_list.get_item_metadata(i)
		if int(meta) == doc_id:
			_doc_list.select(i, true)
			break
	_show_detail_for_id(doc_id)


## Called after a document is inserted / deleted (R3 will call this).
func on_documents_changed() -> void:
	refresh()


# ---------------------------------------------------------------------------
# Private — list population
# ---------------------------------------------------------------------------

func _populate_list(docs: Array) -> void:
	if _doc_list == null:
		return
	_doc_list.clear()

	for doc: Dictionary in docs:
		var doc_id: int = int(doc.get("doc_id", 0))
		var display: String = str(doc.get("display_name", doc.get("original_filename", "unknown")))
		var cat: String     = str(doc.get("category", ""))
		var date: String    = str(doc.get("doc_date", ""))
		var label_text: String = "%s  [%s]  %s" % [display, cat, date]
		_doc_list.add_item(label_text)
		_doc_list.set_item_metadata(_doc_list.item_count - 1, doc_id)

	if _header != null:
		_header.text = "Documents (%d)" % docs.size()


# ---------------------------------------------------------------------------
# Private — detail pane
# ---------------------------------------------------------------------------

func _clear_detail() -> void:
	for field_key: String in _detail_fields:
		_detail_fields[field_key].text = ""


func _show_detail_for_id(doc_id: int) -> void:
	for doc: Dictionary in _all_docs:
		if int(doc.get("doc_id", -1)) == doc_id:
			_show_detail(doc)
			return
	_clear_detail()


func _show_detail(doc: Dictionary) -> void:
	for pair in DETAIL_FIELDS:
		var field_key: String = pair[1]
		var val: Variant = doc.get(field_key, "")
		if val is Array:
			_detail_fields[field_key].text = ", ".join(PackedStringArray(val))
		else:
			_detail_fields[field_key].text = str(val)


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_list_item_selected(index: int) -> void:
	var doc_id: int = int(_doc_list.get_item_metadata(index))
	_selected_doc_id = doc_id
	_show_detail_for_id(doc_id)


func _on_edit_pressed() -> void:
	# Stub — R4 wires edit_details_dialog.
	if _selected_doc_id >= 0:
		edit_details_requested.emit(_selected_doc_id)


func _on_delete_pressed() -> void:
	# Stub — R4 wires delete confirmation.
	pass
