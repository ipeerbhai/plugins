extends AcceptDialog
## Dialog for managing tax checklists: auto-upload rules and expected document tracking.
##
## Ported from: ccsandbox/experiments/scansort/scripts/ui/checklist_dialog.gd
## Architectural differences:
##   - No class_name (off-tree plugin script)
##   - No VaultStore direct calls — all vault operations via _conn.call_tool()
##   - Constructor takes (_conn, _vault_path, _vault_password)
##   - Signals: checklist_changed, closed
##   - R4 fixes applied: call_deferred("refresh"), closed.emit() on OK path

signal checklist_changed()
signal closed()

var _conn: Object = null
var _vault_path: String = ""
var _vault_password: String = ""

var _year_spin: SpinBox = null
var _copy_button: Button = null
var _auto_upload_box: VBoxContainer = null
var _expected_doc_box: VBoxContainer = null
var _add_auto_button: Button = null
var _add_expected_button: Button = null
var _run_button: Button = null
var _found_label: Label = null
var _copy_year_dialog: AcceptDialog = null
var _copy_year_spin: SpinBox = null
var _edit_dialog: AcceptDialog = null
var _edit_fields: Dictionary = {}
var _edit_checklist_id: int = -1


const _UiScale := preload("ui_scale.gd")


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Tax Checklist"
	min_size = Vector2(620, 500)
	ok_button_text = "Close"
	confirmed.connect(_on_close_confirmed)


## Public constructor — call after add_child.
func init(conn: Object, vault_path: String, vault_password: String) -> void:
	_conn = conn
	_vault_path = vault_path
	_vault_password = vault_password
	_build_ui()
	call_deferred("refresh")


func _build_ui() -> void:
	# Remove previous content if reinitializing
	for child in get_children():
		if child is VBoxContainer:
			child.queue_free()

	var vbox := VBoxContainer.new()

	# Top bar: year selector + copy button
	var top_bar := HBoxContainer.new()

	var year_label := Label.new()
	year_label.text = "Tax Year:"
	top_bar.add_child(year_label)

	_year_spin = SpinBox.new()
	_year_spin.min_value = 2020
	_year_spin.max_value = 2035
	_year_spin.value = _get_current_year()
	_year_spin.value_changed.connect(_on_year_changed)
	top_bar.add_child(_year_spin)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	_copy_button = Button.new()
	_copy_button.text = "Copy from Year..."
	_copy_button.pressed.connect(_on_copy_pressed)
	top_bar.add_child(_copy_button)

	vbox.add_child(top_bar)

	# Scroll container for the two sections
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(580, 320)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var sections := VBoxContainer.new()
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Auto-upload section
	var auto_sep := Label.new()
	auto_sep.text = "-- Auto-Upload Rules --"
	auto_sep.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sections.add_child(auto_sep)

	_auto_upload_box = VBoxContainer.new()
	_auto_upload_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sections.add_child(_auto_upload_box)

	_add_auto_button = Button.new()
	_add_auto_button.text = "+ Add Auto-Upload Rule"
	_add_auto_button.pressed.connect(_on_add_auto)
	sections.add_child(_add_auto_button)

	# Expected docs section
	var exp_sep := Label.new()
	exp_sep.text = "-- Expected Documents --"
	exp_sep.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sections.add_child(exp_sep)

	_expected_doc_box = VBoxContainer.new()
	_expected_doc_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sections.add_child(_expected_doc_box)

	_add_expected_button = Button.new()
	_add_expected_button.text = "+ Add Expected Doc"
	_add_expected_button.pressed.connect(_on_add_expected)
	sections.add_child(_add_expected_button)

	scroll.add_child(sections)
	vbox.add_child(scroll)

	# Bottom bar: found count + run button
	var bottom_bar := HBoxContainer.new()

	_found_label = Label.new()
	_found_label.text = ""
	_found_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_bar.add_child(_found_label)

	_run_button = Button.new()
	_run_button.text = "Run Check"
	_run_button.pressed.connect(_on_run_check)
	bottom_bar.add_child(_run_button)

	vbox.add_child(bottom_bar)
	add_child(vbox)


func _get_current_year() -> int:
	var dt := Time.get_datetime_dict_from_system()
	return int(dt.get("year", 2025))


func _on_year_changed(_value: float) -> void:
	call_deferred("refresh")


func _on_close_confirmed() -> void:
	closed.emit()


