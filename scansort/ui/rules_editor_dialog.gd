extends AcceptDialog
## Classification Rules Editor dialog — T7 R4 / Rules-File R6.
##
## Full CRUD for classification rules. As of R6 the dialog operates on an
## external rules JSON file (`rules_path`) rather than the vault's embedded
## rules table — the embedded table is deprecated and read-only.
##
## Two entry points:
##
##   # Preferred — pass an explicit rules file path:
##   dlg.init_with_rules_path(conn, rules_path, source_label)
##
##   # Back-compat — derive sibling path from vault_path:
##   dlg.init(conn, vault_path, vault_password)   # password unused
##
## Usage:
##   var dlg = preload("rules_editor_dialog.gd").new()
##   dlg.init_with_rules_path(conn, "/path/to/rules.json", "Vault rules")
##   add_child(dlg)
##   dlg.rules_changed.connect(_on_rules_changed)
##   dlg.popup_centered(Vector2(860, 560))
##
## No class_name — off-tree plugin script; use preload().

## Emitted after any write operation (insert, update, delete, import).
## Caller may use this to refresh cached rule lists.
signal rules_changed

## Emitted when the dialog closes.
signal closed

# ---------------------------------------------------------------------------
# Dependencies (injected via init())
# ---------------------------------------------------------------------------

var _conn: Object  = null
var _rules_path:   String = ""    # external rules JSON file (R6)
var _source_label: String = ""    # human-readable origin (e.g. "Library rules", "Vault rules")
# Retained for back-compat callers; not forwarded to MCP after R4.
var _vault_path:   String = ""
var _vault_password: String = ""   # never logged

# ---------------------------------------------------------------------------
# Rule data
# ---------------------------------------------------------------------------

## All rules loaded from the vault.  Array of Dicts.
var _rules: Array = []

## Index of the rule currently loaded into the form (-1 = none).
var _current_index: int = -1

## True if the current item in the list is a newly-added unsaved rule.
var _is_new_rule: bool = false

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

var _list:        ItemList   = null
var _form_fields: Dictionary = {}   # field_name → widget
var _error_label: Label      = null

# Confirm-delete dialog (reused).
var _confirm_dlg: ConfirmationDialog = null

# FileDialogs for import / export.
var _import_dialog: FileDialog = null
var _export_dialog: FileDialog = null


func _ready() -> void:
	if _source_label.is_empty():
		title = "Classification Rules"
	else:
		title = "Classification Rules — %s" % _source_label
	min_size = Vector2(860, 560)
	# AcceptDialog OK button → save changes.
	ok_button_text = "Save Changes"
	confirmed.connect(_on_save_pressed)
	canceled.connect(_on_close_pressed)

	_build_ui()


## Preferred (R6+) init: explicit rules file path + label.
##
## rules_path:   absolute path to the JSON file (e.g. <vault>.rules.json sibling
##               or a user-level library file). Created on first save if absent.
## source_label: short string shown in the dialog title to identify the source
##               (e.g. "Library rules", "Vault rules: testvault.rules.json").
func init_with_rules_path(conn: Object, rules_path: String, source_label: String) -> void:
	_conn         = conn
	_rules_path   = rules_path
	_source_label = source_label
	# refresh() requires the scene tree — defer until after add_child().
	call_deferred("refresh")


