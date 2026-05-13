extends AcceptDialog
## Plugin Settings dialog — T7 R5.
##
## Edits per-vault plugin settings (stored via minerva_scansort_update_project_key).
##
## Fields kept for R5 (all others from experiment's settings_dialog.gd dropped):
##   text_model_id    — LLM model for text-mode classification (was hardcoded)
##   vision_model_id  — LLM model for vision-mode classification
##   max_text_chars   — SpinBox, how many chars to send to the classifier
##   default_category — fallback category if classification is ambiguous
##
## Fields DROPPED (not applicable to plugin context):
##   python_path            — plugin is pure Rust, no Python
##   output_dir, incoming_dir — plugin doesn't manage filesystem mode
##   classify_timeout, max_concurrent — orchestration handled in panel
##   dedup_enabled, dedup_threshold, dedup_dhash_threshold — not exposed in R5
##   minerva_rest_url/ws_url, minerva_username/password — not applicable
##   auto_process — no daemon mode in plugin
##   emergency_contact_* — vault-admin data, not plugin settings
##
## Settings load:
##   There is no dedicated get_project_key MCP tool. On open, we fall back to
##   sensible defaults. The panel's _settings cache is the source of truth for
##   the session; changes are persisted via update_project_key on Save.
##
## Usage:
##   var dlg = preload("settings_dialog.gd").new()
##   dlg.init(conn, vault_path, vault_password)
##   add_child(dlg)
##   dlg.settings_changed.connect(_on_settings_changed)
##   dlg.popup_centered(Vector2i(520, 320))
##
## No class_name — off-tree plugin script; use preload().

## Emitted after the user clicks OK and settings are saved to the vault.
## settings: Dictionary with keys text_model_id, vision_model_id, max_text_chars, default_category.
signal settings_changed(settings: Dictionary)

## Emitted when the dialog closes (either save or cancel).
signal closed

# ---------------------------------------------------------------------------
# Dependencies (injected via init())
# ---------------------------------------------------------------------------

var _conn:           Object = null
var _vault_path:     String = ""
var _vault_password: String = ""   # never logged

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

## field_key → widget (LineEdit or SpinBox)
var _fields: Dictionary = {}


func _ready() -> void:
	title = "Scansort Settings"
	min_size = Vector2i(520, 300)
	ok_button_text = "Save"
	confirmed.connect(_on_save)
	canceled.connect(_on_cancel)
	_build_form()


## Inject vault connection + credentials, then populate the form with defaults.
## Pass current_settings to pre-populate from the panel's cached _settings.
func init(conn: Object, vault_path: String, vault_password: String,
		current_settings: Dictionary = {}) -> void:
	_conn           = conn
	_vault_path     = vault_path
	_vault_password = vault_password  # never logged
	_populate_from(current_settings)


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_form() -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# text_model_id — LineEdit
	_fields["text_model_id"] = _add_line_field(vbox,
		"Text Model ID",
		"claude-opus-4-7",
		"LLM model for text-mode classification")

	# vision_model_id — LineEdit
	_fields["vision_model_id"] = _add_line_field(vbox,
		"Vision Model ID",
		"claude-opus-4-7",
		"LLM model for vision-mode (image) classification")

	# max_text_chars — SpinBox
	var max_chars_hbox := HBoxContainer.new()
	max_chars_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var max_chars_lbl := Label.new()
	max_chars_lbl.text = "Max Text Chars"
	max_chars_lbl.custom_minimum_size.x = 160
	max_chars_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	max_chars_hbox.add_child(max_chars_lbl)
	var spin := SpinBox.new()
	spin.min_value   = 100
	spin.max_value   = 100000
	spin.step        = 100
	spin.value       = 4000
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_chars_hbox.add_child(spin)
	_fields["max_text_chars"] = spin
	vbox.add_child(max_chars_hbox)

	# default_category — LineEdit
	_fields["default_category"] = _add_line_field(vbox,
		"Default Category",
		"",
		"Fallback category if classification is ambiguous")

	add_child(vbox)


## Helper: add a labelled LineEdit row, return the LineEdit.
func _add_line_field(container: Control, label_text: String,
		default_val: String, placeholder: String) -> LineEdit:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 160
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(lbl)

	var edit := LineEdit.new()
	edit.text = default_val
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(edit)

	container.add_child(hbox)
	return edit


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Populate form fields from a settings dict (e.g. the panel's _settings cache).
## Keys: text_model_id, vision_model_id, max_text_chars, default_category.
func _populate_from(s: Dictionary) -> void:
	if not _fields.has("text_model_id"):
		return  # form not yet built; init() called before _ready — safe because
				# _ready builds form first, then init() populates.

	if s.has("text_model_id"):
		(_fields["text_model_id"] as LineEdit).text = str(s["text_model_id"])

	if s.has("vision_model_id"):
		(_fields["vision_model_id"] as LineEdit).text = str(s["vision_model_id"])

	if s.has("max_text_chars"):
		var v: Variant = s["max_text_chars"]
		(_fields["max_text_chars"] as SpinBox).value = float(v)

	if s.has("default_category"):
		(_fields["default_category"] as LineEdit).text = str(s["default_category"])


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_save() -> void:
	var settings := _read_form()

	# Persist to vault via update_project_key (one call per key).
	# If no vault is open, skip persistence but still emit settings_changed.
	if _conn != null and not _vault_path.is_empty():
		var base: Dictionary = {"path": _vault_path}
		if not _vault_password.is_empty():
			base["password"] = _vault_password

		for key: String in ["text_model_id", "vision_model_id", "default_category"]:
			var args: Dictionary = base.duplicate()
			args["key"]   = key
			args["value"] = str(settings.get(key, ""))
			var _res: Dictionary = await _conn.call_tool(
				"minerva_scansort_update_project_key", args
			)

		# max_text_chars stored as string
		var chars_args: Dictionary = base.duplicate()
		chars_args["key"]   = "max_text_chars"
		chars_args["value"] = str(int(settings.get("max_text_chars", 4000)))
		var _chars_res: Dictionary = await _conn.call_tool(
			"minerva_scansort_update_project_key", chars_args
		)

	settings_changed.emit(settings)
	# AcceptDialog auto-hides on confirm; emit closed so panel can queue_free us.
	closed.emit()


func _on_cancel() -> void:
	closed.emit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Read current form values into a settings Dictionary.
func _read_form() -> Dictionary:
	var result: Dictionary = {}

	if _fields.has("text_model_id"):
		result["text_model_id"] = (_fields["text_model_id"] as LineEdit).text.strip_edges()

	if _fields.has("vision_model_id"):
		result["vision_model_id"] = (_fields["vision_model_id"] as LineEdit).text.strip_edges()

	if _fields.has("max_text_chars"):
		result["max_text_chars"] = int((_fields["max_text_chars"] as SpinBox).value)

	if _fields.has("default_category"):
		result["default_category"] = (_fields["default_category"] as LineEdit).text.strip_edges()

	return result
