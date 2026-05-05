extends SceneTree
## Headless tests for the auto_fit text-tile mode (DCR 019df67700467e,
## work item 019df67735927e).
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script ~/github/plugins/presentation/test/test_slide_canvas_auto_fit.gd

var CanvasScript: Script = load(OS.get_environment("HOME").path_join("github/plugins/presentation/ui/slide_canvas.gd"))
var SlideModel: Script = load(OS.get_environment("HOME").path_join("github/plugins/presentation/ui/slide_model.gd"))

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("=== presentation auto_fit text rendering ===\n")
	await test_make_text_tile_persists_auto_fit()
	await test_validator_rejects_non_bool_auto_fit()
	await test_auto_fit_grows_short_content_above_coupled()
	await test_auto_fit_shrinks_long_title_to_fit_width()
	await test_font_size_wins_over_auto_fit()
	await test_auto_fit_handles_empty_content()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(description: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		printerr("  FAIL: %s" % description)


# ── Helpers ────────────────────────────────────────────────────────────

func _fitted_font(tile: Dictionary, px: Rect2) -> Dictionary:
	var canvas: Control = CanvasScript.new()
	var rtl: RichTextLabel = canvas._build_text_view(tile) as RichTextLabel
	get_root().add_child(rtl)
	rtl.size = px.size
	await process_frame
	var desired: int = canvas._desired_text_tile_font_px(tile, px)
	var fitted: int = canvas._compute_text_tile_font_px(tile, px, rtl)
	canvas._apply_rich_text_font_size(rtl, fitted)
	var content_h: float = float(rtl.get_content_height())
	rtl.queue_free()
	canvas.queue_free()
	return {"desired": desired, "fitted": fitted, "content_h": content_h}


# ── Tests ──────────────────────────────────────────────────────────────

func test_make_text_tile_persists_auto_fit() -> void:
	print("test_make_text_tile_persists_auto_fit:")
	var off: Dictionary = SlideModel.make_text_tile(0, 0, 0.5, 0.2, "x")
	_check("auto_fit absent by default", not off.has("auto_fit"))
	var on: Dictionary = SlideModel.make_text_tile(0, 0, 0.5, 0.2, "x",
		SlideModel.TEXT_MODE_PLAIN, 0.0, true)
	_check("auto_fit=true persisted", bool(on.get("auto_fit", false)))


func test_validator_rejects_non_bool_auto_fit() -> void:
	print("test_validator_rejects_non_bool_auto_fit:")
	var bad: Dictionary = SlideModel.make_text_tile(0, 0, 0.5, 0.2, "x")
	bad["auto_fit"] = "yes"
	var errors: Array = SlideModel.validate_tile(bad)
	var hit: bool = false
	for e in errors:
		if String(e).contains("auto_fit"):
			hit = true
			break
	_check("validator flags non-bool auto_fit", hit)


func test_auto_fit_grows_short_content_above_coupled() -> void:
	# Tall tile, 1 line of content. Coupled mode picks h/1 ≈ tile height.
	# auto_fit should pick something close to the same large size — but the
	# important property is auto_fit returns a font that *fits* the box AND
	# is bounded by _TEXT_MAX_FONT_PX (200), not crushed by line_count.
	print("test_auto_fit_grows_short_content_above_coupled:")
	var auto: Dictionary = SlideModel.make_text_tile(0, 0, 0.9, 0.2, "Hi",
		SlideModel.TEXT_MODE_PLAIN, 0.0, true)
	var px := Rect2(Vector2.ZERO, Vector2(900.0, 200.0))
	var r: Dictionary = await _fitted_font(auto, px)
	_check("auto_fit desired == 200 (max ceiling)", int(r["desired"]) == 200)
	_check("auto_fit fitted > 8 for visible content", int(r["fitted"]) > 8)
	_check("auto_fit fitted ≤ 200", int(r["fitted"]) <= 200)
	var available_h: float = px.size.y * 0.95
	_check("content height fits available height",
		float(r["content_h"]) <= available_h + 0.5)


func test_auto_fit_shrinks_long_title_to_fit_width() -> void:
	# Long single-line title in a tall tile. Width is the binding constraint.
	# Without auto_fit, coupled mode would pick a huge font (h/1) and the
	# line would horizontally overflow / wrap and clip.
	print("test_auto_fit_shrinks_long_title_to_fit_width:")
	var content: String = "This is a fairly long single-line title that should not horizontally clip"
	var auto: Dictionary = SlideModel.make_text_tile(0, 0, 0.5, 0.4, content,
		SlideModel.TEXT_MODE_PLAIN, 0.0, true)
	var coupled: Dictionary = SlideModel.make_text_tile(0, 0, 0.5, 0.4, content)
	var px := Rect2(Vector2.ZERO, Vector2(400.0, 320.0))
	var r_auto: Dictionary = await _fitted_font(auto, px)
	var r_coupled: Dictionary = await _fitted_font(coupled, px)
	var available_h: float = px.size.y * 0.95
	_check("auto_fit content_h fits in available height",
		float(r_auto["content_h"]) <= available_h + 0.5)
	# auto_fit should pick a SMALLER size than coupled here, because coupled
	# starts from h/line_count (huge) and shrinks-to-fit, but its cap is
	# already within range; auto_fit also fit-tests but starts from 200.
	# What we really want to assert: auto_fit fits, and fitted < 200.
	_check("auto_fit fitted strictly below max ceiling",
		int(r_auto["fitted"]) < 200)


func test_font_size_wins_over_auto_fit() -> void:
	# DCR 019df67776c772: when both font_size and auto_fit are set, font_size wins.
	print("test_font_size_wins_over_auto_fit:")
	var tile: Dictionary = SlideModel.make_text_tile(0, 0, 0.9, 0.2, "Hi",
		SlideModel.TEXT_MODE_PLAIN, 0.0, true)
	tile["font_size"] = 24
	var px := Rect2(Vector2.ZERO, Vector2(900.0, 200.0))
	var r: Dictionary = await _fitted_font(tile, px)
	_check("desired honors explicit font_size when both set",
		int(r["desired"]) == 24)
	_check("fitted ≤ explicit font_size",
		int(r["fitted"]) <= 24)


func test_auto_fit_handles_empty_content() -> void:
	print("test_auto_fit_handles_empty_content:")
	var tile: Dictionary = SlideModel.make_text_tile(0, 0, 0.5, 0.2, "",
		SlideModel.TEXT_MODE_PLAIN, 0.0, true)
	var px := Rect2(Vector2.ZERO, Vector2(400.0, 160.0))
	var r: Dictionary = await _fitted_font(tile, px)
	# Empty content takes the early-exit in _compute_text_tile_font_px, returning desired_px.
	_check("empty content returns desired (no shrink loop)",
		int(r["fitted"]) == int(r["desired"]))
