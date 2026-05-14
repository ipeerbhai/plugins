extends AcceptDialog
## Scansort Settings dialog.
##
## Per-plugin user preference: classification model override.
## Per-vault settings (when a vault is open): destination mode + disk_root.
## Per-user setting: Process All concurrency (1–4).
##
## Storage: OS.get_user_data_dir() + "/scansort_settings.json"
##   { "model_override": {kind: ..., ...} | null,
##     "process_concurrency": int }
##
## Destination mode is stored in the vault's project table via MCP tools
## (minerva_scansort_get_destination / set_destination).
##
## Usage:
##   var dlg = preload("settings_dialog.gd").new()
##   dlg.init(conn, vault_path)   # vault_path may be empty
##   add_child(dlg)
##   dlg.settings_changed.connect(_on_settings_changed)
##   dlg.popup_centered(Vector2(580, 420))
##
## No class_name — off-tree plugin script; use preload().

## Emitted after the user clicks Save. Caller may reload _resolve_chat_model_for_classify.
signal settings_changed

## Emitted when the dialog closes (either save or cancel).
signal closed

# ---------------------------------------------------------------------------
# Dependencies (injected via init())
# ---------------------------------------------------------------------------

var _conn: Object = null
var _vault_path: String = ""

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

var _model_picker:   OptionButton = null
var _help_label:     Label        = null
var _dest_picker:    OptionButton = null
var _disk_root_edit: LineEdit     = null
var _disk_root_btn:  Button       = null
var _dest_section:   Control      = null   # container to enable/disable
var _concurrency_spin: SpinBox    = null
var _dest_error_lbl: Label        = null   # visible error for missing disk_root
## W7: near-dup threshold controls.
var _simhash_spin: SpinBox = null
var _dhash_spin:   SpinBox = null


const _UiScale := preload("ui_scale.gd")


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Scansort Settings"
	min_size = Vector2(580, 420)
	ok_button_text = "Save"
	confirmed.connect(_on_save_pressed)
	canceled.connect(_on_close_pressed)
	_build_ui()


