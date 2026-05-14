extends AcceptDialog
## Edit Document Details dialog — T7 R4.
##
## Lets the user modify metadata on an existing document already in the vault.
## Does NOT call MCP tools itself — emits `accepted(updated_fields)` and lets
## the panel coordinate the update_document call.
##
## Usage:
##   var dlg = preload("edit_details_dialog.gd").new()
##   dlg.set_document(doc_dict, rules_array)   # populate fields
##   add_child(dlg)
##   dlg.accepted.connect(_on_edit_dialog_accepted)
##   dlg.cancelled.connect(_on_edit_dialog_cancelled)
##   dlg.popup_centered()
##
## No class_name — off-tree plugin script; use preload().

## Emitted when the user clicks Save.  updated_fields is the subset of changed
## metadata the caller should pass to minerva_scansort_update_document.
signal accepted(updated_fields: Dictionary)

## Emitted when the user cancels.
signal cancelled

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _doc: Dictionary = {}

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

var _vbox:           VBoxContainer = null
var _name_field:     LineEdit      = null
var _desc_field:     TextEdit      = null
var _tags_field:     LineEdit      = null
var _category_btn:   OptionButton  = null
var _category_labels: Array        = []
var _error_label:    Label         = null


const _UiScale := preload("ui_scale.gd")


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Edit Document Details"
	min_size = Vector2(520, 380)
	ok_button_text = "Save"
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_cancel_pressed)
	_build_form()


## Populate the form with an existing document dict and a list of rule Dicts
## (each having at least a "label" field used as the category name).
func set_document(doc: Dictionary, rules: Array) -> void:
	_doc = doc.duplicate(true)
	if _vbox != null:
		_populate_form(rules)


# ---------------------------------------------------------------------------
# Form construction
# ---------------------------------------------------------------------------

func _build_form() -> void:
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)

	# --- Display Name ---
	_vbox.add_child(_make_row_label("Display Name"))
	_name_field = LineEdit.new()
	_name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_field.placeholder_text = "Human-readable name for this document"
	_vbox.add_child(_name_field)

	# --- Description ---
	_vbox.add_child(_make_row_label("Description"))
	_desc_field = TextEdit.new()
	_desc_field.custom_minimum_size.y = 80
	_desc_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desc_field.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_vbox.add_child(_desc_field)

	# --- Tags ---
	_vbox.add_child(_make_row_label("Tags (comma-separated)"))
	_tags_field = LineEdit.new()
	_tags_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tags_field.placeholder_text = "tax, 2025, w2, income"
	_vbox.add_child(_tags_field)

	# --- Category ---
	_vbox.add_child(_make_row_label("Category"))
	_category_btn = OptionButton.new()
	_category_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(_category_btn)

	# --- Error label ---
	_error_label = Label.new()
	_error_label.text = ""
	_error_label.add_theme_color_override("font_color", Color.RED)
	_vbox.add_child(_error_label)

	add_child(_vbox)

	# Populate if set_document was called before _ready.
	if not _doc.is_empty():
		_populate_form([])


func _populate_form(rules: Array) -> void:
	if _vbox == null:
		return

	# Display name — prefer display_name, fall back to original_filename.
	_name_field.text = str(_doc.get("display_name", _doc.get("original_filename", "")))

	# Description.
	_desc_field.text = str(_doc.get("description", ""))

	# Tags: may be an Array or a JSON-encoded string.
	var tags_val: Variant = _doc.get("tags", [])
	if tags_val is Array:
		_tags_field.text = ", ".join(PackedStringArray(tags_val))
	elif tags_val is String and not (tags_val as String).is_empty():
		var parsed: Variant = JSON.parse_string(tags_val)
		if parsed is Array:
			_tags_field.text = ", ".join(PackedStringArray(parsed))
		else:
			_tags_field.text = tags_val
	else:
		_tags_field.text = ""

	# Category dropdown — populate from rules, then select current.
	_category_btn.clear()
	_category_labels.clear()
	var current_cat: String = str(_doc.get("category", ""))

	var selected_idx: int = 0
	for i: int in range(rules.size()):
		var rule: Dictionary = rules[i]
		var label: String = str(rule.get("label", rule.get("name", "")))
		if label.is_empty():
			continue
		_category_btn.add_item(label)
		_category_labels.append(label)
		if label == current_cat:
			selected_idx = _category_labels.size() - 1

	# If the current category isn't in the rules list, append it so it is selectable.
	if not current_cat.is_empty() and not _category_labels.has(current_cat):
		_category_btn.add_item(current_cat)
		_category_labels.append(current_cat)
		selected_idx = _category_labels.size() - 1

	if _category_btn.item_count > 0:
		_category_btn.selected = selected_idx

	if _error_label != null:
		_error_label.text = ""


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_confirmed() -> void:
	if _name_field == null:
		return

	# Parse tags back to Array.
	var tags_raw: String = _tags_field.text.strip_edges() if _tags_field != null else ""
	var tags: Array = []
	if not tags_raw.is_empty():
		for t: String in tags_raw.split(","):
			var trimmed: String = t.strip_edges()
			if not trimmed.is_empty():
				tags.append(trimmed)

	var updates: Dictionary = {}

	var display_name: String = _name_field.text.strip_edges()
	if not display_name.is_empty():
		updates["display_name"] = display_name

	updates["description"] = _desc_field.text.strip_edges() if _desc_field != null else ""
	updates["tags"] = tags

	if _category_btn != null and _category_btn.item_count > 0 and _category_btn.selected >= 0:
		updates["category"] = _category_labels[_category_btn.selected]

	accepted.emit(updates)


func _on_cancel_pressed() -> void:
	cancelled.emit()


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

func _make_row_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	return lbl
