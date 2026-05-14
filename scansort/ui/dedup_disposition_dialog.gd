extends AcceptDialog
## W7: Deduplication disposition prompt dialog.
##
## Shown when a near-duplicate (simhash or dhash) or logical-identity match is
## found for a document during filing.  Presents three choices:
##
##   Keep Both   — place the incoming document alongside the existing one
##   Replace     — replace the existing document at the destination
##   Skip        — do not file this document at all
##
## HARD CONSTRAINT: only the exact SHA-256 layer auto-skips.  This dialog
## exists precisely because near-dup and logical-identity matches MUST surface
## for explicit user review (a CORRECTED 1099 is near-identical to the
## original — silently dropping it is a data-loss bug).
##
## Usage:
##   var dlg = preload("dedup_disposition_dialog.gd").new()
##   dlg.init(match_info)   # see init() for match_info dict shape
##   add_child(dlg)
##   dlg.disposition_chosen.connect(_on_dedup_disposition)
##   dlg.popup_centered(Vector2(520, 340))
##
## match_info dict keys:
##   "file_name"       String   — display name of the incoming file
##   "match_kind"      String   — "simhash", "dhash", or "logical_identity"
##   "match_count"     int      — number of near-dup matches found
##   "distance"        int      — Hamming distance of closest match (0 for logical)
##   "existing_doc_id" int      — doc_id of the closest existing match (0 if n/a)
##   "rule_label"      String   — rule that fired (for logical identity display)
##   "target_path"     String   — resolved target path (for logical identity display)
##
## No class_name — off-tree plugin script; callers must use preload().

## Emitted when the user clicks one of the three disposition buttons.
## disposition: String — one of "keep_both", "replace", "skip"
signal disposition_chosen(disposition: String)

## Emitted when the dialog closes without a disposition choice (e.g. X button).
## Treated as "skip" by the caller to avoid silent data loss.
signal cancelled

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _match_info: Dictionary = {}

## The chosen disposition string — set by the button handlers before emitting.
var _chosen: String = ""

# ---------------------------------------------------------------------------
# Widget references
# ---------------------------------------------------------------------------

var _summary_label: Label = null
var _detail_label:  RichTextLabel = null
var _keep_both_btn: Button = null
var _replace_btn:   Button = null
var _skip_btn:      Button = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	title = "Near-Duplicate Found — Review Required"
	min_size = Vector2(520, 340)
	# Hide the default OK button — we use custom buttons below.
	get_ok_button().hide()
	canceled.connect(_on_dialog_cancelled)
	_build_ui()


## Populate the dialog with match context before popup.
## match_info: dict (see module docstring for keys).
func init(match_info: Dictionary) -> void:
	_match_info = match_info
	_update_labels()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)

	# Summary line.
	_summary_label = Label.new()
	_summary_label.text = "A near-duplicate was detected."
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_summary_label)

	# Detail block.
	_detail_label = RichTextLabel.new()
	_detail_label.bbcode_enabled = true
	_detail_label.fit_content = true
	_detail_label.custom_minimum_size.y = 80
	_detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_detail_label)

	# Explanation banner.
	var banner := Label.new()
	banner.text = (
		"Important: a CORRECTED or AMENDED document may be nearly identical\n"
		+ "to the original. Choose how to handle this document:"
	)
	banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	root.add_child(banner)

	root.add_child(HSeparator.new())

	# Action buttons row.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_keep_both_btn = Button.new()
	_keep_both_btn.text = "Keep Both"
	_keep_both_btn.tooltip_text = "File the incoming document alongside the existing one."
	_keep_both_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_keep_both_btn.pressed.connect(_on_keep_both_pressed)
	btn_row.add_child(_keep_both_btn)

	_replace_btn = Button.new()
	_replace_btn.text = "Replace Existing"
	_replace_btn.tooltip_text = (
		"Replace the existing document at the destination with this one.\n"
		+ "(W10 will remove the existing document before placing the new one.)"
	)
	_replace_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replace_btn.pressed.connect(_on_replace_pressed)
	btn_row.add_child(_replace_btn)

	_skip_btn = Button.new()
	_skip_btn.text = "Skip"
	_skip_btn.tooltip_text = "Do not file this document. It will remain in the source folder."
	_skip_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skip_btn.pressed.connect(_on_skip_pressed)
	btn_row.add_child(_skip_btn)

	root.add_child(btn_row)

	add_child(root)


func _update_labels() -> void:
	if _summary_label == null:
		return

	var file_name: String = str(_match_info.get("file_name", "(unknown)"))
	var match_kind: String = str(_match_info.get("match_kind", "near_dup"))
	var match_count: int = int(_match_info.get("match_count", 1))
	var distance: int = int(_match_info.get("distance", 0))
	var existing_doc_id: int = int(_match_info.get("existing_doc_id", 0))
	var rule_label: String = str(_match_info.get("rule_label", ""))
	var target_path: String = str(_match_info.get("target_path", ""))

	var kind_display: String
	match match_kind:
		"simhash":
			kind_display = "text near-duplicate (SimHash, %d-bit distance)" % distance
		"dhash":
			kind_display = "image near-duplicate (dHash, %d-bit distance)" % distance
		"logical_identity":
			kind_display = "logical identity (same rule + target path)"
		_:
			kind_display = match_kind

	_summary_label.text = (
		"'%s' appears to be a %s of %d existing document%s in this vault."
		% [file_name, kind_display, match_count, "s" if match_count != 1 else ""]
	)

	var detail_parts: PackedStringArray = PackedStringArray()
	if existing_doc_id > 0:
		detail_parts.append("[b]Existing document id:[/b] %d" % existing_doc_id)
	if not rule_label.is_empty():
		detail_parts.append("[b]Rule:[/b] %s" % rule_label)
	if not target_path.is_empty():
		detail_parts.append("[b]Target path:[/b] %s" % target_path)

	if _detail_label != null:
		_detail_label.text = "\n".join(detail_parts)


# ---------------------------------------------------------------------------
# Button handlers
# ---------------------------------------------------------------------------

func _on_keep_both_pressed() -> void:
	_chosen = "keep_both"
	disposition_chosen.emit(_chosen)
	hide()


func _on_replace_pressed() -> void:
	_chosen = "replace"
	disposition_chosen.emit(_chosen)
	hide()


func _on_skip_pressed() -> void:
	_chosen = "skip"
	disposition_chosen.emit(_chosen)
	hide()


func _on_dialog_cancelled() -> void:
	# X-button or Escape — treat as skip to avoid losing track of this file.
	if _chosen.is_empty():
		cancelled.emit()
