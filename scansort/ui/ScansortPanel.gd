class_name Scansort_Panel
extends MinervaPluginPanel
## Scansort vault browser panel — T7 R1 substrate.
##
## Layout:
##   VBoxContainer
##     HSplitContainer
##       Panel        LeftPane   — file tree
##       Panel        RightPane  — detail/status view
##     HBoxContainer  StatusPanel
##
## R7: Internal toolbar removed. A "File" MenuButton is injected into the
## editor chrome bar via get_editor_actions().
## R8: Settings dialog dropped. Model selection for classify calls inherited
##     from Minerva's Chat panel quick-select via _resolve_chat_model_for_classify().
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

## U4: unified scan-tree component + providers (off-tree: no class_name).
const _ScanTree:       Script = preload("scan_tree.gd")
const _SourceProvider: Script = preload("scan_tree_source_provider.gd")
const _VaultProvider:  Script = preload("scan_tree_vault_provider.gd")
const _StatusPanel:    Script = preload("status_panel.gd")

## R3: add-document dialog (off-tree: no class_name).
const _AddDocumentDialog: Script = preload("add_document_dialog.gd")

## R4: edit-details and rules-editor dialogs (off-tree: no class_name).
const _EditDetailsDialog: Script  = preload("edit_details_dialog.gd")
const _RulesEditorDialog: Script  = preload("rules_editor_dialog.gd")

## R5: vault registry dialog (off-tree: no class_name).
const _VaultRegistryDialog: Script = preload("vault_registry_dialog.gd")

## R6: checklist dialog (off-tree: no class_name).
const _ChecklistDialog: Script = preload("checklist_dialog.gd")
const _SettingsDialog: Script  = preload("settings_dialog.gd")
const _UiScale: Script         = preload("ui_scale.gd")

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

## R7 polish: cached reference to the chrome MenuButton's popup so we can
## enable/disable vault-required items as the vault state changes. Lifetime
## is the editor's — guarded with is_instance_valid before every access.
var _chrome_popup: PopupMenu = null

# ---------------------------------------------------------------------------
# UI widgets
# ---------------------------------------------------------------------------

## R7: No internal toolbar. The File menu is returned via get_editor_actions()
## and lives in the editor chrome bar.
##
## U4: 2-column layout — SourcePane | DestPane — each hosting a unified
## scan_tree bound to a provider, with the status panel as a bottom bar.
## Process All / Stop live in the editor chrome bar (get_editor_actions),
## not in the panel.
var _source_tree: Tree = null
var _dest_tree:   Tree = null
var _source_provider: Object = null
var _dest_provider:   Object = null
## Chrome-bar buttons — created in get_editor_actions(); the editor owns and
## frees them on teardown, so guard with is_instance_valid before use.
var _process_btn: Button = null
var _stop_btn:    Button = null

# ---------------------------------------------------------------------------
# U5: batch pipeline session state
# ---------------------------------------------------------------------------

## Set of absolute source paths processed during the current session.
## Used as a set; value is always true. Never persisted.
var _processed_keys: Dictionary = {}

## Subset of _processed_keys whose classification confidence was below
## LOW_CONFIDENCE_THRESHOLD. Never persisted.
var _low_confidence_keys: Dictionary = {}

## Set to true by _on_stop_pressed(); the batch loop checks this between
## files and breaks early.
var _process_cancelled: bool = false

## Classification confidence below which a processed doc is flagged as
## low-confidence.
const LOW_CONFIDENCE_THRESHOLD := 0.5
var _status_panel: HBoxContainer = null

## File dialog (reused for open and create).
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
# U6: inject-to-chat cache
# ---------------------------------------------------------------------------

## Pre-extracted text from the checked source files, rebuilt whenever the
## source-pane checkboxes change.  Empty string = nothing to inject.
var _inject_payload_cache: String = ""

