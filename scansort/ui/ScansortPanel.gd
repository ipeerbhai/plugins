class_name Scansort_Panel
extends MinervaPluginPanel
## Scansort vault browser panel — T7 R1 substrate.
##
## Layout:
##   VBoxContainer
##     HBoxContainer  (toolbar)
##       MenuButton   "File"
##       Label        (status bar text, right-aligned)
##     HSplitContainer
##       Panel        LeftPane   — placeholder for R2's file tree
##       Panel        RightPane  — placeholder for R2's detail/status view
##
## Open-vault flow (R1):
##   1. User clicks File → "Open Vault…"
##   2. FileDialog opens; user picks a .ssort file
##   3. Panel calls minerva_scansort_check_vault_has_password
##   4a. No password → calls minerva_scansort_open_vault → enters "vault ready" state
##   4b. Has password → shows PasswordDialog in ENTER mode
##       → user submits → calls minerva_scansort_verify_password
##       → on success → calls minerva_scansort_open_vault → enters "vault ready" state
##
## Create-vault flow (R1):
##   1. User clicks File → "New Vault…"
##   2. FileDialog (SAVE_FILE mode) opens; user picks location + .ssort name
##   3. Panel calls minerva_scansort_create_vault
##   4. Shows PasswordDialog in SET mode (optional — user can skip)
##   5. If password set → calls minerva_scansort_set_password
##   6. Enters "vault ready" state
##
## R2 will populate LeftPane / RightPane via vault_opened signal.
##
## Ported from: ccsandbox/experiments/scansort/scripts/ui/app_shell.gd
## Architectural differences from experiment:
##   - No class_name autoloads (ScanFileTree, ScanVaultPanel, etc.)
##   - No VaultStore direct calls — all vault operations go via conn.call_tool()
##   - PasswordDialog adapted: does not hold a VaultStore reference
##   - Plugin connection guard in every _on_*_pressed handler

## Preload the password dialog script (off-tree: no class_name).
const _PasswordDialog: Script = preload("password_dialog.gd")

## R2 view scripts (off-tree: no class_name on any of these).
const _FileTree:    Script = preload("file_tree.gd")
const _VaultView:   Script = preload("vault_view.gd")
const _StatusPanel: Script = preload("status_panel.gd")

## R3: add-document dialog (off-tree: no class_name).
const _AddDocumentDialog: Script = preload("add_document_dialog.gd")

## R4: edit-details and rules-editor dialogs (off-tree: no class_name).
const _EditDetailsDialog: Script  = preload("edit_details_dialog.gd")
const _RulesEditorDialog: Script  = preload("rules_editor_dialog.gd")

## R5: vault registry and settings dialogs (off-tree: no class_name).
const _VaultRegistryDialog: Script = preload("vault_registry_dialog.gd")
const _SettingsDialog: Script      = preload("settings_dialog.gd")

## R6: checklist dialog (off-tree: no class_name).
const _ChecklistDialog: Script = preload("checklist_dialog.gd")

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted after a vault has been opened successfully.
## R2 panels listen to this to populate their views.
## vault_path: absolute path to the opened .ssort file
## vault_info: Dictionary returned by minerva_scansort_open_vault
signal vault_opened(vault_path: String, vault_info: Dictionary)

## Emitted when the active vault is closed.
signal vault_closed()

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Context dict passed by the platform via _on_panel_loaded.
var _ctx: Dictionary = {}

## Absolute path of the currently open vault (empty if none).
var _active_vault_path: String = ""

## True if a vault is open.
var _vault_is_open: bool = false

## R3: password for the currently open vault (empty if no password set).
## Never logged.
var _vault_password: String = ""

## R3: FileDialog for picking a document to ingest (separate from vault picker).
var _doc_file_dialog: FileDialog = null

## R5: per-vault plugin settings cache.
## Loaded from defaults on vault_opened (no get_project_key tool exists).
## Updated when SettingsDialog emits settings_changed.
## Keys: text_model_id, vision_model_id, max_text_chars, default_category.
var _settings: Dictionary = {}

# ---------------------------------------------------------------------------
# UI widgets
# ---------------------------------------------------------------------------

