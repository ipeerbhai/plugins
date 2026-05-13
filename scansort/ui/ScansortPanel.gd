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

# ---------------------------------------------------------------------------
# Menu handling
# ---------------------------------------------------------------------------

func _on_file_menu_id_pressed(id: int) -> void:
	match id:
		0: _on_new_vault_pressed()
		1: _on_open_vault_pressed()
		2: _on_close_vault_pressed()


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
	set_status("Vault closed.")
	vault_closed.emit()

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
	var vault_name: String = open_result.get("name", path.get_file())
	set_status("Vault open: %s — awaiting R2 view." % vault_name)
	vault_opened.emit(path, open_result)

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
