extends AcceptDialog
## Modal dialog for setting or entering a vault encryption password.
## Ported from ccsandbox experiments/scansort/scripts/ui/password_dialog.gd.
##
## Two modes:
##   SET   — new password + confirm + hint (first-time vault password setup)
##   ENTER — show hint + single password field (unlock existing vault)
##
## The caller is responsible for performing the actual MCP tool call
## (minerva_scansort_set_password / minerva_scansort_verify_password).
## This dialog just collects and validates the input, then emits signals.
##
## Signals:
##   password_submitted(password, hint, mode)  — user clicked OK with valid input
##   cancelled                                 — user dismissed / cancelled
##
## No class_name — off-tree plugin script; callers use preload().

signal password_submitted(password: String, hint: String, mode: int)
signal cancelled

enum PasswordMode { SET, ENTER }

var _mode: PasswordMode = PasswordMode.SET
var _password_field: LineEdit = null
var _confirm_field: LineEdit = null
var _hint_field: LineEdit = null
var _hint_label: Label = null
var _error_label: Label = null
var _vbox: VBoxContainer = null


func _ready() -> void:
	min_size = Vector2(420, 200)
	confirmed.connect(_on_ok)
	canceled.connect(_on_cancelled)


## Show the dialog in SET mode (create a new vault password).
func show_set_password() -> void:
	_mode = PasswordMode.SET
	title = "Set Vault Password"
	_build_form()
	popup_centered()


## Show the dialog in ENTER mode (unlock an existing password-protected vault).
## hint: password hint string stored in vault (may be empty).
func show_enter_password(hint: String) -> void:
	_mode = PasswordMode.ENTER
	title = "Enter Vault Password"
	_build_form()
	if _hint_label != null:
		if not hint.is_empty():
			_hint_label.text = "Hint: %s" % hint
		else:
			_hint_label.text = "No password hint was saved."
		_hint_label.visible = true
	popup_centered()


func _build_form() -> void:
	# Remove old content node if present.
	if _vbox != null:
		_vbox.queue_free()
		_vbox = null
	_password_field = null
	_confirm_field = null
	_hint_field = null
	_hint_label = null
	_error_label = null

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)

	if _mode == PasswordMode.SET:
		_build_set_form()
	else:
		_build_enter_form()

	# Shared error label.
	_error_label = Label.new()
	_error_label.text = ""
	_error_label.add_theme_color_override("font_color", Color.RED)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = false
	_vbox.add_child(_error_label)

	add_child(_vbox)


func _build_set_form() -> void:
	# Password row.
	var pw_row := HBoxContainer.new()
	var pw_lbl := Label.new()
	pw_lbl.text = "Password"
	pw_lbl.custom_minimum_size.x = 130
	pw_row.add_child(pw_lbl)
	_password_field = LineEdit.new()
	_password_field.secret = true
	_password_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_password_field.placeholder_text = "Enter password"
	pw_row.add_child(_password_field)
	_vbox.add_child(pw_row)

	# Confirm row.
	var cf_row := HBoxContainer.new()
	var cf_lbl := Label.new()
	cf_lbl.text = "Confirm Password"
	cf_lbl.custom_minimum_size.x = 130
	cf_row.add_child(cf_lbl)
	_confirm_field = LineEdit.new()
	_confirm_field.secret = true
	_confirm_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_field.placeholder_text = "Re-enter password"
	cf_row.add_child(_confirm_field)
	_vbox.add_child(cf_row)

	# Hint row.
	var hint_row := HBoxContainer.new()
	var hint_lbl := Label.new()
	hint_lbl.text = "Password Hint"
	hint_lbl.custom_minimum_size.x = 130
	hint_row.add_child(hint_lbl)
	_hint_field = LineEdit.new()
	_hint_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint_field.placeholder_text = "Optional reminder (stored in plaintext)"
	hint_row.add_child(_hint_field)
	_vbox.add_child(hint_row)

	var notice := Label.new()
	notice.text = "Hint is stored unencrypted."
	notice.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_vbox.add_child(notice)


func _build_enter_form() -> void:
	# Hint display (populated later by show_enter_password).
	_hint_label = Label.new()
	_hint_label.text = ""
	_hint_label.visible = false
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_hint_label)

	var spacer := Control.new()
	spacer.custom_minimum_size.y = 6
	_vbox.add_child(spacer)

	# Password row.
	var pw_row := HBoxContainer.new()
	var pw_lbl := Label.new()
	pw_lbl.text = "Password"
	pw_lbl.custom_minimum_size.x = 130
	pw_row.add_child(pw_lbl)
	_password_field = LineEdit.new()
	_password_field.secret = true
	_password_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_password_field.placeholder_text = "Enter vault password"
	pw_row.add_child(_password_field)
	_vbox.add_child(pw_row)


func _on_ok() -> void:
	_clear_error()

	if _mode == PasswordMode.SET:
		var pw: String = _password_field.text if _password_field != null else ""
		var confirm: String = _confirm_field.text if _confirm_field != null else ""
		var hint: String = _hint_field.text.strip_edges() if _hint_field != null else ""

		if pw.is_empty():
			_show_error("Password cannot be empty.")
			popup_centered()
			return

		if pw != confirm:
			_show_error("Passwords do not match.")
			popup_centered()
			return

		password_submitted.emit(pw, hint, _mode)

	else:  # ENTER
		var pw: String = _password_field.text if _password_field != null else ""

		if pw.is_empty():
			_show_error("Password cannot be empty.")
			popup_centered()
			return

		password_submitted.emit(pw, "", _mode)


func _on_cancelled() -> void:
	cancelled.emit()


## Called by the panel when the MCP verify call returns wrong password.
func show_wrong_password_error() -> void:
	_show_error("Incorrect password. Try again.")
	popup_centered()


## Called by the panel when a generic MCP error occurs.
func show_error(msg: String) -> void:
	_show_error(msg)
	popup_centered()


func _show_error(msg: String) -> void:
	if _error_label != null:
		_error_label.text = msg
		_error_label.visible = true


func _clear_error() -> void:
	if _error_label != null:
		_error_label.text = ""
		_error_label.visible = false
