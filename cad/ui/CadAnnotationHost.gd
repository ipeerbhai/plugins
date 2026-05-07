class_name Cad_AnnotationHost
extends AnnotationHost

const _CadAnchorTypesScript = preload("scripts/CadAnchorTypes.gd")
## AnnotationHost for the CAD plugin panel (Round 1 scaffold).
##
## Follows the canonical pattern established by Helloscene_AnnotationHost
## (hello_scene plugin). For Round 1, document↔screen transforms are IDENTITY
## just like hello_scene. The real transforms — mapping 3-D SubViewport pixel
## coordinates back to document/world space — are a later grandchild.
##
## class_name prefix "Cad" = canonical_prefix("cad")
## per design §6.1: plugin_id.replace("_","").lower() → first-upper.
##
## ── Four-canvas-per-host wiring (future grandchild note) ──────────────────
## The long-term design is one Cad_AnnotationHost per panel owning FOUR
## annotation canvases, one per SubViewportContainer (Top, Front, Right, Iso).
## Each canvas passes its viewport_id when calling host methods so the host can
## apply the correct camera projection. The intended API is:
##
##   set_active_viewport(viewport_id: String)
##   transform_doc_to_viewport_screen(p: Vector2, viewport_id: String) -> Vector2
##
## Both are stubbed below. The canvas would call
##   host.transform_doc_to_viewport_screen(doc_pt, "top")
## and draw at the returned screen-space point.
##
## Annotation envelopes embed get_view_context() = "cad:<viewport_id>" so the
## MCP layer knows which view an annotation was authored in.
##
## describe_point() substrate convention (future grandchild):
##   "mesh.edge:<N>"          — point projects onto named edge N
##   "mesh.face:<N>"          — point projects onto named face N
##   "world.plane:<x>,<y>,<z>" — point in 3-D world space on the working plane
##   ""                        — nothing meaningful at this point
## Resolution requires: camera unproject → ray → BVH/edge proximity query.

## Emitted whenever the annotation list mutates (add, update, remove, bulk replace).
signal annotations_changed()

# ── Internal state ─────────────────────────────────────────────────────────

## Registry shared with the toolbar.
var _registry: AnnotationRegistry = null

## Flat list of all annotation envelope dicts.
var _annotations: Array = []  # Array[Dictionary]

## Currently selected annotation id, or "".
var _selected_id: String = ""

## Active viewport id for per-view authoring (e.g. "top", "front", "right", "iso").
## Set by set_active_viewport(); used by get_view_context() and future transforms.
var _active_viewport_id: String = "iso"

## Currently selected edge id (set by EdgeOverlay → CADPanel). -1 = none.
## Exposed via get_selected_edge_id() so MCP queries can read it.
var _selected_edge_id: int = -1

## Map of view_id -> SubViewport node, populated by CADPanel._ready() via
## set_viewport_for(). Untyped-value Dict because Dictionary value types are
## not enforced and SubViewport has no off-tree resolution issue but we keep
## it loose for symmetry with the rest of the off-tree contract.
var _viewport_for: Dictionary = {}

## Map of view_id -> Camera3D, populated by CADPanel._ready() via
## set_camera_for(). Used by get_panes() so cad_edge_number_kind can project
## a 3-D world point into each pane's screen-space.
var _camera_for: Dictionary = {}

## Ordered list of pane ids (wide mode: the 4 standard CAD views).
## Used by get_panes() to return panes in stable order.
const WIDE_PANE_IDS: PackedStringArray = ["iso", "top", "front", "right"]

## Cache of last captured Image keyed by view_id. Invalidated when
## set_active_viewport() changes the active id, or when the cached frame
## number no longer matches the engine's current frame.
var _capture_cache: Dictionary = {}     # view_id -> Image
var _capture_cache_frame: Dictionary = {}  # view_id -> int (Engine.get_frames_drawn() at capture)
var _capture_pending: Dictionary = {}   # view_id -> bool (one-shot in flight)

# ── AnnotationHost overrides ───────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


