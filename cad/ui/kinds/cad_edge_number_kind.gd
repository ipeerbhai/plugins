extends AnnotationKind
## CAD plugin annotation kind: cad_edge_number.
##
## Phase B2 form: an edge-anchored callout. The annotation carries a
## cad/edge anchor envelope and a world-space text-box offset; the renderer
## resolves the anchor live (so re-evaluation does not strand the callout)
## and draws a leader + auto-wrapped text box ONLY in the perspective pane.
## Ortho panes already show silhouette + selected-edge highlight; a callout
## there would be redundant and visually collide with the projection.
##
## Envelope shape:
##   anchor:  {plugin: "cad", type: "edge", id: <int>}
##   payload:
##     text:        String  (optional, default "") — user instruction body
##     box_offset:  Array[3] world-space Vector3 components — leader_end =
##                  anchor_position + box_offset
##
## Position access: the renderer calls host._resolve_edge_anchor(anchor)
## directly to get the Vector3 midpoint. Substrate's host.resolve_anchor()
## flattens to Vector2, which is correct for substrate consumers but loses
## the depth needed to project both leader endpoints through Camera3D. This
## is plugin-internal; the resolver is in the same plugin as the kind.
##
## Stale rendering: when the resolver returns null or stale=true, the leader
## and box are drawn with reduced alpha. No CAD-specific stale icon — kept
## minimal until a substrate-wide convention exists.
##
## Off-tree note: this file lives at ~/github/plugins/cad/, outside Minerva's
## res:// tree. It MUST NOT declare a class_name. preload() is used by
## CADPanel.gd and tests to load this script.

## Authoring tool — loaded lazily so the tool script can itself preload base classes.
const _CadEdgeNumberToolScript: Script = preload("../tools/cad_edge_number_tool.gd")

## Per-frame screen-space spread layout, shared across render() calls.
const _LayoutHelper: Script = preload("./cad_edge_label_layout.gd")

# Visual constants — leader+box callout.
const _BOX_FILL := Color(0.08, 0.09, 0.11, 0.94)
const _BOX_STROKE := Color(0.55, 0.60, 0.68, 0.90)
const _TITLE_COLOR := Color(0.92, 0.94, 0.97, 1.0)
const _TEXT_COLOR := Color(0.86, 0.88, 0.92, 1.0)
const _LEADER_COLOR := Color(0.75, 0.80, 0.88, 0.85)
const _STALE_ALPHA: float = 0.35
const _TITLE_FONT_SIZE: int = 13
const _TEXT_FONT_SIZE: int = 12
const _BOX_PAD := Vector2(8.0, 6.0)
const _BOX_WIDTH: float = 200.0          # auto-wrap width incl. padding
const _LINE_SPACING: float = 2.0
const _ANCHOR_DOT_RADIUS: float = 3.5


func _init() -> void:
	name = &"cad_edge_number"
	display_name = "Edge Number"
	schema_version = 2
	owning_plugin = &"cad"
	primitives_optional = true
	default_payload = {"text": "", "box_offset": [0.0, 0.0, 0.0]}
	# Toolbar icon: small SVG with a numbered bubble + leader dot.
	# ImageTexture.create_from_image is not available in headless tests without
	# a display, so we guard with a null check.
	var icon_img := Image.new()
	var err := icon_img.load("res://../../plugins/cad/ui/icons/edge_number.svg")
	if err == OK and icon_img != null:
		toolbar_icon = ImageTexture.create_from_image(icon_img)


# ── Validation ────────────────────────────────────────────────────────────────

