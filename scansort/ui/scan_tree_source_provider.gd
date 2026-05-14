extends "scan_tree_provider.gd"
## scan_tree provider backed by the plugin's transitory source directory.
##
## Renders the supported document files (.pdf/.docx/.xlsx/.xls) under the
## source directory — set via minerva_scansort_set_source_dir — as a flat,
## name-sorted list of file nodes. Each node carries an `in_vault` flag
## (surfaced in the tooltip) for dedup feedback.
##
## U5: session marks from the batch pipeline are pushed in via
## set_session_marks(). Files in the processed set or with in_vault=true get
## a ✓ prefix on their display name; low-confidence files also note that in
## their tooltip.
##
## File keys are absolute paths so callers can map a selected row back to disk.
##
## No class_name — off-tree plugin script; loaded via preload().

var _conn: Object = null
var _vault_path: String = ""
var _source_dir: String = ""

## U5: session mark sets pushed by ScansortPanel after each batch step.
## Keys are absolute file paths; used as a set (value is always true).
var _processed_keys: Dictionary = {}
var _low_confidence_keys: Dictionary = {}


## U5: called by ScansortPanel to push current session state so the source
## tree reflects batch-pipeline progress on the next refresh().
func set_session_marks(processed: Dictionary, low_confidence: Dictionary) -> void:
	_processed_keys = processed
	_low_confidence_keys = low_confidence


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

		# U5: show a ✓ mark when the file is in the vault or was processed this
		# session. Low-confidence files get an extra note in the tooltip.
		var is_done: bool = in_vault or _processed_keys.has(fpath)
		var is_low_conf: bool = _low_confidence_keys.has(fpath)
		var display_name: String = ("✓ " if is_done else "") + fname
		var tooltip: String = "%s\nIn vault: %s\nSize: %d bytes" % [
			fpath, ("yes" if in_vault else "no"), size,
		]
		if is_low_conf:
			tooltip += "\n(low confidence)"

		nodes.append({
			"kind": "file",
			"name": display_name,
			"key": fpath,
			"date": "",
			"tooltip": tooltip,
			"children": [],
			"in_vault": in_vault,
		})

	return nodes