func get_capabilities() -> Dictionary:
	return {
		"kinds": ["callout", "2d_arrow", "2d_text", "cad_edge_number"],
		"tools": ["select"],
		"anchor_types": ["cad/edge", "core/canvas.point"],
		"lifecycle": {
			"resolve": true,
			"reopen": true,
			"delete": true,
			"repair": false,
			"apply": false,
		},
		"authoring": {
			"add": false,
			"domain_pickers": false,
		},
		"panes": true,
		"body_views": false,
		"filters": ["all", "open", "applied", "resolved", "broken"],
	}


## Add an annotation. Assigns an id if missing, stamps anchor, emits signal.
func add_annotation(annotation: Dictionary) -> String:
	var id: String = str(annotation.get("id", ""))
	if id.is_empty():
		id = "ann_%x" % randi()
	var stored: Dictionary = annotation.duplicate(true)
	stored["id"] = id
	AnnotationHost._stamp_anchor(stored, self)
	_annotations.append(stored)
	annotations_changed.emit()
	return id


## Identity transform — Round 1. CAD transforms (3-D→2-D camera projection) are
## a later grandchild. See four-canvas wiring note above.
func transform_doc_to_screen(p: Vector2) -> Vector2:
	return p


## Identity inverse — Round 1.
func transform_screen_to_doc(p: Vector2) -> Vector2:
	return p


## View context string. Embeds active viewport so MCP queries know which view.
func get_view_context() -> String:
	return "cad:" + _active_viewport_id


## Replace an annotation by id. Re-stamps anchor. Returns false if not found.
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	for i in range(_annotations.size()):
		var entry: Dictionary = _annotations[i] as Dictionary
		if str(entry.get("id", "")) == annotation_id:
			var stored: Dictionary = new_annotation.duplicate(true)
			stored["id"] = annotation_id
			AnnotationHost._stamp_anchor(stored, self)
			_annotations[i] = stored
			annotations_changed.emit()
			return true
	return false


## Remove an annotation by id. Clears selection if it was selected.
func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		var entry: Dictionary = _annotations[i] as Dictionary
		if str(entry.get("id", "")) == annotation_id:
			_annotations.remove_at(i)
			if _selected_id == annotation_id:
				_selected_id = ""
				selection_changed.emit("")
			annotations_changed.emit()
			return true
	return false


## Track selection. Emits selection_changed only on actual change.
func set_selected_annotation_id(annotation_id: String) -> void:
	if _selected_id == annotation_id:
		return
	_selected_id = annotation_id
	selection_changed.emit(_selected_id)


func get_selected_annotation_id() -> String:
	return _selected_id


## Return a shallow duplicate of the annotation list.
func get_annotations() -> Array:
	return _annotations.duplicate()


## Replace the annotation list wholesale (used by panel save/load).
func set_annotations(list: Array) -> void:
	_annotations = []
	for ann in list:
		if ann is Dictionary:
			_annotations.append((ann as Dictionary).duplicate(true))
	AnnotationHost.refresh_all_anchors(_annotations, self)
	annotations_changed.emit()


## Semantic hit-testing — Round 1 stub returning "".
##
## TODO(scaffold-round-2): implement via camera ray-cast.
## Intended substrate conventions:
##   "mesh.edge:<N>"           — projected edge N is closest to doc_pos
##   "mesh.face:<N>"           — projected face N contains doc_pos
##   "world.plane:<x>,<y>,<z>" — doc_pos maps to 3-D point on working plane
## Implementation requires: SubViewport camera → unproject_position → BVH query.
func describe_point(_doc_pos: Vector2) -> String:
	return ""


## Capture the active SubViewport's texture so MCP overlay-rendering composites
## the 3-D scene + 2-D annotations together.
##
## Pattern mirrors Helloscene_AnnotationHost: schedule a one-shot
## RenderingServer.frame_post_draw lambda to do the GPU→CPU pull, return the
## last cached image (may be null on the very first call before the frame has
## been drawn). Cached per-view, keyed by Engine.get_frames_drawn(), so
## repeated calls within the same frame don't re-capture.
##
## viewport_rect: if non-zero, crop the image to that region (matching the
## hello pattern). If zero, return the full SubViewport image.
func render_content_to_image(viewport_rect: Rect2) -> Image:
	return render_view_to_image(_active_viewport_id, viewport_rect)


