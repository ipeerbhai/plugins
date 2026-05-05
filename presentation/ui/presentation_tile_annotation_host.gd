class_name Presentation_TileAnnotationHost
extends AnnotationHost
## AnnotationHost adapter for the Presentation plugin.
##
## Exposes the active slide's tiles[] as synthesized annotation envelopes so
## the substrate AnnotationTransformTool can drive selection/SRT on tiles.
## Substrate kinds (callout / 2d_arrow / 2d_text) coexist on the same surface
## and are persisted in slide.annotations[].
##
## Off-tree plugin rule: use preload + Script-typed const, NOT class_name imports.

const _SlideModel: Script = preload("slide_model.gd")
const _PresentationTileKindText: Script = preload("presentation_tile_kind_text.gd")
const _PresentationTileKindImage: Script = preload("presentation_tile_kind_image.gd")
const _PresentationTileKindSpreadsheet: Script = preload("presentation_tile_kind_spreadsheet.gd")

## Emitted whenever the annotation list mutates (add, update, remove, slide/rect change).
## AnnotationOverlay.gd:32 listens for exactly this name — do not rename.
signal annotations_changed()

# ── Internal state ─────────────────────────────────────────────────────────

var _registry: AnnotationRegistry = null
var _slide: Dictionary = {}         # the active slide dict (mutated in place)
var _slide_rect: Rect2 = Rect2()    # current slide pixel rect (set by canvas)
var _selected_id: String = ""
var _include_tiles: bool = true
var _include_substrate_annotations: bool = true

# ── Initialization ─────────────────────────────────────────────────────────

func _init() -> void:
	super._init()
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)
	_registry.register_annotation_kind(_PresentationTileKindText.new())
	_registry.register_annotation_kind(_PresentationTileKindImage.new())
	_registry.register_annotation_kind(_PresentationTileKindSpreadsheet.new())

# ── Public setters (called by slide_canvas in Round 3) ────────────────────

## Configure which document objects this host exposes. The presentation canvas
## uses a tile-only host for object manipulation; editor chrome uses an
## annotation-only host so the annotation Select tool cannot select slide tiles.
func configure_surface(include_tiles: bool, include_substrate_annotations: bool) -> void:
	_include_tiles = include_tiles
	_include_substrate_annotations = include_substrate_annotations
	_prune_stale_selection()
	annotations_changed.emit()

## Set the active slide dict. Clears selection if the selected id is no longer
## present in the new slide's tiles or annotations. Emits annotations_changed.
func set_slide(slide: Dictionary) -> void:
	_slide = slide
	_prune_stale_selection()
	annotations_changed.emit()


## Set the current slide pixel rect (position + size in screen space).
## Emits annotations_changed when the size changes so the overlay redraws with
## updated pixel geometry (normalized→pixel conversion depends on slide size).
func set_slide_rect(rect: Rect2) -> void:
	var size_changed: bool = not _slide_rect.size.is_equal_approx(rect.size)
	_slide_rect = rect
	if size_changed:
		annotations_changed.emit()

# ── AnnotationHost overrides ───────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


func get_capabilities() -> Dictionary:
	var kinds: Array = []
	if _include_substrate_annotations:
		kinds.append_array(["callout", "2d_arrow", "2d_text"])
	if _include_tiles:
		kinds.append_array(["presentation_tile_text", "presentation_tile_image", "presentation_tile_spreadsheet"])
	return {
		"kinds": kinds,
		"tools": ["select"],
		"anchor_types": ["core/canvas.point"],
		"lifecycle": {"resolve": false, "reopen": false, "delete": true, "repair": false, "apply": false},
		"authoring": {"add": true, "domain_pickers": false},
		"panes": false, "body_views": false,
		"filters": ["all", "open"],
	}


func get_view_context() -> String:
	return "presentation"


func get_document_identity() -> Dictionary:
	return {
		"kind": "presentation",
		"path": "",
		"display_name": "Slide",
		"save_policy": "host",
	}


