extends SceneTree
## Unit tests for slide_model.gd (Presentation_SlideModel).
## Run: godot --headless --path ~/github/Minerva/src --script ~/github/plugins/presentation/test/test_slide_model.gd
##
## Coverage:
##   Constructors: deck/slide/text/image/spreadsheet/cell shapes & defaults
##   Validation: every error branch (missing fields, type errors, range, dupes)
##   Mutators: add/remove/find slide; find/move/resize tile
##   Title field: optional, omit-when-default, set/clear semantics
##   Round-trip: deck → JSON → deck preserves structure
##   IDs: gen_id uniqueness across rapid calls

const SlideModel: Script = preload("/Users/ipeerbhai/github/plugins/presentation/ui/slide_model.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Presentation Slide Model Tests ===\n")

	test_make_deck_default_shape()
	test_make_slide_default_shape()
	test_make_slide_with_explicit_id_and_title()
	test_make_text_tile_defaults()
	test_make_image_tile_requires_src()
	test_make_spreadsheet_tile_default_grid()
	test_make_spreadsheet_tile_with_provided_cells()
	test_make_cell_default_empty()

	test_validate_deck_happy()
	test_validate_deck_wrong_version()
	test_validate_deck_bad_aspect()
	test_validate_deck_slides_not_array()
	test_validate_deck_duplicate_slide_ids()
	test_validate_slide_missing_id()
	test_validate_slide_title_wrong_type()
	test_validate_slide_duplicate_tile_ids()
	test_validate_background_bad_kind()
	test_validate_tile_unknown_kind()
	test_validate_tile_coords_out_of_range()
	test_validate_tile_coords_wrong_type()
	test_validate_text_tile_bad_mode()
	test_validate_text_tile_non_string_content()
	test_validate_image_tile_missing_src()
	test_validate_spreadsheet_tile_dimension_mismatch()
	test_validate_spreadsheet_tile_negative_dims()

	test_add_slide()
	test_remove_slide_happy()
	test_remove_slide_missing_returns_false()
	test_find_slide_happy_and_missing()
	test_find_tile_happy_and_missing()
	test_move_tile_clamps()
	test_resize_tile_clamps()
	test_set_slide_title_set_and_clear()

	test_roundtrip_deck_via_json()
	test_gen_id_uniqueness()

	# Cold-review coverage gaps.
	test_make_cell_with_extras()
	test_validate_background_non_dict()
	test_validate_slide_tiles_not_array()
	test_validate_slide_reveal_not_array_and_bad_element()
	test_validate_tile_non_dict()
	test_validate_spreadsheet_row_not_array()
	test_validate_background_image_kind_empty_value()

	## tile.rotation field
	test_rotation_text_tile_no_arg()
	test_rotation_text_tile_zero()
	test_rotation_text_tile_nonzero()
	test_rotation_image_tile_no_arg()
	test_rotation_image_tile_zero()
	test_rotation_image_tile_nonzero()
	test_rotation_spreadsheet_tile_no_arg()
	test_rotation_spreadsheet_tile_zero()
	test_rotation_spreadsheet_tile_nonzero()
	test_validate_tile_rotation_absent()
	test_validate_tile_rotation_float()
	test_validate_tile_rotation_whole_number_float()
	test_validate_tile_rotation_int()
	test_validate_tile_rotation_rejects_string()
	test_validate_tile_rotation_rejects_array()
	test_set_tile_rotation_writes_value()
	test_set_tile_rotation_zero_removes_key()
	test_set_tile_rotation_unknown_id_returns_false()
	test_rotation_json_roundtrip()

	## slide.annotations[] field
	test_annotations_make_slide_no_arg()
	test_annotations_make_slide_empty_array()
	test_annotations_make_slide_with_envelopes()
	test_validate_slide_accepts_missing_annotations()
	test_validate_slide_accepts_empty_annotations_array()
	test_validate_slide_accepts_annotations_array_of_dicts()
	test_validate_slide_rejects_annotations_non_array()
	test_validate_slide_rejects_annotations_array_with_non_dict()
	test_add_annotation_appends_and_second_call()
	test_add_annotation_rejects_missing_or_empty_id()
	test_update_annotation_replaces_by_id()
	test_update_annotation_forces_id_match()
	test_update_annotation_unknown_id_returns_false()
	test_remove_annotation_removes_by_id()
	test_remove_annotation_unknown_id_returns_false()
	test_remove_annotation_last_deletes_key()
	test_annotations_json_roundtrip()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ──────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Constructor tests ──────────────────────────────────────────────────────

func test_make_deck_default_shape() -> void:
	print("test_make_deck_default_shape:")
	var d: Dictionary = SlideModel.make_deck()
	check_eq("version is SCHEMA_VERSION", d.get("version", -1), SlideModel.SCHEMA_VERSION)
	check_eq("aspect is default", d.get("aspect", ""), SlideModel.ASPECT_DEFAULT)
	var slides: Array = d.get("slides", []) as Array
	check_eq("starts with one slide", slides.size(), 1)
	check("default deck validates", SlideModel.validate_deck(d).is_empty())