## Per-view variant of render_content_to_image. Lets the snapshot MCP tool
## request a specific view ("iso"/"top"/"front"/"right") without mutating
## _active_viewport_id. Same caching rules: returns cached image when fresh
## for this frame, otherwise schedules a refresh and returns the previous
## capture (or null on cold start).
##
## Caveat: in NARROW layout only the visible SubViewport is actually rendering.
## Capturing a non-visible view returns the last cached image (possibly stale
## from before the layout switched) or null.
func render_view_to_image(view_id: String, viewport_rect: Rect2 = Rect2()) -> Image:
	var current_frame: int = Engine.get_frames_drawn()
	var cached_frame: int = int(_capture_cache_frame.get(view_id, -1))
	var cached_image: Image = _capture_cache.get(view_id, null) as Image

	if cached_image != null and cached_frame == current_frame:
		return _maybe_crop(cached_image, viewport_rect)

	_schedule_capture(view_id)
	return _maybe_crop(cached_image, viewport_rect) if cached_image != null else null


func _maybe_crop(img: Image, viewport_rect: Rect2) -> Image:
	if img == null:
		return null
	if viewport_rect.size.x <= 0.0 or viewport_rect.size.y <= 0.0:
		return img
	var rect_i := Rect2i(viewport_rect.position, viewport_rect.size)
	rect_i = rect_i.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if rect_i.size.x <= 0 or rect_i.size.y <= 0:
		return img
	return img.get_region(rect_i)


## One-shot frame_post_draw scheduling. De-dup'd per-view via _capture_pending.
func _schedule_capture(view_id: String) -> void:
	if bool(_capture_pending.get(view_id, false)):
		return
	if not _viewport_for.has(view_id):
		return
	_capture_pending[view_id] = true
	RenderingServer.frame_post_draw.connect(
		func() -> void: _do_capture_now(view_id),
		CONNECT_ONE_SHOT)


func _do_capture_now(view_id: String) -> void:
	_capture_pending[view_id] = false
	var vp_variant: Variant = _viewport_for.get(view_id, null)
	if vp_variant == null or not is_instance_valid(vp_variant):
		return
	# Duck-typed access — avoid typed `as SubViewport` for symmetry with the
	# rest of the off-tree contract; SubViewport.get_texture() / get_image()
	# are stable platform APIs.
	if not vp_variant.has_method("get_texture"):
		return
	var tex: ViewportTexture = vp_variant.get_texture()
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null:
		return
	_capture_cache[view_id] = img
	_capture_cache_frame[view_id] = Engine.get_frames_drawn()


# ── Per-viewport helpers (future grandchild stubs) ─────────────────────────

## Set the active viewport id used by get_view_context() and future transforms.
## viewport_id must be one of: "top", "front", "right", "iso", "perspective",
## "bottom", "back", "left".
##
## Switching the active view invalidates the per-view capture cache for the
## OUTGOING view (so a later switch back gets a fresh capture rather than
## a stale one from the prior session).
##
## TODO(scaffold-round-2): also store a reference to the matching Camera3D so
## transform_doc_to_viewport_screen can call camera.unproject_position().
func set_active_viewport(viewport_id: String) -> void:
	if _active_viewport_id != viewport_id:
		# Drop the cached capture for the OLD active view so the next render
		# cycle rebuilds. Pending one-shots remain queued; their callbacks just
		# repopulate the cache for whichever view was last requested.
		_capture_cache.erase(_active_viewport_id)
		_capture_cache_frame.erase(_active_viewport_id)
	_active_viewport_id = viewport_id


## Return the currently active viewport id (default "iso"). Used by MCP tools
## that resolve view="active" without needing direct field access.
func get_active_viewport() -> String:
	return _active_viewport_id


