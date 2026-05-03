class_name Presentation_SlideModel
extends RefCounted
## Slide deck data model for the presentation plugin.
##
## Pure-data API: every "object" is a Dictionary. This file provides static
## constructors, validators, and lookups. Saved Dicts JSON-round-trip cleanly
## (no Resource subclasses, no recursive references).
##
## Naming follows project_plugin_class_name_prefix_rule.md — canonical prefix
## for plugin id "presentation" is "Presentation_".
##
## See project_plugin_host_owned_schema.md for the conventions this file
## mirrors (flat root, version=1, defensive .get() on load).

# ---------------------------------------------------------------------------
# Schema constants
# ---------------------------------------------------------------------------

const SCHEMA_VERSION: int = 1

const ASPECT_DEFAULT: String = "16:9"
const ASPECTS_VALID: PackedStringArray = ["16:9", "4:3", "1:1"]

const TILE_TEXT: String = "text"
const TILE_IMAGE: String = "image"
const TILE_SPREADSHEET: String = "spreadsheet"
const TILE_KINDS_VALID: PackedStringArray = [TILE_TEXT, TILE_IMAGE, TILE_SPREADSHEET]

const TEXT_MODE_PLAIN: String = "plain"
const TEXT_MODE_BULLET: String = "bullet"
const TEXT_MODE_NUMBERED: String = "numbered"
const TEXT_MODES_VALID: PackedStringArray = [TEXT_MODE_PLAIN, TEXT_MODE_BULLET, TEXT_MODE_NUMBERED]

const BG_COLOR: String = "color"
const BG_IMAGE: String = "image"
const BG_KINDS_VALID: PackedStringArray = [BG_COLOR, BG_IMAGE]

const BG_DEFAULT: Dictionary = {"kind": "color", "value": "#ffffff"}

# Cell types mirror SpreadsheetCell.CellType (singleton_object peers expect these ints).
const CELL_EMPTY: int = 0
const CELL_TEXT: int = 1
const CELL_NUMBER: int = 2
const CELL_DATE: int = 3
const CELL_FORMULA: int = 4

# ---------------------------------------------------------------------------
# Constructors — return plain Dictionaries
# ---------------------------------------------------------------------------

## Empty deck with one blank slide. Always-valid starting state.
static func make_deck() -> Dictionary:
	return {
		"version": SCHEMA_VERSION,
		"aspect": ASPECT_DEFAULT,
		"slides": [make_slide()],
	}


## Empty slide. `title` is optional and only surfaces in JSON when set —
## per project_presentation_llm_edit_model.md, it's used for LLM list_slides
## summaries and the slide-list UI panel (T3). Speaker notes are NOT a field;
## per-slide ink annotations cover that use case via the substrate.
## `annotations` is optional; omitted from the dict when empty (omit-when-default).
static func make_slide(slide_id: String = "", title: String = "", annotations: Array = []) -> Dictionary:
	var s: Dictionary = {
		"id": slide_id if slide_id != "" else gen_id("slide"),
		"background": BG_DEFAULT.duplicate(true),
		"tiles": [],
		"reveal": [],
	}
	if title != "":
		s["title"] = title
	if not annotations.is_empty():
		s["annotations"] = annotations
	return s


## Set or clear a slide title (omit-when-default — empty title removes the key).
static func set_slide_title(slide: Dictionary, title: String) -> void:
	if title == "":
		slide.erase("title")
	else:
		slide["title"] = title


static func make_text_tile(
	x: float = 0.1,
	y: float = 0.1,
	w: float = 0.4,
	h: float = 0.2,
	content: String = "",
	text_mode: String = TEXT_MODE_PLAIN,
	rotation: float = 0.0
) -> Dictionary:
	var t: Dictionary = {
		"id": gen_id("tile"),
		"kind": TILE_TEXT,
		"x": x, "y": y, "w": w, "h": h,
		"text_mode": text_mode,
		"content": content,
	}
	if not is_zero_approx(rotation):
		t["rotation"] = rotation
	return t


static func make_image_tile(
	src_base64: String,
	x: float = 0.1,
	y: float = 0.1,
	w: float = 0.4,
	h: float = 0.4,
	rotation: float = 0.0
) -> Dictionary:
	var t: Dictionary = {
		"id": gen_id("tile"),
		"kind": TILE_IMAGE,
		"x": x, "y": y, "w": w, "h": h,
		"src": src_base64,
	}
	if not is_zero_approx(rotation):
		t["rotation"] = rotation
	return t