## Back-compat init (T7 R4 era): derives the sibling rules file path from the
## vault path. `vault_password` is retained in the signature for ABI stability
## but unused — rule operations no longer require the vault password.
func init(conn: Object, vault_path: String, vault_password: String) -> void:
	_conn          = conn
	_vault_path    = vault_path
	_vault_password = vault_password
	# Derive sibling: /a/b/foo.ssort  →  /a/b/foo.rules.json
	var rules_path: String = ""
	if not vault_path.is_empty():
		var base_dir: String = vault_path.get_base_dir()
		var stem: String     = vault_path.get_file().get_basename()
		rules_path = "%s/%s.rules.json" % [base_dir, stem]
	var label: String = "Vault rules"
	if not rules_path.is_empty():
		label += ": " + rules_path.get_file()
	init_with_rules_path(conn, rules_path, label)


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var split := HSplitContainer.new()
	split.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ------ Left: rule list + Add/Delete buttons ------
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 240

	_list = ItemList.new()
	_list.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_selected)
	left.add_child(_list)

	var btn_row := HBoxContainer.new()
	var add_btn := Button.new()
	add_btn.text = "Add Rule"
	add_btn.pressed.connect(_on_add_pressed)
	btn_row.add_child(add_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete Rule"
	del_btn.pressed.connect(_on_delete_pressed)
	btn_row.add_child(del_btn)
	left.add_child(btn_row)

	var import_export_row := HBoxContainer.new()
	var import_btn := Button.new()
	import_btn.text = "Import JSON…"
	import_btn.pressed.connect(_on_import_pressed)
	import_export_row.add_child(import_btn)
	var export_btn := Button.new()
	export_btn.text = "Export JSON…"
	export_btn.pressed.connect(_on_export_pressed)
	import_export_row.add_child(export_btn)
	left.add_child(import_export_row)

	split.add_child(left)

	# ------ Right: rule detail form ------
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)

	# Single-line fields: label, name, subfolder, confidence_threshold.
	var line_fields := [
		["label",                "Label",               "machine-identifier (e.g. invoices)"],
		["name",                 "Name",                "Human-readable name"],
		["subfolder",            "Subfolder",           "Optional subfolder inside vault"],
		["confidence_threshold", "Confidence Threshold","0.0–1.0, default 0.6"],
	]
	for def: Array in line_fields:
		var key: String         = def[0]
		var label_text: String  = def[1]
		var placeholder: String = def[2]
		var hbox := HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var lbl := Label.new()
		lbl.text = label_text
		lbl.custom_minimum_size.x = 160
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hbox.add_child(lbl)
		var edit := LineEdit.new()
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.placeholder_text = placeholder
		hbox.add_child(edit)
		_form_fields[key] = edit
		right.add_child(hbox)

	# Instruction — multi-line TextEdit.
	var instr_hbox := HBoxContainer.new()
	instr_hbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	instr_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var instr_lbl := Label.new()
	instr_lbl.text = "Instruction"
	instr_lbl.custom_minimum_size.x = 160
	instr_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	instr_hbox.add_child(instr_lbl)
	var instr_edit := TextEdit.new()
	instr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	instr_edit.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	instr_edit.custom_minimum_size.y = 80
	instr_edit.placeholder_text = "Describe what documents this rule should match."
	instr_hbox.add_child(instr_edit)
	_form_fields["instruction"] = instr_edit
	right.add_child(instr_hbox)

	# Signals — comma-separated.
	var sig_hbox := HBoxContainer.new()
	sig_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sig_lbl := Label.new()
	sig_lbl.text = "Signals"
	sig_lbl.custom_minimum_size.x = 160
	sig_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sig_hbox.add_child(sig_lbl)
	var sig_edit := LineEdit.new()
	sig_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sig_edit.placeholder_text = "comma-separated keywords"
	sig_hbox.add_child(sig_edit)
	_form_fields["signals"] = sig_edit
	right.add_child(sig_hbox)

	# Enabled checkbox.
	var en_hbox := HBoxContainer.new()
	var en_lbl := Label.new()
	en_lbl.text = "Enabled"
	en_lbl.custom_minimum_size.x = 160
	en_hbox.add_child(en_lbl)
	var en_check := CheckBox.new()
	en_check.button_pressed = true
	en_hbox.add_child(en_check)
	_form_fields["enabled"] = en_check
	right.add_child(en_hbox)

	# Encrypt documents checkbox.
	var enc_hbox := HBoxContainer.new()
	var enc_lbl := Label.new()
	enc_lbl.text = "Encrypt Documents"
	enc_lbl.custom_minimum_size.x = 160
	enc_hbox.add_child(enc_lbl)
	var enc_check := CheckBox.new()
	enc_check.button_pressed = false
	enc_hbox.add_child(enc_check)
	_form_fields["encrypt"] = enc_check
	right.add_child(enc_hbox)

	# Error label.
	_error_label = Label.new()
	_error_label.text = ""
	_error_label.add_theme_color_override("font_color", Color.RED)
	right.add_child(_error_label)

	split.add_child(right)
	add_child(split)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Reload rules from the rules file and repopulate the list.