## Register the SubViewport that backs a given view_id. CADPanel calls this
## once per pane in _ready(): "iso", "top", "front", "right" (wide layout),
## plus "perspective"/"bottom"/"back"/"left" (narrow projection options that
## point at the SingleView SubViewport).
##
## We store the value untyped because Dictionary value-types aren't enforced
## and SubViewport itself is a platform class (resolvable from off-tree, but
## we keep the access path duck-typed for consistency).
func set_viewport_for(view_id: String, vp: Node) -> void:
	if vp == null:
		_viewport_for.erase(view_id)
		return
	_viewport_for[view_id] = vp


## Register the Camera3D that backs a given view_id. CADPanel calls this once
## per pane in _ready() (same call site as set_viewport_for). Stored untyped
## for off-tree duck-typing symmetry; Camera3D.unproject_position() is accessed
## via duck typing in cad_edge_number_kind.
func set_camera_for(view_id: String, cam: Object) -> void:
	if cam == null:
		_camera_for.erase(view_id)
		return
	_camera_for[view_id] = cam


## Map of view_id -> SubViewportContainer node, populated by CADPanel._ready() via
## set_container_for(). Used by get_panes() to compute each pane's viewport_rect
## (panel-relative screen-space rectangle) for canvas-coord offset correction.
var _container_for: Dictionary = {}

## Panel-root overlay Control node. Set by CADPanel when it reparents the canvas
## to the panel root. Used to compute panel-relative rects in get_panes().
var _panel_root: Control = null


## Register the SubViewportContainer that backs a given view_id. CADPanel calls
## this so get_panes() can compute viewport_rect via container.get_global_rect()
## minus _panel_root.global_position.
func set_container_for(view_id: String, container: Control) -> void:
	if container == null:
		_container_for.erase(view_id)
		return
	_container_for[view_id] = container


## Set the panel-root overlay Control used to compute panel-relative rects.
func set_panel_root(root: Control) -> void:
	_panel_root = root


## Return a list of active pane descriptors for multi-pane annotation rendering.
##
## Each element is a Dictionary:
##   {
##     "name":          String  — view_id, e.g. "iso", "top", "front", "right"
##     "camera":        Object  — Camera3D (duck-typed); null if not registered
##     "viewport_rect": Rect2   — pane's screen-space rect within the panel-root
##                                canvas (used to offset projected coords so leaders
##                                land in the correct quadrant). Defaults to
##                                Rect2(0,0,512,512) when container not registered.
##   }
##
## Only panes that have BOTH a camera and a SubViewport registered are included.
## This covers the 4 wide-mode panes. In narrow mode the single viewport is
## registered under all preset ids; get_panes() returns only the active one
## (stored under _active_viewport_id) to avoid duplicates.
##
## Narrow-mode handling: when all WIDE_PANE_IDS collapse to a single SubViewport
## (via dedup), the fallback path returns one pane for the active viewport id.
## Its viewport_rect covers the single-view container's full area (offset from
## the panel root). If the container is not registered, rect defaults to
## Rect2(0,0,512,512) so the kind still works correctly for single-pane scenarios.
##
## Round 2b-α callers (cad_edge_number_kind.render) use this to iterate panes,
## project a 3-D world point into each pane's screen-space, then add
## viewport_rect.position to translate into panel-root canvas coordinates.
func get_panes() -> Array:
	var result: Array = []
	# Wide mode: return the 4 canonical pane ids that have both camera + viewport.
	var seen_viewports := {}
	for pane_id in WIDE_PANE_IDS:
		var cam: Variant = _camera_for.get(pane_id, null)
		var vp: Variant = _viewport_for.get(pane_id, null)
		if cam == null or vp == null:
			continue
		# In narrow mode all ids map to the same SubViewport — deduplicate.
		var vp_id: int = vp.get_instance_id() if vp.has_method("get_instance_id") else 0
		if vp_id != 0 and seen_viewports.has(vp_id):
			# Narrow mode: all preset ids share one viewport — emit only once.
			continue
		seen_viewports[vp_id] = true
		result.append({
			"name": pane_id,
			"camera": cam,
			"viewport_rect": _compute_viewport_rect(pane_id),
		})

	# Fallback: if we got nothing from WIDE_PANE_IDS (narrow mode / early init),
	# emit the active viewport's pane so single-pane callers still work.
	if result.is_empty():
		var cam: Variant = _camera_for.get(_active_viewport_id, null)
		var vp: Variant = _viewport_for.get(_active_viewport_id, null)
		if cam != null and vp != null:
			result.append({
				"name": _active_viewport_id,
				"camera": cam,
				"viewport_rect": _compute_viewport_rect(_active_viewport_id),
			})
	return result