func test_make_slide_default_shape() -> void:
	print("test_make_slide_default_shape:")
	var s: Dictionary = SlideModel.make_slide()
	check("id present", s.get("id", "") != "")
	check("background is default color", (s["background"] as Dictionary)["kind"] == SlideModel.BG_COLOR)
	check_eq("tiles is empty", (s["tiles"] as Array).size(), 0)
	check_eq("reveal is empty", (s["reveal"] as Array).size(), 0)
	check("no title key when not provided", not s.has("title"))


func test_make_slide_with_explicit_id_and_title() -> void:
	print("test_make_slide_with_explicit_id_and_title:")
	var s: Dictionary = SlideModel.make_slide("slide_42", "Q4 Revenue")
	check_eq("explicit id used", s["id"], "slide_42")
	check_eq("title set", s["title"], "Q4 Revenue")


func test_make_text_tile_defaults() -> void:
	print("test_make_text_tile_defaults:")
	var t: Dictionary = SlideModel.make_text_tile()
	check_eq("kind", t["kind"], SlideModel.TILE_TEXT)
	check_eq("text_mode default", t["text_mode"], SlideModel.TEXT_MODE_PLAIN)
	check_eq("content default empty", t["content"], "")
	check("validates", SlideModel.validate_tile(t).is_empty())


func test_make_image_tile_requires_src() -> void:
	print("test_make_image_tile_requires_src:")
	var t: Dictionary = SlideModel.make_image_tile("dGVzdA==")
	check_eq("kind", t["kind"], SlideModel.TILE_IMAGE)
	check_eq("src round-trips", t["src"], "dGVzdA==")
	check("validates with src", SlideModel.validate_tile(t).is_empty())
	# Empty src should fail validation.
	var t_bad: Dictionary = SlideModel.make_image_tile("")
	check("empty src fails validate_tile", not SlideModel.validate_tile(t_bad).is_empty())


func test_make_spreadsheet_tile_default_grid() -> void:
	print("test_make_spreadsheet_tile_default_grid:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 3)
	check_eq("kind", t["kind"], SlideModel.TILE_SPREADSHEET)
	check_eq("rows", t["rows"], 2)
	check_eq("cols", t["cols"], 3)
	var cells: Array = t["cells"] as Array
	check_eq("cells row count", cells.size(), 2)
	check_eq("cells col count row 0", (cells[0] as Array).size(), 3)
	check_eq("cell 0,0 is empty", (cells[0][0] as Dictionary)["type"], SlideModel.CELL_EMPTY)
	check("validates", SlideModel.validate_tile(t).is_empty())


func test_make_spreadsheet_tile_with_provided_cells() -> void:
	print("test_make_spreadsheet_tile_with_provided_cells:")
	var custom: Array = [
		[SlideModel.make_cell("A", SlideModel.CELL_TEXT), SlideModel.make_cell("B", SlideModel.CELL_TEXT)],
		[SlideModel.make_cell(1.0, SlideModel.CELL_NUMBER), SlideModel.make_cell(2.0, SlideModel.CELL_NUMBER)],
	]
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 2, custom)
	check_eq("custom cells preserved", (t["cells"][0][0] as Dictionary)["value"], "A")
	check_eq("number cell type", (t["cells"][1][0] as Dictionary)["type"], SlideModel.CELL_NUMBER)
	check("validates", SlideModel.validate_tile(t).is_empty())


func test_make_cell_default_empty() -> void:
	print("test_make_cell_default_empty:")
	var c: Dictionary = SlideModel.make_cell()
	check_eq("default value", c["value"], "")
	check_eq("default type EMPTY", c["type"], SlideModel.CELL_EMPTY)
	# No formatting keys present by default (omit-when-default).
	check("no bold key by default", not c.has("bold"))
	check("no italic key by default", not c.has("italic"))


# ── Validation tests ───────────────────────────────────────────────────────

func test_validate_deck_happy() -> void:
	print("test_validate_deck_happy:")
	var d: Dictionary = SlideModel.make_deck()
	check("freshly-made deck validates", SlideModel.validate_deck(d).is_empty())


func test_validate_deck_wrong_version() -> void:
	print("test_validate_deck_wrong_version:")
	var d: Dictionary = SlideModel.make_deck()
	d["version"] = 99
	var errs: Array = SlideModel.validate_deck(d)
	check("version error reported", errs.size() > 0)
	check("error mentions version", str(errs).contains("version"))


func test_validate_deck_bad_aspect() -> void:
	print("test_validate_deck_bad_aspect:")
	var d: Dictionary = SlideModel.make_deck()
	d["aspect"] = "9:16"
	var errs: Array = SlideModel.validate_deck(d)
	check("aspect error reported", str(errs).contains("aspect"))