func refresh() -> void:
	if _conn == null or _rules_path.is_empty():
		return

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_list_rules",
		{"rules_path": _rules_path},
	)
	if not result.get("ok", false):
		_show_error("list_rules failed: %s" % result.get("error", "unknown"))
		return

	_rules = result.get("rules", [])
	_populate_list()

	if _list != null and _list.item_count > 0:
		_list.select(0)
		_current_index = 0
		_load_rule_into_form(0)


# ---------------------------------------------------------------------------
# Private — list management
# ---------------------------------------------------------------------------

func _populate_list() -> void:
	if _list == null:
		return
	_list.clear()
	for rule: Dictionary in _rules:
		var display: String = str(rule.get("name", rule.get("label", "(unnamed)")))
		if not rule.get("enabled", true):
			display += " (disabled)"
		_list.add_item(display)


func _load_rule_into_form(index: int) -> void:
	if index < 0 or index >= _rules.size():
		_clear_form()
		return
	var rule: Dictionary = _rules[index]
	(_form_fields["label"] as LineEdit).text = str(rule.get("label", ""))
	(_form_fields["name"] as LineEdit).text  = str(rule.get("name", ""))
	(_form_fields["instruction"] as TextEdit).text = str(rule.get("instruction", ""))
	var sigs: Variant = rule.get("signals", [])
	if sigs is Array:
		(_form_fields["signals"] as LineEdit).text = ", ".join(PackedStringArray(sigs))
	else:
		(_form_fields["signals"] as LineEdit).text = str(sigs)
	(_form_fields["subfolder"] as LineEdit).text            = str(rule.get("subfolder", ""))
	(_form_fields["confidence_threshold"] as LineEdit).text = str(rule.get("confidence_threshold", 0.6))
	(_form_fields["enabled"] as CheckBox).button_pressed    = rule.get("enabled", true)
	(_form_fields["encrypt"] as CheckBox).button_pressed    = rule.get("encrypt", false)
	_show_error("")


func _clear_form() -> void:
	for key: String in _form_fields:
		var w: Object = _form_fields[key]
		if w is LineEdit:
			(w as LineEdit).text = ""
		elif w is TextEdit:
			(w as TextEdit).text = ""
		elif w is CheckBox:
			(w as CheckBox).button_pressed = false
	_show_error("")


## Read current form values into a Dict.
func _read_form() -> Dictionary:
	var sig_text: String = (_form_fields["signals"] as LineEdit).text.strip_edges()
	var signals: Array = []
	for s: String in sig_text.split(","):
		var trimmed: String = s.strip_edges()
		if not trimmed.is_empty():
			signals.append(trimmed)

	var conf_str: String = (_form_fields["confidence_threshold"] as LineEdit).text.strip_edges()
	var conf: float = 0.6
	if conf_str.is_valid_float():
		conf = float(conf_str)

	return {
		"label":                (_form_fields["label"] as LineEdit).text.strip_edges(),
		"name":                 (_form_fields["name"] as LineEdit).text.strip_edges(),
		"instruction":          (_form_fields["instruction"] as TextEdit).text.strip_edges(),
		"signals":              signals,
		"subfolder":            (_form_fields["subfolder"] as LineEdit).text.strip_edges(),
		"confidence_threshold": conf,
		"enabled":              (_form_fields["enabled"] as CheckBox).button_pressed,
		"encrypt":              (_form_fields["encrypt"] as CheckBox).button_pressed,
	}


# ---------------------------------------------------------------------------
# Handlers — list
# ---------------------------------------------------------------------------

