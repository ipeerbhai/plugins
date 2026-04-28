extends AnnotationKind
## CAD plugin annotation kind: cad_edge_number.
##
## Draws a numbered callout bubble at a specified screen position, labelling
## a particular edge by its id. Intended for LLM-driven disambiguation flows
## ("here are the candidate edges for your fillet") and future user-placed
## edge markers.
##
## Payload schema (validated by validate()):
##   edge_id  : int     (required) — the edge to call out
##   label    : String  (optional) — override display text (default: str(edge_id))
##   color    : String  (optional) — CSS-style color string parsed via Color()
##   group_id : String  (optional) — logical group for batch clear operations
##
## Primitive: one "point" primitive whose "at" field [x, y] is the screen-space
## anchor where the callout is drawn. Callers supply this when creating the
## annotation; render() is a no-op when primitives is empty.
##
## primitives_optional = true: programmatic add without primitives silently
## renders nothing until the annotation is updated with a position.
##
## Off-tree note: this file lives at ~/github/plugins/cad/, outside Minerva's
## res:// tree. It MUST NOT declare a class_name. Platform base classes
## (AnnotationKind, AnnotationRenderContext) are resolved via res:// class_name
## indexing and work fine from here. preload() is used by CADPanel.gd and tests
## to load this script.

# Visual constants — match the existing "white number on dark bubble" style
# that edge_overlay.gd used for its old built-in labels.
const _BUBBLE_FILL := Color(0.08, 0.09, 0.11, 0.94)
const _BUBBLE_STROKE := Color(0.55, 0.60, 0.68, 0.90)
const _TEXT_COLOR := Color(0.92, 0.94, 0.97, 1.0)
const _DEFAULT_LEADER_COLOR := Color(0.75, 0.80, 0.88, 0.85)
const _FONT_SIZE := 13
const _BUBBLE_PAD := Vector2(6.0, 4.0)     # padding around text inside bubble
const _LEADER_OFFSET := Vector2(28.0, -28.0) # bubble center offset from anchor point


func _init() -> void:
	name = &"cad_edge_number"
	display_name = "Edge Number"
	schema_version = 1
	owning_plugin = &"cad"
	primitives_optional = true
	default_payload = {"edge_id": 0}


# ── Validation ────────────────────────────────────────────────────────────────

func validate(annotation: Dictionary) -> Array:
	var payload: Dictionary = annotation.get("payload", {})
	var errors: Array = []

	if not payload.has("edge_id"):
		errors.append({"field": "payload.edge_id", "message": "edge_id is required"})
		return errors

	var edge_id_val: Variant = payload["edge_id"]
	if not (edge_id_val is int or edge_id_val is float):
		errors.append({
			"field": "payload.edge_id",
			"message": "edge_id must be an integer, got %s" % typeof(edge_id_val)
		})

	return errors


# ── Required rendering ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var prims: Array = annotation.get("primitives", [])
	if prims.is_empty():
		return

	var prim: Variant = prims[0]
	if not (prim is Dictionary):
		return

	var at_raw: Variant = (prim as Dictionary).get("at", null)
	if at_raw == null:
		return
	var anchor := AnnotationKind._to_vec2(at_raw)

	var payload: Dictionary = annotation.get("payload", {})
	var edge_id: int = int(payload.get("edge_id", 0))

	var label_text: String = str(payload.get("label", edge_id))

	var leader_color := _DEFAULT_LEADER_COLOR
	var color_raw: Variant = payload.get("color", null)
	if color_raw != null:
		var color_str := str(color_raw)
		if Color.html_is_valid(color_str):
			leader_color = Color(color_str)

	_draw_callout(ctx, anchor, label_text, leader_color)


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	if prims.is_empty():
		return Rect2()
	var prim: Variant = prims[0]
	if not (prim is Dictionary):
		return Rect2()
	var at_raw: Variant = (prim as Dictionary).get("at", null)
	if at_raw == null:
		return Rect2()
	var anchor := AnnotationKind._to_vec2(at_raw)
	var bubble_center := anchor + _LEADER_OFFSET
	var approx_half := Vector2(20.0, 12.0)
	return Rect2(bubble_center - approx_half, approx_half * 2.0)


# ── author_ui: null for Round 1 (toolbar stub, no click-to-place UX yet) ─────

func author_ui() -> Object:
	return null


# ── Private drawing helpers ───────────────────────────────────────────────────

func _draw_callout(
	ctx: AnnotationRenderContext,
	anchor: Vector2,
	label_text: String,
	leader_color: Color
) -> void:
	var font: Font = ThemeDB.fallback_font
	var bubble_center := anchor + _LEADER_OFFSET

	# Leader line: anchor → bubble center
	ctx.draw_line(anchor, bubble_center, leader_color, 1.2)

	# Compute bubble size from text metrics
	var text_w: float = 30.0
	if font != null:
		text_w = font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _FONT_SIZE).x
	var bubble_size := Vector2(text_w + _BUBBLE_PAD.x * 2.0, float(_FONT_SIZE) + _BUBBLE_PAD.y * 2.0)
	var bubble_rect := Rect2(bubble_center - bubble_size * 0.5, bubble_size)

	# Filled bubble background
	ctx.draw_rect(bubble_rect, _BUBBLE_FILL, true)
	# Bubble stroke
	ctx.draw_rect(bubble_rect, _BUBBLE_STROKE, false, 1.0)

	# Text centered in bubble
	var text_pos := bubble_rect.position + _BUBBLE_PAD - Vector2(0.0, 1.0)
	ctx.draw_string(font, text_pos, label_text, _TEXT_COLOR, _FONT_SIZE)

	# Small circle at the anchor point to mark the edge attachment
	_draw_anchor_dot(ctx, anchor, leader_color)


func _draw_anchor_dot(ctx: AnnotationRenderContext, pos: Vector2, color: Color) -> void:
	# Draw a small filled circle by rendering a tiny polygon approximation.
	# AnnotationRenderContext has no draw_circle, so we use a polygon.
	var r := 3.5
	var segments := 10
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	for i in range(segments):
		var angle := TAU * float(i) / float(segments)
		pts.append(pos + Vector2(cos(angle), sin(angle)) * r)
		cols.append(color)
	if pts.size() >= 3:
		ctx.draw_polygon(pts, cols)