## Inject the plugin connection and optional vault path.
## Settings file is loaded on demand; vault destination loaded if vault_path non-empty.
func init(conn: Object, vault_path: String = "") -> void:
	_conn = conn
	_vault_path = vault_path
	# Defer until added to scene so widgets are populated.
	call_deferred("_load_current_settings")


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)

	# --- Model row ---------------------------------------------------------
	var model_row := HBoxContainer.new()
	model_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var model_lbl := Label.new()
	model_lbl.text = "Classification model"
	model_lbl.custom_minimum_size.x = 180
	model_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	model_row.add_child(model_lbl)

	_model_picker = OptionButton.new()
	_model_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_picker.tooltip_text = "Model used for document classification. \"Inherit from chat panel\" follows whichever model the chat panel currently has selected."
	model_row.add_child(_model_picker)
	root.add_child(model_row)

	# --- Help text ---------------------------------------------------------
	_help_label = Label.new()
	_help_label.text = "Scansort uses a single multimodal model for text and vision classification. Pick one that supports images, or leave inherited to follow the chat panel."
	_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	root.add_child(_help_label)

	# --- Separator ---------------------------------------------------------
	root.add_child(HSeparator.new())

	# --- Destination section (per-vault; disabled if no vault open) --------
	_dest_section = VBoxContainer.new()
	_dest_section.add_theme_constant_override("separation", 6)

	var dest_title := Label.new()
	dest_title.text = "Destination" + ("" if not _vault_path.is_empty() else " (open a vault to configure)")
	dest_title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	_dest_section.add_child(dest_title)

	var dest_row := HBoxContainer.new()
	dest_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dest_lbl := Label.new()
	dest_lbl.text = "Mode"
	dest_lbl.custom_minimum_size.x = 80
	dest_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dest_row.add_child(dest_lbl)

	_dest_picker = OptionButton.new()
	_dest_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dest_picker.add_item("Vault only", 0)
	_dest_picker.set_item_metadata(0, "vault_only")
	_dest_picker.add_item("Disk only", 1)
	_dest_picker.set_item_metadata(1, "disk_only")
	_dest_picker.add_item("Vault and disk", 2)
	_dest_picker.set_item_metadata(2, "vault_and_disk")
	dest_row.add_child(_dest_picker)
	_dest_section.add_child(dest_row)

	var disk_row := HBoxContainer.new()
	disk_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var disk_lbl := Label.new()
	disk_lbl.text = "Disk root"
	disk_lbl.custom_minimum_size.x = 80
	disk_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	disk_row.add_child(disk_lbl)

	_disk_root_edit = LineEdit.new()
	_disk_root_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_disk_root_edit.placeholder_text = "/path/to/disk/root"
	disk_row.add_child(_disk_root_edit)

	_disk_root_btn = Button.new()
	_disk_root_btn.text = "Browse…"
	_disk_root_btn.pressed.connect(_on_browse_disk_root_pressed)
	disk_row.add_child(_disk_root_btn)
	_dest_section.add_child(disk_row)

	# Error label for missing disk_root.
	_dest_error_lbl = Label.new()
	_dest_error_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_dest_error_lbl.text = ""
	_dest_error_lbl.visible = false
	_dest_section.add_child(_dest_error_lbl)

	# Disable the entire destination section if no vault is open.
	if _vault_path.is_empty():
		_dest_picker.disabled = true
		_disk_root_edit.editable = false
		_disk_root_btn.disabled = true

	root.add_child(_dest_section)

	# --- Separator ---------------------------------------------------------
	root.add_child(HSeparator.new())

	# --- Concurrency row ---------------------------------------------------
	var conc_row := HBoxContainer.new()
	conc_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var conc_lbl := Label.new()
	conc_lbl.text = "Process All concurrency"
	conc_lbl.custom_minimum_size.x = 180
	conc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	conc_row.add_child(conc_lbl)

	_concurrency_spin = SpinBox.new()
	_concurrency_spin.min_value = 1
	_concurrency_spin.max_value = 4
	_concurrency_spin.step = 1
	_concurrency_spin.value = ScansortSettings.load_concurrency()
	_concurrency_spin.tooltip_text = "Number of files processed in parallel during Process All (1 = sequential)."
	conc_row.add_child(_concurrency_spin)
	root.add_child(conc_row)

	# --- Separator ---------------------------------------------------------
	root.add_child(HSeparator.new())

	# --- W7: Near-dup thresholds section -----------------------------------
	var dedup_title := Label.new()
	dedup_title.text = "Near-Duplicate Detection"
	dedup_title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	root.add_child(dedup_title)

	var dedup_help := Label.new()
	dedup_help.text = "SimHash compares text fingerprints; dHash compares image fingerprints. Threshold = max Hamming-distance bits to flag as near-duplicate. Set to 0 to disable that layer."
	dedup_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dedup_help.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	root.add_child(dedup_help)

	# SimHash threshold row.
	var simhash_row := HBoxContainer.new()
	simhash_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var simhash_lbl := Label.new()
	simhash_lbl.text = "SimHash threshold"
	simhash_lbl.custom_minimum_size.x = 180
	simhash_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	simhash_row.add_child(simhash_lbl)

	_simhash_spin = SpinBox.new()
	_simhash_spin.min_value = 0
	_simhash_spin.max_value = 64
	_simhash_spin.step = 1
	_simhash_spin.value = ScansortSettings.load_simhash_threshold()
	_simhash_spin.tooltip_text = "SimHash Hamming-distance threshold for near-dup text detection (0–64). Default: 3. Set 0 to disable."
	simhash_row.add_child(_simhash_spin)
	root.add_child(simhash_row)

	# dHash threshold row.
	var dhash_row := HBoxContainer.new()
	dhash_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dhash_lbl := Label.new()
	dhash_lbl.text = "Image hash threshold"
	dhash_lbl.custom_minimum_size.x = 180
	dhash_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dhash_row.add_child(dhash_lbl)

	_dhash_spin = SpinBox.new()
	_dhash_spin.min_value = 0
	_dhash_spin.max_value = 64
	_dhash_spin.step = 1
	_dhash_spin.value = ScansortSettings.load_dhash_threshold()
	_dhash_spin.tooltip_text = "Image perceptual dHash Hamming-distance threshold (0–64). Default: 0 (disabled). Set > 0 to enable image near-dup detection."
	dhash_row.add_child(_dhash_spin)
	root.add_child(dhash_row)

	add_child(root)