## True when the user has toggled the inject-to-chat switch on.
var _inject_enabled: bool = false

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

	# U4: 2-column layout — SourcePane | DestPane — with the status panel as a
	# bottom bar. Process All / Stop live in the editor chrome bar, contributed
	# via get_editor_actions(); R7: no internal toolbar.
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)

	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 4)
	layout.add_child(columns)

	# --- Left column: source pane ---
	var source_col := VBoxContainer.new()
	source_col.name = "SourcePane"
	source_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	source_col.custom_minimum_size.x = 200
	var source_header := Label.new()
	source_header.text = "Source"
	source_col.add_child(source_header)
	_source_tree = _ScanTree.new()
	source_col.add_child(_source_tree)
	columns.add_child(source_col)

	# --- Right column: destination (vault) pane ---
	var dest_col := VBoxContainer.new()
	dest_col.name = "DestPane"
	dest_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dest_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dest_col.custom_minimum_size.x = 200
	var dest_header := Label.new()
	dest_header.text = "Vault"
	dest_col.add_child(dest_header)
	_dest_tree = _ScanTree.new()
	dest_col.add_child(_dest_tree)
	columns.add_child(dest_col)

	# --- Status bar along the bottom ---
	_status_panel = _StatusPanel.new()
	_status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(_status_panel)

	# U6: assign roles for drag context and wire signals.
	_source_tree.tree_role = "source"
	_dest_tree.tree_role   = "vault"
	# Only the vault tree receives drops (source has no folder rows to land on).
	_dest_tree.file_dropped.connect(_on_tree_file_dropped)
	# Rebuild inject payload whenever source checkboxes change.
	_source_tree.check_toggled.connect(_on_source_check_toggled)

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
		7: _on_checklist_pressed()
		8: _on_library_rules_editor_pressed()
		9: _on_create_vault_rules_pressed()
		10: _on_use_library_rules_pressed()
		11: _on_settings_pressed()
		12: _on_export_marked_pressed()


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
	_refresh_chrome_menu_state()

# ---------------------------------------------------------------------------
# File dialog
# ---------------------------------------------------------------------------

func _open_file_dialog(mode: FileDialog.FileMode, dialog_title: String) -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_UiScale.apply_to(_file_dialog)
		# Browse the real filesystem, not Godot's res:// resource view.
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
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
	_refresh_chrome_menu_state()
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

	# U4: bind the source + vault providers to their scan_trees and refresh.
	# The source provider takes the vault path so it can flag in-vault files.
	_source_provider = _SourceProvider.new()
	_source_provider.init(conn, path)
	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(_source_provider)
		await _source_tree.refresh()

	_dest_provider = _VaultProvider.new()
	_dest_provider.init(conn, path)
	if _dest_tree != null and is_instance_valid(_dest_tree):
		_dest_tree.set_provider(_dest_provider)
		await _dest_tree.refresh()

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.init(conn)
		_status_panel.set_vault(vault_name, 0)
		_status_panel.set_status("Idle")


func _on_vault_closed_r2() -> void:
	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(null)
		_source_tree.populate([])
	if _dest_tree != null and is_instance_valid(_dest_tree):
		_dest_tree.set_provider(null)
		_dest_tree.populate([])
	_source_provider = null
	_dest_provider = null
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
		_UiScale.apply_to(_doc_file_dialog)
		# Browse the real filesystem, not Godot's res:// resource view.
		_doc_file_dialog.access     = FileDialog.ACCESS_FILESYSTEM
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

	# R9: inherit model spec from chrome OptionButton; hardcoded max_chars.
	const MAX_CLASSIFY_CHARS := 4000
	var model_desc: Dictionary = _resolve_chat_model_for_classify()
	var model_spec: Dictionary = model_desc.get("model_spec", {}) as Dictionary if model_desc.get("model_spec") is Dictionary else {}
	var classify_args: Dictionary = {
		"vault_path": _active_vault_path,
		"model":      "default",
	}
	# Only attach spec when non-empty — broker rejects empty {} as "unknown kind".
	if not model_spec.is_empty():
		classify_args["model_spec"] = model_spec
	# Use password only if set (never log it).
	if not _vault_password.is_empty():
		classify_args["password"] = _vault_password

	const VISION_THRESHOLD := 50
	if char_count >= VISION_THRESHOLD:
		classify_args["mode"]          = "text"
		classify_args["document_text"] = full_text
		if MAX_CLASSIFY_CHARS > 0:
			classify_args["max_text_chars"] = MAX_CLASSIFY_CHARS
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
	# Carry rule_snapshot through the dialog so the vault keeps a per-doc record
	# of the rule revision that produced this classification (vault v1.1.0+).
	classification["rule_snapshot"] = classify_res.get("rule_snapshot", "")

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
		"rule_snapshot": str(final.get("rule_snapshot", "")),
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

	# Refresh the destination pane so the new document shows up, and re-scan
	# the source pane so the just-ingested file shows its in-vault mark.
	if _dest_tree != null and is_instance_valid(_dest_tree):
		await _dest_tree.refresh()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()


