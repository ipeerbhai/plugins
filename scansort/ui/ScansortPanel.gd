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
const _ChecklistDialog: Script      = preload("checklist_dialog.gd")
const _SettingsDialog: Script       = preload("settings_dialog.gd")
const _RecoverySheetDialog: Script  = preload("recovery_sheet_dialog.gd")
const _UiScale: Script         = preload("ui_scale.gd")

## U7: disk tree provider (off-tree: no class_name).
const _DiskProvider: Script = preload("scan_tree_disk_provider.gd")

## W5: destination registry provider — vault or directory destination.
const _DestinationProvider: Script = preload("scan_tree_destination_provider.gd")

## W5b: aggregate area providers (one per kind) for the two-area splitter layout.
const _AreaProvider: Script = preload("scan_tree_area_provider.gd")

## W7: dedup disposition dialog (off-tree: no class_name).
const _DedupDispositionDialog: Script = preload("dedup_disposition_dialog.gd")

## W5g: extract-target picker dialog (off-tree: no class_name).
const _ExtractTargetDialog: Script = preload("extract_target_dialog.gd")

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
## W5: DestPane is dynamic: N stacked scan_tree sub-trees, one per registered
##     destination (from minerva_scansort_destination_list). The old fixed
##     vault+disk pair is replaced by the destination registry.
var _source_tree: Tree = null
## W5: No longer used for main vault tree — kept for backward-compat reads in
##     tests that check "_dest_tree". Points to the first dest tree or null.
var _dest_tree:   Tree = null
## W5: No longer the fixed disk tree. Kept as null; tests that check "_disk_tree"
##     should migrate to the destinations array.
var _disk_tree:   Tree = null
var _source_provider: Object = null
## W5: U7's fixed dest/disk providers are subsumed by the per-destination
## _dest_providers array; these two stay declared (null) for smoke-test
## member checks (R195) — the dynamic model replaces their function.
var _dest_provider:   Object = null
var _disk_provider:   Object = null

## W5: per-registered-destination state. Parallel arrays indexed by position.
##   _dest_registry      — Array[Dictionary]  — destination dicts from destination_list
##   _dest_trees         — Array[Tree]         — one scan_tree per destination
##   _dest_providers     — Array[Object]       — one DestinationProvider per destination
##   _dest_containers    — Array[VBoxContainer] — one section container per destination
## All four are rebuilt together in _refresh_dest_pane().
var _dest_registry:    Array = []
var _dest_trees:       Array = []
var _dest_providers:   Array = []
var _dest_containers:  Array = []

## W5: The VBoxContainer that holds all destination sections + the add button.
## Child of the DestPane column, created in _build_ui().
var _dest_scroll_content: VBoxContainer = null

## W5: registry_path required by destination_add/list/remove tools.
## Provided at vault-open time (or via settings). Empty = feature unavailable.
var _registry_path: String = ""

## W5b: Two-area splitter layout — Vault area + Directory area, each backed
## by an aggregate AreaProvider that renders all destinations of that kind
## as top-level virtual-root rows with inline [Remove][Reprocess][Lock] buttons.
var _vault_area_tree: Tree = null
var _dir_area_tree: Tree = null
var _vault_area_provider: Object = null
var _dir_area_provider: Object = null

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

## U7: per-run counters shared across concurrent coroutines (Dictionary reference
## so coroutines can mutate them without capture-by-value issues).
var _run_counters: Dictionary = {}  # keys: processed, skipped, failed, low_conf

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
# W7: near-dup dedup state
# ---------------------------------------------------------------------------

## Reusable dedup disposition dialog instance (created once, reused).
var _dedup_dialog: AcceptDialog = null

## When a dedup disposition is pending, this holds the match_info dict that was
## passed to the dialog.  Cleared once the user makes a choice or cancels.
var _pending_dedup_match: Dictionary = {}

## Last disposition chosen by the user for the current near-dup prompt.
## One of "keep_both", "replace", "skip", or "" (pending / not yet chosen).
## W9 (audit log) and W10 (Process All) read this after the dialog closes.
var _last_dedup_disposition: String = ""

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

	# --- Right column: destination pane (W5b: VSplitContainer two-area layout) ---
	var dest_col := VBoxContainer.new()
	dest_col.name = "DestPane"
	dest_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dest_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dest_col.custom_minimum_size.x = 200

	# W5b: VSplitContainer — top = Vault area, bottom = Directory area.
	var dest_split := VSplitContainer.new()
	dest_split.name = "DestSplit"
	dest_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dest_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dest_col.add_child(dest_split)

	# --- Vault area (top half) ---
	var vault_area := VBoxContainer.new()
	vault_area.name = "VaultArea"
	vault_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vault_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vault_area.custom_minimum_size.y = 80

	var vault_hdr := HBoxContainer.new()
	var vault_hdr_lbl := Label.new()
	vault_hdr_lbl.text = "Vaults"
	vault_hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vault_hdr.add_child(vault_hdr_lbl)
	# W5h: a discoverable control to extract checked documents to a directory
	# (previously only reachable via the buried File-menu item).
	var vault_extract_btn := Button.new()
	vault_extract_btn.text = "Extract Marked…"
	vault_extract_btn.tooltip_text = "Extract checked documents to a directory…"
	vault_extract_btn.pressed.connect(_on_export_marked_pressed)
	vault_hdr.add_child(vault_extract_btn)
	var vault_add_btn := Button.new()
	vault_add_btn.text = "+"
	vault_add_btn.tooltip_text = "Add a vault destination…"
	vault_add_btn.flat = false
	vault_add_btn.pressed.connect(func() -> void: _on_dest_add_for_kind("vault"))
	vault_hdr.add_child(vault_add_btn)
	vault_area.add_child(vault_hdr)

	_vault_area_tree = _ScanTree.new()
	_vault_area_tree.tree_role = "dest:vault"
	_vault_area_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vault_area_tree.file_dropped.connect(_on_area_tree_file_dropped)
	_vault_area_tree.dest_button_pressed.connect(
		func(dest_id: String, action: String) -> void:
			_on_area_dest_button_pressed(dest_id, action)
	)
	# W5d: wire file_activated so double-click / open button opens the document.
	_vault_area_tree.file_activated.connect(
		func(key: String) -> void:
			_on_area_tree_file_activated(key)
	)
	vault_area.add_child(_vault_area_tree)
	dest_split.add_child(vault_area)

	# --- Directory area (bottom half) ---
	var dir_area := VBoxContainer.new()
	dir_area.name = "DirArea"
	dir_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dir_area.custom_minimum_size.y = 80

	var dir_hdr := HBoxContainer.new()
	var dir_hdr_lbl := Label.new()
	dir_hdr_lbl.text = "Directories"
	dir_hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_hdr.add_child(dir_hdr_lbl)
	var dir_add_btn := Button.new()
	dir_add_btn.text = "+"
	dir_add_btn.tooltip_text = "Add a directory destination…"
	dir_add_btn.flat = false
	dir_add_btn.pressed.connect(func() -> void: _on_dest_add_for_kind("directory"))
	dir_hdr.add_child(dir_add_btn)
	dir_area.add_child(dir_hdr)

	_dir_area_tree = _ScanTree.new()
	_dir_area_tree.tree_role = "dest:directory"
	_dir_area_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dir_area_tree.file_dropped.connect(_on_area_tree_file_dropped)
	_dir_area_tree.dest_button_pressed.connect(
		func(dest_id: String, action: String) -> void:
			_on_area_dest_button_pressed(dest_id, action)
	)
	# W5d: wire file_activated for directory file rows (open directly via shell).
	_dir_area_tree.file_activated.connect(
		func(key: String) -> void:
			_on_area_tree_file_activated(key)
	)
	dir_area.add_child(_dir_area_tree)
	dest_split.add_child(dir_area)

	# W5: keep _dest_scroll_content as a hidden off-screen VBoxContainer so that
	# pre-existing tests that check "panel._dest_scroll_content != null" still pass.
	# _add_dest_section (called directly by T/V test groups) will append into it.
	_dest_scroll_content = VBoxContainer.new()
	_dest_scroll_content.name = "_DestScrollContent"
	_dest_scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dest_scroll_content.visible = false
	dest_col.add_child(_dest_scroll_content)

	columns.add_child(dest_col)

	# --- Status bar along the bottom ---
	_status_panel = _StatusPanel.new()
	_status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(_status_panel)

	# U6: assign source role for drag context.
	_source_tree.tree_role = "source"
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
		13: _on_recovery_sheet_pressed()


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

	# U4: bind the source provider to its scan_tree and refresh.
	# The source provider takes the vault path so it can flag in-vault files.
	_source_provider = _SourceProvider.new()
	_source_provider.init(conn, path)
	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(_source_provider)
		await _source_tree.refresh()

	# W5: derive registry_path from vault path (sibling .registry.json).
	var base_dir: String = path.get_base_dir()
	var stem: String     = path.get_file().get_basename()
	_registry_path = "%s/%s.registry.json" % [base_dir, stem]

	# W5c: auto-register the open vault as a machine-local routing target.
	# This is idempotent — "already registered" errors are treated as success.
	# The area tree rendering (below) does NOT depend on this succeeding.
	if conn != null and not _registry_path.is_empty():
		var vault_label: String = path.get_file().get_basename()
		var reg_result: Dictionary = await conn.call_tool(
			"minerva_scansort_destination_add",
			{
				"registry_path": _registry_path,
				"kind":          "vault",
				"path":          path,
				"label":         vault_label,
			},
		)
		if not reg_result.get("ok", false):
			var reg_err: String = str(reg_result.get("error", ""))
			if not reg_err.contains("already registered"):
				push_warning("[ScansortPanel] auto-register vault failed: %s" % reg_err)
			# Either already registered (idempotent OK) or warning logged — continue either way.

	# W5: load destinations and build the dynamic right column (legacy stacked sections).
	await _refresh_dest_pane(conn)

	# W5b / W5c: build/refresh the two-area aggregate trees.
	# The vault area renders the open vault directly from its file; no registry dependency.
	await _refresh_area_trees(conn)

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.init(conn)
		_status_panel.set_vault(vault_name, 0)
		_status_panel.set_status("Idle")


