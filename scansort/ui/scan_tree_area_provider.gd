extends "scan_tree_provider.gd"
## Aggregate scan_tree provider for a destination area (vault OR directory kind).
##
## For vault areas: the currently-open vault is ALWAYS rendered first, sourced
## directly from its file path (via query_documents on that path).  This
## ensures vault contents are visible even when the destination registry is
## empty, stale, or on a different machine.  Registry vault destinations that
## are NOT the open vault are appended after it (deduped by path).
##
## For directory areas: behaves as before — renders all "directory" entries
## from the destination registry.
##
## Calls minerva_scansort_destination_list, filters by `area_kind`, and builds
## a virtual-root node list where each top-level entry is one destination of
## that kind.  The destination row is a folder node with key "dest:<id>" and
## its children are the category/document nodes (for vault destinations) or
## folder/file nodes (for directory destinations) fetched via the same per-
## destination logic that scan_tree_destination_provider.gd uses.
##
## Top-level destination nodes carry two extra fields that scan_tree.gd reads
## to add inline row buttons:
##   dest_id: String  — the destination id for button dispatch
##   locked:  bool    — current locked state (drives the lock button icon)
##
## No class_name — off-tree plugin script; loaded via preload().

var _conn: Object = null
var _registry_path: String = ""
var _area_kind: String = ""  # "vault" or "directory"
## For vault areas: the currently-open vault path.  Always rendered first,
## regardless of whether it appears in the registry.  Empty = no open vault.
var _open_vault_path: String = ""

## Latest destination list fetched (used by the panel to resolve dest_id from key).
var last_destinations: Array = []


## Attach connection + registry path + area kind.  Call before get_tree_data().
## open_vault_path: for vault areas, pass the currently-open vault path so it
## is always rendered directly from its file (W5c).  Ignored for directory areas.
func init(conn: Object, registry_path: String, area_kind: String, open_vault_path: String = "") -> void:
	_conn = conn
	_registry_path = registry_path
	_area_kind = area_kind
	_open_vault_path = open_vault_path


func get_source_label() -> String:
	return "Vaults" if _area_kind == "vault" else "Directories"


func get_tree_data() -> Array:
	if _conn == null:
		return []

	# W5c: For vault areas, the open vault is always rendered regardless of the
	# registry.  We need a conn but do NOT require a registry_path to show the
	# open vault row.  Directory areas do require the registry to be set.
	if _area_kind == "vault" and _open_vault_path.is_empty():
		# No vault open — nothing to show even if registry has entries.
		return []
	if _area_kind == "directory" and _registry_path.is_empty():
		return []

	# Fetch the registry destination list (best-effort; may return empty on
	# first open before auto-registration completes, or on a different machine).
	var all_dests: Array = []
	if not _registry_path.is_empty():
		var result: Dictionary = await _conn.call_tool(
			"minerva_scansort_destination_list",
			{"registry_path": _registry_path},
		)
		if result.get("ok", false):
			all_dests = result.get("destinations", [])
		else:
			push_warning("[AreaProvider] destination_list failed: %s" % result.get("error", "unknown"))
	last_destinations = all_dests.duplicate(true)

	var nodes: Array = []

	if _area_kind == "vault":
		# --- W5c: open vault row always first, sourced directly from file ---
		# Find registry entry for the open vault (for dest_id + locked state).
		var open_dest_id: String  = ""
		var open_locked: bool     = false
		var open_label: String    = _open_vault_path.get_file().get_basename()
		for dest: Dictionary in all_dests:
			if str(dest.get("kind", "")) == "vault" and str(dest.get("path", "")) == _open_vault_path:
				open_dest_id = str(dest.get("id", ""))
				open_locked  = bool(dest.get("locked", false))
				var dlabel: String = str(dest.get("label", ""))
				if not dlabel.is_empty():
					open_label = dlabel
				break

		# Build children by querying the vault file directly.
		var open_children: Array = await _get_vault_children_by_path(_open_vault_path)

		nodes.append({
			"kind":     "folder",
			"name":     open_label,
			"key":      "dest:%s" % (open_dest_id if not open_dest_id.is_empty() else _open_vault_path),
			"date":     "",
			"tooltip":  _open_vault_path,
			"children": open_children,
			"dest_id":  open_dest_id,
			"locked":   open_locked,
		})

		# Append any OTHER registry vault destinations (deduped: skip open vault).
		for dest: Dictionary in all_dests:
			var kind: String = str(dest.get("kind", ""))
			if kind != "vault":
				continue
			var dest_path: String = str(dest.get("path", ""))
			if dest_path == _open_vault_path:
				continue  # already rendered above
			var dest_id: String  = str(dest.get("id", ""))
			var label: String    = str(dest.get("label", dest.get("path", dest_id)))
			var is_locked: bool  = bool(dest.get("locked", false))
			var children: Array  = await _get_vault_children(dest)
			nodes.append({
				"kind":     "folder",
				"name":     label,
				"key":      "dest:%s" % dest_id,
				"date":     "",
				"tooltip":  label,
				"children": children,
				"dest_id":  dest_id,
				"locked":   is_locked,
			})
	else:
		# Directory area: registry-driven (unchanged from W5b).
		for dest: Dictionary in all_dests:
			var kind: String = str(dest.get("kind", ""))
			if kind != _area_kind:
				continue
			var dest_id: String  = str(dest.get("id", ""))
			var label: String    = str(dest.get("label", dest.get("path", dest_id)))
			var is_locked: bool  = bool(dest.get("locked", false))
			var children: Array  = await _get_directory_children(dest)
			nodes.append({
				"kind":     "folder",
				"name":     label,
				"key":      "dest:%s" % dest_id,
				"date":     "",
				"tooltip":  label,
				"children": children,
				"dest_id":  dest_id,
				"locked":   is_locked,
			})

	return nodes


