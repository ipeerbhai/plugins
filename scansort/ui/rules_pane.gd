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
const _PasteJsonDialog: Script = preload("paste_json_dialog.gd")
const _DryrunResultDialog: Script = preload("dryrun_result_dialog.gd")

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

	# W7: row menu — [⋮]
	var menu_btn := MenuButton.new()
	menu_btn.text = "⋮"
	menu_btn.tooltip_text = "Row actions"
	var popup := menu_btn.get_popup()
	popup.add_item("Test on…", 0)
	popup.add_item("Move up", 1)
	popup.add_item("Move down", 2)
	popup.add_separator()
	popup.add_item("View JSON", 3)
	popup.add_item("Edit JSON", 4)
	popup.add_item("Duplicate", 5)
	popup.add_separator()
	popup.add_item("Delete…", 6)
	popup.id_pressed.connect(_on_row_menu_id_pressed.bind(label_key))
	top.add_child(menu_btn)

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


# ---------------------------------------------------------------------------
# W7: Row menu dispatch
# ---------------------------------------------------------------------------

func _on_row_menu_id_pressed(id: int, label: String) -> void:
	if _connection == null or label.is_empty():
		return
	var rule: Dictionary = _find_rule(label)
	if rule.is_empty():
		return
	match id:
		0: _row_action_test_on(rule)
		1: _row_action_move(label, -1)
		2: _row_action_move(label, +1)
		3: _row_action_view_json(rule)
		4: _row_action_edit_json(rule)
		5: _row_action_duplicate(rule)
		6: _row_action_delete(label)


func _find_rule(label: String) -> Dictionary:
	for r in _rules:
		if str(r.get("label", "")) == label:
			return r
	return {}


# ----- Test on… -----

func _row_action_test_on(rule: Dictionary) -> void:
	var picker := FileDialog.new()
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.title = "Pick a document to dry-run against rule '%s'" % str(rule.get("label", ""))
	picker.filters = PackedStringArray([
		"*.pdf,*.txt,*.md,*.docx,*.xlsx,*.html ; Documents",
		"* ; All files",
	])
	add_child(picker)
	picker.file_selected.connect(
		func(path: String) -> void:
			picker.queue_free()
			_async_run_dryrun(rule, path)
	)
	picker.canceled.connect(func() -> void: picker.queue_free())
	picker.popup_centered_ratio(0.7)


func _async_run_dryrun(rule: Dictionary, doc_path: String) -> void:
	var args: Dictionary = {
		"doc_path": doc_path,
		"rule_label": str(rule.get("label", "")),
	}
	var result: Dictionary = await _connection.call_tool(
		"minerva_scansort_dryrun_one", args)
	var dlg = _DryrunResultDialog.new()
	add_child(dlg)
	dlg.set_result(result)
	dlg.confirmed.connect(func() -> void: dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered()


# ----- Move up / down -----

func _row_action_move(label: String, delta: int) -> void:
	var idx: int = -1
	for i in range(_rules.size()):
		if str(_rules[i].get("label", "")) == label:
			idx = i
			break
	if idx < 0:
		return
	var new_idx: int = idx + delta
	if new_idx < 0 or new_idx >= _rules.size():
		return
	var labels: Array[String] = []
	for r in _rules:
		labels.append(str(r.get("label", "")))
	var moved: String = labels[idx]
	labels.remove_at(idx)
	labels.insert(new_idx, moved)
	_async_reorder(labels)


func _async_reorder(labels: Array[String]) -> void:
	var arr: Array = []
	for l in labels:
		arr.append(l)
	var _result: Dictionary = await _connection.call_tool(
		"minerva_scansort_library_reorder_rules", {"order": arr})
	refresh()


# ----- View / Edit JSON -----

func _row_action_view_json(rule: Dictionary) -> void:
	var dlg = _PasteJsonDialog.new()
	add_child(dlg)
	dlg.configure(_PasteJsonDialog.Mode.MODE_READONLY, JSON.stringify(rule, "\t"))
	dlg.cancelled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered()


func _row_action_edit_json(rule: Dictionary) -> void:
	var dlg = _PasteJsonDialog.new()
	add_child(dlg)
	# Save handler: parsed -> Dictionary, mode -> int. Returns {ok, error?}.
	var save_cb := func(parsed: Dictionary, _mode: int) -> Dictionary:
		return await _save_rule_via_library(parsed, true, str(rule.get("label", "")))
	dlg.configure(_PasteJsonDialog.Mode.MODE_EDIT, JSON.stringify(rule, "\t"), save_cb)
	dlg.saved.connect(func(_parsed: Dictionary) -> void:
		dlg.queue_free()
		refresh()
	)
	dlg.cancelled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered()


# ----- Duplicate -----

func _row_action_duplicate(rule: Dictionary) -> void:
	var copy: Dictionary = rule.duplicate(true)
	var orig_label: String = str(copy.get("label", "rule"))
	copy["label"] = "%s_copy" % orig_label
	_async_insert(copy)


func _async_insert(payload: Dictionary) -> void:
	var result: Dictionary = await _connection.call_tool(
		"minerva_scansort_library_insert_rule", payload)
	if not result.get("ok", false):
		push_warning("[RulesPane] duplicate failed: %s" % str(result.get("error", "?")))
	refresh()


# ----- Delete -----

func _row_action_delete(label: String) -> void:
	var confirm := ConfirmationDialog.new()
	confirm.title = "Delete rule?"
	confirm.dialog_text = "Delete rule '%s'? This cannot be undone." % label
	add_child(confirm)
	confirm.confirmed.connect(func() -> void:
		confirm.queue_free()
		_async_delete(label)
	)
	confirm.canceled.connect(func() -> void: confirm.queue_free())
	confirm.popup_centered()


func _async_delete(label: String) -> void:
	var _result: Dictionary = await _connection.call_tool(
		"minerva_scansort_library_delete_rule", {"label": label})
	refresh()


# ----- Shared save helper -----

## Updates an existing rule via library_update_rule when `is_edit=true` and
## the parsed JSON's `label` matches `original_label`. If the user changed
## the label in edit mode, we treat it as insert (new label) and the old
## one stays untouched — the dialog never auto-deletes.
##
## Returns the {ok:bool, error?:String} contract that paste_json_dialog
## expects from its save_callable.
func _save_rule_via_library(
		parsed: Dictionary,
		_is_edit: bool,
		_original_label: String) -> Dictionary:
	# library_update_rule only changes named fields; for a full-document
	# overwrite we use library_insert_rule (upsert) which handles both
	# new and existing labels identically. Simpler than diffing fields.
	var result: Dictionary = await _connection.call_tool(
		"minerva_scansort_library_insert_rule", parsed)
	if result.get("ok", false):
		return {"ok": true}
	return {"ok": false, "error": str(result.get("error", "library_insert_rule failed"))}