func _on_add_dialog_cancelled() -> void:
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	set_status("Add document cancelled.")


# ---------------------------------------------------------------------------
# U5: Process All batch pipeline
# ---------------------------------------------------------------------------

## Called when the user clicks the "Process All" button in the chrome bar.
## Iterates every source file: extract → dedup → classify → insert.
## Files already in the vault or in _processed_keys are skipped. One failed
## file does NOT abort the whole run.
func _on_process_all_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if not _vault_is_open:
		set_status("No vault open.")
		return

	# Fetch the source file list.
	var list_res: Dictionary = await conn.call_tool(
		"minerva_scansort_list_source_files",
		{"vault_path": _active_vault_path}
	)
	if not list_res.get("ok", false):
		set_status("Process All: no source directory set or list failed.")
		return
	var files: Array = list_res.get("files", [])
	if files.is_empty():
		set_status("Process All: source directory is empty.")
		return

	# Enter running state.
	_process_cancelled = false
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = true
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = false
	set_status("Processing…")

	var total: int = files.size()
	var processed_this_run: int = 0
	var skipped: int = 0
	var failed: int = 0
	var low_conf: int = 0

	const MAX_CLASSIFY_CHARS := 4000

	for i: int in range(total):
		if _process_cancelled:
			break

		var file: Dictionary = files[i]
		var fpath: String = str(file.get("path", ""))
		var fname: String = str(file.get("name", fpath.get_file()))

		# Skip already-done files.
		if bool(file.get("in_vault", false)) or _processed_keys.has(fpath):
			skipped += 1
			continue

		set_status("Processing %d/%d: %s…" % [i + 1, total, fname])

		# -- Step 1: Extract --
		var extract_res: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_text",
			{"file_path": fpath}
		)
		if not extract_res.get("success", false):
			push_warning("[ScansortPanel] batch extract failed for %s: %s" % [
				fname, str(extract_res.get("error", "unknown"))
			])
			failed += 1
			continue

		var sha256:     String = str(extract_res.get("sha256",   ""))
		var char_count: int    = int(extract_res.get("char_count", 0))
		var full_text:  String = str(extract_res.get("full_text", ""))
		var simhash:    String = str(extract_res.get("simhash",  "0000000000000000"))
		var dhash:      String = str(extract_res.get("dhash",    "0000000000000000"))

		# -- Step 2: Dedup --
		var dup_res: Dictionary = await conn.call_tool(
			"minerva_scansort_check_sha256",
			{"vault_path": _active_vault_path, "sha256": sha256}
		)
		if dup_res.get("found", false):
			# Already in vault (list may have been stale) — mark and skip.
			_processed_keys[fpath] = true
			skipped += 1
			_push_session_marks_to_provider()
			continue

		# -- Step 3: Classify --
		var model_desc: Dictionary = _resolve_chat_model_for_classify()
		var model_spec: Dictionary = model_desc.get("model_spec", {}) as Dictionary if model_desc.get("model_spec") is Dictionary else {}
		var classify_args: Dictionary = {
			"vault_path": _active_vault_path,
			"model":      "default",
		}
		if not model_spec.is_empty():
			classify_args["model_spec"] = model_spec
		if not _vault_password.is_empty():
			classify_args["password"] = _vault_password

		const VISION_THRESHOLD := 50
		if char_count >= VISION_THRESHOLD:
			classify_args["mode"]          = "text"
			classify_args["document_text"] = full_text
			if MAX_CLASSIFY_CHARS > 0:
				classify_args["max_text_chars"] = MAX_CLASSIFY_CHARS
		else:
			var render_res: Dictionary = await conn.call_tool(
				"minerva_scansort_render_pages",
				{"file_path": fpath, "max_pages": 2, "dpi": 96}
			)
			if not render_res.get("success", false):
				push_warning("[ScansortPanel] batch render failed for %s: %s" % [
					fname, str(render_res.get("error", "unknown"))
				])
				failed += 1
				continue
			classify_args["mode"]        = "vision"
			classify_args["page_images"] = render_res.get("pages", [])

		var classify_res: Dictionary = await conn.call_tool(
			"minerva_scansort_classify_document",
			classify_args
		)
		if not classify_res.get("ok", false):
			push_warning("[ScansortPanel] batch classify failed for %s: %s" % [
				fname, str(classify_res.get("error", "unknown"))
			])
			failed += 1
			continue

		var classification: Dictionary = classify_res.get("classification", {})

		# -- Step 4: Insert --
		var insert_args: Dictionary = {
			"vault_path":    _active_vault_path,
			"file_path":     fpath,
			"category":      classification.get("category",    ""),
			"confidence":    float(classification.get("confidence", 0.0)),
			"sender":        classification.get("sender",      ""),
			"description":   classification.get("description", ""),
			"doc_date":      classification.get("doc_date",    ""),
			"status":        "classified",
			"sha256":        sha256,
			"simhash":       simhash,
			"dhash":         dhash,
			"source_path":   fpath,
			"rule_snapshot": str(classify_res.get("rule_snapshot", "")),
		}
		if not _vault_password.is_empty():
			insert_args["password"] = _vault_password

		var insert_res: Dictionary = await conn.call_tool(
			"minerva_scansort_insert_document",
			insert_args
		)
		if not insert_res.get("ok", false):
			push_warning("[ScansortPanel] batch insert failed for %s: %s" % [
				fname, str(insert_res.get("error", "unknown"))
			])
			failed += 1
			continue

		# Successful insert — record session state.
		_processed_keys[fpath] = true
		processed_this_run += 1
		var confidence: float = float(classification.get("confidence", 0.0))
		if confidence < LOW_CONFIDENCE_THRESHOLD:
			_low_confidence_keys[fpath] = true
			low_conf += 1

		_push_session_marks_to_provider()

	# Run finished (or cancelled) — refresh both trees.
	if _dest_tree != null and is_instance_valid(_dest_tree):
		await _dest_tree.refresh()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()

	# Restore button states.
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = not _vault_is_open
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = true

	# Summary status.
	if _process_cancelled:
		set_status("Stopped — processed %d, %d low-confidence, %d failed, %d skipped" % [
			processed_this_run, low_conf, failed, skipped
		])
	else:
		set_status("Processed %d/%d — %d low-confidence, %d failed, %d skipped" % [
			processed_this_run, total, low_conf, failed, skipped
		])


