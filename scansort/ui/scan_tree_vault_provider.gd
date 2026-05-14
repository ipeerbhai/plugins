extends "scan_tree_provider.gd"
## scan_tree provider backed by a .ssort vault.
##
## Renders vault documents grouped by category — a two-level tree of
## (category folder) -> (document file). Replaces what the old file_tree.gd
## did inline; the rendering itself now lives in the generic scan_tree.
##
## Document keys are "doc:<doc_id>" so callers can map a selected row back
## to a vault document.
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
		return "Vault"
	return "Vault: " + _vault_path.get_file()


func get_tree_data() -> Array:
	if _conn == null or _vault_path.is_empty():
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": _vault_path},
	)
	if not result.get("ok", false):
		push_warning("[VaultProvider] query_documents failed: %s" % result.get("error", "unknown"))
		return []

	var docs: Array = result.get("documents", [])

	# Group documents by category.
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
