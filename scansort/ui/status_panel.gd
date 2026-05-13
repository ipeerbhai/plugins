extends HBoxContainer
## Scansort status bar — T7 R2.
##
## Bottom strip showing: current vault name, document count, idle/status message.
##
## No class_name — off-tree script; loaded via preload() from ScansortPanel.gd.
##
## Dropped from experiment's status_panel.gd (out of R2 scope):
##   - process_requested / stop_requested signals (pipeline trigger) — R3
##   - Arrow ">>>" process button — R3
##   - Concurrency SpinBox — R5
##   - ProgressBar (scan progress) — R3
##   - current-file / stage labels (live pipeline status) — R3
##   - Error count label — R3
##   - ScanConfig dependency — R5

# ---------------------------------------------------------------------------
# UI widgets
# ---------------------------------------------------------------------------

var _vault_label: Label  = null
var _count_label: Label  = null
var _status_label: Label = null

# ---------------------------------------------------------------------------
# Initialisation
# ---------------------------------------------------------------------------

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size.y = 24
	_build_ui()


func _build_ui() -> void:
	# Vault name.
	_vault_label = Label.new()
	_vault_label.text = "No vault"
	_vault_label.custom_minimum_size.x = 140
	_vault_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	add_child(_vault_label)

	var sep1 := VSeparator.new()
	add_child(sep1)

	# Document count.
	_count_label = Label.new()
	_count_label.text = ""
	_count_label.custom_minimum_size.x = 80
	add_child(_count_label)

	var sep2 := VSeparator.new()
	add_child(sep2)

	# Spacer.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	# Status message (right-aligned).
	_status_label = Label.new()
	_status_label.text = "Idle"
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_status_label)


## Attach connection (not used by status bar directly, kept for API symmetry).
func init(_conn: Object) -> void:
	pass


## Update the displayed vault name and document count.
func set_vault(vault_name: String, doc_count: int) -> void:
	if _vault_label != null:
		_vault_label.text = vault_name
	if _count_label != null:
		_count_label.text = "%d docs" % doc_count


## Show a status message (e.g. "Idle", "Loading…", "Refreshing…").
func set_status(msg: String) -> void:
	if _status_label != null:
		_status_label.text = msg


## Reset to no-vault display (called on vault close).
func clear() -> void:
	if _vault_label != null:
		_vault_label.text = "No vault"
	if _count_label != null:
		_count_label.text = ""
	if _status_label != null:
		_status_label.text = "Idle"