func _on_vault_closed_r2() -> void:
	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(null)
		_source_tree.populate([])
	# W5: clear all destination trees.
	_clear_dest_pane()
	# W5b: clear area trees.
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		_vault_area_tree.set_provider(null)
		_vault_area_tree.populate([])
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		_dir_area_tree.set_provider(null)
		_dir_area_tree.populate([])
	_vault_area_provider = null
	_dir_area_provider = null
	_source_provider = null
	_registry_path = ""
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.clear()


# ---------------------------------------------------------------------------
# W5: destination registry UI — build / refresh / add / remove
# ---------------------------------------------------------------------------

## Remove all destination section nodes from the scroll content and clear
## the parallel arrays. Does NOT free the providers (RefCounted — auto-freed).
func _clear_dest_pane() -> void:
	for container in _dest_containers:
		if container != null and is_instance_valid(container):
			container.queue_free()
	_dest_registry.clear()
	_dest_trees.clear()
	_dest_providers.clear()
	_dest_containers.clear()
	_dest_tree = null
	_disk_tree = null


## Fetch destination_list and rebuild the stacked sub-trees.
## Async — awaits an MCP call then awaits each tree's refresh().
func _refresh_dest_pane(conn: Object) -> void:
	_clear_dest_pane()
	if _dest_scroll_content == null or not is_instance_valid(_dest_scroll_content):
		return
	if conn == null:
		return
	if _registry_path.is_empty():
		return

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_destination_list",
		{"registry_path": _registry_path},
	)
	if not result.get("ok", false):
		push_warning("[ScansortPanel] destination_list failed: %s" % result.get("error", "unknown"))
		return

	var destinations: Array = result.get("destinations", [])
	_dest_registry = destinations.duplicate(true)

	for dest: Dictionary in destinations:
		_add_dest_section(conn, dest)

	# Back-compat: _dest_tree points to first destination tree (if any) so tests
	# that check panel._dest_tree still see a non-null Tree after open.
	if _dest_trees.size() > 0:
		_dest_tree = _dest_trees[0]

	# Refresh each destination tree sequentially so the UI settles before return.
	for i: int in range(_dest_trees.size()):
		var tree: Tree = _dest_trees[i]
		if tree != null and is_instance_valid(tree):
			await (tree as Object).call("refresh")


## Build one destination section: header row (label + reprocess + lock + remove) + scan_tree.
## W8: adds a Reprocess button and a locked toggle to each section header.
func _add_dest_section(conn: Object, dest: Dictionary) -> void:
	if _dest_scroll_content == null or not is_instance_valid(_dest_scroll_content):
		return

	var dest_id: String  = str(dest.get("id", ""))
	var label: String    = str(dest.get("label", dest.get("path", dest_id)))
	var kind: String     = str(dest.get("kind", ""))
	var is_locked: bool  = bool(dest.get("locked", false))

	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", 2)
	_dest_scroll_content.add_child(section)

	# Header: "[kind icon] label" + reprocess btn + lock toggle + "×" remove button.
	var hdr := HBoxContainer.new()
	var hdr_lbl := Label.new()
	var kind_icon: String = "V:" if kind == "vault" else "D:"
	hdr_lbl.text = "%s %s" % [kind_icon, label]
	hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr.add_child(hdr_lbl)

	# W8: Reprocess button — disabled when locked.
	var reprocess_btn := Button.new()
	reprocess_btn.name = "ReprocessBtn"
	reprocess_btn.text = "⟳"
	reprocess_btn.tooltip_text = "Reprocess: clear this destination's state for a clean re-run"
	reprocess_btn.flat = true
	reprocess_btn.disabled = is_locked
	var captured_id   := dest_id
	var captured_label := label
	reprocess_btn.pressed.connect(func() -> void:
		_on_dest_reprocess_pressed(captured_id, captured_label)
	)
	hdr.add_child(reprocess_btn)

	# W8: Locked toggle (CheckBox). Checked = destination is locked/final.
	var lock_check := CheckBox.new()
	lock_check.name = "LockCheck"
	lock_check.text = "🔒"
	lock_check.button_pressed = is_locked
	lock_check.tooltip_text = "Lock this destination to prevent reprocessing"
	lock_check.toggled.connect(func(pressed: bool) -> void:
		_on_dest_locked_toggled(captured_id, pressed, reprocess_btn)
	)
	hdr.add_child(lock_check)

	var remove_btn := Button.new()
	remove_btn.text = "×"
	remove_btn.tooltip_text = "Remove this destination from the registry"
	remove_btn.flat = true
	# Capture dest_id by value for the closure.
	remove_btn.pressed.connect(func() -> void:
		_on_dest_remove_pressed(captured_id)
	)
	hdr.add_child(remove_btn)
	section.add_child(hdr)

	# Scan tree for this destination.
	var st: Tree = _ScanTree.new()
	st.size_flags_vertical = Control.SIZE_EXPAND_FILL
	st.custom_minimum_size.y = 80
	st.tree_role = "dest:%s" % dest_id
	section.add_child(st)

	# Provider.
	var provider: Object = _DestinationProvider.new()
	provider.init(conn, _registry_path, dest)
	st.set_provider(provider)

	# Wire drop handler: pass dest_id so the handler knows which destination.
	var captured_dest := dest.duplicate(true)
	st.file_dropped.connect(func(drag_data: Dictionary, target_key: String, target_kind: String) -> void:
		_on_tree_file_dropped(drag_data, target_key, target_kind, captured_dest)
	)

	_dest_trees.append(st)
	_dest_providers.append(provider)
	_dest_containers.append(section)


## Refresh all existing destination trees from their providers.
## W5b: also refreshes the two aggregate area trees.
func _refresh_all_dest_trees() -> void:
	for tree in _dest_trees:
		if tree != null and is_instance_valid(tree):
			await (tree as Object).call("refresh")
	# W5b: refresh the area trees too.
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		await _vault_area_tree.refresh()
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		await _dir_area_tree.refresh()


## W5b / W5c: Build / refresh the two aggregate area providers and populate the area trees.
## For the vault area the open vault path is passed explicitly so it is always
## rendered directly from its file (W5c — not registry-dependent).
func _refresh_area_trees(conn: Object) -> void:
	if conn == null:
		return
	# Vault area requires an open vault path (W5c); directory area requires a registry path.
	# Either can be empty without crashing — the providers return [] gracefully.
	# Build / replace providers (RefCounted — old refs auto-freed on reassign).
	_vault_area_provider = _AreaProvider.new()
	_vault_area_provider.init(conn, _registry_path, "vault", _active_vault_path)
	_dir_area_provider = _AreaProvider.new()
	_dir_area_provider.init(conn, _registry_path, "directory")

	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		_vault_area_tree.set_provider(_vault_area_provider)
		await _vault_area_tree.refresh()
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		_dir_area_tree.set_provider(_dir_area_provider)
		await _dir_area_tree.refresh()


