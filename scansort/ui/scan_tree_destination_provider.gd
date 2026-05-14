extends "scan_tree_provider.gd"
## scan_tree provider for a destination registry entry.
##
## Supports both "vault" destinations (backed by minerva_scansort_query_documents
## against a .ssort vault) and "directory" destinations (backed by a recursive
## directory listing via minerva_scansort_list_disk_files with an explicit
## disk_root, which the backend exposes when registry_path + id are passed).
##
## A destination dict (from minerva_scansort_destination_list) has the shape:
##   { id: String, kind: "vault"|"directory", path: String,
##     label: String, locked: bool }
##
## For vault destinations the tree mirrors scan_tree_vault_provider: documents
## grouped by category.
## For directory destinations the tree mirrors scan_tree_disk_provider: files
## grouped by the first path component of their rel_path under the directory
## root.
##
## No class_name — off-tree plugin script; loaded via preload().

var _conn: Object = null
var _registry_path: String = ""
var _destination: Dictionary = {}


## Attach connection + registry path + destination dict. Call before get_tree_data().
func init(conn: Object, registry_path: String, destination: Dictionary) -> void:
	_conn = conn
	_registry_path = registry_path
	_destination = destination


func get_source_label() -> String:
	var label: String = str(_destination.get("label", ""))
	if label.is_empty():
		label = str(_destination.get("path", "")).get_file()
	if label.is_empty():
		label = str(_destination.get("id", "destination"))
	var kind: String = str(_destination.get("kind", ""))
	if kind == "vault":
		return "Vault: " + label
	elif kind == "directory":
		return "Dir: " + label
	return label


func get_tree_data() -> Array:
	if _conn == null or _destination.is_empty():
		return []

	var kind: String = str(_destination.get("kind", ""))
	if kind == "vault":
		return await _get_vault_tree_data()
	elif kind == "directory":
		return await _get_directory_tree_data()
	return []


# ---------------------------------------------------------------------------
# Vault destination — documents grouped by category
# (mirrors scan_tree_vault_provider.gd)
# ---------------------------------------------------------------------------

func _get_vault_tree_data() -> Array:
	var vault_path: String = str(_destination.get("path", ""))
	if vault_path.is_empty():
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_path},
	)
	if not result.get("ok", false):
		push_warning("[DestinationProvider] vault query_documents failed: %s" % result.get("error", "unknown"))
		return []

	var docs: Array = result.get("documents", [])

	# Group by category.
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
				"kind": "file",
				"name": display,
				"key": "doc:%d" % doc_id,
				"date": str(doc.get("doc_date", "")),
				"tooltip": "%s\nSender: %s\n%s" % [display, sender, desc],
				"children": [],
			})

		nodes.append({
			"kind": "folder",
			"name": "%s/ (%d)" % [cat, cat_docs.size()],
			"key": "cat:%s" % cat,
			"date": "",
			"tooltip": "",
			"children": children,
		})

	return nodes


# ---------------------------------------------------------------------------
# Directory destination — files grouped by first rel_path component
# (mirrors scan_tree_disk_provider.gd, but uses explicit disk_root via
# registry context: passes registry_path + destination_id so the backend
# can resolve the registered root)
# ---------------------------------------------------------------------------

func _get_directory_tree_data() -> Array:
	var dir_path: String = str(_destination.get("path", ""))
	var dest_id: String = str(_destination.get("id", ""))
	if dir_path.is_empty():
		return []

	# The backend's list_disk_files accepts an optional disk_root override so
	# it doesn't have to be bound to a vault. Pass registry_path + destination_id
	# so the backend can also resolve from the registry if needed.
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
		push_warning("[DestinationProvider] dir list_disk_files failed: %s" % result.get("error", "unknown"))
		return []

	var files: Array = result.get("files", [])

	# Group by first component of rel_path (same logic as DiskProvider).
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
