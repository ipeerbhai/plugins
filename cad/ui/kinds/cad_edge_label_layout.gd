extends RefCounted
## Layout helper for cad_edge_number annotations.
##
## Computes a non-overlapping screen-space position for each label's text-box
## per pane per frame. The kind's render() function is called once per
## annotation; without coordination, neighbouring labels stack on top of each
## other (default box_offset is zero or a constant) and the user can't tell
## which label points at which edge.
##
## Algorithm:
##   1. Project every cad_edge_number annotation's anchor (edge midpoint) to
##      screen space using the pane's camera.
##   2. Use the annotation's payload.box_offset as the initial box position
##      (back-projected to screen) — when zero, push outward radially from
##      the pane center so labels fan out instead of stacking.
##   3. Iterate pairwise: for any two boxes whose rects (with margin)
##      overlap, push them apart along the dominant axis. Up to N iterations.
##   4. Cache the result keyed by camera transform + viewport rect + frame +
##      annotation count. Subsequent render() calls within the same frame
##      hit the cache (constant-time per annotation).
##
## Off-tree class_name discipline: this file lives outside Minerva's res:// tree.
## It MUST NOT declare a class_name. Loaded via preload() from cad_edge_number_kind.

# Approximate box footprint — matches the kind's _BOX_WIDTH (200) and average
# height for a callout with a 1-line title and 1-2 lines of body text. Used
# only for overlap detection; actual draw size still computed per-annotation.
const _BOX_SIZE := Vector2(200.0, 56.0)

# Margin added around each rect when checking overlap. Keeps boxes visually
# separated even after the spread converges.
const _MIN_GAP_PX := 8.0

# Spread iteration cap. With 4-10 labels the algorithm converges in ~5-10
# passes; the cap guards against pathological clusters.
const _SPREAD_ITERATIONS := 32

# When payload.box_offset is zero (e.g. agent-minted via minerva_cad_annotate_edges),
# push the box this many pixels radially outward from the pane center so the
# spread iterations have something to work with instead of all anchors stacked.
const _DEFAULT_RADIAL_PUSH_PX := 80.0


# Per-camera cache. Keyed by camera instance id → {key: Array, layout: Dict}.
# The layout dict is edge_id (int) → screen-space Vector2 (box center).
static var _cache: Dictionary = {}