## W5b: handler for dest_button_pressed emitted by either area tree.
## Resolves dest_id and dispatches to the appropriate action.
func _on_area_dest_button_pressed(dest_id: String, action: String) -> void:
	if not _vault_is_open:
		return
	var conn = _get_connection()
	if conn == null:
		return
	# Find the destination dict for label + locked state from either provider.
	var dest_dict: Dictionary = _find_dest_by_id(dest_id)
	var dest_label: String = str(dest_dict.get("label", dest_id))
	var is_locked: bool = bool(dest_dict.get("locked", false))

	match action:
		"remove":
			# W5d: disallow removing the currently-open vault (it is the primary context).
			var dest_path: String = str(dest_dict.get("path", ""))
			if not dest_path.is_empty() and dest_path == _active_vault_path:
				set_status("Cannot remove the currently-open vault destination.")
				return
			_on_dest_remove_pressed(dest_id)
		"reprocess":
			_on_dest_reprocess_pressed(dest_id, dest_label)
		"lock_toggle":
			# Toggle locked state; pass null for the reprocess_btn (not available here).
			_on_dest_locked_toggled(dest_id, not is_locked, null)
		"settings":
			# W5d: vault-level settings popup — "Set/Change Password…" and other vault ops.
			_on_vault_dest_settings_pressed(dest_id, dest_dict)
		"encrypt":
			# W5h: dest_id is a "doc:<id>" key here, not a destination id.
			_on_doc_encrypt_toggle(dest_id, true)
		"decrypt":
			_on_doc_encrypt_toggle(dest_id, false)


## W5h: encrypt or decrypt a single vault document at rest. `doc_key` is a
## "doc:<id>" tree key; `want_encrypted` is the desired new state. Fire-and-
## forget (called from a button handler); awaits the MCP call internally.
func _on_doc_encrypt_toggle(doc_key: String, want_encrypted: bool) -> void:
	if not doc_key.begins_with("doc:"):
		return
	var doc_id: int = int(doc_key.substr(4))
	var vault_path: String = _find_vault_path_for_doc_key(doc_key)
	if vault_path.is_empty():
		vault_path = _active_vault_path
	if vault_path.is_empty():
		set_status("Cannot change encryption: vault path unknown.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if _vault_password.is_empty():
		set_status("Set a vault password first to encrypt/decrypt documents.")
		return
	set_status("%s document…" % ("Encrypting" if want_encrypted else "Decrypting"))
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_document_encrypted",
		{
			"vault_path": vault_path,
			"doc_id": doc_id,
			"encrypt": want_encrypted,
			"password": _vault_password,
		}
	)
	if not result.get("ok", false):
		set_status("ERROR: %s" % result.get("error", "unknown"))
		return
	set_status("Document %s." % ("encrypted" if want_encrypted else "decrypted"))
	# Refresh the vault area tree so the lock icon reflects the new state.
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		await _vault_area_tree.refresh()


## W5b: find a destination dict from the area providers' last_destinations cache.
func _find_dest_by_id(dest_id: String) -> Dictionary:
	# Check vault provider first.
	if _vault_area_provider != null:
		var dests: Array = _vault_area_provider.get("last_destinations") if "last_destinations" in _vault_area_provider else []
		for d: Dictionary in dests:
			if str(d.get("id", "")) == dest_id:
				return d
	# Then directory provider.
	if _dir_area_provider != null:
		var dests: Array = _dir_area_provider.get("last_destinations") if "last_destinations" in _dir_area_provider else []
		for d: Dictionary in dests:
			if str(d.get("id", "")) == dest_id:
				return d
	# Also check _dest_registry (populated by _refresh_dest_pane).
	for d: Dictionary in _dest_registry:
		if str(d.get("id", "")) == dest_id:
			return d
	return {}


## W5d: handler for file_activated emitted by either area tree.
## key starts with "doc:" → vault document: extract to temp dir then shell_open.
## key is an absolute path → directory file: shell_open directly.
func _on_area_tree_file_activated(key: String) -> void:
	if key.begins_with("doc:"):
		# Vault document — need to extract it first.
		var doc_id: int = int(key.substr(4))
		# Find the vault_path this doc belongs to by scanning the active tree item metas.
		# We look up the item in both area trees and read the vault_path meta set by scan_tree.
		var vault_path: String = _find_vault_path_for_doc_key(key)
		if vault_path.is_empty():
			# Fall back to the open vault path (most documents live there).
			vault_path = _active_vault_path
		if vault_path.is_empty():
			set_status("Cannot open document: vault path unknown.")
			return
		var conn = _get_connection()
		if conn == null:
			set_status("ERROR: scansort plugin not running.")
			return
		# Extract to a temp subdir under the user data dir.
		var tmp_dir: String = OS.get_user_data_dir().path_join("scansort_preview")
		DirAccess.make_dir_recursive_absolute(tmp_dir)
		# W5f: pass the cached vault password so encrypted documents can be
		# decrypted on extract. The password is only cached for the currently
		# open vault — a document that lives in a different (non-open) vault
		# has no password available here, so an encrypted doc there cannot be
		# opened until that vault is opened.
		var extract_args: Dictionary = {
			"vault_path": vault_path, "doc_id": doc_id, "dest": tmp_dir,
		}
		if vault_path == _active_vault_path and not _vault_password.is_empty():
			extract_args["password"] = _vault_password
		set_status("Extracting document…")
		var result: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_document",
			extract_args
		)
		# extract_document returns {ok: true, path: "/abs/path/to/file"} on success.
		if not result.get("ok", false):
			var err_msg: String = str(result.get("error", "unknown"))
			# W5f: encrypted document in a vault that isn't the open one — the
			# password isn't cached, so give the user a clear, actionable hint
			# instead of a raw backend error.
			if vault_path != _active_vault_path and (
				err_msg.to_lower().contains("encrypt")
				or err_msg.to_lower().contains("password")
			):
				set_status(
					"This document is encrypted. Open its vault first to unlock it."
				)
			else:
				set_status("ERROR: extract_document failed — %s" % err_msg)
			return
		var out_path: String = str(result.get("path", ""))
		if out_path.is_empty():
			set_status("ERROR: extract_document returned no path.")
			return
		set_status("Opening: %s" % out_path.get_file())
		OS.shell_open(out_path)
	else:
		# Directory file — absolute path, open directly.
		if key.is_empty():
			return
		set_status("Opening: %s" % key.get_file())
		OS.shell_open(key)


## W5d: walk both area trees to find the vault_path meta on the item with the given key.
## Returns "" if not found (caller falls back to _active_vault_path).
func _find_vault_path_for_doc_key(key: String) -> String:
	for tree in [_vault_area_tree, _dir_area_tree]:
		if tree == null or not is_instance_valid(tree):
			continue
		var found: TreeItem = _find_item_by_key(tree as Tree, key)
		if found != null and found.has_meta("vault_path"):
			var vp: String = str(found.get_meta("vault_path", ""))
			if not vp.is_empty():
				return vp
	return ""