static func make_spreadsheet_tile(
	rows: int,
	cols: int,
	cells: Array = [],
	x: float = 0.1,
	y: float = 0.1,
	w: float = 0.6,
	h: float = 0.3,
	header_row: bool = false,
	header_col: bool = false,
	rotation: float = 0.0
) -> Dictionary:
	# If caller didn't supply cells, build an empty rows×cols grid.
	var grid: Array = cells if cells.size() > 0 else _empty_cell_grid(rows, cols)
	var t: Dictionary = {
		"id": gen_id("tile"),
		"kind": TILE_SPREADSHEET,
		"x": x, "y": y, "w": w, "h": h,
		"rows": rows,
		"cols": cols,
		"cells": grid,
		"header_row": header_row,
		"header_col": header_col,
	}
	if not is_zero_approx(rotation):
		t["rotation"] = rotation
	return t


## Cell dict mirroring SpreadsheetCell.to_dict() — empty by default; extra
## keys (bold, italic, alignment, text_color, bg_color, formula, etc.) only
## set when non-default. Pass formatting/extras via `extras` to merge them in;
## keeps cells small and round-trips with the editor.
static func make_cell(value: Variant = "", cell_type: int = CELL_EMPTY, extras: Dictionary = {}) -> Dictionary:
	var c: Dictionary = {"value": value, "type": cell_type}
	for k in extras.keys():
		c[k] = extras[k]
	return c


# ---------------------------------------------------------------------------
# Validation — return Array of human-readable error strings; empty = valid.
# ---------------------------------------------------------------------------

static func validate_deck(deck: Variant) -> Array:
	var errors: Array = []
	if not (deck is Dictionary):
		return ["deck: not a Dictionary"]
	var d: Dictionary = deck

	if d.get("version", null) != SCHEMA_VERSION:
		errors.append("deck.version: expected %d, got %s" % [SCHEMA_VERSION, str(d.get("version", null))])

	var aspect: Variant = d.get("aspect", null)
	if not (aspect is String) or not ASPECTS_VALID.has(aspect):
		errors.append("deck.aspect: expected one of %s, got %s" % [str(ASPECTS_VALID), str(aspect)])

	var slides: Variant = d.get("slides", null)
	if not (slides is Array):
		errors.append("deck.slides: not an Array")
		return errors

	var seen_slide_ids: Dictionary = {}
	for i in range(slides.size()):
		var slide_errors: Array = validate_slide(slides[i])
		for e in slide_errors:
			errors.append("slides[%d].%s" % [i, e])
		if slides[i] is Dictionary:
			var sid: Variant = (slides[i] as Dictionary).get("id", null)
			if sid is String:
				if seen_slide_ids.has(sid):
					errors.append("slides[%d].id: duplicate '%s'" % [i, sid])
				seen_slide_ids[sid] = true

	return errors


static func validate_slide(slide: Variant) -> Array:
	var errors: Array = []
	if not (slide is Dictionary):
		return ["slide: not a Dictionary"]
	var s: Dictionary = slide

	var sid: Variant = s.get("id", null)
	if not (sid is String) or (sid as String).is_empty():
		errors.append("id: missing or non-string")

	# title is optional; if present, must be a String.
	if s.has("title") and not (s["title"] is String):
		errors.append("title: expected String when present")

	var bg: Variant = s.get("background", null)
	if bg != null:
		var bg_errors: Array = validate_background(bg)
		for e in bg_errors:
			errors.append("background.%s" % e)

	var tiles: Variant = s.get("tiles", null)
	if not (tiles is Array):
		errors.append("tiles: not an Array")
	else:
		var seen_tile_ids: Dictionary = {}
		for i in range(tiles.size()):
			var tile_errors: Array = validate_tile(tiles[i])
			for e in tile_errors:
				errors.append("tiles[%d].%s" % [i, e])
			if tiles[i] is Dictionary:
				var tid: Variant = (tiles[i] as Dictionary).get("id", null)
				if tid is String:
					if seen_tile_ids.has(tid):
						errors.append("tiles[%d].id: duplicate '%s'" % [i, tid])
					seen_tile_ids[tid] = true

	var reveal: Variant = s.get("reveal", null)
	if not (reveal is Array):
		errors.append("reveal: not an Array")
	else:
		for r_idx in range((reveal as Array).size()):
			if not ((reveal as Array)[r_idx] is String):
				errors.append("reveal[%d]: expected String annotation id" % r_idx)

	# annotations is optional; if present, must be Array of Dictionary.
	if s.has("annotations"):
		var ann: Variant = s["annotations"]
		if not (ann is Array):
			errors.append("annotations: expected Array, got %s" % str(ann))
		else:
			for a_idx in range((ann as Array).size()):
				if not ((ann as Array)[a_idx] is Dictionary):
					errors.append("annotations[%d]: expected Dictionary" % a_idx)

	return errors