## Populate the model picker and (if vault open) load destination settings.
func _load_current_settings() -> void:
	if _model_picker == null:
		return
	_model_picker.clear()
	_model_picker.add_item("Inherit from chat panel", 0)
	_model_picker.set_item_metadata(0, {})

	# Reach ChatPane via SingletonObject.Chats.
	var model_list: Array = []
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() != null else null
	if so != null:
		var chats = so.get("Chats") if "Chats" in so else null
		if chats != null and chats.has_method("get_available_models"):
			model_list = chats.get_available_models()

	for i in range(model_list.size()):
		var entry: Dictionary = model_list[i]
		var spec: Dictionary = entry.get("spec", {}) as Dictionary if entry.get("spec") is Dictionary else {}
		var display: String = str(entry.get("display_name", "?"))
		var item_id: int = i + 1
		_model_picker.add_item(display, item_id)
		_model_picker.set_item_metadata(item_id, spec)

	# Restore previously-saved model selection.
	var override: Dictionary = ScansortSettings.load_model_override()
	var target_idx: int = 0  # default to "Inherit"
	if not override.is_empty():
		for i in range(_model_picker.get_item_count()):
			var meta = _model_picker.get_item_metadata(i)
			if meta is Dictionary and not (meta as Dictionary).is_empty():
				if _specs_match(meta as Dictionary, override):
					target_idx = i
					break
	_model_picker.select(target_idx)

	# Load destination settings from vault (async — safe here since called deferred).
	if not _vault_path.is_empty() and _conn != null and _dest_picker != null:
		var dest_result: Dictionary = await _conn.call_tool(
			"minerva_scansort_get_destination",
			{"vault_path": _vault_path}
		)
		if dest_result.get("ok", false):
			var mode: String = str(dest_result.get("mode", "vault_only"))
			var disk_root: String = str(dest_result.get("disk_root", ""))
			# Find the matching OptionButton item by metadata.
			for i in range(_dest_picker.get_item_count()):
				if str(_dest_picker.get_item_metadata(i)) == mode:
					_dest_picker.select(i)
					break
			if _disk_root_edit != null:
				_disk_root_edit.text = disk_root


