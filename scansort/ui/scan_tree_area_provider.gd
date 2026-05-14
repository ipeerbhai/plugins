extends "scan_tree_provider.gd"
## Aggregate scan_tree provider for a destination area (vault OR directory kind).
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

## Latest destination list fetched (used by the panel to resolve dest_id from key).
var last_destinations: Array = []


## Attach connection + registry path + area kind.  Call before get_tree_data().
func init(conn: Object, registry_path: String, area_kind: String) -> void:
	_conn = conn
	_registry_path = registry_path
	_area_kind = area_kind


func get_source_label() -> String:
	return "Vaults" if _area_kind == "vault" else "Directories"


func get_tree_data() -> Array:
	if _conn == null or _registry_path.is_empty():
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_destination_list",
		{"registry_path": _registry_path},
	)
	if not result.get("ok", false):
		push_warning("[AreaProvider] destination_list failed: %s" % result.get("error", "unknown"))
		return []

	var all_dests: Array = result.get("destinations", [])
	last_destinations = all_dests.duplicate(true)

	var nodes: Array = []
	for dest: Dictionary in all_dests:
		var kind: String = str(dest.get("kind", ""))
		if kind != _area_kind:
			continue
		var dest_id: String  = str(dest.get("id", ""))
		var label: String    = str(dest.get("label", dest.get("path", dest_id)))
		var is_locked: bool  = bool(dest.get("locked", false))

		# Fetch children for this destination.
		var children: Array = []
		if kind == "vault":
			children = await _get_vault_children(dest)
		elif kind == "directory":
			children = await _get_directory_children(dest)

		nodes.append({
			"kind":     "folder",
			"name":     label,
			"key":      "dest:%s" % dest_id,
			"date":     "",
			"tooltip":  label,
			"children": children,
			# Extra fields consumed by scan_tree._add_node to place inline buttons.
			"dest_id":  dest_id,
			"locked":   is_locked,
		})

	return nodes


# ---------------------------------------------------------------------------
# Per-destination child fetching (mirrors scan_tree_destination_provider.gd)
# ---------------------------------------------------------------------------

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

	var docs: Array = result.get("documents", [])
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