var _toolbar: HBoxContainer = null
var _file_menu_btn: MenuButton = null
var _status_label: Label = null
var _split: HSplitContainer = null
var _left_pane: Panel = null
var _right_pane: Panel = null

## File dialog (reused for open and create).
## R2 view instances (created in _build_ui, populated on vault_opened).
var _file_tree:    Tree        = null
var _vault_view:   Control     = null
var _status_panel: HBoxContainer = null

var _file_dialog: FileDialog = null

## Password dialog instance (created once, reused).
var _password_dialog: AcceptDialog = null

## Pending action while waiting for password dialog:
##   "open"   — waiting for password to open existing vault
##   "create" — waiting for password to protect a newly-created vault (optional)
##   ""       — no pending action
var _pending_password_action: String = ""

## Path involved in the current pending password action.
var _pending_vault_path: String = ""

## File dialog mode pending (to distinguish open vs create).
var _file_dialog_mode: String = ""  # "open" | "create"

# ---------------------------------------------------------------------------
# Platform hooks
# ---------------------------------------------------------------------------

func _ready() -> void:
	_build_ui()
	set_status("No vault open.")


func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx


func _on_panel_unload() -> void:
	if _file_dialog != null and is_instance_valid(_file_dialog):
		_file_dialog.queue_free()
	if _password_dialog != null and is_instance_valid(_password_dialog):
		_password_dialog.queue_free()

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	# --- Toolbar ---
	_toolbar = HBoxContainer.new()
	_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_file_menu_btn = MenuButton.new()
	_file_menu_btn.text = "File"
	_file_menu_btn.flat = false
	var popup: PopupMenu = _file_menu_btn.get_popup()
	popup.add_item("New Vault...", 0)
	popup.add_item("Open Vault...", 1)
	popup.add_separator()
	popup.add_item("Add Document...", 3)
	popup.add_item("Rules Editor...", 4)
	popup.add_separator()
	popup.add_item("Vault Registry...", 5)
	popup.add_item("Settings...", 6)
	popup.add_item("Checklist...", 7)
	popup.add_separator()
	popup.add_item("Close Vault", 2)
	popup.id_pressed.connect(_on_file_menu_id_pressed)
	_toolbar.add_child(_file_menu_btn)

	# Spacer between menu and status.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(spacer)

	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(_status_label)

	vbox.add_child(_toolbar)

	# --- Split panes ---
	_split = HSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_left_pane = Panel.new()
	_left_pane.name = "LeftPane"
	_left_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_pane.custom_minimum_size.x = 200
	_split.add_child(_left_pane)

	_right_pane = Panel.new()
	_right_pane.name = "RightPane"
	_right_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_pane.custom_minimum_size.x = 200
	_split.add_child(_right_pane)

	vbox.add_child(_split)

	# --- R2: file tree in LeftPane ---
	_file_tree = _FileTree.new()
	_file_tree.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_file_tree.size_flags_vertical  = Control.SIZE_EXPAND_FILL
	_file_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_pane.add_child(_file_tree)

	# --- R2: vault view in RightPane ---
	_vault_view = _VaultView.new()
	_vault_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vault_view.size_flags_vertical  = Control.SIZE_EXPAND_FILL
	_vault_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_pane.add_child(_vault_view)

	# --- R2: status bar at bottom of vbox ---
	_status_panel = _StatusPanel.new()
	_status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_status_panel)

	# Wire file_tree selection → vault_view detail.
	_file_tree.document_selected.connect(_vault_view.on_document_selected)

	# R4: wire vault_view edit button → panel handler.
	_vault_view.edit_details_requested.connect(_on_edit_doc_pressed)

# ---------------------------------------------------------------------------
# Menu handling
# ---------------------------------------------------------------------------

func _on_file_menu_id_pressed(id: int) -> void:
	match id:
		0: _on_new_vault_pressed()
		1: _on_open_vault_pressed()
		2: _on_close_vault_pressed()
		3: _on_add_document_pressed()
		4: _on_rules_editor_pressed()
		5: _on_vault_registry_pressed()
		6: _on_settings_pressed()
		7: _on_checklist_pressed()


func _on_new_vault_pressed() -> void:
	_file_dialog_mode = "create"
	_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, "Create New Vault")


