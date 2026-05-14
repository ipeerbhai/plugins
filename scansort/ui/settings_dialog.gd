extends AcceptDialog
## Scansort Settings dialog.
##
## Single per-plugin preference: classification model override. The default
## is "Inherit from chat panel" — whatever model is currently selected in
## the chat panel's ProviderOptionButton is used for classify. When the user
## picks a specific model here, that override travels across vaults.
##
## Scansort always operates in multimodal mode (text and vision share one
## model), so this dialog exposes a single model picker rather than separate
## text/vision options.
##
## Storage: OS.get_user_data_dir() + "/scansort_settings.json"
##   { "model_override": {kind: ..., ...} | null }
##
## Usage:
##   var dlg = preload("settings_dialog.gd").new()
##   dlg.init(conn)
##   add_child(dlg)
##   dlg.settings_changed.connect(_on_settings_changed)
##   dlg.popup_centered(Vector2(520, 240))
##
## No class_name — off-tree plugin script; use preload().

## Emitted after the user clicks Save. Caller may reload _resolve_chat_model_for_classify.
signal settings_changed

## Emitted when the dialog closes (either save or cancel).
signal closed

# ---------------------------------------------------------------------------
# Dependencies (injected via init())
# ---------------------------------------------------------------------------

var _conn: Object = null

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

var _model_picker: OptionButton = null
var _help_label:   Label        = null


const _UiScale := preload("ui_scale.gd")


func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Scansort Settings"
	min_size = Vector2(520, 240)
	ok_button_text = "Save"
	confirmed.connect(_on_save_pressed)
	canceled.connect(_on_close_pressed)
	_build_ui()


## Inject the plugin connection. Settings file is loaded on demand from
## OS.get_user_data_dir(); the panel doesn't need to pass a path.
func init(conn: Object) -> void:
	_conn = conn
	# Defer until added to scene so _model_picker is populated.
	call_deferred("_load_current_settings")


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)

	# --- Model row ---------------------------------------------------------
	var model_row := HBoxContainer.new()
	model_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var model_lbl := Label.new()
	model_lbl.text = "Classification model"
	model_lbl.custom_minimum_size.x = 180
	model_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	model_row.add_child(model_lbl)

	_model_picker = OptionButton.new()
	_model_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_picker.tooltip_text = "Model used for document classification. \"Inherit from chat panel\" follows whichever model the chat panel currently has selected."
	model_row.add_child(_model_picker)
	root.add_child(model_row)

	# --- Help text ---------------------------------------------------------
	_help_label = Label.new()
	_help_label.text = "Scansort always uses a single multimodal model for both text and vision classification. Pick one that supports images for the best results, or leave inherited to follow the chat panel."
	_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	root.add_child(_help_label)

	add_child(root)


## Populate the model picker:
##   index 0: "Inherit from chat panel" (metadata = empty Dict)
##   index 1+: items from ChatPane.get_available_models()
## Selection set from the current saved override if any.
func _load_current_settings() -> void:
	if _model_picker == null:
		return
	_model_picker.clear()
	_model_picker.add_item("Inherit from chat panel", 0)
	_model_picker.set_item_metadata(0, {})

	# Reach ChatPane via SingletonObject.Chats.
	var model_list: Array = []
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() != null else null
	if so != null:
		var chats = so.get("Chats") if "Chats" in so else null
		if chats != null and chats.has_method("get_available_models"):
			model_list = chats.get_available_models()

	for i in range(model_list.size()):
		var entry: Dictionary = model_list[i]
		var spec: Dictionary = entry.get("spec", {}) as Dictionary if entry.get("spec") is Dictionary else {}
		var display: String = str(entry.get("display_name", "?"))
		var item_id: int = i + 1
		_model_picker.add_item(display, item_id)
		_model_picker.set_item_metadata(item_id, spec)

	# Restore previously-saved selection.
	var override: Dictionary = ScansortSettings.load_model_override()
	var target_idx: int = 0  # default to "Inherit"
	if not override.is_empty():
		for i in range(_model_picker.get_item_count()):
			var meta = _model_picker.get_item_metadata(i)
			if meta is Dictionary and not (meta as Dictionary).is_empty():
				if _specs_match(meta as Dictionary, override):
					target_idx = i
					break
	_model_picker.select(target_idx)


## Shallow equality on the two fields that uniquely identify a spec:
## "kind" plus whatever follows for that kind (model_id for builtin/dynamic,
## service_client_id+action_name for core_action).
static func _specs_match(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	match str(a.get("kind", "")):
		"core_action":
			return (
				str(a.get("service_client_id", "")) == str(b.get("service_client_id", ""))
				and str(a.get("action_name", "")) == str(b.get("action_name", ""))
			)
		_:
			return int(a.get("model_id", 0)) == int(b.get("model_id", 0))


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_save_pressed() -> void:
	if _model_picker == null:
		closed.emit()
		return
	var idx: int = _model_picker.get_selected()
	if idx < 0:
		closed.emit()
		return
	var meta = _model_picker.get_item_metadata(idx)
	var spec: Dictionary = meta as Dictionary if meta is Dictionary else {}
	# Empty spec → inherit (clears the override).
	ScansortSettings.save_model_override(spec)
	settings_changed.emit()
	closed.emit()


func _on_close_pressed() -> void:
	closed.emit()


# ---------------------------------------------------------------------------
# Storage — inline because GDScript can't preload a sibling const in a class
# body inside an AcceptDialog subclass without name collisions.
# ---------------------------------------------------------------------------

class ScansortSettings:
	const SETTINGS_FILENAME := "scansort_settings.json"

	## Returns the absolute path to the per-user scansort settings JSON.
	static func settings_path() -> String:
		return OS.get_user_data_dir() + "/" + SETTINGS_FILENAME

	## Read the saved model override spec. Returns an empty Dict when no
	## override is set (i.e. inherit-from-chat is in effect).
	static func load_model_override() -> Dictionary:
		var path := settings_path()
		if not FileAccess.file_exists(path):
			return {}
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return {}
		var text: String = f.get_as_text()
		f.close()
		var parsed: Variant = JSON.parse_string(text)
		if not (parsed is Dictionary):
			return {}
		var p_dict: Dictionary = parsed as Dictionary
		var raw = p_dict.get("model_override", null)
		if raw is Dictionary:
			return raw as Dictionary
		return {}

	## Save the model override spec. Empty Dict → write null (inherit mode).
	## Creates the parent directory if missing. Returns true on success.
	static func save_model_override(spec: Dictionary) -> bool:
		var path := settings_path()
		var dir := path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			var err := DirAccess.make_dir_recursive_absolute(dir)
			if err != OK:
				push_error("[ScansortSettings] could not create %s (error %d)" % [dir, err])
				return false
		var blob: Dictionary
		if spec.is_empty():
			blob = {"model_override": null}
		else:
			blob = {"model_override": spec}
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_error("[ScansortSettings] could not write %s" % path)
			return false
		f.store_string(JSON.stringify(blob, "  "))
		f.close()
		return true
