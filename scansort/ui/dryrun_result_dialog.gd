extends AcceptDialog
## Dry-run result dialog — W7 (DCR 019e33bf).
##
## Shows the structured response from `minerva_scansort_dryrun_one`:
##   * Per-rule header line: rule label, fired/not-fired, score vs threshold
##   * If fired: per-stage trace (ask, slot values, keep_when, kept) plus
##     resolved subfolder and filename and would_copy_to
##   * If filtered: per-stage trace, with the kept:false stage highlighted
##   * If below threshold: short "score < threshold" note
##
## Pure renderer. The caller supplies the dryrun_one response Dictionary
## via `set_result(...)`.
##
## No `class_name` — off-tree plugin script; use preload().

const _UiScale := preload("ui_scale.gd")

var _content_vbox: VBoxContainer = null


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Dry-run result"
	min_size = Vector2(640, 480)
	ok_button_text = "Close"
	_build_chrome()


func set_result(result: Dictionary) -> void:
	if _content_vbox == null:
		_build_chrome()
	for child in _content_vbox.get_children():
		_content_vbox.remove_child(child)
		child.queue_free()
	_render(result)


# ---------------------------------------------------------------------------

func _build_chrome() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(620, 420)

	_content_vbox = VBoxContainer.new()
	_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(_content_vbox)

	add_child(scroll)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _render(result: Dictionary) -> void:
	if not result.get("ok", false):
		var err := Label.new()
		err.text = "Dry-run failed: %s" % str(result.get("error", "unknown"))
		err.add_theme_color_override("font_color", Color.RED)
		err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_content_vbox.add_child(err)
		return

	# Header — document path.
	var doc_path: String = str(result.get("doc_path", ""))
	var header := Label.new()
	header.text = "Tested: %s" % doc_path.get_file()
	header.add_theme_font_size_override("font_size", 14)
	_content_vbox.add_child(header)

	var sha := Label.new()
	sha.text = "sha256: %s" % str(result.get("doc_sha256", "")).substr(0, 16) + "…"
	sha.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_content_vbox.add_child(sha)

	var rules_evaluated: Array = result.get("rules_evaluated", [])
	if rules_evaluated.is_empty():
		var none := Label.new()
		none.text = "(no rules evaluated — library is empty or no enabled rules matched the filter)"
		none.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_content_vbox.add_child(none)
		return

	for rule_data in rules_evaluated:
		_content_vbox.add_child(_render_rule(rule_data))


func _render_rule(data: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# Header line.
	var label_name: String = str(data.get("rule_label", ""))
	var fired: bool = bool(data.get("fired", false))
	var score: float = float(data.get("score", 0.0))
	var threshold: float = float(data.get("threshold", 0.0))
	var reason: String = str(data.get("reason", ""))

	var header := Label.new()
	if fired:
		header.text = "Rule: %s — FIRED  (Phase 1 score: %.2f, threshold: %.2f)" \
			% [label_name, score, threshold]
		header.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
	elif reason == "below_threshold":
		header.text = "Rule: %s — DID NOT FIRE  (score %.2f < threshold %.2f)" \
			% [label_name, score, threshold]
		header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	elif reason == "filtered":
		header.text = "Rule: %s — FILTERED OUT  (passed threshold but a keep_when failed)" \
			% [label_name]
		header.add_theme_color_override("font_color", Color(0.9, 0.7, 0.4))
	else:
		header.text = "Rule: %s — did not fire" % label_name
	header.add_theme_font_size_override("font_size", 13)
	vbox.add_child(header)

	# Stage trace.
	var stages: Array = data.get("stages", [])
	for i in range(stages.size()):
		var stage: Dictionary = stages[i]
		var stage_line := Label.new()
		var ask: String = str(stage.get("ask", "")).substr(0, 80)
		var kept: bool = bool(stage.get("kept", true))
		var slot_values: Dictionary = stage.get("slot_values", {})
		var keep_when_text: Variant = stage.get("keep_when", null)

		var slot_pairs: Array = []
		for key in slot_values.keys():
			slot_pairs.append("%s = %s" % [key, str(slot_values[key])])
		var slot_summary: String = ", ".join(PackedStringArray(slot_pairs)) \
			if not slot_pairs.is_empty() else "(no slots)"

		var bullet := "    " if kept else "  ✗ "
		var kept_word := "kept" if kept else "FILTERED OUT here"
		var kw_str: String = ""
		if keep_when_text != null and not str(keep_when_text).is_empty():
			kw_str = "  [keep_when: %s]" % str(keep_when_text)
		stage_line.text = "%sStage %d: %s — %s%s\n         %s" \
			% [bullet, i + 1, kept_word, ask, kw_str, slot_summary]
		stage_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if not kept:
			stage_line.add_theme_color_override("font_color", Color(0.9, 0.6, 0.5))
		vbox.add_child(stage_line)

	# Resolved placement (only when fired).
	if fired:
		var subfolder: Variant = data.get("resolved_subfolder", null)
		var filename: Variant = data.get("resolved_filename", null)
		var copy_to: Array = data.get("would_copy_to", [])

		var place_lbl := Label.new()
		var sub_str: String = str(subfolder) if subfolder != null else "(none)"
		var fn_str: String = str(filename) if filename != null else "(none)"
		place_lbl.text = "    Would file as: %s/%s" % [sub_str, fn_str]
		place_lbl.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
		vbox.add_child(place_lbl)

		if not copy_to.is_empty():
			var copy_lbl := Label.new()
			copy_lbl.text = "    Would copy to: %s" % ", ".join(PackedStringArray(copy_to))
			copy_lbl.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
			vbox.add_child(copy_lbl)

	return panel