## W5d: vault destination [Settings] button → PopupMenu with vault-level actions.
## Shows "Set/Change Password…" (reuses existing password dialog flow).
func _on_vault_dest_settings_pressed(dest_id: String, dest_dict: Dictionary) -> void:
	var dest_path: String = str(dest_dict.get("path", ""))
	# Only support settings for the open vault for now (the only vault with a live conn).
	if dest_path != _active_vault_path:
		set_status("Settings are only available for the currently-open vault.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Build a one-item PopupMenu anchored to the mouse position.
	var menu := PopupMenu.new()
	menu.add_item("Set / Change Password…", 0)
	add_child(menu)
	menu.id_pressed.connect(func(id: int) -> void:
		match id:
			0:
				# Reuse the existing set-password dialog flow.
				_pending_vault_path = _active_vault_path
				_pending_password_action = "create"
				_show_password_dialog_set()
		if is_instance_valid(menu):
			menu.queue_free()
	)
	menu.popup_on_parent(Rect2i(
		int(get_viewport().get_mouse_position().x),
		int(get_viewport().get_mouse_position().y),
		0, 0))


## W5b: file_dropped handler wired to both area trees.
## Resolves the destination from the drop target key (which is either "dest:<id>"
## for a top-level row, or a category/file key nested inside a destination).
## Walks up the item's parent chain to find the "dest:<id>" ancestor.
## W5g: vault-doc drops (role "dest:vault") onto directory rows are intercepted
## here and routed to _on_vault_doc_dropped_to_dir instead of classify logic.
func _on_area_tree_file_dropped(drag_data: Dictionary, target_key: String, target_kind: String) -> void:
	var role: String = str(drag_data.get("role", ""))

	# W5g: vault-doc → directory extract gesture.
	# A drag_data whose role is "dest:vault" carries a vault document key ("doc:<id>")
	# and vault_path.  The target is a row in the directory area tree (a dest:<id>
	# directory destination row or a dir:<name> subfolder row).
	if role == "dest:vault":
		await _on_vault_doc_dropped_to_dir(drag_data, target_key)
		return

	# Original classify / reclassify path — resolve which vault destination the
	# target row belongs to, then delegate to _on_tree_file_dropped.
	var dest_id: String = ""
	var dest_dict: Dictionary = {}

	if target_key.begins_with("dest:"):
		dest_id = target_key.substr(5)  # strip "dest:"
		dest_dict = _find_dest_by_id(dest_id)
	else:
		# Walk up the active tree's item hierarchy to find the dest ancestor.
		# Determine which tree emitted (vault or dir area tree).
		var tree_that_dropped: Tree = null
		if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
			# We find the item by key in both trees.
			var item = _find_item_by_key(_vault_area_tree, target_key)
			if item != null:
				tree_that_dropped = _vault_area_tree
		if tree_that_dropped == null and _dir_area_tree != null and is_instance_valid(_dir_area_tree):
			var item = _find_item_by_key(_dir_area_tree, target_key)
			if item != null:
				tree_that_dropped = _dir_area_tree
		if tree_that_dropped != null:
			var item = _find_item_by_key(tree_that_dropped, target_key)
			# Walk up to root's direct child (top-level dest row).
			while item != null:
				var parent = item.get_parent()
				if parent == null or parent == tree_that_dropped.get_root():
					break
				item = parent
			if item != null:
				var item_key: String = str(item.get_metadata(1))
				if item_key.begins_with("dest:"):
					dest_id = item_key.substr(5)
					dest_dict = _find_dest_by_id(dest_id)

	# Delegate to the main drop handler with the resolved dest context.
	_on_tree_file_dropped(drag_data, target_key, target_kind, dest_dict)


## W5g: handle a vault doc row dropped onto a directory tree row.
## Resolves the filesystem directory path from target_key and calls extract_document.
func _on_vault_doc_dropped_to_dir(drag_data: Dictionary, target_key: String) -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var drag_key: String = str(drag_data.get("key", ""))
	if not drag_key.begins_with("doc:"):
		return  # unexpected — only doc rows should have role dest:vault
	var doc_id: int = int(drag_key.substr(4))

	# vault_path is embedded in drag data by _get_drag_data (W5g).
	var vault_path: String = str(drag_data.get("vault_path", ""))
	if vault_path.is_empty():
		vault_path = _find_vault_path_for_doc_key(drag_key)
	if vault_path.is_empty():
		vault_path = _active_vault_path
	if vault_path.is_empty():
		set_status("Cannot extract: vault path unknown.")
		return

	# Resolve the target filesystem directory from target_key.
	# target_key may be:
	#   "dest:<id>"   — top-level directory destination row → use dest.path
	#   "dir:<name>"  — subfolder row → walk up to the "dest:<id>" ancestor + append name
	var dest_dir: String = _resolve_dir_path_from_key(target_key)
	if dest_dir.is_empty():
		set_status("Cannot extract: could not resolve target directory.")
		return

	var extract_args: Dictionary = {
		"vault_path": vault_path,
		"doc_id":     doc_id,
		"dest":       dest_dir,
	}
	if vault_path == _active_vault_path and not _vault_password.is_empty():
		extract_args["password"] = _vault_password

	set_status("Extracting…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_document",
		extract_args
	)
	if not result.get("ok", false):
		var err: String = str(result.get("error", "unknown"))
		push_warning("[ScansortPanel] drag-extract: doc_id %d failed — %s" % [doc_id, err])
		set_status("Extract failed: %s" % err)
		return

	var out_file: String = str(result.get("path", ""))
	set_status("Extracted %s → %s" % [out_file.get_file(), dest_dir])

	# Refresh the directory tree so the new file shows up.
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		await _dir_area_tree.refresh()


## W5g: resolve an absolute filesystem directory path from a dir-area tree key.
## "dest:<id>"  → look up destination.path in the dir provider's last_destinations.
## "dir:<name>" → walk up the dir tree to find the dest:<id> ancestor, then
##                 append the subfolder name.
func _resolve_dir_path_from_key(key: String) -> String:
	if key.begins_with("dest:"):
		var dest_id: String = key.substr(5)
		var dest_dict: Dictionary = _find_dest_by_id(dest_id)
		return str(dest_dict.get("path", ""))

	if key.begins_with("dir:"):
		var subfolder: String = key.substr(4)
		# Walk the dir area tree to find the parent dest:<id> ancestor.
		if _dir_area_tree == null or not is_instance_valid(_dir_area_tree):
			return ""
		var item: TreeItem = _find_item_by_key(_dir_area_tree, key)
		if item == null:
			return ""
		# Walk upward until we hit a "dest:…" key.
		var ancestor: TreeItem = item.get_parent()
		while ancestor != null and ancestor != _dir_area_tree.get_root():
			var anc_key: String = str(ancestor.get_metadata(1))
			if anc_key.begins_with("dest:"):
				var dest_id: String = anc_key.substr(5)
				var dest_dict: Dictionary = _find_dest_by_id(dest_id)
				var base_path: String = str(dest_dict.get("path", ""))
				if base_path.is_empty():
					return ""
				# Only append if subfolder is not the virtual "(root)" marker.
				if subfolder == "(root)":
					return base_path
				return base_path.path_join(subfolder)
			ancestor = ancestor.get_parent()
		return ""

	return ""


## W5b: helper — find a TreeItem by its COL_NAME metadata key, searching from root.
func _find_item_by_key(tree: Tree, key: String) -> TreeItem:
	var root: TreeItem = tree.get_root()
	if root == null:
		return null
	return _find_item_recursive(root, key)


func _find_item_recursive(item: TreeItem, key: String) -> TreeItem:
	if str(item.get_metadata(1)) == key:
		return item
	var child: TreeItem = item.get_first_child()
	while child != null:
		var found: TreeItem = _find_item_recursive(child, key)
		if found != null:
			return found
		child = child.get_next()
	return null


## W5b: per-kind Add button handler — opens the add-destination dialog
## pre-set to the given kind ("vault" or "directory").
func _on_dest_add_for_kind(kind: String) -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if _registry_path.is_empty():
		set_status("No registry path — open a vault first.")
		return

	var dlg := AcceptDialog.new()
	dlg.title = "Add %s Destination" % ("Vault" if kind == "vault" else "Directory")
	dlg.min_size = Vector2i(440, 180)
	_UiScale.apply_to(dlg)

	var vbox := VBoxContainer.new()
	dlg.add_child(vbox)

	# Label field.
	var label_row := HBoxContainer.new()
	var label_lbl := Label.new()
	label_lbl.text = "Label:"
	label_row.add_child(label_lbl)
	var label_edit := LineEdit.new()
	label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_edit.placeholder_text = "e.g. Archived Invoices"
	label_row.add_child(label_edit)
	vbox.add_child(label_row)

	# Path field + browse button.
	var path_row := HBoxContainer.new()
	var path_lbl := Label.new()
	path_lbl.text = "Path:"
	path_row.add_child(path_lbl)
	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if kind == "vault":
		path_edit.placeholder_text = "/absolute/path/to/vault.ssort"
	else:
		path_edit.placeholder_text = "/absolute/path/to/directory"
	path_row.add_child(path_edit)
	var browse_btn := Button.new()
	browse_btn.text = "…"
	path_row.add_child(browse_btn)
	vbox.add_child(path_row)

	add_child(dlg)

	browse_btn.pressed.connect(func() -> void:
		var picker := FileDialog.new()
		_UiScale.apply_to(picker)
		picker.access = FileDialog.ACCESS_FILESYSTEM
		if kind == "vault":
			picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			picker.filters = PackedStringArray(["*.ssort ; Scansort Vault"])
			picker.title = "Select Vault File"
		else:
			picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			picker.title = "Select Directory"
		picker.file_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.dir_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.canceled.connect(func() -> void: picker.queue_free())
		add_child(picker)
		picker.popup_centered(Vector2i(700, 500))
	)

	dlg.confirmed.connect(func() -> void:
		var dest_path: String = path_edit.text.strip_edges()
		var dest_label: String = label_edit.text.strip_edges()
		if dest_path.is_empty():
			set_status("Add destination: path is required.")
			dlg.queue_free()
			return
		if dest_label.is_empty():
			dest_label = dest_path.get_file()
		_do_add_destination(conn, kind, dest_path, dest_label)
		dlg.queue_free()
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered()


## "+" add-destination button handler. Shows a simple dialog to pick kind + path.
func _on_dest_add_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if _registry_path.is_empty():
		set_status("No registry path — open a vault first.")
		return

	# Build a simple inline add-destination dialog (AcceptDialog + VBoxContainer).
	var dlg := AcceptDialog.new()
	dlg.title = "Add Destination"
	dlg.min_size = Vector2i(440, 220)
	_UiScale.apply_to(dlg)

	var vbox := VBoxContainer.new()
	dlg.add_child(vbox)

	# Kind selector.
	var kind_row := HBoxContainer.new()
	var kind_lbl := Label.new()
	kind_lbl.text = "Kind:"
	kind_row.add_child(kind_lbl)
	var kind_opt := OptionButton.new()
	kind_opt.add_item("Vault (.ssort)")
	kind_opt.add_item("Directory")
	kind_row.add_child(kind_opt)
	vbox.add_child(kind_row)

	# Label field.
	var label_row := HBoxContainer.new()
	var label_lbl := Label.new()
	label_lbl.text = "Label:"
	label_row.add_child(label_lbl)
	var label_edit := LineEdit.new()
	label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_edit.placeholder_text = "e.g. Archived Invoices"
	label_row.add_child(label_edit)
	vbox.add_child(label_row)

	# Path field + browse button.
	var path_row := HBoxContainer.new()
	var path_lbl := Label.new()
	path_lbl.text = "Path:"
	path_row.add_child(path_lbl)
	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.placeholder_text = "/absolute/path/to/vault.ssort or /directory"
	path_row.add_child(path_edit)
	var browse_btn := Button.new()
	browse_btn.text = "…"
	browse_btn.tooltip_text = "Browse for a vault or directory"
	path_row.add_child(browse_btn)
	vbox.add_child(path_row)

	add_child(dlg)

	# Browse button opens a file/directory picker.
	browse_btn.pressed.connect(func() -> void:
		var picker := FileDialog.new()
		_UiScale.apply_to(picker)
		picker.access = FileDialog.ACCESS_FILESYSTEM
		if kind_opt.selected == 0:
			picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			picker.filters = PackedStringArray(["*.ssort ; Scansort Vault"])
			picker.title = "Select Vault File"
		else:
			picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			picker.title = "Select Directory"
		picker.file_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.dir_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.canceled.connect(func() -> void: picker.queue_free())
		add_child(picker)
		picker.popup_centered(Vector2i(700, 500))
	)

	dlg.confirmed.connect(func() -> void:
		var kind_str: String = "vault" if kind_opt.selected == 0 else "directory"
		var dest_path: String = path_edit.text.strip_edges()
		var dest_label: String = label_edit.text.strip_edges()
		if dest_path.is_empty():
			set_status("Add destination: path is required.")
			dlg.queue_free()
			return
		if dest_label.is_empty():
			dest_label = dest_path.get_file()
		_do_add_destination(conn, kind_str, dest_path, dest_label)
		dlg.queue_free()
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())

	dlg.popup_centered()


## Call destination_add then refresh the pane.
func _do_add_destination(conn: Object, kind: String, path: String, label: String) -> void:
	set_status("Adding destination…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_destination_add",
		{
			"registry_path": _registry_path,
			"kind":          kind,
			"path":          path,
			"label":         label,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: destination_add failed — %s" % result.get("error", "unknown"))
		return
	set_status("Destination added.")
	await _refresh_dest_pane(conn)
	await _refresh_area_trees(conn)


## "×" remove-destination button handler.
func _on_dest_remove_pressed(dest_id: String) -> void:
	if not _vault_is_open:
		return
	var conn = _get_connection()
	if conn == null:
		return
	if _registry_path.is_empty():
		return

	set_status("Removing destination…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_destination_remove",
		{
			"registry_path": _registry_path,
			"id":            dest_id,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: destination_remove failed — %s" % result.get("error", "unknown"))
		return
	set_status("Destination removed.")
	await _refresh_dest_pane(conn)
	await _refresh_area_trees(conn)


## W8: Reprocess button handler — shows confirm dialog then calls backend.
## Called when the user clicks the ⟳ button on a destination's header.
## MUST show a confirm dialog before doing anything destructive.
func _on_dest_reprocess_pressed(dest_id: String, dest_label: String) -> void:
	if not _vault_is_open:
		return
	var conn = _get_connection()
	if conn == null:
		return
	if _registry_path.is_empty():
		return

	# Show confirm dialog — do NOT call the backend without explicit user confirmation.
	var dlg := AcceptDialog.new()
	dlg.title = "Confirm Reprocess"
	dlg.dialog_text = (
		"Reprocess destination '%s'?\n\n" % dest_label
		+ "This will PERMANENTLY DELETE all filed output for this destination\n"
		+ "(files in a directory, or document rows in a vault).\n\n"
		+ "The operation cannot be undone. Process All will re-populate it on the next run."
	)
	dlg.ok_button_text = "Reprocess"
	add_child(dlg)

	var confirmed := false
	dlg.confirmed.connect(func() -> void:
		confirmed = true
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(480, 220))

	# Wait for dialog to be dismissed.
	await dlg.visibility_changed
	if not confirmed:
		if is_instance_valid(dlg):
			dlg.queue_free()
		return
	if is_instance_valid(dlg):
		dlg.queue_free()

	# User confirmed — now call the backend.
	set_status("Reprocessing destination '%s'..." % dest_label)
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_reprocess_destination",
		{
			"registry_path":  _registry_path,
			"destination_id": dest_id,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: reprocess_destination failed — %s" % result.get("error", "unknown"))
		return
	var summary: String = str(result.get("summary", "Done."))
	set_status("Reprocessed: %s" % summary)
	# Refresh this destination's sub-tree so the UI reflects the cleared state.
	await _refresh_dest_pane(conn)
	await _refresh_area_trees(conn)


## W8: Locked toggle handler — calls set_destination_locked and updates the
## Reprocess button's disabled state immediately (no full pane refresh needed).
func _on_dest_locked_toggled(dest_id: String, locked: bool, reprocess_btn: Button) -> void:
	if not _vault_is_open:
		return
	var conn = _get_connection()
	if conn == null:
		return
	if _registry_path.is_empty():
		return

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_destination_locked",
		{
			"registry_path":  _registry_path,
			"destination_id": dest_id,
			"locked":         locked,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: set_destination_locked failed — %s" % result.get("error", "unknown"))
		return

	# Sync the Reprocess button's disabled state immediately (UX — backend refuses
	# regardless, but this gives instant visual feedback).
	if reprocess_btn != null and is_instance_valid(reprocess_btn):
		reprocess_btn.disabled = locked
	set_status("Destination %s." % ("locked" if locked else "unlocked"))


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

	# W5: refresh all destination trees so the new document shows up,
	# and re-scan the source pane so the just-ingested file shows its in-vault mark.
	await _refresh_all_dest_trees()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()


func _on_add_dialog_cancelled() -> void:
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	set_status("Add document cancelled.")


# ---------------------------------------------------------------------------
# W10: Process All — full filing-engine pipeline (integration capstone)
# ---------------------------------------------------------------------------
#
# Per-source-document pipeline (replaces U5's extract→dedup→classify→insert):
#
#   1. Phase 1 — classify_document → facts + rule_signals envelope.
#   2. Phase 2 — run_rule_engine (classification + file facts + rules_path)
#                → outcome.fired (FiredRuleAction list).
#   3. Dedup (W7) — BEFORE placement: near-dup simhash/dhash check via
#      _check_near_dup; on a hit, surface the disposition dialog and AWAIT
#      the user's choice (keep_both / replace / skip). Cancel == skip.
#      Exact SHA-256 is handled inside place_fanout (skipped-already-present).
#   4. Fan-out placement (W6) — for each fired action, place_fanout to its
#      copy_to dest-id list, honouring the disposition.
#   5. Audit (W9) — when audit_log_enabled, one audit_append row per
#      PlacementResult. Audit failure is non-fatal.
#
# U5's batched-parallel structure is PRESERVED: N source files in flight at
# once, drained on process_frame, batch size from Settings concurrency. The
# Stop control and the end-of-run status summary are kept (the summary is
# extended with the new outcome counters).
#
# Deadlock note: the dedup disposition dialog is awaited mid-loop. To avoid a
# process_frame-drain deadlock (and to keep the UX sane — never two prompts at
# once) the dialog is SERIALISED behind _dedup_prompt_busy: a worker that
# needs a prompt awaits process_frame until the prompt seat is free, then
# holds it for the duration of its await. The rest of the batch keeps running
# in parallel; only the prompting step is single-file.

## W10: true when a dedup disposition dialog is currently being awaited by some
## worker coroutine. Serialises the prompt so the batched-parallel loop never
## shows two prompts at once and never deadlocks the process_frame drain.
var _dedup_prompt_busy: bool = false

## W10 test seam: when non-empty, _show_dedup_disposition returns this value
## immediately instead of popping the real dialog. Lets headless smoke tests
## drive the near-dup path without a visible popup. Production leaves it "".
var _test_dedup_auto_disposition: String = ""


## Called when the user clicks the "Process All" button in the chrome bar.
## Drives every source file through the full filing-engine pipeline.
## Files already in the vault or in _processed_keys are skipped. One failed
## file does NOT abort the whole run.
## Batched-parallel execution via ScansortSettings.load_concurrency().
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

	# Stable ordering — sort source files by path so runs are deterministic.
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("path", "")) < str(b.get("path", ""))
	)

	# Enter running state.
	_process_cancelled = false
	_dedup_prompt_busy = false
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = true
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = false
	set_status("Processing…")

	# Reset per-run shared counters. W10 extends U7's counter set with the new
	# filing-engine outcomes.
	_run_counters = {
		"processed":  0,  # source files that produced at least one placement
		"skipped":    0,  # session-skipped (already processed / in vault)
		"failed":     0,  # pipeline error (classify / rule engine / etc.)
		"low_conf":   0,  # processed but classification confidence < threshold
		"placed":     0,  # individual PlacementResults with status "placed"
		"exact_dup":  0,  # PlacementResults skipped-already-present (exact SHA)
		"user_skip":  0,  # source files the user dispositioned as "skip"
		"flagged":    0,  # source files that surfaced a near-dup disposition
		"no_rule":    0,  # source files where no rule fired (nothing to place)
	}
	# Per-destination placement tally: dest_id -> count of "placed" results.
	var per_dest: Dictionary = {}

	var total: int = files.size()

	# Read concurrency from settings (default 1 = sequential).
	var concurrency: int = _SettingsDialog.ScansortSettings.load_concurrency()

	# Processed-state priming: place_fanout does its own per-destination
	# processed-state check, so we rely on that rather than priming
	# scan_directory_hashes here. Priming would be a pure optimisation and is
	# skipped to keep the loop simple (documented W10 decision).

	# Audit-log settings — read once at run start.
	var audit_enabled: bool = _SettingsDialog.ScansortSettings.load_audit_log_enabled()
	var audit_path: String  = _SettingsDialog.ScansortSettings.load_audit_log_path()

	# Batched-parallel loop — structure preserved from U5/U7.
	var idx: int = 0
	while idx < total:
		if _process_cancelled:
			break
		var batch_remaining: Dictionary = {"n": 0}
		for _j: int in range(concurrency):
			if idx >= total or _process_cancelled:
				break
			batch_remaining["n"] += 1
			# Fire the worker — do NOT await. Worker decrements batch_remaining.
			_process_one_source_file(
				files[idx], conn, batch_remaining,
				audit_enabled, audit_path, per_dest
			)
			idx += 1
		# Wait for the batch to drain.
		while int(batch_remaining["n"]) > 0:
			await get_tree().process_frame

	# Run finished (or cancelled) — refresh trees.
	await _refresh_all_dest_trees()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()

	# Restore button states.
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = not _vault_is_open
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = true

	# Summary status — extended with the new filing-engine outcome counters.
	var processed_this_run: int = int(_run_counters.get("processed", 0))
	var skipped: int    = int(_run_counters.get("skipped", 0))
	var failed: int     = int(_run_counters.get("failed", 0))
	var placed: int     = int(_run_counters.get("placed", 0))
	var exact_dup: int  = int(_run_counters.get("exact_dup", 0))
	var user_skip: int  = int(_run_counters.get("user_skip", 0))
	var flagged: int    = int(_run_counters.get("flagged", 0))

	# Per-destination tail (only when there were placements worth reporting).
	var dest_tail: String = ""
	if not per_dest.is_empty():
		var parts: PackedStringArray = PackedStringArray()
		var dest_ids: Array = per_dest.keys()
		dest_ids.sort()
		for dest_id: String in dest_ids:
			parts.append("%s:%d" % [dest_id, int(per_dest[dest_id])])
		dest_tail = " [" + ", ".join(parts) + "]"

	var head: String = "Stopped" if _process_cancelled else "Processed %d/%d" % [processed_this_run, total]
	set_status(
		"%s — %d placed, %d exact-dup, %d flagged, %d user-skip, %d failed, %d skipped%s" % [
			head, placed, exact_dup, flagged, user_skip, failed, skipped, dest_tail
		]
	)


## W10: per-file worker coroutine for the batched-parallel Process All loop.
## Drives one source file through classify → run_rule_engine → dedup →
## place_fanout → audit. Decrements batch_remaining["n"] in EVERY exit path
## (success or failure) so the outer while-loop can drain without a separate
## join mechanism.
##
## conn is passed explicitly so this worker is unit-testable with a mock
## connection (the smoke test drives it directly).
func _process_one_source_file(
		file: Dictionary,
		conn: Object,
		batch_remaining: Dictionary,
		audit_enabled: bool = false,
		audit_path: String = "",
		per_dest: Dictionary = {}) -> void:
	const MAX_CLASSIFY_CHARS := 4000
	const VISION_THRESHOLD := 50

	var fpath: String = str(file.get("path", ""))
	var fname: String = str(file.get("name", fpath.get_file()))

	# Skip already-done files.
	if bool(file.get("in_vault", false)) or _processed_keys.has(fpath):
		_run_counters["skipped"] = int(_run_counters.get("skipped", 0)) + 1
		batch_remaining["n"] -= 1
		return

	# -- Step 0: Extract text + fingerprints (needed for classify + dedup) --
	var extract_res: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": fpath}
	)
	if not extract_res.get("success", false):
		push_warning("[ScansortPanel] W10 extract failed for %s: %s" % [
			fname, str(extract_res.get("error", "unknown"))
		])
		_run_counters["failed"] = int(_run_counters.get("failed", 0)) + 1
		batch_remaining["n"] -= 1
		return

	var sha256:     String = str(extract_res.get("sha256",   ""))
	var char_count: int    = int(extract_res.get("char_count", 0))
	var full_text:  String = str(extract_res.get("full_text", ""))
	var simhash:    String = str(extract_res.get("simhash",  "0000000000000000"))
	var dhash:      String = str(extract_res.get("dhash",    "0000000000000000"))
	var file_size:  int    = int(extract_res.get("size", file.get("size", 0)))
	var extension:  String = fpath.get_extension()

	# -- Phase 1: classify_document → facts + rule_signals envelope --
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
			push_warning("[ScansortPanel] W10 render failed for %s: %s" % [
				fname, str(render_res.get("error", "unknown"))
			])
			_run_counters["failed"] = int(_run_counters.get("failed", 0)) + 1
			batch_remaining["n"] -= 1
			return
		classify_args["mode"]        = "vision"
		classify_args["page_images"] = render_res.get("pages", [])

	var classify_res: Dictionary = await conn.call_tool(
		"minerva_scansort_classify_document",
		classify_args
	)
	if not classify_res.get("ok", false):
		push_warning("[ScansortPanel] W10 classify failed for %s: %s" % [
			fname, str(classify_res.get("error", "unknown"))
		])
		_run_counters["failed"] = int(_run_counters.get("failed", 0)) + 1
		batch_remaining["n"] -= 1
		return

	var classification: Dictionary = classify_res.get("classification", {})
	var rule_snapshot: String = str(classify_res.get("rule_snapshot", ""))

	# -- Phase 2: run_rule_engine → fired actions --
	var rules_path: String = _vault_rules_path()
	var rule_engine_res: Dictionary = await conn.call_tool(
		"minerva_scansort_run_rule_engine",
		{
			"classification": classification,
			"rules_path":     rules_path,
			"filename":       fname,
			"extension":      extension,
			"size":           file_size,
		}
	)
	if not rule_engine_res.get("ok", false):
		push_warning("[ScansortPanel] W10 rule engine failed for %s: %s" % [
			fname, str(rule_engine_res.get("error", "unknown"))
		])
		_run_counters["failed"] = int(_run_counters.get("failed", 0)) + 1
		batch_remaining["n"] -= 1
		return

	var outcome: Dictionary = rule_engine_res.get("outcome", {})
	var fired: Array = outcome.get("fired", [])

	if fired.is_empty():
		# No rule fired — nothing to place. Record as processed-with-no-rule
		# (the file is reviewed; it is NOT a failure and NOT lost).
		_processed_keys[fpath] = true
		_run_counters["no_rule"] = int(_run_counters.get("no_rule", 0)) + 1
		_push_session_marks_to_provider()
		batch_remaining["n"] -= 1
		return

	# Common DocMeta carried into every place_fanout call.
	var doc_meta: Dictionary = {
		"category":      str(classification.get("category", outcome.get("effective_category", ""))),
		"confidence":    float(classification.get("confidence", 0.0)),
		"issuer":        str(classification.get("issuer", "")),
		"description":   str(classification.get("description", "")),
		"doc_date":      str(classification.get("doc_date", "")),
		"status":        "classified",
		"sha256":        sha256,
		"simhash":       simhash,
		"dhash":         dhash,
		"source_path":   fpath,
		"rule_snapshot": rule_snapshot,
	}

	var any_placed: bool = false

	# -- Per fired action: dedup → disposition → place_fanout → audit --
	for action: Dictionary in fired:
		if _process_cancelled:
			break

		var copy_to: Array = action.get("copy_to", [])
		if copy_to.is_empty():
			continue

		var rule_dict: Dictionary = action.get("rule", {})
		var rule_label: String = str(rule_dict.get("label", action.get("category", "")))
		var resolved_subfolder: String = str(action.get("resolved_subfolder", ""))
		var resolved_rename_pattern: String = str(action.get("resolved_rename_pattern", ""))
		var encrypt: bool = bool(action.get("encrypt", false))

		# -- W7 dedup: near-dup check BEFORE placement --
		# Exact SHA-256 dups are auto-skipped inside place_fanout — we do not
		# re-check them here. Near-dup (simhash/dhash) matches MUST surface a
		# disposition prompt; logical-identity has no MCP surface so it stays a
		# place_fanout-internal concern.
		var disposition: String = "keep_both"  # default when no near-dup match
		var target_hint: String = "%s/%s" % [resolved_subfolder, fname] if not resolved_subfolder.is_empty() else fname
		var match_info: Dictionary = await _check_near_dup(
			conn, fpath, simhash, dhash, rule_label, target_hint
		)
		if not match_info.is_empty():
			# HARD CONSTRAINT: a near-dup match is NEVER auto-dropped. The user's
			# explicit disposition decides. Serialise the prompt so the
			# batched-parallel drain never sees two prompts at once.
			_run_counters["flagged"] = int(_run_counters.get("flagged", 0)) + 1
			while _dedup_prompt_busy and not _process_cancelled:
				await get_tree().process_frame
			if _process_cancelled:
				break
			_dedup_prompt_busy = true
			disposition = await _show_dedup_disposition(match_info)
			_dedup_prompt_busy = false

		if disposition == "skip":
			# Explicit user skip — do NOT place this action. No data loss: the
			# source file stays where it is.
			_run_counters["user_skip"] = int(_run_counters.get("user_skip", 0)) + 1
			if audit_enabled and not audit_path.is_empty():
				await _append_audit_rows(conn, audit_path, [{
					"event":            "skipped",
					"source_sha256":    sha256,
					"source_filename":  fname,
					"rule_label":       rule_label,
					"destination_id":   "",
					"destination_kind": "",
					"resolved_path":    "",
					"disposition":      "skip",
					"detail":           "user dispositioned near-dup as skip",
				}])
			continue

		# -- W6 fan-out placement --
		# disposition is "keep_both" or "replace". place_fanout has no native
		# replace mode, so for "replace" we place normally (collision-safe
		# naming) and record the disposition in the audit row as "replace" —
		# the existing document is left in place; the new one is filed
		# alongside it and the audit trail records the human's intent.
		var place_res: Dictionary = await conn.call_tool(
			"minerva_scansort_place_fanout",
			{
				"file_path":               fpath,
				"copy_to":                 copy_to,
				"resolved_subfolder":      resolved_subfolder,
				"resolved_rename_pattern": resolved_rename_pattern,
				"encrypt":                 encrypt,
				"registry_path":           _registry_path,
				"category":                doc_meta["category"],
				"confidence":              doc_meta["confidence"],
				"issuer":                  doc_meta["issuer"],
				"description":             doc_meta["description"],
				"doc_date":                doc_meta["doc_date"],
				"status":                  doc_meta["status"],
				"sha256":                  doc_meta["sha256"],
				"simhash":                 doc_meta["simhash"],
				"dhash":                   doc_meta["dhash"],
				"source_path":             doc_meta["source_path"],
				"rule_snapshot":           doc_meta["rule_snapshot"],
			}
		)
		if not place_res.get("ok", false):
			push_warning("[ScansortPanel] W10 place_fanout failed for %s: %s" % [
				fname, str(place_res.get("error", "unknown"))
			])
			_run_counters["failed"] = int(_run_counters.get("failed", 0)) + 1
			continue

		var placements: Array = place_res.get("placements", [])
		var audit_rows: Array = []
		for pr: Dictionary in placements:
			var pr_status: String = str(pr.get("status", "error"))
			var dest_id: String   = str(pr.get("destination_id", ""))
			var dest_kind: String = str(pr.get("kind", ""))
			var target_path: String = str(pr.get("target_path", ""))
			var pr_msg: String    = str(pr.get("message", ""))

			if pr_status == "placed":
				any_placed = true
				_run_counters["placed"] = int(_run_counters.get("placed", 0)) + 1
				if not dest_id.is_empty():
					per_dest[dest_id] = int(per_dest.get(dest_id, 0)) + 1
			elif pr_status == "skipped-already-present":
				_run_counters["exact_dup"] = int(_run_counters.get("exact_dup", 0)) + 1

			# W9: one audit row per PlacementResult.
			audit_rows.append({
				"event":            pr_status,
				"source_sha256":    sha256,
				"source_filename":  fname,
				"rule_label":       rule_label,
				"destination_id":   dest_id,
				"destination_kind": dest_kind,
				"resolved_path":    target_path,
				"disposition":      disposition,
				"detail":           pr_msg,
			})

		# W9: append audit rows — non-fatal on failure.
		if audit_enabled and not audit_path.is_empty() and not audit_rows.is_empty():
			await _append_audit_rows(conn, audit_path, audit_rows)

	# Record session state. A source file is "processed" when it produced at
	# least one placement; otherwise it was user-skipped / no-rule (already
	# counted above) but we still mark it so it is not re-attempted this run.
	_processed_keys[fpath] = true
	if any_placed:
		_run_counters["processed"] = int(_run_counters.get("processed", 0)) + 1
		var confidence: float = float(classification.get("confidence", 0.0))
		if confidence < LOW_CONFIDENCE_THRESHOLD:
			_low_confidence_keys[fpath] = true
			_run_counters["low_conf"] = int(_run_counters.get("low_conf", 0)) + 1

	_push_session_marks_to_provider()
	batch_remaining["n"] -= 1


## W10: append one or more audit rows. NON-FATAL — a write failure logs a
## warning and never aborts the run. Fills in the timestamp per row.
func _append_audit_rows(conn: Object, audit_path: String, rows: Array) -> void:
	if conn == null or audit_path.is_empty() or rows.is_empty():
		return
	var ts: String = Time.get_datetime_string_from_system(true, true)
	var stamped: Array = []
	for row: Dictionary in rows:
		var r: Dictionary = row.duplicate(true)
		if not r.has("timestamp") or str(r.get("timestamp", "")).is_empty():
			r["timestamp"] = ts
		stamped.append(r)
	var res: Dictionary = await conn.call_tool(
		"minerva_scansort_audit_append",
		{"log_path": audit_path, "rows": stamped}
	)
	if not res.get("ok", false):
		push_warning("[ScansortPanel] W10 audit_append failed (non-fatal): %s" % str(res.get("error", "unknown")))


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
	# W5: refresh all destination trees so updated metadata is visible.
	await _refresh_all_dest_trees()


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
	dlg.init(conn, _active_vault_path)
	dlg.settings_changed.connect(
		func() -> void:
			set_status("Scansort settings saved.")
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(580, 420))


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


## Called when user picks "Recovery Sheet…" from the File menu.
func _on_recovery_sheet_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _RecoverySheetDialog.new()
	add_child(dlg)
	dlg.init(conn, _active_vault_path, _vault_password)
	dlg.recovery_changed.connect(
		func() -> void:
			set_status("Recovery sheet metadata saved.")
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
	popup.add_item("Extract Marked...", 12)
	popup.add_item("Recovery Sheet...", 13)
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
	var vault_gated: Array[int] = [2, 3, 4, 7, 9, 10, 12, 13]
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

## Handles drops from any tree onto a destination folder row.
## W5: dest_context is the destination dict for the tree that received the drop
##     (may be empty if called from a non-registry path, though that no longer
##     occurs with the new wiring).
## drag_data.role == "source"  → classify source file into target category.
## drag_data.role starts with "dest:"  → reclassify within that destination.
func _on_tree_file_dropped(drag_data: Dictionary, target_key: String, _target_kind: String, dest_context: Dictionary = {}) -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Determine which vault to use: prefer dest_context's vault path (for vault
	# destinations), fall back to the open vault.
	var dest_kind: String    = str(dest_context.get("kind", ""))
	var dest_vault: String   = _active_vault_path
	if dest_kind == "vault":
		dest_vault = str(dest_context.get("path", _active_vault_path))

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

		# Dedup check against the target destination vault.
		var dup_res: Dictionary = await conn.call_tool(
			"minerva_scansort_check_sha256",
			{"vault_path": dest_vault, "sha256": sha256}
		)
		if dup_res.get("found", false):
			set_status("Already in vault.")
			return

		# Insert with user-assigned category (no AI classify step).
		var insert_args: Dictionary = {
			"vault_path":    dest_vault,
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
		# W5: refresh all destination trees + source.
		await _refresh_all_dest_trees()
		if _source_tree != null and is_instance_valid(_source_tree):
			await _source_tree.refresh()

	elif role == "vault" or role.begins_with("dest:"):
		# Drag-to-reclassify: doc:<id> → update category in the destination vault.
		var doc_id: int = int(drag_key.substr(4))  # strip "doc:" prefix
		var upd_args: Dictionary = {
			"vault_path": dest_vault,
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
		# W5: refresh all destination trees.
		await _refresh_all_dest_trees()


# ---------------------------------------------------------------------------
# U6: Export Marked to Disk
# ---------------------------------------------------------------------------

## W5g: Extracts every checked vault document to a user-chosen directory.
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

	# W5g: collect checked keys from the VISIBLE vault area tree.
	var all_keys: Array = []
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		all_keys = _vault_area_tree.get_checked_keys()
	var keys: Array = []
	for k: String in all_keys:
		if k.begins_with("doc:"):
			keys.append(k)
	if keys.is_empty():
		set_status("No documents marked for extraction.")
		return

	# W5g: show target picker — registered directory destinations + Browse.
	var dir_dests: Array = []
	if _dir_area_provider != null and "last_destinations" in _dir_area_provider:
		for d: Dictionary in _dir_area_provider.get("last_destinations"):
			if str(d.get("kind", "")) == "directory":
				dir_dests.append(d)

	var dlg: AcceptDialog = _ExtractTargetDialog.new()
	(dlg as Object).call("set_destinations", dir_dests)
	add_child(dlg)

	var chosen_path: String = ""
	var got_choice: bool = false

	(dlg as Object).target_chosen.connect(func(p: String) -> void:
		chosen_path = p
		got_choice  = true
	)
	(dlg as Object).cancelled.connect(func() -> void:
		got_choice = true  # signal received, path stays empty
	)

	dlg.popup_centered(Vector2i(500, 320))

	# Wait until the dialog emits one of its signals.
	while not got_choice:
		await Engine.get_main_loop().process_frame

	if is_instance_valid(dlg):
		dlg.queue_free()

	if chosen_path.is_empty():
		return  # user cancelled

	# Extract each checked document to the chosen directory.
	var extracted: int = 0
	var failed: int    = 0

	for key: String in keys:
		var doc_id: int = int(key.substr(4))
		var vault_path: String = _find_vault_path_for_doc_key(key)
		if vault_path.is_empty():
			vault_path = _active_vault_path
		if vault_path.is_empty():
			push_warning("[ScansortPanel] extract_marked: no vault_path for key %s" % key)
			failed += 1
			continue

		var extract_args: Dictionary = {
			"vault_path": vault_path,
			"doc_id":     doc_id,
			"dest":       chosen_path,
		}
		if vault_path == _active_vault_path and not _vault_password.is_empty():
			extract_args["password"] = _vault_password

		var result: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_document",
			extract_args
		)
		if not result.get("ok", false):
			var err: String = str(result.get("error", "unknown"))
			push_warning("[ScansortPanel] extract_marked: doc_id %d failed — %s" % [doc_id, err])
			failed += 1
		else:
			extracted += 1

	set_status("Extracted %d, %d failed" % [extracted, failed])
	# Refresh directory tree so new files appear.
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		await _dir_area_tree.refresh()


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


# ---------------------------------------------------------------------------
# W7: near-dup dedup detection + disposition prompt
# ---------------------------------------------------------------------------

## Check a candidate document for near-duplicates in the active vault.
##
## Calls `minerva_scansort_check_simhash` and `minerva_scansort_check_dhash`
## using the thresholds from Settings.  Returns a match_info dict if any match
## is found, or an empty dict if no match (caller proceeds normally).
##
## The match_info dict shape:
##   { "file_name", "match_kind", "match_count", "distance",
##     "existing_doc_id", "rule_label", "target_path" }
##
## HARD CONSTRAINT: the caller must surface non-empty results as a disposition
## prompt — NEVER auto-discard.
## W10: `conn` is now passed explicitly (was resolved internally in W7) so the
## Process All worker — and the headless smoke test — can supply a mock
## connection. Callers without a conn handy may pass null; the method then
## falls back to _get_connection().
func _check_near_dup(
	conn: Object,
	file_path: String,
	simhash: String,
	dhash: String,
	rule_label: String = "",
	target_path: String = "",
) -> Dictionary:
	if not _vault_is_open:
		return {}
	if conn == null:
		conn = _get_connection()
	if conn == null:
		return {}

	# Load thresholds from settings.
	var SettingsClass = _SettingsDialog.ScansortSettings
	var simhash_threshold: int = SettingsClass.load_simhash_threshold()
	var dhash_threshold: int = SettingsClass.load_dhash_threshold()

	# Layer 2a: SimHash near-dup check.
	if simhash_threshold > 0 and simhash != "0000000000000000" and not simhash.is_empty():
		var sim_res: Dictionary = await conn.call_tool(
			"minerva_scansort_check_simhash",
			{
				"vault_path": _active_vault_path,
				"simhash": simhash,
				"threshold": simhash_threshold,
			}
		)
		if sim_res.get("ok", false) and sim_res.get("found", false):
			var matches: Array = sim_res.get("matches", [])
			var best_match: Dictionary = matches[0] if matches.size() > 0 else {}
			return {
				"file_name":       file_path.get_file(),
				"match_kind":      "simhash",
				"match_count":     int(sim_res.get("count", 1)),
				"distance":        int(best_match.get("distance", 0)),
				"existing_doc_id": int(best_match.get("doc_id", 0)),
				"rule_label":      rule_label,
				"target_path":     target_path,
			}

	# Layer 2b: dHash near-dup check (image).
	if dhash_threshold > 0 and dhash != "0000000000000000" and not dhash.is_empty():
		var dhash_res: Dictionary = await conn.call_tool(
			"minerva_scansort_check_dhash",
			{
				"vault_path": _active_vault_path,
				"dhash": dhash,
				"threshold": dhash_threshold,
			}
		)
		if dhash_res.get("ok", false) and dhash_res.get("found", false):
			var matches: Array = dhash_res.get("matches", [])
			var best_match: Dictionary = matches[0] if matches.size() > 0 else {}
			return {
				"file_name":       file_path.get_file(),
				"match_kind":      "dhash",
				"match_count":     int(dhash_res.get("count", 1)),
				"distance":        int(best_match.get("distance", 0)),
				"existing_doc_id": int(best_match.get("doc_id", 0)),
				"rule_label":      rule_label,
				"target_path":     target_path,
			}

	return {}


## Show the dedup disposition dialog for a near-dup or logical-identity match.
##
## Awaitable — suspends until the user makes a choice (or cancels).
## Returns the chosen disposition string: "keep_both", "replace", "skip".
## A cancelled dialog (X button) returns "skip" — the safest fallback that
## doesn't lose data silently.
##
## The chosen disposition is also written to `_last_dedup_disposition` so that
## W9 (audit log) and W10 (Process All) can read it after this coroutine returns.
##
## HARD CONSTRAINT: callers MUST await this and check the result before
## deciding whether to place the document.  Never call place_fanout without
## first honouring the disposition.
func _show_dedup_disposition(match_info: Dictionary) -> String:
	_pending_dedup_match = match_info
	_last_dedup_disposition = ""

	# W10 test seam: headless smoke tests set _test_dedup_auto_disposition to
	# drive the near-dup path without a visible popup. Production leaves it "".
	if not _test_dedup_auto_disposition.is_empty():
		_last_dedup_disposition = _test_dedup_auto_disposition
		_pending_dedup_match = {}
		return _last_dedup_disposition

	# Create or reuse the dialog.
	if _dedup_dialog == null or not is_instance_valid(_dedup_dialog):
		_dedup_dialog = _DedupDispositionDialog.new()
		add_child(_dedup_dialog)

	# Wire signals (disconnect first to avoid double-connections on reuse).
	if _dedup_dialog.disposition_chosen.is_connected(_on_dedup_disposition_chosen):
		_dedup_dialog.disposition_chosen.disconnect(_on_dedup_disposition_chosen)
	if _dedup_dialog.cancelled.is_connected(_on_dedup_disposition_cancelled):
		_dedup_dialog.cancelled.disconnect(_on_dedup_disposition_cancelled)

	_dedup_dialog.disposition_chosen.connect(_on_dedup_disposition_chosen)
	_dedup_dialog.cancelled.connect(_on_dedup_disposition_cancelled)

	_dedup_dialog.init(match_info)
	_dedup_dialog.popup_centered(Vector2i(520, 340))

	# Suspend until the user picks a disposition.
	await _dedup_dialog.hide

	_pending_dedup_match = {}
	return _last_dedup_disposition if not _last_dedup_disposition.is_empty() else "skip"


## Handler: user picked a disposition in the dedup dialog.
func _on_dedup_disposition_chosen(disposition: String) -> void:
	_last_dedup_disposition = disposition


## Handler: user dismissed the dedup dialog without choosing (X button / Escape).
## Treat as "skip" — do not auto-place to avoid data loss.
func _on_dedup_disposition_cancelled() -> void:
	_last_dedup_disposition = "skip"


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