func refresh() -> void:
	if _conn == null or _vault_path.is_empty():
		return
	if _year_spin == null:
		return
	var year := int(_year_spin.value)
	var args: Dictionary = {"path": _vault_path, "tax_year": year}
	if not _vault_password.is_empty():
		args["password"] = _vault_password

	var result: Dictionary = await _conn.call_tool("minerva_scansort_list_checklists", args)
	if not result.get("ok", false):
		return

	# Clear sections
	for child in _auto_upload_box.get_children():
		child.queue_free()
	for child in _expected_doc_box.get_children():
		child.queue_free()

	var items: Array = result.get("items", [])
	var found_count := 0
	var total_expected := 0

	for item: Dictionary in items:
		var ctype: String = str(item.get("item_type", ""))
		var cid: int = int(item.get("checklist_id", 0))
		var cname: String = str(item.get("name", ""))
		var status: String = str(item.get("status", "pending"))
		var enabled: bool = bool(item.get("enabled", true))

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		if ctype == "expected_doc":
			total_expected += 1
			var status_label := Label.new()
			if status == "found":
				found_count += 1
				status_label.text = "[OK] %s" % cname
			elif status == "missing":
				status_label.text = "[X] %s (MISSING)" % cname
			else:
				status_label.text = "[?] %s" % cname
			status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(status_label)
		else:
			# auto_upload
			var check := CheckBox.new()
			check.button_pressed = enabled
			check.text = cname
			check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			check.toggled.connect(_on_toggle_enabled.bind(cid))
			row.add_child(check)

		var edit_btn := Button.new()
		edit_btn.text = "Edit"
		edit_btn.pressed.connect(_on_edit_item.bind(cid))
		row.add_child(edit_btn)

		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.pressed.connect(_on_delete_item.bind(cid))
		row.add_child(del_btn)

		if ctype == "auto_upload":
			_auto_upload_box.add_child(row)
		else:
			_expected_doc_box.add_child(row)

	if total_expected > 0:
		_found_label.text = "Found: %d/%d    Missing: %d" % [
			found_count, total_expected, total_expected - found_count]
	else:
		_found_label.text = ""


func _on_toggle_enabled(toggled_on: bool, checklist_id: int) -> void:
	if _conn == null:
		return
	var args: Dictionary = {
		"path": _vault_path,
		"checklist_id": checklist_id,
		"enabled": toggled_on,
	}
	if not _vault_password.is_empty():
		args["password"] = _vault_password
	await _conn.call_tool("minerva_scansort_toggle_checklist_enabled", args)
	checklist_changed.emit()


func _on_add_auto() -> void:
	_show_edit_dialog(-1, "auto_upload")


func _on_add_expected() -> void:
	_show_edit_dialog(-1, "expected_doc")


func _on_edit_item(checklist_id: int) -> void:
	_show_edit_dialog(checklist_id)


func _on_delete_item(checklist_id: int) -> void:
	if _conn == null:
		return
	var args: Dictionary = {"path": _vault_path, "checklist_id": checklist_id}
	if not _vault_password.is_empty():
		args["password"] = _vault_password
	await _conn.call_tool("minerva_scansort_delete_checklist", args)
	checklist_changed.emit()
	call_deferred("refresh")


func _on_run_check() -> void:
	if _conn == null:
		return
	var year := int(_year_spin.value)
	var args: Dictionary = {"path": _vault_path, "tax_year": year}
	if not _vault_password.is_empty():
		args["password"] = _vault_password
	await _conn.call_tool("minerva_scansort_run_checklist_check", args)
	checklist_changed.emit()
	call_deferred("refresh")


func _on_copy_pressed() -> void:
	if _copy_year_dialog != null and is_instance_valid(_copy_year_dialog):
		_copy_year_dialog.queue_free()

	_copy_year_dialog = AcceptDialog.new()
	_copy_year_dialog.title = "Copy Checklist from Year"
	_copy_year_dialog.min_size = Vector2(300, 100)

	var hbox := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "Copy from year:"
	hbox.add_child(lbl)

	_copy_year_spin = SpinBox.new()
	_copy_year_spin.min_value = 2020
	_copy_year_spin.max_value = 2035
	_copy_year_spin.value = int(_year_spin.value) - 1
	hbox.add_child(_copy_year_spin)

	_copy_year_dialog.add_child(hbox)
	_copy_year_dialog.confirmed.connect(_on_copy_confirmed)
	add_child(_copy_year_dialog)
	_copy_year_dialog.popup_centered()


