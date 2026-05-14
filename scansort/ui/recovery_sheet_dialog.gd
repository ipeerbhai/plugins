extends AcceptDialog
## Recovery Sheet dialog — edit emergency-contact metadata and a custom extraction
## guide for a vault, and optionally generate a plain-text recovery sheet file.
##
## No class_name — off-tree plugin script; use preload().
##
## Usage:
##   var dlg = preload("recovery_sheet_dialog.gd").new()
##   add_child(dlg)
##   dlg.init(conn, vault_path, vault_password)
##   dlg.recovery_changed.connect(func(): ...)
##   dlg.closed.connect(func(): dlg.queue_free())
##   dlg.popup_centered(Vector2i(660, 560))

signal recovery_changed()
signal closed()

var _conn: Object = null
var _vault_path: String = ""
var _vault_password: String = ""

var _name_edit: LineEdit = null
var _email_edit: LineEdit = null
var _phone_edit: LineEdit = null
var _guide_edit: TextEdit = null
var _status_label: Label = null

const _UiScale := preload("ui_scale.gd")


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Recovery Sheet"
	min_size = Vector2(620, 520)
	ok_button_text = "Save"
	confirmed.connect(_on_save_pressed)
	canceled.connect(_on_close_pressed)


## Public constructor — call after add_child.
func init(conn: Object, vault_path: String, vault_password: String) -> void:
	_conn = conn
	_vault_path = vault_path
	_vault_password = vault_password
	_build_ui()
	call_deferred("_load_current_values")


func _build_ui() -> void:
	# Remove any previously-added VBoxContainers if reinitialising.
	for child in get_children():
		if child is VBoxContainer:
			child.queue_free()

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)

	# --- Emergency contact name ---
	var name_row := HBoxContainer.new()
	name_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	name_lbl.text = "Emergency contact name"
	name_lbl.custom_minimum_size.x = 200
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.placeholder_text = "Full name of trusted contact"
	name_row.add_child(_name_edit)
	root.add_child(name_row)

	# --- Emergency contact email ---
	var email_row := HBoxContainer.new()
	email_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var email_lbl := Label.new()
	email_lbl.text = "Emergency contact email"
	email_lbl.custom_minimum_size.x = 200
	email_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	email_row.add_child(email_lbl)
	_email_edit = LineEdit.new()
	_email_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_email_edit.placeholder_text = "contact@example.com"
	email_row.add_child(_email_edit)
	root.add_child(email_row)

	# --- Emergency contact phone ---
	var phone_row := HBoxContainer.new()
	phone_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var phone_lbl := Label.new()
	phone_lbl.text = "Emergency contact phone"
	phone_lbl.custom_minimum_size.x = 200
	phone_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	phone_row.add_child(phone_lbl)
	_phone_edit = LineEdit.new()
	_phone_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_edit.placeholder_text = "+1 (555) 000-0000"
	phone_row.add_child(_phone_edit)
	root.add_child(phone_row)

	# --- Separator ---
	root.add_child(HSeparator.new())

	# --- Extraction guide label ---
	var guide_lbl := Label.new()
	guide_lbl.text = "Extraction guide (optional — custom instructions for recovering documents\nwithout Scansort; leave blank to use the default SQLite-fallback guide)"
	guide_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(guide_lbl)

	# --- Extraction guide TextEdit ---
	_guide_edit = TextEdit.new()
	_guide_edit.custom_minimum_size = Vector2(580, 110)
	_guide_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_guide_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_guide_edit.placeholder_text = "Leave blank for the default SQLite recovery guide."
	root.add_child(_guide_edit)

	# --- Separator ---
	root.add_child(HSeparator.new())

	# --- Generate button + status ---
	var bottom_row := HBoxContainer.new()
	bottom_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom_row.add_child(_status_label)

	var gen_btn := Button.new()
	gen_btn.text = "Generate Recovery Sheet..."
	gen_btn.pressed.connect(_on_generate_pressed)
	bottom_row.add_child(gen_btn)

	root.add_child(bottom_row)
	add_child(root)