func validate(annotation: Dictionary) -> Array:
	var errors: Array = []

	var anchor: Variant = annotation.get("anchor", null)
	if not (anchor is Dictionary):
		errors.append({"field": "anchor", "message": "anchor dict is required"})
		return errors
	var anchor_d: Dictionary = anchor as Dictionary
	if str(anchor_d.get("plugin", "")) != "cad":
		errors.append({"field": "anchor.plugin", "message": "anchor.plugin must be 'cad'"})
	if str(anchor_d.get("type", "")) != "edge":
		errors.append({"field": "anchor.type", "message": "anchor.type must be 'edge'"})
	if not anchor_d.has("id"):
		errors.append({"field": "anchor.id", "message": "anchor.id is required"})
	else:
		var id_val: Variant = anchor_d["id"]
		if not (id_val is int or id_val is float):
			errors.append({"field": "anchor.id", "message": "anchor.id must be an integer"})

	var payload: Dictionary = annotation.get("payload", {})
	# payload.text is optional (defaults to ""); validate type when present.
	if payload.has("text") and not (payload["text"] is String):
		errors.append({"field": "payload.text", "message": "payload.text must be a string"})
	# payload.box_offset is optional (defaults to zero vector); validate when present.
	if payload.has("box_offset"):
		var off: Variant = payload["box_offset"]
		if not (off is Array) or (off as Array).size() != 3:
			errors.append({
				"field": "payload.box_offset",
				"message": "payload.box_offset must be an Array of 3 numbers",
			})

	return errors


# ── Required rendering ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var host: Variant = ctx.host if "host" in ctx else null
	if host == null:
		return
	if not host.has_method("get_panes"):
		return

	var anchor: Variant = _anchor_for_annotation(annotation)
	if not (anchor is Dictionary):
		return

	# Resolve anchor directly via the host's resolver to keep the Vector3.
	# Substrate's host.resolve_anchor() flattens to Vector2 (correct for
	# substrate consumers, wrong for our perspective Camera3D projection).
	if not host.has_method("_resolve_edge_anchor"):
		return
	var resolved: Variant = host._resolve_edge_anchor(anchor)
	if resolved == null:
		return
	if not (resolved is Dictionary):
		return
	var resolved_d: Dictionary = resolved as Dictionary

	var leader_start_world: Vector3 = resolved_d.get("position", Vector3.ZERO)
	var edge_id: int = int(resolved_d.get("edge_id", (anchor as Dictionary).get("id", -1)))
	var is_stale: bool = bool(resolved_d.get("stale", false))

	var payload: Dictionary = annotation.get("payload", {})
	var text: String = str(payload.get("text", payload.get("label", "")))
	var box_offset := _vec3_from_payload(payload.get("box_offset", [0.0, 0.0, 0.0]))
	var leader_end_world: Vector3 = leader_start_world + box_offset

	# Filter to the perspective pane only.
	var panes: Array = host.get_panes()
	for pane in panes:
		if not (pane is Dictionary):
			continue
		var camera: Variant = (pane as Dictionary).get("camera", null)
		if camera == null or not camera.has_method("unproject_position"):
			continue
		if camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
			continue

		var rect: Rect2 = (pane as Dictionary).get("viewport_rect", Rect2())
		var leader_start: Vector2 = camera.unproject_position(leader_start_world) + rect.position

		# Ask the layout helper for a per-frame, per-pane non-overlapping
		# screen position. Falls back to the legacy box_offset back-projection
		# when the helper has no entry for this edge_id (e.g. anchor failed
		# upstream or annotation list is being rebuilt).
		var leader_end: Vector2 = camera.unproject_position(leader_end_world) + rect.position
		if host.has_method("get_annotations"):
			var all_anns: Array = host.get_annotations()
			var layout: Dictionary = _LayoutHelper.get_layout(host, camera, rect, all_anns)
			if layout.has(edge_id):
				leader_end = layout[edge_id]
		_draw_leader_and_box(ctx, leader_start, leader_end, edge_id, text, is_stale)


func bounds(_annotation: Dictionary) -> Rect2:
	# Live-resolved anchor → bounds are not knowable at annotation-store time.
	# Substrate consumers fall back to other fields (summary, anchored_to).
	# Drag-time hit-testing uses the kind's own hit_test override below, which
	# resolves through the host's perspective camera + layout cache.
	return Rect2()