## Shallow equality on the two fields that uniquely identify a spec:
## "kind" plus whatever follows for that kind (model_id for builtin/dynamic,
## service_client_id+action_name for core_action).
static func _specs_match(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	match str(a.get("kind", "")):
		"core_action":
			return (
				str(a.get("service_client_id", "")) == str(b.get("service_client_id", ""))
				and str(a.get("action_name", "")) == str(b.get("action_name", ""))
			)
		_:
			return int(a.get("model_id", 0)) == int(b.get("model_id", 0))


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_save_pressed() -> void:
	if _model_picker == null:
		closed.emit()
		return
	var idx: int = _model_picker.get_selected()
	if idx < 0:
		closed.emit()
		return
	var meta = _model_picker.get_item_metadata(idx)
	var spec: Dictionary = meta as Dictionary if meta is Dictionary else {}
	# Empty spec → inherit (clears the override).
	ScansortSettings.save_model_override(spec)

	# Save concurrency.
	if _concurrency_spin != null:
		ScansortSettings.save_concurrency(int(_concurrency_spin.value))

	# W7: Save near-dup thresholds.
	if _simhash_spin != null:
		ScansortSettings.save_simhash_threshold(int(_simhash_spin.value))
	if _dhash_spin != null:
		ScansortSettings.save_dhash_threshold(int(_dhash_spin.value))

	# Save destination (vault-level, async) — only when vault is open.
	if not _vault_path.is_empty() and _conn != null and _dest_picker != null:
		var dest_idx: int = _dest_picker.get_selected()
		var mode: String = str(_dest_picker.get_item_metadata(dest_idx)) if dest_idx >= 0 else "vault_only"
		var disk_root: String = _disk_root_edit.text.strip_edges() if _disk_root_edit != null else ""

		# Require disk_root for non-vault_only modes.
		if mode != "vault_only" and disk_root.is_empty():
			if _dest_error_lbl != null:
				_dest_error_lbl.text = "disk_root is required for %s mode." % mode
				_dest_error_lbl.visible = true
			# Do NOT close — let user fix the error.
			return

		if _dest_error_lbl != null:
			_dest_error_lbl.visible = false

		var set_args: Dictionary = {"vault_path": _vault_path, "mode": mode}
		if not disk_root.is_empty():
			set_args["disk_root"] = disk_root
		await _conn.call_tool("minerva_scansort_set_destination", set_args)

	settings_changed.emit()
	closed.emit()


func _on_browse_disk_root_pressed() -> void:
	var fd := FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.title = "Choose disk root directory"
	fd.dir_selected.connect(func(dir: String) -> void:
		if _disk_root_edit != null:
			_disk_root_edit.text = dir
		fd.queue_free()
	)
	fd.canceled.connect(func() -> void:
		fd.queue_free()
	)
	add_child(fd)
	fd.popup_centered(Vector2i(700, 500))


func _on_close_pressed() -> void:
	closed.emit()


# ---------------------------------------------------------------------------
# Storage — inline because GDScript can't preload a sibling const in a class
# body inside an AcceptDialog subclass without name collisions.
# ---------------------------------------------------------------------------

class ScansortSettings:
	const SETTINGS_FILENAME := "scansort_settings.json"

	## Returns the absolute path to the per-user scansort settings JSON.
	static func settings_path() -> String:
		return OS.get_user_data_dir() + "/" + SETTINGS_FILENAME

	## Read the full settings blob, or {} on missing/corrupt file.
	static func _load_blob() -> Dictionary:
		var path := settings_path()
		if not FileAccess.file_exists(path):
			return {}
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return {}
		var text: String = f.get_as_text()
		f.close()
		var parsed: Variant = JSON.parse_string(text)
		if not (parsed is Dictionary):
			return {}
		return parsed as Dictionary

	## Write the blob to disk. Creates parent dir if missing. Returns true on success.
	static func _save_blob(blob: Dictionary) -> bool:
		var path := settings_path()
		var dir := path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			var err := DirAccess.make_dir_recursive_absolute(dir)
			if err != OK:
				push_error("[ScansortSettings] could not create %s (error %d)" % [dir, err])
				return false
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_error("[ScansortSettings] could not write %s" % path)
			return false
		f.store_string(JSON.stringify(blob, "  "))
		f.close()
		return true

	## Read the saved model override spec. Returns an empty Dict when no
	## override is set (i.e. inherit-from-chat is in effect).
	static func load_model_override() -> Dictionary:
		var blob := _load_blob()
		var raw = blob.get("model_override", null)
		if raw is Dictionary:
			return raw as Dictionary
		return {}

	## Save the model override spec. Empty Dict → write null (inherit mode).
	## Read-modify-write so other keys (concurrency) are preserved.
	static func save_model_override(spec: Dictionary) -> bool:
		var blob := _load_blob()
		if spec.is_empty():
			blob["model_override"] = null
		else:
			blob["model_override"] = spec
		return _save_blob(blob)

	## Read the saved process concurrency. Returns 1 (sequential) as default.
	## Clamped to [1, 4].
	static func load_concurrency() -> int:
		var blob := _load_blob()
		var raw = blob.get("process_concurrency", 1)
		var n: int = int(raw)
		return clampi(n, 1, 4)

	## Save the process concurrency. Read-modify-write to preserve other keys.
	static func save_concurrency(n: int) -> void:
		var blob := _load_blob()
		blob["process_concurrency"] = clampi(n, 1, 4)
		_save_blob(blob)

	## Read the saved SimHash near-dup threshold. Default is 3 (experiment default).
	## Clamped to [0, 64].
	static func load_simhash_threshold() -> int:
		var blob := _load_blob()
		var raw = blob.get("simhash_threshold", 3)
		return clampi(int(raw), 0, 64)

	## Save the SimHash near-dup threshold. Read-modify-write to preserve other keys.
	static func save_simhash_threshold(n: int) -> void:
		var blob := _load_blob()
		blob["simhash_threshold"] = clampi(n, 0, 64)
		_save_blob(blob)

	## Read the saved dHash near-dup threshold. Default is 0 (disabled by default).
	## Clamped to [0, 64].
	static func load_dhash_threshold() -> int:
		var blob := _load_blob()
		var raw = blob.get("dhash_threshold", 0)
		return clampi(int(raw), 0, 64)

	## Save the dHash near-dup threshold. Read-modify-write to preserve other keys.
	static func save_dhash_threshold(n: int) -> void:
		var blob := _load_blob()
		blob["dhash_threshold"] = clampi(n, 0, 64)
		_save_blob(blob)