static func validate_background(bg: Variant) -> Array:
	var errors: Array = []
	if not (bg is Dictionary):
		return ["not a Dictionary"]
	var b: Dictionary = bg
	var kind: Variant = b.get("kind", null)
	if not (kind is String) or not BG_KINDS_VALID.has(kind):
		errors.append("kind: expected one of %s, got %s" % [str(BG_KINDS_VALID), str(kind)])
	var value: Variant = b.get("value", null)
	if not (value is String):
		errors.append("value: expected String, got %s" % str(value))
	elif kind == BG_IMAGE and (value as String).is_empty():
		errors.append("value: image background requires non-empty base64")
	return errors


static func validate_tile(tile: Variant) -> Array:
	var errors: Array = []
	if not (tile is Dictionary):
		return ["tile: not a Dictionary"]
	var t: Dictionary = tile

	var tid: Variant = t.get("id", null)
	if not (tid is String) or (tid as String).is_empty():
		errors.append("id: missing or non-string")

	var kind: Variant = t.get("kind", null)
	if not (kind is String) or not TILE_KINDS_VALID.has(kind):
		errors.append("kind: expected one of %s, got %s" % [str(TILE_KINDS_VALID), str(kind)])
		return errors  # Can't validate the rest without a known kind.

	# Coords: 0..1 normalized, slide-relative.
	for axis in ["x", "y", "w", "h"]:
		var v: Variant = t.get(axis, null)
		if not (v is float or v is int):
			errors.append("%s: expected number, got %s" % [axis, str(v)])
		else:
			var fv: float = float(v)
			if fv < 0.0 or fv > 1.0:
				errors.append("%s: out of [0,1], got %f" % [axis, fv])

	# rotation is optional; if present must be int or float (JSON round-trip may
	# deliver whole-number floats for integer values).
	if t.has("rotation"):
		var rotation_v: Variant = t["rotation"]
		if not (rotation_v is int or rotation_v is float):
			errors.append("rotation: expected int or float, got %s" % str(rotation_v))

	match kind:
		TILE_TEXT:
			var mode: Variant = t.get("text_mode", null)
			if not (mode is String) or not TEXT_MODES_VALID.has(mode):
				errors.append("text_mode: expected one of %s, got %s" % [str(TEXT_MODES_VALID), str(mode)])
			if not (t.get("content", null) is String):
				errors.append("content: expected String")
		TILE_IMAGE:
			var src: Variant = t.get("src", null)
			if not (src is String) or (src as String).is_empty():
				errors.append("src: expected non-empty String (base64)")
		TILE_SPREADSHEET:
			# Accept int OR whole-number float — JSON.parse() returns all numbers
			# as float, so a round-tripped {rows:2} arrives as 2.0. Reject 2.5.
			var rows: int = _coerce_positive_int(t.get("rows", null))
			var cols: int = _coerce_positive_int(t.get("cols", null))
			if rows < 1:
				errors.append("rows: expected positive integer, got %s" % str(t.get("rows", null)))
			if cols < 1:
				errors.append("cols: expected positive integer, got %s" % str(t.get("cols", null)))
			var cells: Variant = t.get("cells", null)
			if not (cells is Array):
				errors.append("cells: expected Array")
			elif rows >= 1 and cols >= 1:
				if (cells as Array).size() != rows:
					errors.append("cells: row count %d != rows=%d" % [(cells as Array).size(), rows])
				else:
					for r_idx in range((cells as Array).size()):
						var row: Variant = (cells as Array)[r_idx]
						if not (row is Array):
							errors.append("cells[%d]: not an Array" % r_idx)
						elif (row as Array).size() != cols:
							errors.append("cells[%d]: col count %d != cols=%d" % [r_idx, (row as Array).size(), cols])
	return errors


# ---------------------------------------------------------------------------
# Mutators
# ---------------------------------------------------------------------------

static func add_slide(deck: Dictionary, slide: Dictionary) -> void:
	(deck["slides"] as Array).append(slide)


static func remove_slide(deck: Dictionary, slide_id: String) -> bool:
	var slides: Array = deck.get("slides", []) as Array
	for i in range(slides.size()):
		var s: Dictionary = slides[i]
		if s.get("id", "") == slide_id:
			slides.remove_at(i)
			return true
	return false