## Compute the panel-relative Rect2 for a given pane id using the registered
## SubViewportContainer. Returns Rect2(0,0,512,512) as a safe default when the
## container or panel root is not set (e.g. in tests without a live scene tree).
func _compute_viewport_rect(pane_id: String) -> Rect2:
	var container: Variant = _container_for.get(pane_id, null)
	if container == null or not is_instance_valid(container):
		return Rect2(0.0, 0.0, 512.0, 512.0)
	if _panel_root == null or not is_instance_valid(_panel_root):
		# No panel root reference — return the container's global rect as-is.
		if container.has_method("get_global_rect"):
			return container.get_global_rect()
		return Rect2(0.0, 0.0, 512.0, 512.0)
	# Panel-relative rect: global rect minus panel root's global position.
	if container.has_method("get_global_rect"):
		var global_rect: Rect2 = container.get_global_rect()
		var panel_origin: Vector2 = _panel_root.global_position
		return Rect2(global_rect.position - panel_origin, global_rect.size)
	return Rect2(0.0, 0.0, 512.0, 512.0)


## Set/get the currently selected edge id for the active viewport.
## EdgeOverlay → CADPanel pushes this; MCP queries can read it via get.
func set_selected_edge_id(edge_id: int) -> void:
	_selected_edge_id = edge_id


func get_selected_edge_id() -> int:
	return _selected_edge_id


# ── MCP introspection state (task 019dd2049ff6) ────────────────────────────
## Mesh data last pushed by CADPanel after a successful cad.evaluate reply.
## Shape: {vertices: [[x,y,z],...], faces: [[i,j,k],...]} — same dict the
## worker returns.  Empty dict = no geometry yet.
var _mesh_data: Dictionary = {}

## Edge registry last pushed by CADPanel after a successful cad.evaluate reply.
## Array of edge dicts; exact shape from the worker (id, kind, length/radius, …).
var _edge_registry_data: Array = []

## Document source last pushed by CADPanel on load / evaluate.
var _document_file_path: String = ""
var _document_dsl_text: String = ""


## Called by CADPanel after a successful cad.evaluate IPC reply.
func set_mesh_data(mesh: Dictionary) -> void:
	_mesh_data = mesh


## Called by CADPanel after a successful cad.evaluate IPC reply.
func set_edge_registry(edges: Array) -> void:
	_edge_registry_data = edges


## Return the current mesh data dict (may be empty if not yet evaluated).
func get_mesh_data() -> Dictionary:
	return _mesh_data


## Return the current edge registry array (may be empty).
func get_edge_registry() -> Array:
	return _edge_registry_data


## Called by CADPanel once both file_path and dsl_text are known.
func set_document_source(file_path: String, dsl_text: String) -> void:
	_document_file_path = file_path
	_document_dsl_text = dsl_text


## Return {file_path, dsl_text} for MCP introspection.
func get_document_source() -> Dictionary:
	return {"file_path": _document_file_path, "dsl_text": _document_dsl_text}