func _on_open_vault_pressed() -> void:
	_file_dialog_mode = "open"
	_open_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Open Vault")


func _on_close_vault_pressed() -> void:
	if not _vault_is_open:
		set_status("No vault is open.")
		return
	_active_vault_path = ""
	_vault_is_open = false
	_vault_password = ""  # R3: clear cached password
	set_status("Vault closed.")
	vault_closed.emit()
	# R2: clear views.
	_on_vault_closed_r2()

# ---------------------------------------------------------------------------
# File dialog
# ---------------------------------------------------------------------------

func _open_file_dialog(mode: FileDialog.FileMode, dialog_title: String) -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.file_selected.connect(_on_file_selected)
		_file_dialog.canceled.connect(_on_file_dialog_cancelled)
		add_child(_file_dialog)

	_file_dialog.file_mode = mode
	_file_dialog.title = dialog_title
	_file_dialog.filters = PackedStringArray(["*.ssort ; Scansort Vault"])
	_file_dialog.popup_centered(Vector2i(700, 500))


func _on_file_selected(path: String) -> void:
	if _file_dialog_mode == "open":
		_begin_open_vault(path)
	elif _file_dialog_mode == "create":
		_begin_create_vault(path)
	_file_dialog_mode = ""


func _on_file_dialog_cancelled() -> void:
	_file_dialog_mode = ""

# ---------------------------------------------------------------------------
# Create vault flow
# ---------------------------------------------------------------------------

func _begin_create_vault(path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Creating vault...")
	var vault_name: String = path.get_file().get_basename()
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": path, "name": vault_name}
	)
	if not result.get("ok", false):
		set_status("ERROR: create_vault failed — %s" % result.get("error", "unknown"))
		return

	set_status("Vault created. Set a password (optional)...")
	_pending_vault_path = path
	_pending_password_action = "create"
	_show_password_dialog_set()


func _on_create_vault_password_submitted(password: String, hint: String, _mode: int) -> void:
	if password.is_empty():
		# No password chosen — open the vault directly.
		_vault_password = ""
		await _do_open_vault(_pending_vault_path)
		_pending_vault_path = ""
		_pending_password_action = ""
		return

	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Setting vault password...")
	var set_result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_password",
		{"path": _pending_vault_path, "password": password}
	)
	if not set_result.get("ok", false):
		set_status("ERROR: set_password failed — %s" % set_result.get("error", "unknown"))
		if is_instance_valid(_password_dialog):
			_password_dialog.show_error("set_password failed: %s" % set_result.get("error", "unknown"))
		return

	if not hint.is_empty():
		# Best-effort: ignore errors on hint storage.
		await conn.call_tool(
			"minerva_scansort_update_project_key",
			{"path": _pending_vault_path, "key": "password_hint", "value": hint}
		)

	# R3: cache the password so the ingest pipeline can use it.
	_vault_password = password
	await _do_open_vault(_pending_vault_path)
	_pending_vault_path = ""
	_pending_password_action = ""

# ---------------------------------------------------------------------------
# Open vault flow
# ---------------------------------------------------------------------------

