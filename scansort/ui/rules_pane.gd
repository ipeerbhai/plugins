extends VBoxContainer
## W6 (DCR 019e33bf): Rules pane skeleton.
##
## Inline section under ScansortPanel showing the global rules library.
## Per-row UI:
##   * Enable toggle (CheckBox) → library_enable_rule / library_disable_rule
##   * Label
##   * Subfolder/rename preview (raw template strings — not LLM-resolved)
##   * Fired-count from trace log (DCR 019e33a2; shows "—" until that lands)
##   * 1-line instruction excerpt
##
## Read-only otherwise. The row menu (Test on…, View JSON, Edit JSON,
## Duplicate, Delete, Move up/down) is W7's deliverable.
##
## The pane does NOT touch the MCP bridge directly — `init(connection)` is
## called by the panel before the pane is shown. All library_* calls go
## through that connection.
##
## No `class_name` — off-tree plugin script; use preload().

const _UiScale := preload("ui_scale.gd")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _connection: Variant = null
var _rules: Array = []
var _row_container: VBoxContainer = null
var _header_count: Label = null
var _empty_label: Label = null

# Fired-counts keyed by rule label. Populated by `_load_fired_counts()` from
# the trace log when DCR 019e33a2 lands; until then this map stays empty
# and the pane renders "—" for every row.
var _fired_counts: Dictionary = {}

# Emitted when the user requests a refresh (so the panel can co-refresh
# whatever surfaces depend on the same library state).
signal rules_refreshed(rules: Array)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_UiScale.apply_to(self)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	_build_chrome()


## Called by the panel after the bridge connection is available. Triggers
## an initial refresh.
func init(connection: Variant) -> void:
	_connection = connection
	refresh()


# ---------------------------------------------------------------------------
# Chrome
# ---------------------------------------------------------------------------

func _build_chrome() -> void:
	# Header row: title + count + refresh button.
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = "Rules"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	_header_count = Label.new()
	_header_count.text = ""
	_header_count.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_header_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_header_count)

	var refresh_btn := Button.new()
	refresh_btn.text = "↻"
	refresh_btn.tooltip_text = "Refresh from library"
	refresh_btn.pressed.connect(refresh)
	header.add_child(refresh_btn)

	add_child(header)

	# Authoring hint — focused-chat skill discovery (W9 ships the skill itself).
	var hint := Label.new()
	hint.text = "To author rules, open Focused Chat and add 'Scansort rule authoring' to your skill list."
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint)

	# Empty-state placeholder.
	_empty_label = Label.new()
	_empty_label.text = "No rules in the library yet."
	_empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_empty_label.visible = false
	add_child(_empty_label)

	# Scrollable row container.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 120

	_row_container = VBoxContainer.new()
	_row_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row_container.add_theme_constant_override("separation", 2)
	scroll.add_child(_row_container)

	add_child(scroll)


# ---------------------------------------------------------------------------
# Refresh / load
# ---------------------------------------------------------------------------

## Re-fetch the library and rebuild row widgets.
func refresh() -> void:
	if _connection == null:
		return
	# Async fetch via the bridge.
	_async_refresh()


func _async_refresh() -> void:
	var rules_result: Dictionary = await _connection.call_tool(
		"minerva_scansort_library_list_rules", {})
	if not rules_result.get("ok", false):
		_rules = []
		_render_rows()
		return
	_rules = rules_result.get("rules", [])
	_load_fired_counts()
	_render_rows()
	rules_refreshed.emit(_rules)


## DCR 019e33a2 (trace log) will populate `_fired_counts[label] = int` from
## the trace log file. Until that's wired the map stays empty and the pane
## shows "—" for every row — the documented graceful fallback.
func _load_fired_counts() -> void:
	_fired_counts = {}


# ---------------------------------------------------------------------------
# Row rendering
# ---------------------------------------------------------------------------

func _render_rows() -> void:
	for child in _row_container.get_children():
		_row_container.remove_child(child)
		child.queue_free()

	_header_count.text = "(%d rule%s)" % [_rules.size(), "" if _rules.size() == 1 else "s"]
	_empty_label.visible = _rules.is_empty()

	for rule in _rules:
		_row_container.add_child(_build_row(rule))


func _build_row(rule: Dictionary) -> Control:
	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)
	row.add_child(vbox)

	# Top line: [✓] label   →  subfolder/rename   · N fired
	var top := HBoxContainer.new()
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 6)

	var enable_cb := CheckBox.new()
	enable_cb.button_pressed = bool(rule.get("enabled", true))
	enable_cb.toggled.connect(_on_enable_toggled.bind(str(rule.get("label", ""))))
	top.add_child(enable_cb)

	var label_lbl := Label.new()
	label_lbl.text = str(rule.get("label", ""))
	label_lbl.add_theme_font_size_override("font_size", 13)
	top.add_child(label_lbl)

	var preview := Label.new()
	preview.text = "→ %s" % _build_target_preview(rule)
	preview.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(preview)

	var fired := Label.new()
	var label_key: String = str(rule.get("label", ""))
	if _fired_counts.has(label_key):
		fired.text = "· %d fired" % int(_fired_counts[label_key])
	else:
		fired.text = "· — fired"
	fired.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	top.add_child(fired)

	vbox.add_child(top)

	# Instruction excerpt — single line, truncated.
	var instruction := str(rule.get("instruction", ""))
	if not instruction.is_empty():
		var excerpt := Label.new()
		excerpt.text = '"%s"' % _truncate_one_line(instruction, 120)
		excerpt.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		excerpt.autowrap_mode = TextServer.AUTOWRAP_OFF
		vbox.add_child(excerpt)

	return row


func _build_target_preview(rule: Dictionary) -> String:
	var subfolder := str(rule.get("subfolder", "")).strip_edges()
	var rename := str(rule.get("rename_pattern", "")).strip_edges()
	if subfolder.is_empty() and rename.is_empty():
		return "(no destination set)"
	if rename.is_empty():
		return "%s/" % subfolder
	if subfolder.is_empty():
		return rename
	return "%s/%s" % [subfolder, rename]


func _truncate_one_line(s: String, max_chars: int) -> String:
	# Replace newlines with spaces, then cap length.
	var flat := s.replace("\n", " ").replace("\r", " ").strip_edges()
	if flat.length() <= max_chars:
		return flat
	return flat.substr(0, max_chars - 1) + "…"


# ---------------------------------------------------------------------------
# Enable toggle handler
# ---------------------------------------------------------------------------

func _on_enable_toggled(pressed: bool, label: String) -> void:
	if _connection == null or label.is_empty():
		return
	_async_set_enabled(label, pressed)


func _async_set_enabled(label: String, enabled: bool) -> void:
	var tool_name := "minerva_scansort_library_enable_rule" if enabled \
		else "minerva_scansort_library_disable_rule"
	var _result: Dictionary = await _connection.call_tool(tool_name, {"label": label})
	# Refresh so the canonical state reflects what the library says, not
	# what the user clicked (in case the call failed).
	refresh()