func test_validate_deck_slides_not_array() -> void:
	print("test_validate_deck_slides_not_array:")
	var d: Dictionary = SlideModel.make_deck()
	d["slides"] = "not an array"
	var errs: Array = SlideModel.validate_deck(d)
	check("slides type error reported", str(errs).contains("slides"))


func test_validate_deck_duplicate_slide_ids() -> void:
	print("test_validate_deck_duplicate_slide_ids:")
	var d: Dictionary = SlideModel.make_deck()
	var s2: Dictionary = SlideModel.make_slide()
	s2["id"] = (d["slides"][0] as Dictionary)["id"]   # force collision
	(d["slides"] as Array).append(s2)
	var errs: Array = SlideModel.validate_deck(d)
	check("duplicate id error reported", str(errs).contains("duplicate"))


func test_validate_slide_missing_id() -> void:
	print("test_validate_slide_missing_id:")
	var s: Dictionary = SlideModel.make_slide()
	s.erase("id")
	var errs: Array = SlideModel.validate_slide(s)
	check("id error reported", str(errs).contains("id"))


func test_validate_slide_title_wrong_type() -> void:
	print("test_validate_slide_title_wrong_type:")
	var s: Dictionary = SlideModel.make_slide()
	s["title"] = 42
	var errs: Array = SlideModel.validate_slide(s)
	check("title type error reported", str(errs).contains("title"))


func test_validate_slide_duplicate_tile_ids() -> void:
	print("test_validate_slide_duplicate_tile_ids:")
	var s: Dictionary = SlideModel.make_slide()
	var t1: Dictionary = SlideModel.make_text_tile()
	var t2: Dictionary = SlideModel.make_text_tile()
	t2["id"] = t1["id"]
	(s["tiles"] as Array).append(t1)
	(s["tiles"] as Array).append(t2)
	var errs: Array = SlideModel.validate_slide(s)
	check("duplicate tile id error reported", str(errs).contains("duplicate"))


func test_validate_background_bad_kind() -> void:
	print("test_validate_background_bad_kind:")
	var bg: Dictionary = {"kind": "video", "value": ""}
	var errs: Array = SlideModel.validate_background(bg)
	check("bad bg kind error", str(errs).contains("kind"))


