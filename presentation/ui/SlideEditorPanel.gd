class_name Presentation_SlideEditorPanel
extends MinervaPluginPanel
## Slide editor panel — owns the deck document.
##
## T2 wires the real slide_model.gd in: _on_panel_save_request returns the
## current deck dict; _on_panel_load_request validates + adopts an incoming
## doc (or falls back to a fresh deck if the doc is malformed). T3 will add
## the slide list + canvas UI; until then the placeholder Label shows a
## live slide count for HITL feedback.
##
## class_name prefix discipline: PluginDB.install() runs scan_class_names()
## which enforces `^<canonical_prefix(id)>_[A-Za-z0-9_]+$`. For id="presentation"
## the canonical prefix is "Presentation_". See memory:
## project_plugin_class_name_prefix_rule.md.

const _SlideModel: Script = preload("slide_model.gd")

var _ctx: Dictionary = {}
var _placeholder_label: Label = null

# The deck document. Always a valid Dictionary in the slide_model schema.
var _deck: Dictionary = {}


func _ready() -> void:
	if has_node("Placeholder"):
		_placeholder_label = get_node("Placeholder") as Label
	if _deck.is_empty():
		_deck = _SlideModel.make_deck()
	_refresh_placeholder()


# ---------------------------------------------------------------------------
# Lifecycle hooks (MinervaPluginPanel contract)
# ---------------------------------------------------------------------------

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	_refresh_placeholder()


func _on_panel_unload() -> void:
	pass


func _on_panel_save_request() -> Dictionary:
	# Save-on-error is intentional: surfacing a warning gives the user a chance
	# to inspect/repair, while still preserving their work to disk. Refusing to
	# save would risk silent data loss on a borderline-malformed deck.
	var errors: Array = _SlideModel.validate_deck(_deck)
	if errors.size() > 0:
		push_warning("[presentation] save: deck has %d validation errors; saving anyway: %s" % [errors.size(), str(errors)])
	return _deck


func _on_panel_load_request(doc: Dictionary) -> void:
	var errors: Array = _SlideModel.validate_deck(doc)
	if errors.size() > 0:
		push_warning("[presentation] load: doc has validation errors, falling back to fresh deck: %s" % str(errors))
		_deck = _SlideModel.make_deck()
	else:
		_deck = doc
	_refresh_placeholder()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _refresh_placeholder() -> void:
	if _placeholder_label == null:
		return
	var slide_count: int = (_deck.get("slides", []) as Array).size()
	var fname: String = str(_ctx.get("file_path", ""))
	var lines: Array = []
	lines.append("Presentation plugin loaded")
	lines.append("Slides: %d" % slide_count)
	if fname != "":
		lines.append("File: %s" % fname)
	else:
		lines.append("New untitled deck")
	_placeholder_label.text = "\n".join(lines)


# ---------------------------------------------------------------------------
# Public accessors (used by tests + future T3/T7 wiring)
# ---------------------------------------------------------------------------

func get_deck() -> Dictionary:
	return _deck


func set_deck(deck: Dictionary) -> void:
	_deck = deck
	_refresh_placeholder()
