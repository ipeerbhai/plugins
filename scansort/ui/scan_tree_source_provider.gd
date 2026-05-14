extends "scan_tree_provider.gd"
## scan_tree provider backed by the plugin's transitory source directory.
##
## Renders the supported document files (.pdf/.docx/.xlsx/.xls) under the
## source directory — set via minerva_scansort_set_source_dir — as a flat,
## name-sorted list of file nodes. Each node carries an `in_vault` flag
## (surfaced in the tooltip) for dedup feedback; the visible ✓ indicator is
## a later round's concern.
##
## File keys are absolute paths so callers can map a selected row back to disk.
##
## No class_name — off-tree plugin script; loaded via preload().

var _conn: Object = null
var _vault_path: String = ""
var _source_dir: String = ""


## Attach the plugin connection + optional vault path (enables in_vault dedup).
## Call before get_tree_data().
func init(conn: Object, vault_path: String = "") -> void:
	_conn = conn
	_vault_path = vault_path


func get_source_label() -> String:
	if _source_dir.is_empty():
		return "Source"
	return "Source: " + _source_dir.get_file()


func get_tree_data() -> Array:
	if _conn == null:
		return []

	# Resolve the current source dir for the pane label.
	var dir_result: Dictionary = await _conn.call_tool(
		"minerva_scansort_get_source_dir", {},
	)
	if dir_result.get("ok", false):
		_source_dir = str(dir_result.get("path", ""))

	var args: Dictionary = {}
	if not _vault_path.is_empty():
		args["vault_path"] = _vault_path

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_list_source_files", args,
	)
	if not result.get("ok", false):
		push_warning("[SourceProvider] list_source_files failed: %s" % result.get("error", "unknown"))
		return []

	var files: Array = result.get("files", [])
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")) < str(b.get("name", ""))
	)

	var nodes: Array = []
	for f: Dictionary in files:
		var fpath: String = str(f.get("path", ""))
		var fname: String = str(f.get("name", "unknown"))
		var in_vault: bool = bool(f.get("in_vault", false))
		var size: int = int(f.get("size", 0))
		nodes.append({
			"kind": "file",
			"name": fname,
			"key": fpath,
			"date": "",
			"tooltip": "%s\nIn vault: %s\nSize: %d bytes" % [
				fpath, ("yes" if in_vault else "no"), size,
			],
			"children": [],
			"in_vault": in_vault,
		})

	return nodes