# ---------------------------------------------------------------------------
# Per-destination child fetching (mirrors scan_tree_destination_provider.gd)
# ---------------------------------------------------------------------------

## W5c: fetch vault children directly from a vault path (bypasses registry).
## Used for the always-present open vault row.
func _get_vault_children_by_path(vault_path: String) -> Array:
	if vault_path.is_empty():
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_path},
	)
	if not result.get("ok", false):
		push_warning("[AreaProvider] open vault query_documents failed: %s" % result.get("error", "unknown"))
		return []

	return _build_category_nodes(result.get("documents", []))


func _get_vault_children(dest: Dictionary) -> Array:
	var vault_path: String = str(dest.get("path", ""))
	if vault_path.is_empty():
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_path},
	)
	if not result.get("ok", false):
		push_warning("[AreaProvider] vault query_documents failed: %s" % result.get("error", "unknown"))
		return []

	return _build_category_nodes(result.get("documents", []))


## Build a category→document tree from a flat documents array.
## Shared by both _get_vault_children and _get_vault_children_by_path.
func _build_category_nodes(docs: Array) -> Array:
	var by_category: Dictionary = {}
	for doc: Dictionary in docs:
		var cat: String = str(doc.get("category", "uncategorized"))
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(doc)

	var sorted_cats: Array = by_category.keys()
	sorted_cats.sort()

	var nodes: Array = []
	for cat: String in sorted_cats:
		var cat_docs: Array = by_category[cat]
		cat_docs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var da: String = str(a.get("display_name", a.get("original_filename", "")))
			var db: String = str(b.get("display_name", b.get("original_filename", "")))
			return da < db
		)
		var children: Array = []
		for doc: Dictionary in cat_docs:
			var doc_id: int = int(doc.get("doc_id", 0))
			var display: String = str(doc.get("display_name", doc.get("original_filename", "unknown")))
			var sender: String = str(doc.get("sender", ""))
			var desc: String = str(doc.get("description", ""))
			children.append({
				"kind":    "file",
				"name":    display,
				"key":     "doc:%d" % doc_id,
				"date":    str(doc.get("doc_date", "")),
				"tooltip": "%s\nSender: %s\n%s" % [display, sender, desc],
				"children": [],
			})
		nodes.append({
			"kind":     "folder",
			"name":     "%s/ (%d)" % [cat, cat_docs.size()],
			"key":      "cat:%s" % cat,
			"date":     "",
			"tooltip":  "",
			"children": children,
		})
	return nodes


func _get_directory_children(dest: Dictionary) -> Array:
	var dir_path: String = str(dest.get("path", ""))
	var dest_id: String  = str(dest.get("id", ""))
	if dir_path.is_empty():
		return []

	var args: Dictionary = {"disk_root": dir_path}
	if not _registry_path.is_empty():
		args["registry_path"] = _registry_path
	if not dest_id.is_empty():
		args["destination_id"] = dest_id

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_list_disk_files",
		args,
	)
	if not result.get("ok", false):
		push_warning("[AreaProvider] dir list_disk_files failed: %s" % result.get("error", "unknown"))
		return []

	var files: Array = result.get("files", [])
	var by_dir: Dictionary = {}
	for f: Dictionary in files:
		var rel: String = str(f.get("rel_path", ""))
		var top: String
		var slash_pos: int = rel.find("/")
		if slash_pos < 0:
			top = "(root)"
		else:
			top = rel.substr(0, slash_pos)
		if not by_dir.has(top):
			by_dir[top] = []
		by_dir[top].append(f)

	var sorted_dirs: Array = by_dir.keys()
	sorted_dirs.sort()

	var nodes: Array = []
	for dir_name: String in sorted_dirs:
		var dir_files: Array = by_dir[dir_name]
		dir_files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return str(a.get("rel_path", "")) < str(b.get("rel_path", ""))
		)
		var children: Array = []
		for f: Dictionary in dir_files:
			var fpath: String = str(f.get("path", ""))
			var fname: String = str(f.get("name", fpath.get_file()))
			var rel: String   = str(f.get("rel_path", fname))
			var size: int     = int(f.get("size", 0))
			children.append({
				"kind":     "file",
				"name":     fname,
				"key":      fpath,
				"date":     "",
				"tooltip":  "%s\nSize: %d bytes" % [rel, size],
				"children": [],
			})
		nodes.append({
			"kind":     "folder",
			"name":     "%s/ (%d)" % [dir_name, dir_files.size()],
			"key":      "dir:%s" % dir_name,
			"date":     "",
			"tooltip":  "",
			"children": children,
		})
	return nodes