static func find_slide(deck: Dictionary, slide_id: String) -> Variant:
	for s in deck.get("slides", []) as Array:
		if (s as Dictionary).get("id", "") == slide_id:
			return s
	return null


static func find_tile(slide: Dictionary, tile_id: String) -> Variant:
	for t in slide.get("tiles", []) as Array:
		if (t as Dictionary).get("id", "") == tile_id:
			return t
	return null


static func move_tile(slide: Dictionary, tile_id: String, x: float, y: float) -> bool:
	var t: Variant = find_tile(slide, tile_id)
	if t == null:
		return false
	(t as Dictionary)["x"] = clampf(x, 0.0, 1.0)
	(t as Dictionary)["y"] = clampf(y, 0.0, 1.0)
	return true


static func resize_tile(slide: Dictionary, tile_id: String, w: float, h: float) -> bool:
	var t: Variant = find_tile(slide, tile_id)
	if t == null:
		return false
	(t as Dictionary)["w"] = clampf(w, 0.0, 1.0)
	(t as Dictionary)["h"] = clampf(h, 0.0, 1.0)
	return true


static func set_tile_rotation(slide: Dictionary, tile_id: String, rotation: float) -> bool:
	var t: Variant = find_tile(slide, tile_id)
	if t == null:
		return false
	if is_zero_approx(rotation):
		(t as Dictionary).erase("rotation")
	else:
		(t as Dictionary)["rotation"] = rotation
	return true


## Append an annotation envelope to slide.annotations[].
## Creates the key if absent. Envelope must have a non-empty "id" string.
## Returns true on success, false if envelope id is missing or empty.
static func add_annotation(slide: Dictionary, envelope: Dictionary) -> bool:
	var env_id: Variant = envelope.get("id", "")
	if not (env_id is String) or (env_id as String).is_empty():
		return false
	if not slide.has("annotations"):
		slide["annotations"] = []
	(slide["annotations"] as Array).append(envelope)
	return true


## Replace the annotation with the given id in slide.annotations[].
## Forces new_envelope["id"] = annotation_id regardless of what was passed.
## Returns false if annotation_id is not found.
static func update_annotation(slide: Dictionary, annotation_id: String, new_envelope: Dictionary) -> bool:
	var anns: Array = slide.get("annotations", []) as Array
	for i in range(anns.size()):
		var a: Dictionary = anns[i] as Dictionary
		if a.get("id", "") == annotation_id:
			new_envelope["id"] = annotation_id
			anns[i] = new_envelope
			return true
	return false


## Remove the annotation with the given id from slide.annotations[].
## If removal empties the array, deletes the "annotations" key entirely
## (preserves omit-when-default invariant).
## Returns false if annotation_id is not found.
static func remove_annotation(slide: Dictionary, annotation_id: String) -> bool:
	if not slide.has("annotations"):
		return false
	var anns: Array = slide["annotations"] as Array
	for i in range(anns.size()):
		var a: Dictionary = anns[i] as Dictionary
		if a.get("id", "") == annotation_id:
			anns.remove_at(i)
			if anns.is_empty():
				slide.erase("annotations")
			return true
	return false


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Generate an ID like "slide_1714723200_a1b2_42" (prefix + unix-second +
## per-session 16-bit hex seed + monotonic counter).
##
## Within a session: counter is monotonic and never collides.
## Across sessions: session seed is a fresh 16-bit random, so two sessions
## starting in the same second still get different IDs.
##
## A pure-random suffix would hit birthday-paradox collisions at ~200 calls;
## the counter eliminates that without giving up cross-session uniqueness.
static var _id_counter: int = 0
static var _id_seed: int = -1

static func gen_id(prefix: String) -> String:
	if _id_seed < 0:
		_id_seed = randi() & 0xffff
	_id_counter += 1
	var ts: int = int(Time.get_unix_time_from_system())
	return "%s_%d_%04x_%d" % [prefix, ts, _id_seed, _id_counter]


## Coerce a Variant to a positive int, returning -1 on failure. Accepts int
## or whole-number float (per JSON round-trip — see project_godot_json_int_to_float.md).
static func _coerce_positive_int(v: Variant) -> int:
	if v is int:
		return int(v) if int(v) >= 1 else -1
	if v is float and float(v) == int(v) and float(v) >= 1.0:
		return int(v)
	return -1


static func _empty_cell_grid(rows: int, cols: int) -> Array:
	var grid: Array = []
	for _r in range(rows):
		var row: Array = []
		for _c in range(cols):
			row.append(make_cell())
		grid.append(row)
	return grid