## Stop button — sets the cancel flag; the batch loop picks it up between
## files.
func _on_stop_pressed() -> void:
	_process_cancelled = true
	set_status("Stopping…")


## Clear session state (processed + low-confidence sets) and refresh the
## source tree so ✓ marks are removed. Public — U6 may expose a UI trigger.
func clear_processed_state() -> void:
	_processed_keys.clear()
	_low_confidence_keys.clear()
	_push_session_marks_to_provider()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()


## Push the current session mark sets into the source provider so the next
## refresh() reflects up-to-date ✓ marks without a full list_source_files
## round-trip.
func _push_session_marks_to_provider() -> void:
	if _source_provider != null and _source_provider.has_method("set_session_marks"):
		_source_provider.set_session_marks(_processed_keys, _low_confidence_keys)


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

## Edit Document flow. Currently unwired after the U4 layout rewrite — the
## old trigger (vault_view's edit_details_requested) is gone; a right-click
## re-entry point is Tier-2 work. Kept intact so that re-wiring is trivial.
## Fetches the full document, loads rules for the category dropdown, then
## shows EditDetailsDialog. On accept, calls update_document and refreshes.
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
	# Refresh the destination pane so the updated metadata is visible.
	if _dest_tree != null and is_instance_valid(_dest_tree):
		await _dest_tree.refresh()


