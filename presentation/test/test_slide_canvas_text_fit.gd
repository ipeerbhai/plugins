extends SceneTree
## Focused regression probe for text-tile shrink-to-fit rendering.
## Run: godot --headless --path ~/github/Minerva/src --script ~/github/plugins/presentation/test/test_slide_canvas_text_fit.gd

var CanvasScript: Script = load(OS.get_environment("HOME").path_join("github/plugins/presentation/ui/slide_canvas.gd"))
var SlideModel: Script = load(OS.get_environment("HOME").path_join("github/plugins/presentation/ui/slide_model.gd"))


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var canvas: Control = CanvasScript.new()
	var tile: Dictionary = SlideModel.make_text_tile(
		0.0,
		0.0,
		0.25,
		0.10,
		"Long bullet item text that should wrap into multiple rendered lines in a narrow text box\nSecond long bullet item that also wraps",
		SlideModel.TEXT_MODE_BULLET
	)
	var rtl: RichTextLabel = canvas._build_text_view(tile) as RichTextLabel
	get_root().add_child(rtl)

	var px := Rect2(Vector2.ZERO, Vector2(220.0, 80.0))
	rtl.size = px.size
	await process_frame

	var desired: int = canvas._desired_text_tile_font_px(tile, px)
	var fitted: int = canvas._compute_text_tile_font_px(tile, px, rtl)
	canvas._apply_rich_text_font_size(rtl, fitted)

	var content_h: float = float(rtl.get_content_height())
	var available_h: float = px.size.y * 0.95
	print("desired=%d fitted=%d content_h=%.2f available_h=%.2f" % [desired, fitted, content_h, available_h])
	if fitted > desired or fitted < 8 or content_h > available_h + 0.5:
		printerr("text shrink-to-fit did not fit wrapped content")
		quit(1)
		return
	quit(0)