## Map a document-space point to screen-space for a specific viewport.
## Round 1 stub: identity. Round 2 will delegate to the viewport's Camera3D.
##
## TODO(scaffold-round-2): look up the Camera3D for viewport_id in a dict
## populated by CADPanel._ready(), then call:
##   camera.unproject_position(Vector3(p.x, p.y, 0.0))
## (The z=0 plane assumption is adequate for orthographic views; perspective
## requires a proper depth from the working plane or a BVH raycast.)
func transform_doc_to_viewport_screen(p: Vector2, _viewport_id: String) -> Vector2:
	return p


# ── Phase B1: edge anchor resolver ────────────────────────────────────────────

## Override _init to chain to AnnotationHost._init() (sets resolve_cache) and
## then register the edge anchor resolver on self.
func _init() -> void:
	super._init()
	register_anchor_resolver(
		_CadAnchorTypesScript.EDGE_ANCHOR_KEY,
		_resolve_edge_anchor
	)


## Phase B2: domain picker — surfaces the currently-selected edge as a
## cad/edge anchor envelope. Authoring tools call this from on_activate to
## skip the click-pick step when the user already has an edge selected.
##
## Returns {} when no edge is selected, or when the requested kind doesn't
## match cad/edge. The "kind" filter is the substrate's mechanism for tools
## that only want one anchor type.
func get_current_selection_anchor(kind: String = "") -> Dictionary:
	if _selected_edge_id < 0:
		return {}
	if kind != "" and kind != _CadAnchorTypesScript.EDGE_ANCHOR_KEY:
		return {}
	return {
		"plugin": _CadAnchorTypesScript.PLUGIN,
		"type":   _CadAnchorTypesScript.EDGE_TYPE,
		"id":     _selected_edge_id,
	}


# ── Phase B2 follow-up: camera-tracking → AnnotationOverlay redraw ────────────

## Cache of last-known per-pane camera global_transform. _process compares the
## live transform against this cache and emits annotations_changed when any
## differs, so substrate AnnotationOverlay re-projects camera-dependent kinds
## (the Phase B2 leader+box callout). Without this, kinds that call
## camera.unproject_position only re-run on annotations_changed (data change),
## leaving the callout frozen at the projection state of the last data event.
var _camera_xform_cache: Dictionary = {}

func _process(_delta: float) -> void:
	var any_moved := false
	for vid in _camera_for:
		var cam: Variant = _camera_for[vid]
		if cam == null or not (cam is Camera3D):
			continue
		var current: Transform3D = (cam as Camera3D).global_transform
		var cached: Variant = _camera_xform_cache.get(vid, null)
		if cached == null or not (cached is Transform3D) or (cached as Transform3D) != current:
			_camera_xform_cache[vid] = current
			any_moved = true
	if any_moved:
		annotations_changed.emit()


## Resolve a CAD edge anchor to its current world-space midpoint.
##
## anchor shape: { "plugin": "cad", "type": "edge", "id": <int> }
## Returns a Dict with position (Vector3), edge_id (int), stale (bool).
## Returns null when the anchor dict is malformed (substrate calls fallback).
## Returns { stale: true, ... } when edge id is not in the live registry.
func _resolve_edge_anchor(anchor: Dictionary) -> Variant:
	if not anchor.has("id"):
		return null
	var edge_id: int = int(anchor["id"])
	for edge_info in _edge_registry_data:
		if not (edge_info is Dictionary):
			continue
		if int((edge_info as Dictionary).get("id", -1)) != edge_id:
			continue
		var start_raw: Variant = (edge_info as Dictionary).get("start", null)
		var end_raw: Variant = (edge_info as Dictionary).get("end", null)
		var start_3d := _vec3_from_raw(start_raw)
		var end_3d := _vec3_from_raw(end_raw)
		return {
			"position": start_3d.lerp(end_3d, 0.5),
			"edge_id": edge_id,
			"stale": false,
		}
	return {"position": Vector3.ZERO, "edge_id": edge_id, "stale": true}


## Convert a raw worker vertex ([x,y,z] or Vector3) to Vector3.
func _vec3_from_raw(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		return Vector3(float((raw as Array)[0]), float((raw as Array)[1]), float((raw as Array)[2]))
	return Vector3.ZERO
