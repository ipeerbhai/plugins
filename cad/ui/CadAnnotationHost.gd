class_name Cad_AnnotationHost
extends AnnotationHost
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

## Cache of last captured Image keyed by view_id. Invalidated when
## set_active_viewport() changes the active id, or when the cached frame
## number no longer matches the engine's current frame.
var _capture_cache: Dictionary = {}     # view_id -> Image
var _capture_cache_frame: Dictionary = {}  # view_id -> int (Engine.get_frames_drawn() at capture)
var _capture_pending: Dictionary = {}   # view_id -> bool (one-shot in flight)

# ── AnnotationHost overrides ───────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


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
	var view_id: String = _active_viewport_id
	var current_frame: int = Engine.get_frames_drawn()
	var cached_frame: int = int(_capture_cache_frame.get(view_id, -1))
	var cached_image: Image = _capture_cache.get(view_id, null) as Image

	if cached_image != null and cached_frame == current_frame:
		return _maybe_crop(cached_image, viewport_rect)

	# Cache miss or stale — schedule a refresh for next frame.
	_schedule_capture(view_id)
	# Return the previous capture if we have one (stale by ≥1 frame is fine);
	# null only on cold start.
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