func test_validate_tile_unknown_kind() -> void:
	print("test_validate_tile_unknown_kind:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["kind"] = "video"
	var errs: Array = SlideModel.validate_tile(t)
	check("unknown kind error", str(errs).contains("kind"))


func test_validate_tile_coords_out_of_range() -> void:
	print("test_validate_tile_coords_out_of_range:")
	var t: Dictionary = SlideModel.make_text_tile(1.5, 0.0, 0.5, 0.5)
	var errs: Array = SlideModel.validate_tile(t)
	check("out-of-range x reported", str(errs).contains("x"))
	var t2: Dictionary = SlideModel.make_text_tile(0.0, -0.1, 0.5, 0.5)
	check("negative y reported", str(SlideModel.validate_tile(t2)).contains("y"))


func test_validate_tile_coords_wrong_type() -> void:
	print("test_validate_tile_coords_wrong_type:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["x"] = "0.5"
	var errs: Array = SlideModel.validate_tile(t)
	check("wrong-type x reported", str(errs).contains("x"))


func test_validate_text_tile_bad_mode() -> void:
	print("test_validate_text_tile_bad_mode:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["text_mode"] = "checklist"
	var errs: Array = SlideModel.validate_tile(t)
	check("bad text_mode reported", str(errs).contains("text_mode"))


func test_validate_text_tile_non_string_content() -> void:
	print("test_validate_text_tile_non_string_content:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["content"] = 99
	var errs: Array = SlideModel.validate_tile(t)
	check("non-string content reported", str(errs).contains("content"))


func test_validate_image_tile_missing_src() -> void:
	print("test_validate_image_tile_missing_src:")
	var t: Dictionary = SlideModel.make_image_tile("abc")
	t.erase("src")
	var errs: Array = SlideModel.validate_tile(t)
	check("missing src reported", str(errs).contains("src"))


func test_validate_spreadsheet_tile_dimension_mismatch() -> void:
	print("test_validate_spreadsheet_tile_dimension_mismatch:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(3, 3)
	# Truncate one row.
	(t["cells"] as Array).pop_back()
	var errs: Array = SlideModel.validate_tile(t)
	check("row count mismatch reported", str(errs).contains("row count"))

	var t2: Dictionary = SlideModel.make_spreadsheet_tile(2, 4)
	((t2["cells"] as Array)[0] as Array).pop_back()
	var errs2: Array = SlideModel.validate_tile(t2)
	check("col count mismatch reported", str(errs2).contains("col count"))


func test_validate_spreadsheet_tile_negative_dims() -> void:
	print("test_validate_spreadsheet_tile_negative_dims:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 2)
	t["rows"] = 0
	var errs: Array = SlideModel.validate_tile(t)
	check("zero rows reported", str(errs).contains("rows"))


# ── Mutator tests ──────────────────────────────────────────────────────────

func test_add_slide() -> void:
	print("test_add_slide:")
	var d: Dictionary = SlideModel.make_deck()
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_slide(d, s)
	check_eq("deck now has 2 slides", (d["slides"] as Array).size(), 2)
	check("still validates", SlideModel.validate_deck(d).is_empty())


func test_remove_slide_happy() -> void:
	print("test_remove_slide_happy:")
	var d: Dictionary = SlideModel.make_deck()
	var s: Dictionary = SlideModel.make_slide("toremove")
	SlideModel.add_slide(d, s)
	var removed: bool = SlideModel.remove_slide(d, "toremove")
	check("returned true", removed)
	check_eq("back to 1 slide", (d["slides"] as Array).size(), 1)


func test_remove_slide_missing_returns_false() -> void:
	print("test_remove_slide_missing_returns_false:")
	var d: Dictionary = SlideModel.make_deck()
	check("missing slide returns false", not SlideModel.remove_slide(d, "nope"))


func test_find_slide_happy_and_missing() -> void:
	print("test_find_slide_happy_and_missing:")
	var d: Dictionary = SlideModel.make_deck()
	var sid: String = (d["slides"][0] as Dictionary)["id"]
	check("found by id", SlideModel.find_slide(d, sid) != null)
	check("missing returns null", SlideModel.find_slide(d, "nope") == null)


func test_find_tile_happy_and_missing() -> void:
	print("test_find_tile_happy_and_missing:")
	var s: Dictionary = SlideModel.make_slide()
	var t: Dictionary = SlideModel.make_text_tile()
	(s["tiles"] as Array).append(t)
	check("found by id", SlideModel.find_tile(s, t["id"]) != null)
	check("missing returns null", SlideModel.find_tile(s, "nope") == null)


func test_move_tile_clamps() -> void:
	print("test_move_tile_clamps:")
	var s: Dictionary = SlideModel.make_slide()
	var t: Dictionary = SlideModel.make_text_tile()
	(s["tiles"] as Array).append(t)
	SlideModel.move_tile(s, t["id"], 1.5, -0.2)   # both out-of-range
	check_eq("x clamped to 1.0", t["x"], 1.0)
	check_eq("y clamped to 0.0", t["y"], 0.0)


func test_resize_tile_clamps() -> void:
	print("test_resize_tile_clamps:")
	var s: Dictionary = SlideModel.make_slide()
	var t: Dictionary = SlideModel.make_text_tile()
	(s["tiles"] as Array).append(t)
	SlideModel.resize_tile(s, t["id"], 2.0, 0.3)
	check_eq("w clamped to 1.0", t["w"], 1.0)
	check_eq("h preserved at 0.3", t["h"], 0.3)


func test_set_slide_title_set_and_clear() -> void:
	print("test_set_slide_title_set_and_clear:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.set_slide_title(s, "Hello")
	check_eq("title set", s.get("title", ""), "Hello")
	SlideModel.set_slide_title(s, "")
	check("empty title removes the key", not s.has("title"))


# ── Round-trip + ID tests ──────────────────────────────────────────────────

func test_roundtrip_deck_via_json() -> void:
	print("test_roundtrip_deck_via_json:")
	var d: Dictionary = SlideModel.make_deck()
	var s: Dictionary = SlideModel.make_slide("s1", "T1")
	(s["tiles"] as Array).append(SlideModel.make_text_tile(0.1, 0.2, 0.3, 0.4, "[b]hi[/b]", SlideModel.TEXT_MODE_BULLET))
	(s["tiles"] as Array).append(SlideModel.make_image_tile("Zm9v"))
	(s["tiles"] as Array).append(SlideModel.make_spreadsheet_tile(2, 2))
	SlideModel.add_slide(d, s)

	var json_str: String = JSON.stringify(d)
	var parser: JSON = JSON.new()
	var rc: int = parser.parse(json_str)
	check_eq("JSON parses", rc, OK)
	var d2: Variant = parser.data
	check("round-trip is Dictionary", d2 is Dictionary)
	check("round-trip validates", SlideModel.validate_deck(d2 as Dictionary).is_empty())
	check_eq("slide count preserved", ((d2 as Dictionary)["slides"] as Array).size(), 2)


func test_make_cell_with_extras() -> void:
	print("test_make_cell_with_extras:")
	var c: Dictionary = SlideModel.make_cell("Hello", SlideModel.CELL_TEXT, {"bold": true, "alignment": 1})
	check_eq("value preserved", c["value"], "Hello")
	check_eq("type preserved", c["type"], SlideModel.CELL_TEXT)
	check_eq("bold merged", c["bold"], true)
	check_eq("alignment merged", c["alignment"], 1)


func test_validate_background_non_dict() -> void:
	print("test_validate_background_non_dict:")
	var errs: Array = SlideModel.validate_background("color")
	check("non-Dict bg reports error", errs.size() > 0)


func test_validate_slide_tiles_not_array() -> void:
	print("test_validate_slide_tiles_not_array:")
	var s: Dictionary = SlideModel.make_slide()
	s["tiles"] = "oops"
	var errs: Array = SlideModel.validate_slide(s)
	check("tiles type error reported", str(errs).contains("tiles"))


func test_validate_slide_reveal_not_array_and_bad_element() -> void:
	print("test_validate_slide_reveal_not_array_and_bad_element:")
	var s1: Dictionary = SlideModel.make_slide()
	s1["reveal"] = "oops"
	var errs1: Array = SlideModel.validate_slide(s1)
	check("non-Array reveal reported", str(errs1).contains("reveal"))

	var s2: Dictionary = SlideModel.make_slide()
	(s2["reveal"] as Array).append(42)   # bad element
	var errs2: Array = SlideModel.validate_slide(s2)
	check("non-String reveal element reported", str(errs2).contains("reveal[0]"))


func test_validate_tile_non_dict() -> void:
	print("test_validate_tile_non_dict:")
	var errs: Array = SlideModel.validate_tile("not a tile")
	check("non-Dict tile reports error", errs.size() > 0)


func test_validate_spreadsheet_row_not_array() -> void:
	print("test_validate_spreadsheet_row_not_array:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 2)
	(t["cells"] as Array)[0] = "not a row"   # row entry should be Array
	var errs: Array = SlideModel.validate_tile(t)
	check("non-Array row reported", str(errs).contains("cells[0]"))


func test_validate_background_image_kind_empty_value() -> void:
	print("test_validate_background_image_kind_empty_value:")
	var bg: Dictionary = {"kind": SlideModel.BG_IMAGE, "value": ""}
	var errs: Array = SlideModel.validate_background(bg)
	check("empty image bg value reported", str(errs).contains("non-empty"))


func test_gen_id_uniqueness() -> void:
	print("test_gen_id_uniqueness:")
	# Generate 200 ids in a tight loop (same wall-second very likely);
	# duplicates would surface a bad RNG seed or low-entropy suffix.
	var seen: Dictionary = {}
	var collisions: int = 0
	for i in range(200):
		var id: String = SlideModel.gen_id("x")
		if seen.has(id):
			collisions += 1
		seen[id] = true
	check_eq("no collisions across 200 calls", collisions, 0)


# ── tile.rotation field ────────────────────────────────────────────────────

func test_rotation_text_tile_no_arg() -> void:
	print("test_rotation_text_tile_no_arg:")
	var t: Dictionary = SlideModel.make_text_tile()
	check("no rotation key when arg omitted", not t.has("rotation"))


func test_rotation_text_tile_zero() -> void:
	print("test_rotation_text_tile_zero:")
	var t: Dictionary = SlideModel.make_text_tile(0.1, 0.1, 0.4, 0.2, "", SlideModel.TEXT_MODE_PLAIN, 0.0)
	check("no rotation key when 0.0", not t.has("rotation"))


func test_rotation_text_tile_nonzero() -> void:
	print("test_rotation_text_tile_nonzero:")
	var t: Dictionary = SlideModel.make_text_tile(0.1, 0.1, 0.4, 0.2, "", SlideModel.TEXT_MODE_PLAIN, 1.5)
	check("rotation key present when non-zero", t.has("rotation"))
	check_eq("rotation value correct", t["rotation"], 1.5)


func test_rotation_image_tile_no_arg() -> void:
	print("test_rotation_image_tile_no_arg:")
	var t: Dictionary = SlideModel.make_image_tile("dGVzdA==")
	check("no rotation key when arg omitted", not t.has("rotation"))


func test_rotation_image_tile_zero() -> void:
	print("test_rotation_image_tile_zero:")
	var t: Dictionary = SlideModel.make_image_tile("dGVzdA==", 0.1, 0.1, 0.4, 0.4, 0.0)
	check("no rotation key when 0.0", not t.has("rotation"))


func test_rotation_image_tile_nonzero() -> void:
	print("test_rotation_image_tile_nonzero:")
	var t: Dictionary = SlideModel.make_image_tile("dGVzdA==", 0.1, 0.1, 0.4, 0.4, 1.5)
	check("rotation key present when non-zero", t.has("rotation"))
	check_eq("rotation value correct", t["rotation"], 1.5)


func test_rotation_spreadsheet_tile_no_arg() -> void:
	print("test_rotation_spreadsheet_tile_no_arg:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 2)
	check("no rotation key when arg omitted", not t.has("rotation"))


func test_rotation_spreadsheet_tile_zero() -> void:
	print("test_rotation_spreadsheet_tile_zero:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 2, [], 0.1, 0.1, 0.6, 0.3, false, false, 0.0)
	check("no rotation key when 0.0", not t.has("rotation"))


func test_rotation_spreadsheet_tile_nonzero() -> void:
	print("test_rotation_spreadsheet_tile_nonzero:")
	var t: Dictionary = SlideModel.make_spreadsheet_tile(2, 2, [], 0.1, 0.1, 0.6, 0.3, false, false, 1.5)
	check("rotation key present when non-zero", t.has("rotation"))
	check_eq("rotation value correct", t["rotation"], 1.5)


func test_validate_tile_rotation_absent() -> void:
	print("test_validate_tile_rotation_absent:")
	var t: Dictionary = SlideModel.make_text_tile()
	check("validates without rotation key", SlideModel.validate_tile(t).is_empty())


func test_validate_tile_rotation_float() -> void:
	print("test_validate_tile_rotation_float:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["rotation"] = 1.5
	check("validates with float rotation", SlideModel.validate_tile(t).is_empty())


func test_validate_tile_rotation_whole_number_float() -> void:
	print("test_validate_tile_rotation_whole_number_float:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["rotation"] = 0.0
	check("validates with 0.0 float rotation", SlideModel.validate_tile(t).is_empty())
	t["rotation"] = 2.0
	check("validates with 2.0 float rotation", SlideModel.validate_tile(t).is_empty())


func test_validate_tile_rotation_int() -> void:
	print("test_validate_tile_rotation_int:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["rotation"] = 0
	check("validates with int 0 rotation", SlideModel.validate_tile(t).is_empty())
	t["rotation"] = 2
	check("validates with int 2 rotation", SlideModel.validate_tile(t).is_empty())


func test_validate_tile_rotation_rejects_string() -> void:
	print("test_validate_tile_rotation_rejects_string:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["rotation"] = "0.5"
	var errs: Array = SlideModel.validate_tile(t)
	check("rejects string rotation", not errs.is_empty())
	check("error mentions rotation", str(errs).contains("rotation"))


func test_validate_tile_rotation_rejects_array() -> void:
	print("test_validate_tile_rotation_rejects_array:")
	var t: Dictionary = SlideModel.make_text_tile()
	t["rotation"] = [1.5]
	var errs: Array = SlideModel.validate_tile(t)
	check("rejects array rotation", not errs.is_empty())
	check("error mentions rotation", str(errs).contains("rotation"))


func test_set_tile_rotation_writes_value() -> void:
	print("test_set_tile_rotation_writes_value:")
	var s: Dictionary = SlideModel.make_slide()
	var t: Dictionary = SlideModel.make_text_tile()
	(s["tiles"] as Array).append(t)
	var ok: bool = SlideModel.set_tile_rotation(s, t["id"], 45.0)
	check("returns true for known tile", ok)
	check("rotation key written", t.has("rotation"))
	check_eq("rotation value correct", t["rotation"], 45.0)


func test_set_tile_rotation_zero_removes_key() -> void:
	print("test_set_tile_rotation_zero_removes_key:")
	var s: Dictionary = SlideModel.make_slide()
	var t: Dictionary = SlideModel.make_text_tile(0.1, 0.1, 0.4, 0.2, "", SlideModel.TEXT_MODE_PLAIN, 45.0)
	(s["tiles"] as Array).append(t)
	check("rotation key present before clear", t.has("rotation"))
	var ok: bool = SlideModel.set_tile_rotation(s, t["id"], 0.0)
	check("returns true", ok)
	check("rotation key removed after set to 0.0", not t.has("rotation"))


func test_set_tile_rotation_unknown_id_returns_false() -> void:
	print("test_set_tile_rotation_unknown_id_returns_false:")
	var s: Dictionary = SlideModel.make_slide()
	var ok: bool = SlideModel.set_tile_rotation(s, "nonexistent_id", 45.0)
	check("returns false for unknown tile_id", not ok)


func test_rotation_json_roundtrip() -> void:
	print("test_rotation_json_roundtrip:")
	var d: Dictionary = SlideModel.make_deck()
	var s: Dictionary = SlideModel.make_slide("s_rot")
	var t: Dictionary = SlideModel.make_text_tile(0.1, 0.1, 0.4, 0.2, "hello", SlideModel.TEXT_MODE_PLAIN, 45.0)
	(s["tiles"] as Array).append(t)
	SlideModel.add_slide(d, s)

	var json_str: String = JSON.stringify(d)
	var parser: JSON = JSON.new()
	var rc: int = parser.parse(json_str)
	check_eq("JSON parses", rc, OK)
	var d2: Dictionary = parser.data as Dictionary
	var errs: Array = SlideModel.validate_deck(d2)
	check("round-trip deck validates", errs.is_empty())
	# Find the rotated tile in the round-tripped deck.
	var s2: Variant = SlideModel.find_slide(d2, "s_rot")
	check("slide found in round-trip", s2 != null)
	if s2 != null:
		var tiles2: Array = (s2 as Dictionary).get("tiles", []) as Array
		check("one tile in round-trip slide", tiles2.size() == 1)
		if tiles2.size() == 1:
			var t2: Dictionary = tiles2[0] as Dictionary
			check("rotation key preserved", t2.has("rotation"))
			check_eq("rotation value preserved", float(t2.get("rotation", 0.0)), 45.0)


# ── slide.annotations[] field ─────────────────────────────────────────────

func test_annotations_make_slide_no_arg() -> void:
	print("test_annotations_make_slide_no_arg:")
	var s: Dictionary = SlideModel.make_slide()
	check("no annotations key when arg omitted", not s.has("annotations"))


func test_annotations_make_slide_empty_array() -> void:
	print("test_annotations_make_slide_empty_array:")
	var s: Dictionary = SlideModel.make_slide("", "", [])
	check("no annotations key when empty array passed", not s.has("annotations"))


func test_annotations_make_slide_with_envelopes() -> void:
	print("test_annotations_make_slide_with_envelopes:")
	var env: Dictionary = {"id": "a", "kind": "callout"}
	var s: Dictionary = SlideModel.make_slide("", "", [env])
	check("annotations key present", s.has("annotations"))
	var anns: Array = s["annotations"] as Array
	check_eq("one annotation stored", anns.size(), 1)
	check_eq("envelope id preserved", (anns[0] as Dictionary).get("id", ""), "a")
	check_eq("envelope kind preserved", (anns[0] as Dictionary).get("kind", ""), "callout")


func test_validate_slide_accepts_missing_annotations() -> void:
	print("test_validate_slide_accepts_missing_annotations:")
	var s: Dictionary = SlideModel.make_slide()
	check("no annotations key", not s.has("annotations"))
	check("validates without annotations", SlideModel.validate_slide(s).is_empty())


func test_validate_slide_accepts_empty_annotations_array() -> void:
	print("test_validate_slide_accepts_empty_annotations_array:")
	var s: Dictionary = SlideModel.make_slide()
	s["annotations"] = []
	check("validates with empty annotations array", SlideModel.validate_slide(s).is_empty())


func test_validate_slide_accepts_annotations_array_of_dicts() -> void:
	print("test_validate_slide_accepts_annotations_array_of_dicts:")
	var s: Dictionary = SlideModel.make_slide()
	s["annotations"] = [{"id": "x", "kind": "arrow"}, {"id": "y", "kind": "callout"}]
	check("validates with array of dicts", SlideModel.validate_slide(s).is_empty())


func test_validate_slide_rejects_annotations_non_array() -> void:
	print("test_validate_slide_rejects_annotations_non_array:")
	var s_str: Dictionary = SlideModel.make_slide()
	s_str["annotations"] = "not an array"
	check("rejects string annotations", not SlideModel.validate_slide(s_str).is_empty())
	check("error mentions annotations (string)", str(SlideModel.validate_slide(s_str)).contains("annotations"))

	var s_int: Dictionary = SlideModel.make_slide()
	s_int["annotations"] = 42
	check("rejects int annotations", not SlideModel.validate_slide(s_int).is_empty())
	check("error mentions annotations (int)", str(SlideModel.validate_slide(s_int)).contains("annotations"))

	var s_dict: Dictionary = SlideModel.make_slide()
	s_dict["annotations"] = {"id": "x"}
	check("rejects dict annotations", not SlideModel.validate_slide(s_dict).is_empty())
	check("error mentions annotations (dict)", str(SlideModel.validate_slide(s_dict)).contains("annotations"))


func test_validate_slide_rejects_annotations_array_with_non_dict() -> void:
	print("test_validate_slide_rejects_annotations_array_with_non_dict:")
	var s: Dictionary = SlideModel.make_slide()
	s["annotations"] = [{"id": "x"}, "not a dict", 99]
	var errs: Array = SlideModel.validate_slide(s)
	check("rejects array with non-dict elements", not errs.is_empty())
	check("error mentions annotations[1]", str(errs).contains("annotations[1]"))


func test_add_annotation_appends_and_second_call() -> void:
	print("test_add_annotation_appends_and_second_call:")
	var s: Dictionary = SlideModel.make_slide()
	var env1: Dictionary = {"id": "ann1", "kind": "callout"}
	var ok1: bool = SlideModel.add_annotation(s, env1)
	check("first add returns true", ok1)
	check("annotations key created", s.has("annotations"))
	check_eq("one annotation after first add", (s["annotations"] as Array).size(), 1)

	var env2: Dictionary = {"id": "ann2", "kind": "arrow"}
	var ok2: bool = SlideModel.add_annotation(s, env2)
	check("second add returns true", ok2)
	check_eq("two annotations after second add", (s["annotations"] as Array).size(), 2)
	check_eq("second envelope id correct", ((s["annotations"] as Array)[1] as Dictionary).get("id", ""), "ann2")


func test_add_annotation_rejects_missing_or_empty_id() -> void:
	print("test_add_annotation_rejects_missing_or_empty_id:")
	var s: Dictionary = SlideModel.make_slide()
	var env_no_id: Dictionary = {"kind": "callout"}
	check("rejects envelope with no id key", not SlideModel.add_annotation(s, env_no_id))
	check("no annotations key after rejection", not s.has("annotations"))

	var env_empty_id: Dictionary = {"id": "", "kind": "callout"}
	check("rejects envelope with empty id", not SlideModel.add_annotation(s, env_empty_id))
	check("no annotations key after rejection (empty id)", not s.has("annotations"))


func test_update_annotation_replaces_by_id() -> void:
	print("test_update_annotation_replaces_by_id:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout", "text": "old"})
	var new_env: Dictionary = {"id": "ann1", "kind": "arrow", "text": "new"}
	var ok: bool = SlideModel.update_annotation(s, "ann1", new_env)
	check("update returns true", ok)
	var stored: Dictionary = (s["annotations"] as Array)[0] as Dictionary
	check_eq("kind updated", stored.get("kind", ""), "arrow")
	check_eq("text updated", stored.get("text", ""), "new")


func test_update_annotation_forces_id_match() -> void:
	print("test_update_annotation_forces_id_match:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout"})
	# Pass envelope with a DIFFERENT id — update should force it to match annotation_id.
	var new_env: Dictionary = {"id": "wrong_id", "kind": "arrow"}
	SlideModel.update_annotation(s, "ann1", new_env)
	var stored: Dictionary = (s["annotations"] as Array)[0] as Dictionary
	check_eq("id forced to annotation_id", stored.get("id", ""), "ann1")


func test_update_annotation_unknown_id_returns_false() -> void:
	print("test_update_annotation_unknown_id_returns_false:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout"})
	var ok: bool = SlideModel.update_annotation(s, "nonexistent", {"id": "nonexistent", "kind": "arrow"})
	check("returns false for unknown id", not ok)
	check_eq("array unchanged (still 1)", (s["annotations"] as Array).size(), 1)


func test_remove_annotation_removes_by_id() -> void:
	print("test_remove_annotation_removes_by_id:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout"})
	SlideModel.add_annotation(s, {"id": "ann2", "kind": "arrow"})
	var ok: bool = SlideModel.remove_annotation(s, "ann1")
	check("remove returns true", ok)
	check_eq("one annotation remains", (s["annotations"] as Array).size(), 1)
	check_eq("remaining annotation is ann2", ((s["annotations"] as Array)[0] as Dictionary).get("id", ""), "ann2")


func test_remove_annotation_unknown_id_returns_false() -> void:
	print("test_remove_annotation_unknown_id_returns_false:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout"})
	var ok: bool = SlideModel.remove_annotation(s, "nonexistent")
	check("returns false for unknown id", not ok)
	check_eq("array unchanged (still 1)", (s["annotations"] as Array).size(), 1)


func test_remove_annotation_last_deletes_key() -> void:
	print("test_remove_annotation_last_deletes_key:")
	var s: Dictionary = SlideModel.make_slide()
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout"})
	check("annotations key present before remove", s.has("annotations"))
	var ok: bool = SlideModel.remove_annotation(s, "ann1")
	check("remove returns true", ok)
	check("annotations key deleted after last removal (omit-when-empty)", not s.has("annotations"))


func test_annotations_json_roundtrip() -> void:
	print("test_annotations_json_roundtrip:")
	var d: Dictionary = SlideModel.make_deck()
	var s: Dictionary = SlideModel.make_slide("s_ann")
	SlideModel.add_annotation(s, {"id": "ann1", "kind": "callout", "text": "hello"})
	SlideModel.add_annotation(s, {"id": "ann2", "kind": "arrow"})
	SlideModel.add_slide(d, s)

	var json_str: String = JSON.stringify(d)
	var parser: JSON = JSON.new()
	var rc: int = parser.parse(json_str)
	check_eq("JSON parses", rc, OK)
	var d2: Dictionary = parser.data as Dictionary
	var errs: Array = SlideModel.validate_deck(d2)
	check("round-trip deck validates", errs.is_empty())

	var s2: Variant = SlideModel.find_slide(d2, "s_ann")
	check("annotated slide found in round-trip", s2 != null)
	if s2 != null:
		var anns2: Array = (s2 as Dictionary).get("annotations", []) as Array
		check_eq("two annotations preserved", anns2.size(), 2)
		check_eq("first annotation id preserved", (anns2[0] as Dictionary).get("id", ""), "ann1")
		check_eq("first annotation kind preserved", (anns2[0] as Dictionary).get("kind", ""), "callout")
		check_eq("second annotation id preserved", (anns2[1] as Dictionary).get("id", ""), "ann2")