# ---------------------------------------------------------------------------
# R4: Rules Editor flow
# ---------------------------------------------------------------------------

## Sibling rules path for the currently-open vault.
## /a/b/foo.ssort → /a/b/foo.rules.json. Empty if no vault is open.
func _vault_rules_path() -> String:
	if _active_vault_path.is_empty():
		return ""
	var base_dir: String = _active_vault_path.get_base_dir()
	var stem: String     = _active_vault_path.get_file().get_basename()
	return "%s/%s.rules.json" % [base_dir, stem]


## User-level library rules path. Lives in the Minerva per-user data dir so
## it survives across vaults and across project tree moves.
func _library_rules_path() -> String:
	return OS.get_user_data_dir() + "/scansort_rules.json"


## Called when user picks "Vault Rules Editor…" from the File menu (id 4).
## Edits the sibling .rules.json of the currently-open vault.
func _on_rules_editor_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var rules_path: String = _vault_rules_path()
	var label: String = "Vault rules: " + rules_path.get_file()

	var dlg = _RulesEditorDialog.new()
	add_child(dlg)
	dlg.init_with_rules_path(conn, rules_path, label)
	dlg.rules_changed.connect(
		func() -> void:
			pass  # panel has no cached rules list to invalidate
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(880, 580))


## Called when user picks "Library Rules Editor…" from the File menu (id 8).
## Edits the user-level scansort_rules.json. Available without a vault open.
func _on_library_rules_editor_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var rules_path: String = _library_rules_path()
	var label: String = "Library rules"

	var dlg = _RulesEditorDialog.new()
	add_child(dlg)
	dlg.init_with_rules_path(conn, rules_path, label)
	dlg.rules_changed.connect(
		func() -> void:
			pass
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(880, 580))


## Create a vault-specific rules file by copying the library file to the
## sibling location. Only meaningful when a vault is open.
func _on_create_vault_rules_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var sibling: String = _vault_rules_path()
	if FileAccess.file_exists(sibling):
		set_status("Vault already has its own rules file: " + sibling.get_file())
		return
	var library: String = _library_rules_path()
	if not FileAccess.file_exists(library):
		set_status("No library rules file to seed from. Use 'Library Rules Editor' first.")
		return
	var src := FileAccess.open(library, FileAccess.READ)
	if src == null:
		set_status("Could not read library rules: " + library)
		return
	var content: String = src.get_as_text()
	src.close()
	var dst := FileAccess.open(sibling, FileAccess.WRITE)
	if dst == null:
		set_status("Could not write sibling rules: " + sibling)
		return
	dst.store_string(content)
	dst.close()
	set_status("Created vault-specific rules: " + sibling.get_file())


## Delete the sibling rules file so the vault falls back to the library file.
## Only meaningful when a vault is open and a sibling rules file exists.
func _on_use_library_rules_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var sibling: String = _vault_rules_path()
	if not FileAccess.file_exists(sibling):
		set_status("No vault-specific rules file to remove.")
		return
	var err := DirAccess.remove_absolute(sibling)
	if err != OK:
		set_status("Could not remove sibling rules file (error %d): %s" % [err, sibling])
		return
	set_status("Removed vault-specific rules; library rules will be used.")


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
# R8: Chat model inheritance
# ---------------------------------------------------------------------------

## R9: Resolve the model spec to use for classify_document calls.
## Returns {model_spec: Dictionary} — reads from the chrome OptionButton
## Resolves the classification model spec.
##
## Precedence:
##   1. Per-plugin user override stored in scansort_settings.json (set via
##      the Settings dialog). Travels across vaults.
##   2. Chat panel's currently-selected model (inherit mode — the default).
##
## Returns {"model_spec": Dictionary} — empty Dict when neither layer
## supplies a spec (headless tests / no chat / inherit + chat unset). The
## caller's classify call site drops empty specs from args (broker rejects
## empty {} as "unknown kind").
func _resolve_chat_model_for_classify() -> Dictionary:
	# Layer 1: per-plugin override.
	var override: Dictionary = _SettingsDialog.ScansortSettings.load_model_override()
	if not override.is_empty():
		return {"model_spec": override}

	# Layer 2: inherit chat panel's current selection.
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() != null else null
	if so == null:
		return {"model_spec": {}}
	var chats = so.get("Chats") if "Chats" in so else null
	if chats == null or not chats.has_method("get_active_model_spec"):
		return {"model_spec": {}}
	var spec = chats.get_active_model_spec()
	var dict_spec: Dictionary = spec as Dictionary if spec is Dictionary else {}
	return {"model_spec": dict_spec}