func _load_current_values() -> void:
	if _conn == null or _vault_path.is_empty():
		return
	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_get_project_keys",
		{
			"vault_path": _vault_path,
			"keys": [
				"emergency_contact_name",
				"emergency_contact_email",
				"emergency_contact_phone",
				"extraction_guide",
			],
		}
	)
	if not result.get("ok", false):
		return
	var values: Dictionary = result.get("values", {}) as Dictionary if result.get("values") is Dictionary else {}
	if _name_edit != null:
		_name_edit.text = str(values.get("emergency_contact_name", ""))
	if _email_edit != null:
		_email_edit.text = str(values.get("emergency_contact_email", ""))
	if _phone_edit != null:
		_phone_edit.text = str(values.get("emergency_contact_phone", ""))
	if _guide_edit != null:
		_guide_edit.text = str(values.get("extraction_guide", ""))


func _on_save_pressed() -> void:
	if _conn == null:
		if _status_label != null:
			_status_label.text = "ERROR: no connection."
		return

	var fields: Array = [
		["emergency_contact_name",  _name_edit.text  if _name_edit  != null else ""],
		["emergency_contact_email", _email_edit.text if _email_edit != null else ""],
		["emergency_contact_phone", _phone_edit.text if _phone_edit != null else ""],
		["extraction_guide",        _guide_edit.text if _guide_edit != null else ""],
	]

	for pair: Array in fields:
		var key: String = str(pair[0])
		var value: String = str(pair[1])
		var res: Dictionary = await _conn.call_tool(
			"minerva_scansort_update_project_key",
			{"path": _vault_path, "key": key, "value": value}
		)
		if not res.get("ok", false):
			var err: String = str(res.get("error", "unknown error"))
			if _status_label != null:
				_status_label.text = "Save failed (%s): %s" % [key, err]
			return

	recovery_changed.emit()
	closed.emit()


func _on_close_pressed() -> void:
	closed.emit()


func _on_generate_pressed() -> void:
	var fd := FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.title = "Save Recovery Sheet"
	fd.filters = PackedStringArray(["*.txt ; Text Files"])
	fd.current_file = "recovery_sheet.txt"
	fd.file_selected.connect(_on_generate_file_selected)
	fd.canceled.connect(func() -> void: fd.queue_free())
	add_child(fd)
	fd.popup_centered(Vector2i(700, 500))


func _on_generate_file_selected(save_path: String) -> void:
	# Find and free the FileDialog.
	for child in get_children():
		if child is FileDialog:
			child.queue_free()
			break

	var text: String = await _build_recovery_sheet_text()
	if text.is_empty():
		if _status_label != null:
			_status_label.text = "ERROR: failed to build recovery sheet."
		return

	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		var err_code: int = FileAccess.get_open_error()
		if _status_label != null:
			_status_label.text = "ERROR: could not write file (error %d)." % err_code
		return
	f.store_string(text)
	f.close()

	if _status_label != null:
		_status_label.text = "Recovery sheet written: %s" % save_path