## DOC SPACE = canvas-local pixels (matches the overlay's local coords).
##
## We chose canvas-local rather than slide-local because AnnotationOverlay creates
## its render context with Transform2D.IDENTITY (AnnotationOverlay.gd:78) — i.e.,
## tool-drawn gizmo handles render at doc-space coords AS IF they were overlay-local.
## A slide-local doc space would draw gizmo handles offset by -slide_rect.position
## from the visible tiles (invisible whenever the slide is letterboxed).
##
## Synthesized rect_px in get_annotations() therefore includes slide_rect.position;
## writeback in _writeback_tile() subtracts it before normalizing.
func transform_screen_to_doc(p: Vector2) -> Vector2:
	return p


func transform_doc_to_screen(p: Vector2) -> Vector2:
	return p


## Return CONCATENATION of synthesized tile annotations + persisted substrate
## annotations from slide.annotations[].
func get_annotations() -> Array:
	var result: Array = []
	if _slide.is_empty() or _slide_rect.size.x <= 0.0 or _slide_rect.size.y <= 0.0:
		return result
	var size_v: Vector2 = _slide_rect.size
	var origin: Vector2 = _slide_rect.position
	if _include_tiles:
		for tile in (_slide.get("tiles", []) as Array):
			if not (tile is Dictionary):
				continue
			var t: Dictionary = tile
			var kind_name: String = _kind_for_tile(str(t.get("kind", "")))
			if kind_name.is_empty():
				continue
			# rect_px is in canvas-local pixels (= overlay-local = doc-space for our host).
			var rect_px := Rect2(
				origin.x + float(t.get("x", 0.0)) * size_v.x,
				origin.y + float(t.get("y", 0.0)) * size_v.y,
				float(t.get("w", 0.0)) * size_v.x,
				float(t.get("h", 0.0)) * size_v.y,
			)
			result.append({
				"id": str(t.get("id", "")),
				"kind": kind_name,
				"kind_payload": {
					"rect_px": rect_px,
					"rotation_rad": float(t.get("rotation", 0.0)),
					"tile_id": str(t.get("id", "")),
					"font_size": float(t.get("font_size", 18.0)),
					"font_size_explicit": t.has("font_size"),
				},
				"view_context": "presentation",
			})
	# Append real substrate annotations (callout / 2d_arrow / 2d_text) — persisted
	# in slide.annotations[].
	if _include_substrate_annotations:
		for ann in (_slide.get("annotations", []) as Array):
			if ann is Dictionary:
				result.append((ann as Dictionary).duplicate(true))
	return result


## Route update by kind: tile kinds → writeback into tile dict;
## substrate kinds → write through to slide.annotations[].
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	if _slide.is_empty():
		return false
	var kind_str := str(new_annotation.get("kind", ""))
	if kind_str.begins_with("presentation_tile_"):
		if not _include_tiles:
			return false
		return _writeback_tile(annotation_id, new_annotation)
	# Substrate kind — write through to slide.annotations[].
	var ok: bool = _SlideModel.update_annotation(_slide, annotation_id, new_annotation)
	if ok:
		annotations_changed.emit()
	return ok


## Add a substrate annotation. Tile kinds are rejected (tiles are created via the
## PLACE flow, not via add_annotation). Assigns id if missing, stamps anchor,
## appends to slide.annotations[], emits annotations_changed.
func add_annotation(annotation: Dictionary) -> String:
	if _slide.is_empty():
		return ""
	var kind_str := str(annotation.get("kind", ""))
	if kind_str.begins_with("presentation_tile_"):
		# Tile kinds cannot be added via this path.
		return ""
	if not _include_substrate_annotations:
		return ""
	var id: String = str(annotation.get("id", ""))
	if id.is_empty():
		id = "ann_%x" % randi()
	var stored: Dictionary = annotation.duplicate(true)
	stored["id"] = id
	AnnotationHost._stamp_anchor(stored, self)
	_SlideModel.add_annotation(_slide, stored)
	annotations_changed.emit()
	return id


## Remove an annotation. Tile kinds are rejected (tile deletion stays on the tool
## palette / Del key path). Substrate kinds are removed from slide.annotations[].
func remove_annotation(annotation_id: String) -> bool:
	if _slide.is_empty():
		return false
	# Reject if this id belongs to a tile.
	for tile in (_slide.get("tiles", []) as Array):
		if (tile as Dictionary).get("id", "") == annotation_id:
			return false
	if not _include_substrate_annotations:
		return false
	var ok: bool = _SlideModel.remove_annotation(_slide, annotation_id)
	if ok:
		if _selected_id == annotation_id:
			_selected_id = ""
			selection_changed.emit("")
		annotations_changed.emit()
	return ok


