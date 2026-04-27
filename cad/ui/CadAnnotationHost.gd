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


## Render content to image — Round 1 stub returning null.
##
## TODO(scaffold-round-2): capture the active SubViewport's texture and crop it
## to viewport_rect (in document/screen coordinates). Use the same
## RenderingServer.frame_post_draw one-shot pattern as Helloscene_AnnotationHost
## to avoid blocking on GPU→CPU sync.
func render_content_to_image(_viewport_rect: Rect2) -> Image:
	return null


# ── Per-viewport helpers (future grandchild stubs) ─────────────────────────

## Set the active viewport id used by get_view_context() and future transforms.
## viewport_id must be one of: "top", "front", "right", "iso".
##
## TODO(scaffold-round-2): also store a reference to the matching Camera3D so
## transform_doc_to_viewport_screen can call camera.unproject_position().
func set_active_viewport(viewport_id: String) -> void:
	_active_viewport_id = viewport_id


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