## Return the v2 cad/edge anchor for an annotation. Older agent-authored edge
## labels used payload.edge_id without an anchor; keep that shape renderable so
## live sessions created before the v2 migration do not silently disappear.
static func _anchor_for_annotation(annotation: Dictionary) -> Variant:
	var anchor: Variant = annotation.get("anchor", null)
	if anchor is Dictionary:
		return anchor
	var payload_v: Variant = annotation.get("payload", {})
	if payload_v is Dictionary and (payload_v as Dictionary).has("edge_id"):
		return {
			"plugin": "cad",
			"type": "edge",
			"id": int((payload_v as Dictionary).get("edge_id", -1)),
		}
	return null


# ── Drag-to-move (substrate AnnotationTranslateTool) ──────────────────────────
#
# The kind opts into drag-and-drop by overriding hit_test (does the cursor sit
# over a label box?) and transform_annotation (apply a screen-space delta to
# payload.box_offset). The tool layer dispatches; we don't manage drag state.
#
# Coordinate notes: CadAnnotationHost identity-maps doc↔screen, so the `point`
# substrate hands us is panel-root screen-space — the same frame the layout
# helper publishes positions in. We resolve the box's current screen position
# the same way render() does: layout helper for un-placed labels (auto-spread),
# raw payload.box_offset back-projection for user-placed ones.

func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var rect := _resolve_box_rect_screen(annotation)
	if rect.size == Vector2.ZERO:
		return false
	return rect.grow(threshold).has_point(point)


## Apply a screen-space transform to the label's text-box position. Sets
## payload.user_placed=true so the auto-spread layout treats this box as a
## fixed obstacle (other labels move around it; this one stays put).
func transform_annotation(
		annotation: Dictionary,
		transform: Transform2D,
		_operation: String = ""
) -> Dictionary:
	var ctx := _resolve_perspective_ctx_for_annotation(annotation)
	if ctx.is_empty():
		# No perspective camera + anchor available — leave annotation untouched.
		return annotation.duplicate(true)

	var camera: Camera3D = ctx["camera"]
	var rect: Rect2 = ctx["viewport_rect"]
	var anchor_world: Vector3 = ctx["anchor_world"]
	var current_box_screen: Vector2 = ctx["box_screen"]

	# Apply the screen-space delta. Transform2D from the translate tool is a
	# pure translation in panel-root space (origin = drag delta).
	var new_box_screen: Vector2 = transform * current_box_screen

	# Back-project to a world-space leader_end at the same camera depth as the
	# anchor. Same algorithm as cad_edge_number_tool._compute_default_box_offset
	# (kept inline rather than imported to avoid an extra preload cycle).
	var new_box_offset := _back_project_to_world_offset(camera, rect, anchor_world, new_box_screen)

	var out := annotation.duplicate(true)
	var payload_v: Variant = out.get("payload", {})
	var payload: Dictionary = payload_v.duplicate(true) if payload_v is Dictionary else {}
	payload["box_offset"] = [new_box_offset.x, new_box_offset.y, new_box_offset.z]
	payload["user_placed"] = true
	out["payload"] = payload
	return out


## Compute the on-screen rect for an annotation's text box, using the same
## resolution path render() uses. Returns Rect2() (zero size) when the box is
## not currently rendered (no perspective pane, anchor unresolvable, etc.) —
## callers should treat that as "not hittable".
func _resolve_box_rect_screen(annotation: Dictionary) -> Rect2:
	var ctx := _resolve_perspective_ctx_for_annotation(annotation)
	if ctx.is_empty():
		return Rect2()
	var center: Vector2 = ctx["box_screen"]
	# Use a conservative footprint covering the kind's actual draw size. The
	# real box can be larger when payload.text wraps to many lines, but the
	# title strip alone is enough for grab-handle hit-testing — and the
	# substrate caller adds its own threshold via grow().
	var size := Vector2(_BOX_WIDTH, 56.0)
	return Rect2(center - size * 0.5, size)