func _begin_open_vault(path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Checking vault...")
	var pw_check: Dictionary = await conn.call_tool(
		"minerva_scansort_check_vault_has_password",
		{"path": path}
	)
	if not pw_check.get("ok", false):
		set_status("ERROR: check_vault_has_password failed — %s" % pw_check.get("error", "unknown"))
		return

	var has_pw: bool = pw_check.get("has_password", false)
	if not has_pw:
		# No password — open directly.
		await _do_open_vault(path)
		return

	# Has password — ask the user.
	var hint: String = pw_check.get("hint", "")
	_pending_vault_path = path
	_pending_password_action = "open"
	_show_password_dialog_enter(hint)


func _on_open_vault_password_submitted(password: String, _hint: String, _mode: int) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Verifying password...")
	var verify: Dictionary = await conn.call_tool(
		"minerva_scansort_verify_password",
		{"path": _pending_vault_path, "password": password}
	)
	if not verify.get("ok", false):
		set_status("ERROR: verify_password failed — %s" % verify.get("error", "unknown"))
		if is_instance_valid(_password_dialog):
			_password_dialog.show_error("verify_password error: %s" % verify.get("error", "unknown"))
		return

	if not verify.get("verified", false):
		set_status("Incorrect password.")
		if is_instance_valid(_password_dialog):
			_password_dialog.show_wrong_password_error()
		return

	# R3: cache the password for use in the ingest pipeline.
	_vault_password = password
	await _do_open_vault(_pending_vault_path)
	_pending_vault_path = ""
	_pending_password_action = ""


## Final step: call open_vault and transition to vault-ready state.
func _do_open_vault(path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Opening vault...")
	var open_result: Dictionary = await conn.call_tool(
		"minerva_scansort_open_vault",
		{"path": path}
	)
	if not open_result.get("ok", false):
		set_status("ERROR: open_vault failed — %s" % open_result.get("error", "unknown"))
		return

	_active_vault_path = path
	_vault_is_open = true
	# open_vault returns {ok, info: {name, ...}} — name is nested, not flat.
	var vault_info: Dictionary = open_result.get("info", {})
	var vault_name: String = vault_info.get("name", path.get_file())
	set_status("Vault open: %s" % vault_name)
	# R5: reset settings to defaults on each new vault open.
	_load_settings_defaults()
	vault_opened.emit(path, open_result)
	# R2: populate views.
	_on_vault_opened_r2(path, open_result)

# ---------------------------------------------------------------------------
# Password dialog helpers
# ---------------------------------------------------------------------------

func _ensure_password_dialog() -> void:
	if _password_dialog == null or not is_instance_valid(_password_dialog):
		_password_dialog = _PasswordDialog.new()
		add_child(_password_dialog)


func _show_password_dialog_set() -> void:
	_ensure_password_dialog()
	# Disconnect any stale connections.
	if _password_dialog.password_submitted.is_connected(_on_create_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_create_vault_password_submitted)
	if _password_dialog.password_submitted.is_connected(_on_open_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_open_vault_password_submitted)
	_password_dialog.password_submitted.connect(_on_create_vault_password_submitted)
	_password_dialog.show_set_password()


func _show_password_dialog_enter(hint: String) -> void:
	_ensure_password_dialog()
	# Disconnect any stale connections.
	if _password_dialog.password_submitted.is_connected(_on_open_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_open_vault_password_submitted)
	if _password_dialog.password_submitted.is_connected(_on_create_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_create_vault_password_submitted)
	_password_dialog.password_submitted.connect(_on_open_vault_password_submitted)
	_password_dialog.show_enter_password(hint)

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# R2 view coordination
# ---------------------------------------------------------------------------

func _on_vault_opened_r2(path: String, open_result: Dictionary) -> void:
	var conn := _get_connection()
	# open_vault returns {ok, info: {name, ...}} — name is nested, not flat.
	var vault_info: Dictionary = open_result.get("info", {})
	var vault_name: String = vault_info.get("name", path.get_file())
	# Init views — each will call refresh() internally.
	if _file_tree != null and is_instance_valid(_file_tree):
		_file_tree.init(conn, path, "")
	if _vault_view != null and is_instance_valid(_vault_view):
		_vault_view.init(conn, path, "")
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.init(conn)
		_status_panel.set_vault(vault_name, 0)
		_status_panel.set_status("Loading…")


func _on_vault_closed_r2() -> void:
	if _file_tree != null and is_instance_valid(_file_tree):
		_file_tree.clear_vault()
	if _vault_view != null and is_instance_valid(_vault_view):
		_vault_view.clear()
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.clear()


# ---------------------------------------------------------------------------
# R3: Add Document flow
# ---------------------------------------------------------------------------

## Called when user picks "Add Document…" from the File menu.
func _on_add_document_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Show a document-picker FileDialog (separate from the vault picker).
	if _doc_file_dialog == null:
		_doc_file_dialog = FileDialog.new()
		_doc_file_dialog.file_mode  = FileDialog.FILE_MODE_OPEN_FILE
		_doc_file_dialog.title      = "Add Document to Vault"
		_doc_file_dialog.file_selected.connect(_on_doc_file_selected)
		_doc_file_dialog.canceled.connect(_on_doc_file_dialog_cancelled)
		add_child(_doc_file_dialog)

	_doc_file_dialog.filters = PackedStringArray([
		"*.pdf *.txt *.csv *.md *.json *.xml *.html *.docx *.xlsx *.xls *.png *.jpg *.jpeg *.tiff *.bmp *.webp ; Supported Documents"
	])
	_doc_file_dialog.popup_centered(Vector2i(700, 500))


func _on_doc_file_selected(file_path: String) -> void:
	_ingest_pipeline(file_path)


func _on_doc_file_dialog_cancelled() -> void:
	pass  # Nothing to do — user cancelled before picking a file.


## Ingest pipeline: extract → dedup → classify → dialog → insert.
## All call_tool calls must be awaited.
func _ingest_pipeline(file_path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if not _vault_is_open:
		set_status("No vault open.")
		return

	# -- Step 1: Extract text + fingerprints --
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Extracting text…")

	var extract_res: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": file_path}
	)
	# extract_text returns a FLAT dict with `success` (not `ok`).
	if not extract_res.get("success", false):
		_show_pipeline_error("Extraction failed: " + str(extract_res.get("error", "unknown")))
		return

	var sha256:    String = str(extract_res.get("sha256",   ""))
	var char_count: int   = int(extract_res.get("char_count", 0))
	var full_text: String = str(extract_res.get("full_text", ""))
	var simhash:   String = str(extract_res.get("simhash",  "0000000000000000"))
	var dhash:     String = str(extract_res.get("dhash",    "0000000000000000"))

	# -- Step 2: Dedup check (SHA-256 in current vault) --
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Checking for duplicates…")

	# check_sha256 returns {found: bool, doc_id: ...} — no `ok` wrapper.
	var dup_res: Dictionary = await conn.call_tool(
		"minerva_scansort_check_sha256",
		{"vault_path": _active_vault_path, "sha256": sha256}
	)
	if dup_res.get("found", false):
		_show_pipeline_info("This document is already in the vault.")
		if _status_panel != null and is_instance_valid(_status_panel):
			_status_panel.set_status("Idle")
		return

	# -- Step 3: Classify (text vs vision mode) --
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Classifying…")

	var classify_args: Dictionary = {
		"vault_path": _active_vault_path,
		"model_id":   _settings.get("text_model_id", "claude-opus-4-7"),  # R5: from _settings
	}
	# Use password only if set (never log it).
	if not _vault_password.is_empty():
		classify_args["password"] = _vault_password

	const VISION_THRESHOLD := 50
	if char_count >= VISION_THRESHOLD:
		classify_args["mode"]          = "text"
		classify_args["document_text"] = full_text
		# max_text_chars from settings (R5).
		var max_chars: int = _settings.get("max_text_chars", 4000)
		if max_chars > 0:
			classify_args["max_text_chars"] = max_chars
	else:
		# Vision mode — render pages first.
		var render_res: Dictionary = await conn.call_tool(
			"minerva_scansort_render_pages",
			{"file_path": file_path, "max_pages": 2, "dpi": 96}
		)
		# render_pages also returns a FLAT dict with `success`.
		if not render_res.get("success", false):
			_show_pipeline_error("Render failed: " + str(render_res.get("error", "unknown")))
			return
		classify_args["mode"]        = "vision"
		classify_args["page_images"] = render_res.get("pages", [])
		# Switch to vision model_id for image-based classification (R5).
		classify_args["model_id"] = _settings.get("vision_model_id", "claude-opus-4-7")

	var classify_res: Dictionary = await conn.call_tool(
		"minerva_scansort_classify_document",
		classify_args
	)
	# classify_document returns {ok: true, classification: {...}} or {error: ...}.
	if not classify_res.get("ok", false):
		_show_pipeline_error("Classification failed: " + str(classify_res.get("error", "unknown")))
		if _status_panel != null and is_instance_valid(_status_panel):
			_status_panel.set_status("Idle")
		return

	var classification: Dictionary = classify_res.get("classification", {})

	# Augment classification with fingerprints + source info.
	classification["sha256"]      = sha256
	classification["simhash"]     = simhash
	classification["dhash"]       = dhash
	classification["source_file"] = file_path

	# -- Step 4: Show dialog so user can review / edit --
	var dlg = _AddDocumentDialog.new()
	dlg.set_proposal(classification)
	add_child(dlg)
	dlg.accepted.connect(
		func(final: Dictionary) -> void:
			dlg.queue_free()
			_on_add_dialog_accepted(final, file_path, sha256, simhash, dhash)
	)
	dlg.cancelled.connect(
		func() -> void:
			dlg.queue_free()
			_on_add_dialog_cancelled()
	)
	dlg.popup_centered()

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Waiting for user review…")


func _on_add_dialog_accepted(
		final: Dictionary,
		file_path: String,
		sha256: String,
		simhash: String,
		dhash: String) -> void:
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Storing in vault…")

	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var insert_args: Dictionary = {
		"vault_path":   _active_vault_path,
		"file_path":    file_path,
		"category":     final.get("category",    ""),
		"confidence":   float(final.get("confidence", 0.0)),
		"sender":       final.get("sender",      ""),
		"description":  final.get("description", ""),
		"doc_date":     final.get("doc_date",    ""),
		"status":       "classified",
		"sha256":       sha256,
		"simhash":      simhash,
		"dhash":        dhash,
		"source_path":  file_path,
	}
	# Pass password only if set.
	if not _vault_password.is_empty():
		insert_args["password"] = _vault_password

	var insert_res: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_document",
		insert_args
	)
	# insert_document returns {ok: true, doc_id: N}.
	if not insert_res.get("ok", false):
		_show_pipeline_error("Insert failed: " + str(insert_res.get("error", "unknown")))
		return

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	set_status("Document added to vault.")

	# Refresh views.
	if _file_tree != null and is_instance_valid(_file_tree):
		_file_tree.refresh()
	if _vault_view != null and is_instance_valid(_vault_view):
		_vault_view.refresh()


func _on_add_dialog_cancelled() -> void:
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	set_status("Add document cancelled.")


## Show a non-blocking error in the status bar / status panel.
## Toolbar carries the error message; pipeline-state panel returns to Idle so
## subsequent runs aren't gated on the user noticing the stale label.
func _show_pipeline_error(msg: String) -> void:
	set_status("ERROR: " + msg)
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	push_warning("[ScansortPanel] pipeline error: " + msg)


## Show a non-blocking info message.
func _show_pipeline_info(msg: String) -> void:
	set_status(msg)
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status(msg)


# ---------------------------------------------------------------------------
# R4: Edit Document flow
# ---------------------------------------------------------------------------

## Called when vault_view emits edit_details_requested(doc_id).
## Fetches the full document, loads rules for the category dropdown, then
## shows EditDetailsDialog.  On accept, calls update_document and refreshes.
func _on_edit_doc_pressed(doc_id: int) -> void:
	if not _vault_is_open:
		set_status("No vault open.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Fetch current document metadata.
	var doc_args: Dictionary = {"vault_path": _active_vault_path, "doc_id": doc_id}
	if not _vault_password.is_empty():
		doc_args["password"] = _vault_password

	var doc_result: Dictionary = await conn.call_tool("minerva_scansort_get_document", doc_args)
	if not doc_result.get("ok", false):
		set_status("ERROR: get_document failed — %s" % doc_result.get("error", "unknown"))
		return

	var doc: Dictionary = doc_result.get("document", {})

	# Fetch rules for category dropdown.
	var rules_args: Dictionary = {"path": _active_vault_path}
	if not _vault_password.is_empty():
		rules_args["password"] = _vault_password

	var rules_result: Dictionary = await conn.call_tool("minerva_scansort_list_rules", rules_args)
	var rules: Array = []
	if rules_result.get("ok", false):
		rules = rules_result.get("rules", [])

	# Show the dialog.
	var dlg = _EditDetailsDialog.new()
	dlg.set_document(doc, rules)
	add_child(dlg)
	dlg.accepted.connect(
		func(updated_fields: Dictionary) -> void:
			dlg.queue_free()
			_on_edit_dialog_accepted(doc_id, updated_fields)
	)
	dlg.cancelled.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered()


func _on_edit_dialog_accepted(doc_id: int, updated_fields: Dictionary) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var upd_args: Dictionary = {
		"vault_path": _active_vault_path,
		"doc_id":     doc_id,
	}
	# Merge updated fields into the call args.
	for k: String in updated_fields:
		upd_args[k] = updated_fields[k]
	if not _vault_password.is_empty():
		upd_args["password"] = _vault_password

	var upd_result: Dictionary = await conn.call_tool("minerva_scansort_update_document", upd_args)
	if not upd_result.get("ok", false):
		set_status("ERROR: update_document failed — %s" % upd_result.get("error", "unknown"))
		return

	set_status("Document updated.")
	# Refresh both views so the updated metadata is visible.
	if _file_tree != null and is_instance_valid(_file_tree):
		_file_tree.refresh()
	if _vault_view != null and is_instance_valid(_vault_view):
		_vault_view.refresh()


# ---------------------------------------------------------------------------
# R4: Rules Editor flow
# ---------------------------------------------------------------------------

## Called when user picks "Rules Editor…" from the File menu.
func _on_rules_editor_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _RulesEditorDialog.new()
	add_child(dlg)
	dlg.init(conn, _active_vault_path, _vault_password)
	# rules_changed is a no-op for now (panel does not cache a rules list).
	# If a cached rules list is added in R5/R6, connect here.
	dlg.rules_changed.connect(
		func() -> void:
			pass  # no-op: panel has no cached rules list to invalidate in R4
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(880, 580))


# ---------------------------------------------------------------------------
# R5: Vault Registry flow
# ---------------------------------------------------------------------------

## Called when user picks "Vault Registry…" from the File menu.
func _on_vault_registry_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _VaultRegistryDialog.new()
	add_child(dlg)
	dlg.init(conn)
	dlg.vault_picked.connect(
		func(picked_path: String, _picked_name: String) -> void:
			# User double-clicked a vault entry — switch to it.
			# Close the current vault first (if any), then begin open flow.
			if _vault_is_open:
				_on_close_vault_pressed()
			_file_dialog_mode = "open"
			_begin_open_vault(picked_path)
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(600, 400))


# ---------------------------------------------------------------------------
# R5: Settings flow
# ---------------------------------------------------------------------------

## Called when user picks "Settings…" from the File menu.
func _on_settings_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _SettingsDialog.new()
	add_child(dlg)
	dlg.init(conn, _active_vault_path, _vault_password, _settings)
	dlg.settings_changed.connect(
		func(new_settings: Dictionary) -> void:
			_settings = new_settings
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(540, 340))


## Initialize _settings to defaults.  Called on vault_opened.
## There is no get_project_key MCP tool, so we fall back to hard defaults.
## Existing per-vault settings would require a future get_project_key tool.
func _load_settings_defaults() -> void:
	_settings = {
		"text_model_id":    "claude-opus-4-7",
		"vision_model_id":  "claude-opus-4-7",
		"max_text_chars":   4000,
		"default_category": "",
	}


# ---------------------------------------------------------------------------
# R6: Checklist flow
# ---------------------------------------------------------------------------

## Called when user picks "Checklist…" from the File menu.
func _on_checklist_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _ChecklistDialog.new()
	add_child(dlg)
	dlg.init(conn, _active_vault_path, _vault_password)
	dlg.checklist_changed.connect(
		func() -> void:
			pass  # panel has no cached checklist state to invalidate
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(660, 560))


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

## Return the scansort PluginConnection, or null if unavailable.
func _get_connection() -> Object:
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so == null:
		push_error("[ScansortPanel] SingletonObject not found")
		return null
	var pm = so.get("plugin_manager") if "plugin_manager" in so else null
	if pm == null:
		push_error("[ScansortPanel] SingletonObject.plugin_manager not found")
		return null
	var conn = pm.get_connection("scansort")
	if conn == null:
		push_warning("[ScansortPanel] scansort plugin not running — start it first")
	return conn


func set_status(text: String) -> void:
	if _status_label != null and is_instance_valid(_status_label):
		_status_label.text = text


## True if a vault is currently open.
func has_open_vault() -> bool:
	return _vault_is_open


## Returns the absolute path of the open vault, or "" if none.
func get_active_vault_path() -> String:
	return _active_vault_path