## Returns Dictionary[int edge_id → Vector2 box_center_screen].
## The keys are exactly the edge_ids of cad_edge_number annotations whose
## anchors successfully resolve through host._resolve_edge_anchor.
##
## Callers (the kind's render()) look up their own edge_id and use the result
## as the box center, falling back to the legacy box_offset path if the id is
## missing (e.g. anchor failed to resolve).
static func get_layout(
		host: Object,
		camera: Camera3D,
		viewport_rect: Rect2,
		annotations: Array
) -> Dictionary:
	if camera == null or host == null:
		return {}

	# Cache key includes the camera's basis (orbit/rotation), origin, the
	# viewport rect (resize / pane reflow), the frame number, and the count
	# of cad_edge_number annotations. A change in any invalidates the cache.
	var ann_count := 0
	for ann in annotations:
		if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "cad_edge_number":
			ann_count += 1

	var cam_id: int = camera.get_instance_id()
	var key: Array = [
		camera.global_transform.basis,
		camera.global_transform.origin,
		viewport_rect,
		ann_count,
		Engine.get_frames_drawn(),
	]
	if _cache.has(cam_id):
		var entry: Dictionary = _cache[cam_id] as Dictionary
		if entry.get("key", null) == key:
			return entry.get("layout", {})

	# Build initial positions: project anchor + box_offset. Fan out anchors
	# whose offset is effectively zero so the spread has working room.
	var positions: Dictionary = {}
	var pane_center := viewport_rect.position + viewport_rect.size * 0.5
	# Deterministic but distinct fan-out direction per anchor when many
	# anchors share the pane center direction (rare, defensive only).
	var fan_index := 0

	for ann in annotations:
		if not (ann is Dictionary):
			continue
		var ann_d: Dictionary = ann as Dictionary
		if str(ann_d.get("kind", "")) != "cad_edge_number":
			continue
		var anchor: Variant = ann_d.get("anchor", null)
		if not (anchor is Dictionary):
			continue
		if not host.has_method("_resolve_edge_anchor"):
			continue
		var resolved: Variant = host._resolve_edge_anchor(anchor)
		if not (resolved is Dictionary):
			continue
		var resolved_d: Dictionary = resolved as Dictionary

		var leader_start_world: Vector3 = resolved_d.get("position", Vector3.ZERO)
		var edge_id: int = int(resolved_d.get("edge_id", anchor.get("id", -1)))
		if edge_id < 0:
			continue

		var payload: Dictionary = ann_d.get("payload", {})
		var box_offset: Vector3 = _vec3_from_payload(payload.get("box_offset", [0.0, 0.0, 0.0]))
		var leader_end_world: Vector3 = leader_start_world + box_offset

		var anchor_screen: Vector2 = camera.unproject_position(leader_start_world) + viewport_rect.position
		var box_center: Vector2 = camera.unproject_position(leader_end_world) + viewport_rect.position

		# When the world offset is effectively zero, the unproject collapses
		# back onto the anchor → fan outward radially so labels start spread.
		if box_offset.length_squared() < 0.0001:
			var dir: Vector2 = anchor_screen - pane_center
			if dir.length_squared() < 1.0:
				# Anchor at exact pane center: synthesise a distinct direction
				# per fan_index so co-located anchors don't all stack.
				var angle: float = TAU * float(fan_index) / 8.0
				dir = Vector2(cos(angle), sin(angle))
			box_center = anchor_screen + dir.normalized() * _DEFAULT_RADIAL_PUSH_PX
			fan_index += 1

		positions[edge_id] = box_center

	# Spread overlapping boxes in screen space. Pairwise iteration: for each
	# overlapping pair, push them apart along the dominant axis of their
	# centre-to-centre vector. Equal-and-opposite displacement preserves
	# bulk position. Stops early once no pair overlaps.
	var ids: Array = positions.keys()
	for _iter in range(_SPREAD_ITERATIONS):
		var moved := false
		for i in range(ids.size()):
			for j in range(i + 1, ids.size()):
				var a_id = ids[i]
				var b_id = ids[j]
				var a_pos: Vector2 = positions[a_id]
				var b_pos: Vector2 = positions[b_id]
				var a_rect := Rect2(a_pos - _BOX_SIZE * 0.5, _BOX_SIZE).grow(_MIN_GAP_PX * 0.5)
				var b_rect := Rect2(b_pos - _BOX_SIZE * 0.5, _BOX_SIZE).grow(_MIN_GAP_PX * 0.5)
				if not a_rect.intersects(b_rect):
					continue
				var diff: Vector2 = b_pos - a_pos
				if diff.length_squared() < 0.0001:
					# Coincident centres: push along a deterministic diagonal
					# so the next iteration has a defined direction.
					diff = Vector2(1.0, -1.0)
				var inter := a_rect.intersection(b_rect)
				var overlap: Vector2 = inter.size
				# Push along the dominant axis only — keeps motion stable and
				# avoids diagonal drift that can re-collide with a third box.
				var push: Vector2
				if abs(diff.x) >= abs(diff.y):
					push = Vector2((overlap.x + 1.0) * 0.5 * sign(diff.x), 0.0)
				else:
					push = Vector2(0.0, (overlap.y + 1.0) * 0.5 * sign(diff.y))
				positions[a_id] = a_pos - push
				positions[b_id] = b_pos + push
				moved = true
		if not moved:
			break

	_cache[cam_id] = {"key": key, "layout": positions}
	return positions


static func _vec3_from_payload(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		return Vector3(
			float((raw as Array)[0]),
			float((raw as Array)[1]),
			float((raw as Array)[2]),
		)
	return Vector3.ZERO