func _on_list_selected(index: int) -> void:
	# Commit the current form to the in-memory rule before switching.
	if _current_index >= 0 and _current_index < _rules.size():
		_rules[_current_index] = _read_form()
		# Keep list text in sync.
		var display: String = str(_rules[_current_index].get("name", _rules[_current_index].get("label", "(unnamed)")))
		if not _rules[_current_index].get("enabled", true):
			display += " (disabled)"
		_list.set_item_text(_current_index, display)

	_current_index = index
	_is_new_rule = false
	_load_rule_into_form(index)


# ---------------------------------------------------------------------------
# Handlers — CRUD buttons
# ---------------------------------------------------------------------------

func _on_add_pressed() -> void:
	# Commit current form first.
	if _current_index >= 0 and _current_index < _rules.size():
		_rules[_current_index] = _read_form()

	var new_rule: Dictionary = {
		"label":                "new-rule",
		"name":                 "New Rule",
		"instruction":          "Describe what documents this rule should match.",
		"signals":              [],
		"subfolder":            "new-rule",
		"confidence_threshold": 0.6,
		"enabled":              true,
		"encrypt":              false,
	}
	_rules.append(new_rule)
	_list.add_item("New Rule")
	var new_idx: int = _list.item_count - 1
	_list.select(new_idx)
	_current_index = new_idx
	_is_new_rule = true
	_load_rule_into_form(new_idx)


func _on_delete_pressed() -> void:
	if _current_index < 0 or _rules.size() <= 1:
		_show_error("Cannot delete: must have at least one rule.")
		return

	# Build confirmation dialog lazily.
	if _confirm_dlg == null:
		_confirm_dlg = ConfirmationDialog.new()
		add_child(_confirm_dlg)
		_confirm_dlg.confirmed.connect(_execute_delete)

	var rule_label: String = str(_rules[_current_index].get("label", "(unknown)"))
	_confirm_dlg.dialog_text = "Delete rule \"%s\"?\nThis cannot be undone." % rule_label
	_confirm_dlg.popup_centered()


func _execute_delete() -> void:
	if _current_index < 0 or _current_index >= _rules.size():
		return
	var conn := _conn
	if conn == null:
		_show_error("Plugin not connected.")
		return

	var rule_label: String = str(_rules[_current_index].get("label", ""))
	if rule_label.is_empty():
		_show_error("Cannot delete: rule has no label.")
		return

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_delete_rule",
		{"rules_path": _rules_path, "label": rule_label},
	)
	if not result.get("ok", false):
		_show_error("delete_rule failed: %s" % result.get("error", "unknown"))
		return

	_show_error("")
	rules_changed.emit()
	await refresh()


# ---------------------------------------------------------------------------
# Handler — Save Changes (AcceptDialog "OK")
# ---------------------------------------------------------------------------

func _on_save_pressed() -> void:
	# Commit current form values back to the in-memory rule.
	if _current_index >= 0 and _current_index < _rules.size():
		_rules[_current_index] = _read_form()

	if _current_index < 0:
		return

	var conn := _conn
	if conn == null:
		_show_error("Plugin not connected.")
		return

	var rule: Dictionary = _rules[_current_index]
	var rule_label: String = str(rule.get("label", ""))
	if rule_label.is_empty():
		_show_error("Label is required.")
		return

	if _is_new_rule:
		# Insert (upserts in R4 file-mode if label already exists).
		var ins_args: Dictionary = {
			"rules_path":           _rules_path,
			"label":                rule_label,
			"name":                 str(rule.get("name", "")),
			"instruction":          str(rule.get("instruction", "")),
			"signals":              rule.get("signals", []),
			"subfolder":            str(rule.get("subfolder", "")),
			"confidence_threshold": float(rule.get("confidence_threshold", 0.6)),
			"enabled":              rule.get("enabled", true),
			"encrypt":              rule.get("encrypt", false),
		}
		var ins_result: Dictionary = await conn.call_tool("minerva_scansort_insert_rule", ins_args)
		if not ins_result.get("ok", false):
			_show_error("insert_rule failed: %s" % ins_result.get("error", "unknown"))
			return
		_is_new_rule = false
	else:
		# Update — send the whole rule as the updates dict.
		var upd_args: Dictionary = {
			"rules_path": _rules_path,
			"label":      rule_label,
			"updates": {
				"name":                 rule.get("name", ""),
				"instruction":          rule.get("instruction", ""),
				"signals":              rule.get("signals", []),
				"subfolder":            rule.get("subfolder", ""),
				"confidence_threshold": float(rule.get("confidence_threshold", 0.6)),
				"enabled":              rule.get("enabled", true),
				"encrypt":              rule.get("encrypt", false),
			},
		}
		var upd_result: Dictionary = await conn.call_tool("minerva_scansort_update_rule", upd_args)
		if not upd_result.get("ok", false):
			_show_error("update_rule failed: %s" % upd_result.get("error", "unknown"))
			return

	_show_error("")
	rules_changed.emit()
	# AcceptDialog auto-hides on confirm; emit closed so the panel queue_frees us.
	closed.emit()


