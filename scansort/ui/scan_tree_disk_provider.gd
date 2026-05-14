extends "scan_tree_provider.gd"
## scan_tree provider backed by the vault's configured disk_root.
##
## Calls minerva_scansort_list_disk_files and groups results by the
## first path component of each file's rel_path (files whose rel_path has
## no directory component land under a synthetic "(root)" folder).
##
## File keys are absolute paths (the "path" field returned by the tool)
## so callers can identify/open the on-disk file.  Folder keys are
## "dir:<topcomponent>".
##
## No class_name — off-tree plugin script; loaded via preload().

var _conn: Object = null
var _vault_path: String = ""


## Attach the plugin connection + vault path. Call before get_tree_data().
func init(conn: Object, vault_path: String) -> void:
	_conn = conn
	_vault_path = vault_path


func get_source_label() -> String:
	if _vault_path.is_empty():
		return "Disk"
	return "Disk: " + _vault_path.get_file()


func get_tree_data() -> Array:
	if _conn == null:
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_list_disk_files",
		{"vault_path": _vault_path},
	)
	if not result.get("ok", false):
		push_warning("[DiskProvider] list_disk_files failed: %s" % result.get("error", "unknown"))
		return []

	var files: Array = result.get("files", [])

	# Group by the first component of rel_path.
	var by_dir: Dictionary = {}
	for f: Dictionary in files:
		var rel: String = str(f.get("rel_path", ""))
		var top: String
		var slash_pos: int = rel.find("/")
		if slash_pos < 0:
			# File is directly in disk_root — synthetic "(root)" group.
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