## Track selection. Emits selection_changed ONLY when value actually changes
## (mirror Cad_AnnotationHost.gd:168-172 to avoid loops).
func set_selected_annotation_id(annotation_id: String) -> void:
	if _selected_id == annotation_id:
		return
	_selected_id = annotation_id
	selection_changed.emit(_selected_id)


func get_selected_annotation_id() -> String:
	return _selected_id


## Notify listeners that the slide changed externally (e.g., tile created via
## PLACE flow, tile deleted via Del key, background swapped). Used by slide_canvas
## after mutations that don't go through update/add/remove.
func notify_changed() -> void:
	annotations_changed.emit()


## No semantic anchoring on slides yet.
func describe_point(_doc_pos: Vector2) -> String:
	return ""

# ── Private helpers ────────────────────────────────────────────────────────

## Map a slide_model tile kind string to the corresponding annotation kind name.
## Returns "" for unknown kinds.
func _kind_for_tile(tile_kind: String) -> String:
	match tile_kind:
		_SlideModel.TILE_TEXT:
			return "presentation_tile_text"
		_SlideModel.TILE_IMAGE:
			return "presentation_tile_image"
		_SlideModel.TILE_SPREADSHEET:
			return "presentation_tile_spreadsheet"
	return ""


func _prune_stale_selection() -> void:
	if _selected_id.is_empty():
		return
	var found: bool = false
	if _include_tiles:
		for tile in (_slide.get("tiles", []) as Array):
			if (tile as Dictionary).get("id", "") == _selected_id:
				found = true
				break
	if not found and _include_substrate_annotations:
		for ann in (_slide.get("annotations", []) as Array):
			if (ann as Dictionary).get("id", "") == _selected_id:
				found = true
				break
	if not found:
		_selected_id = ""
		selection_changed.emit("")


## Write back a transformed tile annotation into the underlying tile dict.
## Reads rect_px and rotation_rad from new_annotation.kind_payload, normalizes
## by _slide_rect.size, and updates the tile via SlideModel mutators.
## Returns false if tile not found or slide_rect is degenerate.
func _writeback_tile(tile_id: String, new_ann: Dictionary) -> bool:
	if _slide_rect.size.x <= 0.0 or _slide_rect.size.y <= 0.0:
		return false
	var payload: Dictionary = (new_ann.get("kind_payload", {}) as Dictionary)
	var rect_px: Rect2 = payload.get("rect_px", Rect2())
	var rotation_rad: float = float(payload.get("rotation_rad", 0.0))
	var font_size: float = float(payload.get("font_size", 18.0))
	var size_v: Vector2 = _slide_rect.size
	var origin: Vector2 = _slide_rect.position
	# rect_px is canvas-local — subtract slide_rect origin before normalizing.
	var norm_x: float = (rect_px.position.x - origin.x) / size_v.x
	var norm_y: float = (rect_px.position.y - origin.y) / size_v.y
	var norm_w: float = rect_px.size.x / size_v.x
	var norm_h: float = rect_px.size.y / size_v.y
	# find_tile returns null if not found.
	var tile: Variant = _SlideModel.find_tile(_slide, tile_id)
	if tile == null:
		return false
	var t: Dictionary = tile as Dictionary
	t["x"] = clampf(norm_x, 0.0, 1.0)
	t["y"] = clampf(norm_y, 0.0, 1.0)
	t["w"] = clampf(norm_w, 0.0, 1.0)
	t["h"] = clampf(norm_h, 0.0, 1.0)
	var should_write_font_size: bool = bool(payload.get("font_size_explicit", t.has("font_size")))
	if str(t.get("kind", "")) == _SlideModel.TILE_TEXT and should_write_font_size:
		t["font_size"] = clampf(font_size, 8.0, 160.0)
	_SlideModel.set_tile_rotation(_slide, tile_id, rotation_rad)
	annotations_changed.emit()
	return true