# ---------------------------------------------------------------------------
# Handler — Import from JSON
# ---------------------------------------------------------------------------

func _on_import_pressed() -> void:
	if _import_dialog == null:
		_import_dialog = FileDialog.new()
		_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_import_dialog.title = "Import Rules from JSON"
		_import_dialog.filters = PackedStringArray(["*.json ; JSON files"])
		_import_dialog.file_selected.connect(_on_import_file_selected)
		add_child(_import_dialog)
	_import_dialog.popup_centered(Vector2i(700, 500))


func _on_import_file_selected(file_path: String) -> void:
	var conn := _conn
	if conn == null:
		_show_error("Plugin not connected.")
		return

	# Read the file via FileAccess and pass the contents (not the path) to the tool.
	var fa := FileAccess.open(file_path, FileAccess.READ)
	if fa == null:
		_show_error("Could not open file: %s" % file_path)
		return
	var json_text: String = fa.get_as_text()
	fa.close()

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_import_rules_from_json",
		{"rules_path": _rules_path, "json_text": json_text},
	)
	if not result.get("ok", false):
		_show_error("import_rules failed: %s" % result.get("error", "unknown"))
		return

	var count: int = int(result.get("count", 0))
	_show_error("")  # clear errors
	rules_changed.emit()
	await refresh()
	push_warning("[RulesEditorDialog] imported %d rules from %s" % [count, file_path.get_file()])


# ---------------------------------------------------------------------------
# Handler — Export to JSON
# ---------------------------------------------------------------------------

func _on_export_pressed() -> void:
	if _export_dialog == null:
		_export_dialog = FileDialog.new()
		_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_export_dialog.title = "Export Rules to JSON"
		_export_dialog.filters = PackedStringArray(["*.json ; JSON files"])
		_export_dialog.file_selected.connect(_on_export_file_selected)
		add_child(_export_dialog)
	_export_dialog.current_file = "rules_export.json"
	_export_dialog.popup_centered(Vector2i(700, 500))


func _on_export_file_selected(file_path: String) -> void:
	var conn := _conn
	if conn == null:
		_show_error("Plugin not connected.")
		return

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_list_rules",
		{"rules_path": _rules_path},
	)
	if not result.get("ok", false):
		_show_error("list_rules failed: %s" % result.get("error", "unknown"))
		return

	var rules_data: Variant = result.get("rules", [])
	var json_str: String = JSON.stringify(rules_data, "  ")

	var fa := FileAccess.open(file_path, FileAccess.WRITE)
	if fa == null:
		_show_error("Could not write to file: %s" % file_path)
		return
	fa.store_string(json_str)
	fa.close()
	_show_error("")


# ---------------------------------------------------------------------------
# Handler — Close
# ---------------------------------------------------------------------------

func _on_close_pressed() -> void:
	closed.emit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _show_error(msg: String) -> void:
	if _error_label != null:
		_error_label.text = msg