## Called when user picks "Settings…" from the File menu (id 11).
## Always available — settings are user-level, not vault-gated.
func _on_settings_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	var dlg = _SettingsDialog.new()
	add_child(dlg)
	dlg.init(conn)
	dlg.settings_changed.connect(
		func() -> void:
			set_status("Scansort settings saved.")
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(520, 240))


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


## Editor actions API — returns Controls to insert into the editor chrome bar.
## Called by Editor._apply_plugin_chrome_actions() after the panel is mounted.
## Returns a fresh MenuButton each call; the editor owns and frees it on teardown.
func get_editor_actions() -> Array:
	# Process All / Stop — contributed to the chrome bar, left of the File menu.
	# Disabled placeholders until U5 wires the batch pipeline. Icons match the
	# chat panel's submit / stop buttons; style matches the File MenuButton
	# (flat = false, icon-only + tooltip).
	_process_btn = Button.new()
	_process_btn.flat = false
	_process_btn.icon = load("res://assets/icons/send_icons/send_icon_24_no_bg.png")
	_process_btn.tooltip_text = "Process All — extract, classify and file every source document."
	_process_btn.disabled = not _vault_is_open
	_process_btn.pressed.connect(_on_process_all_pressed)
	_stop_btn = Button.new()
	_stop_btn.flat = false
	_stop_btn.icon = load("res://assets/icons/stop_icons/stop-sign-24.png")
	_stop_btn.tooltip_text = "Stop the running batch."
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(_on_stop_pressed)

	var menu := MenuButton.new()
	# Reuse Minerva's drawer icon for the File menu; tooltip explains it.
	var icon: Texture2D = load("res://assets/icons/drawer.png")
	if icon != null:
		menu.icon = icon
	else:
		menu.text = "File"
	menu.tooltip_text = "Scansort File menu"
	menu.flat = false
	var popup := menu.get_popup()
	popup.add_item("New Vault...", 0)
	popup.add_item("Open Vault...", 1)
	popup.add_separator()
	popup.add_item("Add Document...", 3)
	popup.add_item("Vault Rules Editor...", 4)
	popup.add_item("Library Rules Editor...", 8)
	popup.add_separator()
	popup.add_item("Create Vault-Specific Rules", 9)
	popup.add_item("Use Library Rules (remove sibling)", 10)
	popup.add_separator()
	popup.add_item("Vault Registry...", 5)
	popup.add_item("Checklist...", 7)
	popup.add_separator()
	popup.add_item("Settings...", 11)
	popup.add_separator()
	popup.add_item("Export Marked to Disk...", 12)
	popup.add_separator()
	popup.add_item("Close Vault", 2)
	popup.id_pressed.connect(_on_file_menu_id_pressed)
	# Cache the popup so vault state changes can grey out gated items.
	_chrome_popup = popup
	_refresh_chrome_menu_state()

	# Scansort inherits the chat panel's model selection at classify time via
	# _resolve_chat_model_for_classify() → ChatPane.get_active_model_spec().
	# No per-panel model picker.
	# Process | Stop | File — buttons land left of the File menu in the chrome.
	return [_process_btn, _stop_btn, menu]


## Disable File-menu items that require an open vault when no vault is open.
## Always enabled: New Vault (0), Open Vault (1), Vault Registry (5),
##                 Library Rules Editor (8).
## Vault-gated: Close (2), Add Document (3), Vault Rules Editor (4),
##              Checklist (7), Create Vault-Specific Rules (9),
##              Use Library Rules (10).
func _refresh_chrome_menu_state() -> void:
	if _chrome_popup == null or not is_instance_valid(_chrome_popup):
		return
	var vault_gated: Array[int] = [2, 3, 4, 7, 9, 10, 12]
	for item_id in vault_gated:
		var idx: int = _chrome_popup.get_item_index(item_id)
		if idx >= 0:
			_chrome_popup.set_item_disabled(idx, not _vault_is_open)
	# U5: enable Process All when a vault is open (and no run is in progress).
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = not _vault_is_open


