extends AcceptDialog
## Paste-JSON dialog — W8 (DCR 019e33bf).
##
## A small modal with one TextEdit for a rule's JSON body. Three modes:
##   - `MODE_NEW`      : empty TextArea, Save calls library_insert_rule
##   - `MODE_EDIT`     : prefilled, Save calls library_update_rule (label
##                       taken from the JSON's `label` field)
##   - `MODE_READONLY` : prefilled, Save button hidden, Close-only
##
## The dialog does NOT call MCP tools directly. The panel supplies a
## `save_callable` via `configure(...)` that receives the parsed
## Dictionary and returns `{ok: bool, error?: String}`. The dialog runs
## the callable, shows inline errors on failure, and closes on success.
##
## No `class_name` — off-tree plugin script; use preload().

const _UiScale := preload("ui_scale.gd")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

enum Mode { MODE_NEW, MODE_EDIT, MODE_READONLY }

## Emitted after a successful save (parse OK + callable returned ok:true).
signal saved(parsed: Dictionary)

## Emitted on cancel / close (no save attempted).
signal cancelled

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _mode: int = Mode.MODE_NEW
var _initial_json: String = ""
var _save_callable: Callable = Callable()

var _vbox: VBoxContainer = null
var _text: TextEdit = null
var _error_label: Label = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Paste rule JSON"
	min_size = Vector2(640, 480)
	ok_button_text = "Save"
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_canceled)
	_build_form()
	_apply_mode_to_widgets()


## Configure the dialog before popup. `save_callable` is invoked with the
## parsed Dictionary on Save; it must return either {ok:true} or
## {ok:false, error:"<msg>"}.
func configure(
		mode: int,
		initial_json: String = "",
		save_callable: Callable = Callable()) -> void:
	_mode = mode
	_initial_json = initial_json
	_save_callable = save_callable
	if _vbox != null:
		_apply_mode_to_widgets()


# ---------------------------------------------------------------------------
# Form construction
# ---------------------------------------------------------------------------

func _build_form() -> void:
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)

	var help := Label.new()
	help.text = "Paste one rule's JSON body. Must include a `label` field."
	help.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_vbox.add_child(help)

	_text = TextEdit.new()
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_text.custom_minimum_size.y = 380
	_text.placeholder_text = "{\n  \"label\": \"my_rule\",\n  \"instruction\": \"...\",\n  \"stages\": []\n}"
	_vbox.add_child(_text)

	_error_label = Label.new()
	_error_label.text = ""
	_error_label.add_theme_color_override("font_color", Color.RED)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_error_label)

	add_child(_vbox)


func _apply_mode_to_widgets() -> void:
	if _text == null:
		return
	match _mode:
		Mode.MODE_NEW:
			title = "Paste rule JSON — new rule"
			_text.editable = true
			_text.text = _initial_json
			ok_button_text = "Save"
			get_ok_button().visible = true
		Mode.MODE_EDIT:
			title = "Edit rule JSON"
			_text.editable = true
			_text.text = _initial_json
			ok_button_text = "Save"
			get_ok_button().visible = true
		Mode.MODE_READONLY:
			title = "View rule JSON"
			_text.editable = false
			_text.text = _initial_json
			get_ok_button().visible = false
			# AcceptDialog already has a Close button via canceled.
	if _error_label != null:
		_error_label.text = ""


# ---------------------------------------------------------------------------
# Save flow
# ---------------------------------------------------------------------------

func _on_confirmed() -> void:
	# Read-only mode never gets here (Save button hidden); guard anyway.
	if _mode == Mode.MODE_READONLY:
		return

	var raw: String = _text.text.strip_edges()
	if raw.is_empty():
		_show_error("JSON body cannot be empty.")
		_reopen()
		return

	var parsed: Variant = JSON.parse_string(raw)
	if parsed == null or not (parsed is Dictionary):
		_show_error("Could not parse JSON object. Check braces, quotes, commas.")
		_reopen()
		return

	var parsed_dict: Dictionary = parsed
	if not parsed_dict.has("label") or str(parsed_dict["label"]).is_empty():
		_show_error("Rule JSON must include a non-empty `label` field.")
		_reopen()
		return

	if not _save_callable.is_valid():
		_show_error("No save handler configured (panel bug).")
		_reopen()
		return

	var result: Variant = _save_callable.call(parsed_dict, _mode)
	if not (result is Dictionary):
		_show_error("Save handler returned non-Dictionary; expected {ok:bool, error?}.")
		_reopen()
		return

	var result_dict: Dictionary = result
	if not result_dict.get("ok", false):
		var msg: String = str(result_dict.get("error", "unknown save error"))
		_show_error("Save failed: %s" % msg)
		_reopen()
		return

	saved.emit(parsed_dict)
	# Dialog closes itself when `confirmed` fires; no explicit hide needed.


func _on_canceled() -> void:
	cancelled.emit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _show_error(msg: String) -> void:
	if _error_label != null:
		_error_label.text = msg


## Re-show the dialog after a failed Save. AcceptDialog auto-hides on
## `confirmed`; we want it to stay visible so the user can fix the JSON.
func _reopen() -> void:
	call_deferred("popup_centered")