## Resolve the perspective pane + anchor + current box screen position for an
## annotation. Returns an empty Dictionary when any prerequisite is missing
## (no perspective camera, anchor not resolvable, host lacks methods).
##
## Returned keys: camera, viewport_rect, anchor_world, anchor_screen, box_screen.
func _resolve_perspective_ctx_for_annotation(annotation: Dictionary) -> Dictionary:
	var anchor: Variant = _anchor_for_annotation(annotation)
	if not (anchor is Dictionary):
		return {}
	# We need an AnnotationRenderContext-like host reference, but transform_/hit_
	# are called without a ctx — the substrate hands us only the annotation
	# itself. Reach the host via the static EditorRegistry so the kind can
	# self-resolve. Keeps the kind's interface compatible with the substrate
	# tool layer (which doesn't pass a ctx to manipulation calls).
	var host: Object = _find_host_for_annotation(annotation)
	if host == null:
		return {}
	if not host.has_method("get_panes") or not host.has_method("_resolve_edge_anchor"):
		return {}

	var resolved: Variant = host._resolve_edge_anchor(anchor)
	if not (resolved is Dictionary):
		return {}
	var resolved_d: Dictionary = resolved as Dictionary
	var anchor_world: Vector3 = resolved_d.get("position", Vector3.ZERO)
	var edge_id: int = int(resolved_d.get("edge_id", anchor.get("id", -1)))

	var panes: Array = host.get_panes()
	for pane in panes:
		if not (pane is Dictionary):
			continue
		var camera: Variant = (pane as Dictionary).get("camera", null)
		if camera == null or not (camera is Camera3D):
			continue
		var cam3 := camera as Camera3D
		if cam3.projection != Camera3D.PROJECTION_PERSPECTIVE:
			continue
		var rect: Rect2 = (pane as Dictionary).get("viewport_rect", Rect2())
		var anchor_screen: Vector2 = cam3.unproject_position(anchor_world) + rect.position

		# Determine current box screen position. user_placed labels: use
		# payload.box_offset directly (back-projected). Otherwise: ask the
		# layout helper, which is the source of truth for auto-spread.
		var payload: Dictionary = annotation.get("payload", {}) as Dictionary
		var user_placed: bool = bool(payload.get("user_placed", false))
		var box_screen: Vector2
		if user_placed:
			var box_offset := _vec3_from_payload(payload.get("box_offset", [0.0, 0.0, 0.0]))
			box_screen = cam3.unproject_position(anchor_world + box_offset) + rect.position
		else:
			var all_anns: Array = host.get_annotations() if host.has_method("get_annotations") else []
			var layout: Dictionary = _LayoutHelper.get_layout(host, cam3, rect, all_anns)
			if layout.has(edge_id):
				box_screen = layout[edge_id]
			else:
				var box_offset2 := _vec3_from_payload(payload.get("box_offset", [0.0, 0.0, 0.0]))
				box_screen = cam3.unproject_position(anchor_world + box_offset2) + rect.position

		return {
			"camera": cam3,
			"viewport_rect": rect,
			"anchor_world": anchor_world,
			"anchor_screen": anchor_screen,
			"box_screen": box_screen,
		}
	return {}


## Locate the AnnotationHost that owns this annotation. The substrate keeps
## annotations in a host's _annotations array; we walk the registry to find
## the one whose list contains this annotation's id. Returns null when the
## annotation is orphaned (never registered, or already removed).
static func _find_host_for_annotation(annotation: Dictionary) -> Object:
	var ann_id: String = str(annotation.get("id", ""))
	if ann_id == "":
		return null
	# AnnotationHostRegistry exposes list_editor_names() + get_host() only;
	# walk by name. Empty list when no panels are open — caller treats null
	# host as "drag is not currently possible," same as a freed panel.
	for editor_name in AnnotationHostRegistry.list_editor_names():
		var h: AnnotationHost = AnnotationHostRegistry.get_host(str(editor_name))
		if h == null or not h.has_method("get_annotations"):
			continue
		for a in h.get_annotations():
			if a is Dictionary and str((a as Dictionary).get("id", "")) == ann_id:
				return h
	return null