# ---------------------------------------------------------------------------
# U6: drag-to-classify / drag-to-reclassify
# ---------------------------------------------------------------------------

## Handles drops from either tree onto a vault category folder.
## drag_data.role == "source"  → classify source file into target category.
## drag_data.role == "vault"   → reclassify vault document to target category.
func _on_tree_file_dropped(drag_data: Dictionary, target_key: String, _target_kind: String) -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var category: String = target_key.substr(4)  # strip "cat:" prefix
	var role: String     = str(drag_data.get("role", ""))
	var drag_key: String = str(drag_data.get("key", ""))

	if role == "source":
		# Drag-to-classify: source file path → insert with user-assigned category.
		var fname: String = drag_key.get_file()

		# Extract text + fingerprints.
		var extract_res: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_text",
			{"file_path": drag_key}
		)
		if not extract_res.get("success", false):
			set_status("ERROR: extraction failed — %s" % str(extract_res.get("error", "unknown")))
			return

		var sha256:  String = str(extract_res.get("sha256",  ""))
		var simhash: String = str(extract_res.get("simhash", "0000000000000000"))
		var dhash:   String = str(extract_res.get("dhash",   "0000000000000000"))

		# Dedup check.
		var dup_res: Dictionary = await conn.call_tool(
			"minerva_scansort_check_sha256",
			{"vault_path": _active_vault_path, "sha256": sha256}
		)
		if dup_res.get("found", false):
			set_status("Already in vault.")
			return

		# Insert with user-assigned category (no AI classify step).
		var insert_args: Dictionary = {
			"vault_path":    _active_vault_path,
			"file_path":     drag_key,
			"category":      category,
			"confidence":    1.0,
			"sender":        "",
			"description":   "",
			"doc_date":      "",
			"status":        "classified",
			"sha256":        sha256,
			"simhash":       simhash,
			"dhash":         dhash,
			"source_path":   drag_key,
			"rule_snapshot": "",
		}
		if not _vault_password.is_empty():
			insert_args["password"] = _vault_password

		var insert_res: Dictionary = await conn.call_tool(
			"minerva_scansort_insert_document",
			insert_args
		)
		if not insert_res.get("ok", false):
			set_status("ERROR: insert failed — %s" % str(insert_res.get("error", "unknown")))
			return

		set_status("Filed %s → %s" % [fname, category])
		if _dest_tree != null and is_instance_valid(_dest_tree):
			await _dest_tree.refresh()
		if _source_tree != null and is_instance_valid(_source_tree):
			await _source_tree.refresh()

	elif role == "vault":
		# Drag-to-reclassify: doc:<id> → update category.
		var doc_id: int = int(drag_key.substr(4))  # strip "doc:" prefix
		var upd_args: Dictionary = {
			"vault_path": _active_vault_path,
			"doc_id":     doc_id,
			"category":   category,
		}
		if not _vault_password.is_empty():
			upd_args["password"] = _vault_password

		var upd_res: Dictionary = await conn.call_tool(
			"minerva_scansort_update_document",
			upd_args
		)
		if not upd_res.get("ok", false):
			set_status("ERROR: reclassify failed — %s" % str(upd_res.get("error", "unknown")))
			return

		set_status("Reclassified → %s" % category)
		if _dest_tree != null and is_instance_valid(_dest_tree):
			await _dest_tree.refresh()


# ---------------------------------------------------------------------------
# U6: Export Marked to Disk
# ---------------------------------------------------------------------------

