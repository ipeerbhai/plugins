class_name Presentation_TileKindBase
extends AnnotationKind
## Shared base for all presentation tile annotation kinds.
##
## Tile kinds are GEOMETRY-ONLY adapters. The visual content (text, image,
## spreadsheet) is rendered by Control-tree children inside the slide canvas.
## The substrate annotation overlay draws only selection/transform gizmo handles.
##
## Envelope contract (kind_payload):
##   rect_px:      Rect2   — slide-local pixel rect; origin at slide_rect top-left
##   rotation_rad: float   — rotation in radians; 0.0 default
##   tile_id:      String  — back-reference to the tile id (== annotation id)
##
## Subclasses set name, display_name in their _init().
## All other logic lives here.


func _init() -> void:
	owning_plugin = &"presentation"
	primitives_optional = true
	schema_version = 1


# ── Required overrides ────────────────────────────────────────────────────────

## Return the unrotated slide-local bounding rect for this tile.
## Substrate convention: bounds() is axis-aligned; rotation is separate metadata.
func bounds(annotation: Dictionary) -> Rect2:
	var payload: Dictionary = annotation.get("kind_payload", {}) as Dictionary
	return payload.get("rect_px", Rect2())


## Hit-test point against the tile rect.
## For zero rotation, grow the rect by threshold and test directly.
## For non-zero rotation, inverse-rotate the point around the rect center first.
func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var payload: Dictionary = (annotation.get("kind_payload", {}) as Dictionary)
	var rect: Rect2 = payload.get("rect_px", Rect2())
	var rotation: float = float(payload.get("rotation_rad", 0.0))
	if is_zero_approx(rotation):
		return rect.grow(threshold).has_point(point)
	# Inverse-rotate the point so we can test against the axis-aligned rect.
	var center := rect.get_center()
	var t := Transform2D(-rotation, Vector2.ZERO)
	var local_point := t * (point - center) + center
	return rect.grow(threshold).has_point(local_point)


## Apply a Transform2D to the tile's rect_px and rotation_rad.
## Mirrors the substrate "text" primitive pattern in AnnotationKind lines 461-478.
func transform_annotation(annotation: Dictionary, transform: Transform2D, _operation: String = "") -> Dictionary:
	var out: Dictionary = annotation.duplicate(true)
	var payload: Dictionary = (out.get("kind_payload", {}) as Dictionary).duplicate(true)
	var rect: Rect2 = payload.get("rect_px", Rect2())
	var rotation: float = float(payload.get("rotation_rad", 0.0))
	var font_size: float = float(payload.get("font_size", 18.0))

	var center := rect.get_center()
	var new_center := transform * center

	var dr: float = transform.get_rotation()
	if not is_zero_approx(dr):
		rotation += dr

	var ds: Vector2 = transform.get_scale()
	var new_size := Vector2(rect.size.x * ds.x, rect.size.y * ds.y)
	if _operation == "scale":
		var font_scale: float = sqrt(maxf(absf(ds.x * ds.y), 0.0001))
		font_size = clampf(font_size * font_scale, 8.0, 160.0)
	# Guard against negative/tiny sizes (mirror MIN_SCALE in AnnotationTransformTool).
	new_size.x = maxf(absf(new_size.x), 1.0)
	new_size.y = maxf(absf(new_size.y), 1.0)

	payload["rect_px"] = Rect2(new_center - new_size * 0.5, new_size)
	payload["rotation_rad"] = rotation
	payload["font_size"] = font_size
	out["kind_payload"] = payload
	return out


## The canonical anchor point for this tile is its rect center.
func primary_anchor_point(annotation: Dictionary) -> Vector2:
	var payload: Dictionary = (annotation.get("kind_payload", {}) as Dictionary)
	var rect: Rect2 = payload.get("rect_px", Rect2())
	return rect.get_center()


# ── Visual render — disabled (Control children handle tile content) ────────────

## Tile content renders via Control children in the slide canvas.
## The substrate overlay only draws selection/transform gizmo handles.
func has_visual_render() -> bool:
	return false


## No-op: tile kinds do not draw into the annotation overlay canvas.
func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
	pass