## Back-project a screen-space target point to a world-space offset relative
## to anchor_world, at the anchor's camera depth. Mirrors the algorithm in
## cad_edge_number_tool._compute_default_box_offset.
static func _back_project_to_world_offset(
		camera: Camera3D,
		viewport_rect: Rect2,
		anchor_world: Vector3,
		target_screen_panel: Vector2
) -> Vector3:
	var cam_origin: Vector3 = camera.global_transform.origin
	var look_dir: Vector3 = -camera.global_transform.basis.z.normalized()
	var depth: float = look_dir.dot(anchor_world - cam_origin)
	if depth < 0.001:
		return Vector3.ZERO
	# Translate panel-root screen back to viewport-local before project_ray_*.
	var target_local: Vector2 = target_screen_panel - viewport_rect.position
	var ray_origin: Vector3 = camera.project_ray_origin(target_local)
	var ray_dir: Vector3 = camera.project_ray_normal(target_local)
	var dz: float = look_dir.dot(ray_dir)
	if abs(dz) < 0.001:
		return Vector3.ZERO
	var t: float = (depth - look_dir.dot(ray_origin - cam_origin)) / dz
	var world_target: Vector3 = ray_origin + ray_dir * t
	return world_target - anchor_world


# ── author_ui ────────────────────────────────────────────────────────────────

## Returns a fresh cad_edge_number_tool instance so the AnnotationToolbar can
## activate click-to-add authoring. Each call returns a NEW instance to avoid
## stale state leaking across deactivate/reactivate cycles.
func author_ui() -> Object:
	return _CadEdgeNumberToolScript.new()


# ── Private drawing helpers ───────────────────────────────────────────────────

## Draw a leader from anchor_screen to box_screen, then a text box at box_screen
## with edge_id as title (top center) and `text` as body (auto-wrap at _BOX_WIDTH).
func _draw_leader_and_box(
	ctx: AnnotationRenderContext,
	anchor_screen: Vector2,
	box_screen: Vector2,
	edge_id: int,
	text: String,
	is_stale: bool
) -> void:
	var alpha: float = _STALE_ALPHA if is_stale else 1.0
	var leader_color := Color(_LEADER_COLOR.r, _LEADER_COLOR.g, _LEADER_COLOR.b, _LEADER_COLOR.a * alpha)
	var fill_color := Color(_BOX_FILL.r, _BOX_FILL.g, _BOX_FILL.b, _BOX_FILL.a * alpha)
	var stroke_color := Color(_BOX_STROKE.r, _BOX_STROKE.g, _BOX_STROKE.b, _BOX_STROKE.a * alpha)
	var title_color := Color(_TITLE_COLOR.r, _TITLE_COLOR.g, _TITLE_COLOR.b, _TITLE_COLOR.a * alpha)
	var text_color := Color(_TEXT_COLOR.r, _TEXT_COLOR.g, _TEXT_COLOR.b, _TEXT_COLOR.a * alpha)

	var font: Font = ThemeDB.fallback_font

	# Layout: title line + wrapped body lines. Box width fixed at _BOX_WIDTH.
	var title_text := str(edge_id)
	var content_w: float = _BOX_WIDTH - _BOX_PAD.x * 2.0
	var body_lines: PackedStringArray = _wrap_text(font, text, _TEXT_FONT_SIZE, content_w)

	var title_h: float = float(_TITLE_FONT_SIZE)
	var body_line_h: float = float(_TEXT_FONT_SIZE) + _LINE_SPACING
	var has_body := not body_lines.is_empty() and body_lines[0] != ""
	var content_h: float = title_h
	if has_body:
		content_h += _LINE_SPACING + body_line_h * float(body_lines.size()) - _LINE_SPACING
	var box_size := Vector2(_BOX_WIDTH, content_h + _BOX_PAD.y * 2.0)
	var box_rect := Rect2(box_screen - box_size * 0.5, box_size)

	# Leader: from anchor_screen to nearest edge of the box rect (clipped).
	var leader_target: Vector2 = _clip_point_to_rect(anchor_screen, box_rect)
	ctx.draw_line(anchor_screen, leader_target, leader_color, 1.2)
	_draw_anchor_dot(ctx, anchor_screen, leader_color)

	# Box.
	ctx.draw_rect(box_rect, fill_color, true)
	ctx.draw_rect(box_rect, stroke_color, false, 1.0)

	# Title (top-center).
	if font != null:
		var title_w: float = font.get_string_size(
			title_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _TITLE_FONT_SIZE
		).x
		var title_pos := Vector2(
			box_rect.position.x + (box_size.x - title_w) * 0.5,
			box_rect.position.y + _BOX_PAD.y + title_h - 2.0
		)
		ctx.draw_string(font, title_pos, title_text, title_color, _TITLE_FONT_SIZE)

		# Body lines (left-aligned under the title).
		if has_body:
			var y: float = box_rect.position.y + _BOX_PAD.y + title_h + _LINE_SPACING + body_line_h - 2.0
			for line in body_lines:
				var line_pos := Vector2(box_rect.position.x + _BOX_PAD.x, y)
				ctx.draw_string(font, line_pos, line, text_color, _TEXT_FONT_SIZE)
				y += body_line_h