func _on_copy_confirmed() -> void:
	if _conn == null:
		return
	var from_year := int(_copy_year_spin.value)
	var to_year := int(_year_spin.value)
	# insert all items from from_year into to_year by list + re-insert
	var list_args: Dictionary = {"path": _vault_path, "tax_year": from_year}
	if not _vault_password.is_empty():
		list_args["password"] = _vault_password
	var list_result: Dictionary = await _conn.call_tool("minerva_scansort_list_checklists", list_args)
	if not list_result.get("ok", false):
		return
	for item: Dictionary in list_result.get("items", []):
		var ins_args: Dictionary = {
			"path": _vault_path,
			"tax_year": to_year,
			"item_type": str(item.get("item_type", "expected_doc")),
			"name": str(item.get("name", "")),
		}
		if not _vault_password.is_empty():
			ins_args["password"] = _vault_password
		var cat = item.get("match_category")
		if cat != null and str(cat) != "":
			ins_args["match_category"] = str(cat)
		var sender = item.get("match_sender")
		if sender != null and str(sender) != "":
			ins_args["match_sender"] = str(sender)
		var pattern = item.get("match_pattern")
		if pattern != null and str(pattern) != "":
			ins_args["match_pattern"] = str(pattern)
		await _conn.call_tool("minerva_scansort_insert_checklist", ins_args)
	checklist_changed.emit()
	call_deferred("refresh")


func _show_edit_dialog(checklist_id: int, default_type: String = "") -> void:
	if _edit_dialog != null and is_instance_valid(_edit_dialog):
		_edit_dialog.queue_free()

	_edit_checklist_id = checklist_id

	_edit_dialog = AcceptDialog.new()
	_edit_dialog.title = "Add Checklist Item" if checklist_id < 0 else "Edit Checklist Item"
	_edit_dialog.min_size = Vector2(420, 250)
	_edit_fields.clear()

	# Load existing values if editing
	var existing: Dictionary = {}

	var vbox := VBoxContainer.new()

	var field_defs: Array = [
		["name", "Name", ""],
		["match_category", "Match Category", ""],
		["match_sender", "Match Sender", ""],
		["match_pattern", "Match Pattern", ""],
	]

	for def: Array in field_defs:
		var key: String = def[0]
		var label_text: String = def[1]
		var value: String = str(existing.get(key, def[2]))

		var hbox := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.custom_minimum_size.x = 130
		hbox.add_child(label)

		var edit := LineEdit.new()
		edit.text = value
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(edit)

		_edit_fields[key] = edit
		vbox.add_child(hbox)

	# Type selector (only for new items)
	if checklist_id < 0:
		var type_hbox := HBoxContainer.new()
		var type_label := Label.new()
		type_label.text = "Type"
		type_label.custom_minimum_size.x = 130
		type_hbox.add_child(type_label)

		var type_option := OptionButton.new()
		type_option.add_item("auto_upload", 0)
		type_option.add_item("expected_doc", 1)
		if default_type == "expected_doc":
			type_option.select(1)
		else:
			type_option.select(0)
		type_hbox.add_child(type_option)
		_edit_fields["type_option"] = type_option

		vbox.add_child(type_hbox)

	_edit_dialog.add_child(vbox)
	_edit_dialog.confirmed.connect(_on_edit_confirmed)
	add_child(_edit_dialog)
	_edit_dialog.popup_centered()


func _on_edit_confirmed() -> void:
	if _conn == null:
		return

	var item_name: String = _edit_fields["name"].text.strip_edges()
	if item_name.is_empty():
		return

	var match_category: String = _edit_fields["match_category"].text.strip_edges()
	var match_sender: String = _edit_fields["match_sender"].text.strip_edges()
	var match_pattern: String = _edit_fields["match_pattern"].text.strip_edges()

	if _edit_checklist_id < 0:
		# Adding new
		var type_opt: OptionButton = _edit_fields.get("type_option")
		var ctype := "auto_upload"
		if type_opt != null and type_opt.selected == 1:
			ctype = "expected_doc"
		var ins_args: Dictionary = {
			"path": _vault_path,
			"tax_year": int(_year_spin.value),
			"item_type": ctype,
			"name": item_name,
		}
		if not _vault_password.is_empty():
			ins_args["password"] = _vault_password
		if not match_category.is_empty():
			ins_args["match_category"] = match_category
		if not match_sender.is_empty():
			ins_args["match_sender"] = match_sender
		if not match_pattern.is_empty():
			ins_args["match_pattern"] = match_pattern
		await _conn.call_tool("minerva_scansort_insert_checklist", ins_args)
	else:
		# Updating existing
		var updates: Dictionary = {"name": item_name}
		if not match_category.is_empty():
			updates["match_category"] = match_category
		if not match_sender.is_empty():
			updates["match_sender"] = match_sender
		if not match_pattern.is_empty():
			updates["match_pattern"] = match_pattern
		var upd_args: Dictionary = {
			"path": _vault_path,
			"checklist_id": _edit_checklist_id,
			"updates": updates,
		}
		if not _vault_password.is_empty():
			upd_args["password"] = _vault_password
		await _conn.call_tool("minerva_scansort_update_checklist", upd_args)

	checklist_changed.emit()
	call_deferred("refresh")