func _build_recovery_sheet_text() -> String:
	if _conn == null or _vault_path.is_empty():
		return ""

	# Fetch all relevant project keys.
	var keys_result: Dictionary = await _conn.call_tool(
		"minerva_scansort_get_project_keys",
		{
			"vault_path": _vault_path,
			"keys": [
				"name",
				"version",
				"created_at",
				"password_hint",
				"software_url",
				"emergency_contact_name",
				"emergency_contact_email",
				"emergency_contact_phone",
				"extraction_guide",
			],
		}
	)
	if not keys_result.get("ok", false):
		return ""
	var kv: Dictionary = keys_result.get("values", {}) as Dictionary if keys_result.get("values") is Dictionary else {}

	var vault_name:    String = str(kv.get("name",                   ""))
	var vault_version: String = str(kv.get("version",                ""))
	var created_at:    String = str(kv.get("created_at",             ""))
	var pw_hint:       String = str(kv.get("password_hint",          ""))
	var software_url:  String = str(kv.get("software_url",           ""))
	var ec_name:       String = str(kv.get("emergency_contact_name",  ""))
	var ec_email:      String = str(kv.get("emergency_contact_email", ""))
	var ec_phone:      String = str(kv.get("emergency_contact_phone", ""))
	var guide:         String = str(kv.get("extraction_guide",        ""))

	# Fetch document count + category breakdown.
	var doc_count: int = 0
	var categories: Dictionary = {}
	var docs_result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": _vault_path}
	)
	if docs_result.get("ok", false):
		var docs: Array = docs_result.get("documents", []) as Array if docs_result.get("documents") is Array else []
		doc_count = docs.size()
		for doc: Dictionary in docs:
			var cat: String = str(doc.get("category", "uncategorized"))
			if cat.is_empty():
				cat = "uncategorized"
			categories[cat] = int(categories.get(cat, 0)) + 1

	# --- Build the plain-text sheet ---
	var lines: PackedStringArray = PackedStringArray()

	var title_text: String = "SCANSORT VAULT RECOVERY SHEET"
	lines.append(title_text)
	lines.append("=".repeat(title_text.length()))
	lines.append("")

	# Vault metadata
	lines.append("Vault name   : %s" % (vault_name if not vault_name.is_empty() else "(unnamed)"))
	lines.append("Version      : %s" % (vault_version if not vault_version.is_empty() else "(unknown)"))
	lines.append("Created      : %s" % (created_at   if not created_at.is_empty()   else "(unknown)"))
	lines.append("Documents    : %d" % doc_count)
	lines.append("")

	# Category breakdown
	if not categories.is_empty():
		lines.append("Category breakdown:")
		var sorted_cats: Array = categories.keys()
		sorted_cats.sort()
		for cat: String in sorted_cats:
			lines.append("  %-30s %d" % [cat + ":", int(categories[cat])])
		lines.append("")

	# Password hint
	if not pw_hint.is_empty():
		lines.append("Password hint: %s" % pw_hint)
		lines.append("")

	# Emergency contact
	var has_ec: bool = (not ec_name.is_empty()) or (not ec_email.is_empty()) or (not ec_phone.is_empty())
	if has_ec:
		lines.append("Emergency contact:")
		if not ec_name.is_empty():
			lines.append("  Name  : %s" % ec_name)
		if not ec_email.is_empty():
			lines.append("  Email : %s" % ec_email)
		if not ec_phone.is_empty():
			lines.append("  Phone : %s" % ec_phone)
		lines.append("")

	# Extraction guide
	var section_title: String = "HOW TO RECOVER YOUR DOCUMENTS"
	lines.append(section_title)
	lines.append("-".repeat(section_title.length()))
	if not guide.is_empty():
		lines.append(guide)
	else:
		lines.append("The .ssort file is a standard SQLite 3 database.")
		lines.append("Open it with DB Browser for SQLite (https://sqlitebrowser.org/).")
		lines.append("")
		lines.append("The 'documents' table holds all stored files. Key columns:")
		lines.append("  display_name  — original filename")
		lines.append("  category      — document category")
		lines.append("  file_data     — file bytes, compressed with zstd")
		lines.append("  encryption_iv — present if this document is AES-256-GCM encrypted")
		lines.append("")
		lines.append("To decompress a document:")
		lines.append("  1. Export the file_data blob from DB Browser.")
		lines.append("  2. Decompress it with: zstd -d file_data.bin -o output_file")
		lines.append("")
		lines.append("Encrypted documents (encryption_iv is non-empty) also require the")
		lines.append("vault password for AES-256-GCM decryption. All other metadata")
		lines.append("(category, sender, description, dates, tags) is stored as plain text.")
		if not software_url.is_empty():
			lines.append("")
			lines.append("Download Scansort to open this vault normally: %s" % software_url)
	lines.append("")

	# Footer
	lines.append("Generated: %s" % Time.get_datetime_string_from_system())

	return "\n".join(lines)