func _draw_anchor_dot(ctx: AnnotationRenderContext, pos: Vector2, color: Color) -> void:
	var segments := 10
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	for i in range(segments):
		var angle := TAU * float(i) / float(segments)
		pts.append(pos + Vector2(cos(angle), sin(angle)) * _ANCHOR_DOT_RADIUS)
		cols.append(color)
	if pts.size() >= 3:
		ctx.draw_polygon(pts, cols)


## Word-wrap `text` to fit within `width` pixels. Returns one entry per line.
## Greedy algorithm: fills each line with as many whitespace-separated tokens
## as fit. A single token longer than `width` overflows on its own line.
static func _wrap_text(font: Font, text: String, font_size: int, width: float) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		out.append("")
		return out
	if font == null:
		out.append(text)
		return out
	var words: PackedStringArray = text.split(" ", false)
	var current := ""
	for word in words:
		var trial: String = word if current == "" else current + " " + word
		var trial_w: float = font.get_string_size(
			trial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size
		).x
		if trial_w <= width:
			current = trial
		else:
			if current != "":
				out.append(current)
			current = word
	if current != "":
		out.append(current)
	if out.is_empty():
		out.append("")
	return out


## Clip a point to the edge of a rect (for leader endpoint placement).
## When the point is outside the rect, returns the nearest point on the rect's
## border. When inside, returns the rect's center.
static func _clip_point_to_rect(p: Vector2, rect: Rect2) -> Vector2:
	if rect.has_point(p):
		return rect.get_center()
	var center := rect.get_center()
	var dir: Vector2 = (p - center)
	if dir.length_squared() < 0.0001:
		return center
	# Find intersection of the ray center→p with the rect border.
	var half := rect.size * 0.5
	var tx: float = INF
	if dir.x > 0.0001:
		tx = half.x / dir.x
	elif dir.x < -0.0001:
		tx = -half.x / dir.x
	var ty: float = INF
	if dir.y > 0.0001:
		ty = half.y / dir.y
	elif dir.y < -0.0001:
		ty = -half.y / dir.y
	var t: float = min(tx, ty)
	return center + dir * t


static func _vec3_from_payload(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		return Vector3(float((raw as Array)[0]), float((raw as Array)[1]), float((raw as Array)[2]))
	return Vector3.ZERO