## Copies every checked vault document to the configured disk root.
## One failure does NOT abort the loop — counts are summarised at the end.
## Checkboxes are left as-is (they clear naturally on the next tree refresh).
func _on_export_marked_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var keys: Array = _dest_tree.get_checked_keys() if _dest_tree != null and is_instance_valid(_dest_tree) else []
	if keys.is_empty():
		set_status("No documents marked for export.")
		return

	var exported: int = 0
	var failed: int   = 0
	var skipped: int  = 0

	for key: String in keys:
		if not key.begins_with("doc:"):
			skipped += 1
			continue
		var doc_id: int = int(key.substr(4))

		# Fetch document metadata for source_path and doc_date.
		var doc_args: Dictionary = {"vault_path": _active_vault_path, "doc_id": doc_id}
		if not _vault_password.is_empty():
			doc_args["password"] = _vault_password

		var doc_res: Dictionary = await conn.call_tool("minerva_scansort_get_document", doc_args)
		if not doc_res.get("ok", false):
			push_warning("[ScansortPanel] export: get_document failed for doc_id %d: %s" % [
				doc_id, str(doc_res.get("error", "unknown"))
			])
			failed += 1
			continue

		var document: Dictionary = doc_res.get("document", {})
		var source_path: String  = str(document.get("source_path", ""))
		var doc_date: String     = str(document.get("doc_date", ""))

		if source_path.is_empty():
			# Original file gone — can't export.
			skipped += 1
			continue

		var place_args: Dictionary = {
			"vault_path": _active_vault_path,
			"file_path":  source_path,
			"subfolder":  "{year}",
			"doc_date":   doc_date,
		}
		if not _vault_password.is_empty():
			place_args["password"] = _vault_password

		var place_res: Dictionary = await conn.call_tool("minerva_scansort_place_on_disk", place_args)
		if place_res.has("error"):
			push_warning("[ScansortPanel] export: place_on_disk failed for doc %d: %s" % [
				doc_id, str(place_res.get("error", "unknown"))
			])
			failed += 1
			continue

		exported += 1

	set_status("Exported %d, %d failed, %d skipped" % [exported, failed, skipped])


# ---------------------------------------------------------------------------
# U6: inject-to-chat
# ---------------------------------------------------------------------------

## Called when source-pane checkboxes change.
## Rebuilds _inject_payload_cache from the extracted text of all checked files.
## Async — each file may require an MCP round-trip.
func _on_source_check_toggled() -> void:
	var conn = _get_connection()
	if conn == null:
		_inject_payload_cache = ""
		return

	var keys: Array = _source_tree.get_checked_keys() if _source_tree != null and is_instance_valid(_source_tree) else []
	if keys.is_empty():
		_inject_payload_cache = ""
		return

	const MAX_FILE_CHARS := 20000
	var blob: String = ""

	for file_path: String in keys:
		var extract_res: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_text",
			{"file_path": file_path}
		)
		if not extract_res.get("success", false):
			continue
		var text: String = str(extract_res.get("full_text", ""))
		if text.length() > MAX_FILE_CHARS:
			text = text.substr(0, MAX_FILE_CHARS) + "\n…[truncated]"
		blob += "=== %s ===\n%s\n\n" % [file_path.get_file(), text]

	_inject_payload_cache = blob


## Platform hook: called when the user toggles the inject-to-chat switch.
## If enabled but no source files are checked yet, nudges the user.
func _on_panel_inject_toggle_changed(enabled: bool) -> void:
	_inject_enabled = enabled
	if enabled and _inject_payload_cache.is_empty():
		set_status("Inject to Chat: check source files first.")


## Platform hook: called synchronously when a note is requested for chat injection.
## MUST NOT use await — PluginScenePanelHost.invoke_create_note does not await it.
## Returns null when no cache is ready (platform falls back to a screenshot).
## Returns a text-kind payload dict that Editor._build_note_from_plugin_payload
## recognises when the cache is populated.
func _on_panel_create_note_request(_ctx: Dictionary) -> Variant:
	if _inject_payload_cache.is_empty():
		return null
	return {
		"kind":    "text",
		"title":   "Scansort source files",
		"content": _inject_payload_cache,
	}


func set_status(text: String) -> void:
	# R7: _status_label removed (toolbar gone). Route status to the bottom panel.
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status(text)


## True if a vault is currently open.
func has_open_vault() -> bool:
	return _vault_is_open


## Returns the absolute path of the open vault, or "" if none.
func get_active_vault_path() -> String:
	return _active_vault_path
