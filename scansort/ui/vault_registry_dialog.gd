extends AcceptDialog
## Vault Registry dialog — T7 R5.
##
## Lists vaults in the cross-vault registry (~/.config/scansort/vault_registry.json).
## Supports Add (file picker → registry_add), Remove (selected entry → registry_remove).
##
## Usage:
##   var dlg = preload("vault_registry_dialog.gd").new()
##   dlg.init(conn)
##   add_child(dlg)
##   dlg.vault_picked.connect(_on_vault_picked)
##   dlg.popup_centered(Vector2i(580, 380))
##
## No class_name — off-tree plugin script; use preload().

## Emitted when the user double-clicks an entry. The panel may use this to
## close the current vault and open the chosen one.
signal vault_picked(path: String, name: String)

## Emitted when the dialog closes.
signal closed

# ---------------------------------------------------------------------------
# Dependencies (injected via init())
# ---------------------------------------------------------------------------

var _conn: Object = null

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

var _item_list:    ItemList = null
var _add_button:   Button   = null
var _remove_button: Button  = null
var _file_dialog:  FileDialog = null


func _ready() -> void:
	title = "Vault Registry"
	min_size = Vector2i(580, 380)
	ok_button_text = "Close"
	confirmed.connect(_on_close_pressed)
	canceled.connect(_on_close_pressed)
	_build_ui()


## Inject connection, then refresh the list.  Refresh defers until scene tree.
func init(conn: Object) -> void:
	_conn = conn
	call_deferred("refresh")


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var desc := Label.new()
	desc.text = "Cross-vault registry. Registered vaults are available for dedup checks across all known vaults."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	_item_list = ItemList.new()
	_item_list.custom_minimum_size = Vector2i(520, 220)
	_item_list.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_list.item_selected.connect(_on_item_selected)
	_item_list.item_activated.connect(_on_item_activated)
	vbox.add_child(_item_list)

	var button_bar := HBoxContainer.new()

	_add_button = Button.new()
	_add_button.text = "Add..."
	_add_button.pressed.connect(_on_add_pressed)
	button_bar.add_child(_add_button)

	_remove_button = Button.new()
	_remove_button.text = "Remove"
	_remove_button.disabled = true
	_remove_button.pressed.connect(_on_remove_pressed)
	button_bar.add_child(_remove_button)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(refresh)
	button_bar.add_child(refresh_btn)

	vbox.add_child(button_bar)

	# FileDialog for adding vault files.
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access    = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.min_size  = Vector2i(600, 400)
	_file_dialog.title     = "Select Vault File"
	_file_dialog.filters   = PackedStringArray(["*.ssort ; ScanSort Vault"])
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)

	add_child(vbox)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Reload the registry list from the plugin.
func refresh() -> void:
	if _conn == null or _item_list == null:
		return

	var result: Dictionary = await _conn.call_tool("minerva_scansort_registry_list", {})
	_item_list.clear()
	_remove_button.disabled = true

	# registry_list returns {"entries": [...]} — NOT {"ok", "vaults"}.
	# Each entry: {"path": str, "name": str, "added_at": str, "doc_count": int}
	if not result.has("entries"):
		# Treat as empty (could be an error response with "error" key).
		push_warning("[VaultRegistryDialog] registry_list: unexpected envelope: %s" % str(result))
		return

	var entries: Array = result.get("entries", [])
	for entry: Dictionary in entries:
		var vault_name: String = str(entry.get("name",      ""))
		var path:       String = str(entry.get("path",      ""))
		var doc_count:  int    = int(entry.get("doc_count", -1))
		var added_at:   String = str(entry.get("added_at",  ""))
		# Trim ISO8601 timestamp to the date portion for the display ("2026-05-13").
		var added_date: String = added_at.substr(0, 10) if added_at.length() >= 10 else added_at

		var display: String
		if doc_count < 0:
			display = "%s (unavailable, added %s) — %s" % [vault_name, added_date, path]
		else:
			display = "%s (%d docs, added %s) — %s" % [vault_name, doc_count, added_date, path]

		var idx: int = _item_list.add_item(display)
		# Store both path and name in metadata as a dict.
		_item_list.set_item_metadata(idx, {"path": path, "name": vault_name})


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_item_selected(_index: int) -> void:
	_remove_button.disabled = false


## Double-click on an entry → emit vault_picked so the panel can switch vaults.
func _on_item_activated(index: int) -> void:
	var meta: Variant = _item_list.get_item_metadata(index)
	if meta is Dictionary:
		vault_picked.emit(str(meta.get("path", "")), str(meta.get("name", "")))
		hide()
		closed.emit()


func _on_add_pressed() -> void:
	_file_dialog.popup_centered(Vector2i(600, 400))


func _on_file_selected(path: String) -> void:
	if _conn == null:
		return
	# registry_add param is vault_path (not path).
	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_registry_add",
		{"vault_path": path}
	)
	# response: {"ok": true, "added": bool}
	if not result.get("ok", false):
		push_warning("[VaultRegistryDialog] registry_add failed: %s" % str(result.get("error", "unknown")))
	await refresh()


func _on_remove_pressed() -> void:
	var selected: PackedInt32Array = _item_list.get_selected_items()
	if selected.is_empty():
		return
	var idx: int = selected[0]
	var meta: Variant = _item_list.get_item_metadata(idx)
	if not meta is Dictionary:
		return
	var vault_path: String = str(meta.get("path", ""))
	if vault_path.is_empty() or _conn == null:
		return
	# registry_remove param is vault_path.
	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_registry_remove",
		{"vault_path": vault_path}
	)
	# response: {"ok": true, "removed": bool}
	if not result.get("ok", false):
		push_warning("[VaultRegistryDialog] registry_remove failed: %s" % str(result.get("error", "unknown")))
	await refresh()


func _on_close_pressed() -> void:
	closed.emit()
