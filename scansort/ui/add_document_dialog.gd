extends AcceptDialog
## Add Document dialog — T7 R3.
##
## Shows the proposed classification from the ingest pipeline and lets the user
## edit fields before committing the insert.
##
## Usage:
##   var dlg = preload("add_document_dialog.gd").new()
##   dlg.set_proposal(classification_dict)
##   add_child(dlg)
##   dlg.accepted.connect(_on_add_dialog_accepted)
##   dlg.cancelled.connect(_on_add_dialog_cancelled)
##   dlg.popup_centered()
##
## No class_name — off-tree plugin script; use preload().

## Emitted when the user clicks OK.  final_classification is the (possibly
## edited) dict; the caller is responsible for calling insert_document.
signal accepted(final_classification: Dictionary)

## Emitted when the user cancels.
signal cancelled

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _proposal: Dictionary = {}

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

var _vbox:              VBoxContainer = null
var _sha256_label:      Label         = null
var _source_label:      Label         = null
var _confidence_label:  Label         = null
var _category_field:    LineEdit      = null
var _sender_field:      LineEdit      = null
var _description_field: LineEdit      = null
var _date_field:        LineEdit      = null
var _tags_field:        LineEdit      = null
var _error_label:       Label         = null


func _ready() -> void:
	title = "Add Document to Vault"
	min_size = Vector2(520, 380)
	# AcceptDialog fires `confirmed` when OK is pressed.
	confirmed.connect(_on_accept_pressed)
	canceled.connect(_on_cancel_pressed)
	_build_form()


## Populate the form with a proposed classification dict.
## Keys used: category, confidence, sender, description, doc_date, tags,
##            sha256, source_file  (all optional — empty values tolerated).
func set_proposal(proposal: Dictionary) -> void:
	_proposal = proposal.duplicate(true)
	if _vbox != null:
		_populate_form()


# ---------------------------------------------------------------------------
# Form construction
# ---------------------------------------------------------------------------

func _build_form() -> void:
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)

	# --- Source file (read-only) ---
	_vbox.add_child(_make_row_label("File"))
	_source_label = Label.new()
	_source_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_source_label.text = ""
	_vbox.add_child(_source_label)

	# --- SHA-256 short (read-only) ---
	var sha_row := _make_hbox()
	sha_row.add_child(_make_fixed_label("SHA-256", 100))
	_sha256_label = Label.new()
	_sha256_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sha256_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	sha_row.add_child(_sha256_label)
	_vbox.add_child(sha_row)

	# --- Confidence (read-only) ---
	var conf_row := _make_hbox()
	conf_row.add_child(_make_fixed_label("Confidence", 100))
	_confidence_label = Label.new()
	_confidence_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conf_row.add_child(_confidence_label)
	_vbox.add_child(conf_row)

	# --- Category (editable) ---
	var cat_row := _make_hbox()
	cat_row.add_child(_make_fixed_label("Category", 100))
	_category_field = LineEdit.new()
	_category_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_category_field.placeholder_text = "e.g. invoices"
	cat_row.add_child(_category_field)
	_vbox.add_child(cat_row)

	# --- Sender (editable) ---
	var sender_row := _make_hbox()
	sender_row.add_child(_make_fixed_label("Sender", 100))
	_sender_field = LineEdit.new()
	_sender_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sender_field.placeholder_text = "Who sent this document"
	sender_row.add_child(_sender_field)
	_vbox.add_child(sender_row)

	# --- Description (editable) ---
	var desc_row := _make_hbox()
	desc_row.add_child(_make_fixed_label("Description", 100))
	_description_field = LineEdit.new()
	_description_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_description_field.placeholder_text = "Brief description"
	desc_row.add_child(_description_field)
	_vbox.add_child(desc_row)

	# --- Date (editable) ---
	var date_row := _make_hbox()
	date_row.add_child(_make_fixed_label("Date", 100))
	_date_field = LineEdit.new()
	_date_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_date_field.placeholder_text = "YYYY-MM-DD"
	date_row.add_child(_date_field)
	_vbox.add_child(date_row)

	# --- Tags (editable, comma-separated) ---
	var tags_row := _make_hbox()
	tags_row.add_child(_make_fixed_label("Tags", 100))
	_tags_field = LineEdit.new()
	_tags_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tags_field.placeholder_text = "tag1, tag2, …"
	tags_row.add_child(_tags_field)
	_vbox.add_child(tags_row)

	# --- Error label ---
	_error_label = Label.new()
	_error_label.text = ""
	_error_label.add_theme_color_override("font_color", Color.RED)
	_vbox.add_child(_error_label)

	add_child(_vbox)

	# Populate if we already have a proposal (set_proposal called before _ready).
	if not _proposal.is_empty():
		_populate_form()


func _populate_form() -> void:
	if _source_label == null:
		return  # form not built yet

	var source: String = str(_proposal.get("source_file", ""))
	_source_label.text = source.get_file() if not source.is_empty() else "(unknown)"

	var sha: String = str(_proposal.get("sha256", ""))
	_sha256_label.text = sha.left(16) + "…" if sha.length() > 16 else sha

	var conf: float = float(_proposal.get("confidence", 0.0))
	_confidence_label.text = "%.0f%%" % (conf * 100.0)

	_category_field.text    = str(_proposal.get("category", ""))
	_sender_field.text      = str(_proposal.get("sender", ""))
	_description_field.text = str(_proposal.get("description", ""))
	_date_field.text        = str(_proposal.get("doc_date", Time.get_date_string_from_system()))

	# Tags: Array → comma-separated string
	var tags = _proposal.get("tags", [])
	if tags is Array:
		_tags_field.text = ", ".join(tags)
	else:
		_tags_field.text = str(tags)

	if _error_label != null:
		_error_label.text = ""


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_accept_pressed() -> void:
	if _category_field == null:
		return
	var category: String = _category_field.text.strip_edges()
	if category.is_empty():
		if _error_label != null:
			_error_label.text = "Category is required."
		# Re-show the dialog so the user can fix the error.
		popup_centered()
		return

	# Parse tags back to Array.
	var tags_raw: String = _tags_field.text.strip_edges() if _tags_field != null else ""
	var tags: Array = []
	if not tags_raw.is_empty():
		for t: String in tags_raw.split(","):
			var trimmed: String = t.strip_edges()
			if not trimmed.is_empty():
				tags.append(trimmed)

	var final_classification: Dictionary = _proposal.duplicate(true)
	final_classification["category"]    = category
	final_classification["sender"]      = _sender_field.text.strip_edges()    if _sender_field      != null else ""
	final_classification["description"] = _description_field.text.strip_edges() if _description_field != null else ""
	final_classification["doc_date"]    = _date_field.text.strip_edges()      if _date_field        != null else ""
	final_classification["tags"]        = tags

	accepted.emit(final_classification)


func _on_cancel_pressed() -> void:
	cancelled.emit()


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

func _make_hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return h


func _make_fixed_label(text: String, min_width: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size.x = min_width
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _make_row_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	return lbl
