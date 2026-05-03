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

const SlideModel: Script = preload("/home/imran/github/plugins/presentation/ui/slide_model.gd")

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
