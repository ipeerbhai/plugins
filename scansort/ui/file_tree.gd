extends Tree
## Scansort vault file tree — T7 R2.
##
## Left-pane vault browser: groups documents by category as tree items.
## Tree shape: (hidden root) → category item → doc-row item
##
## No class_name — off-tree script; loaded via preload() from ScansortPanel.gd.
##
## Dropped from experiment's file_tree.gd (out of R2 scope):
##   - INCOMING / ORGANIZED mode duality (filesystem scan) — vault-only here
##   - Scanner._is_supported() dependency — not available off-tree
##   - EventLog status colouring (incoming pipeline) — R3
##   - Upload bar / mark-for-upload UI — R3
##   - Drag-and-drop reclassification (filesystem moves) — R3+
##   - Export-upload button / unmark — R3
##   - ScanConfig concurrency dependency — R5
##
## call_tool is async: every conn.call_tool() MUST be awaited.

signal document_selected(doc_id: int)

# Column indices.
const COL_NAME := 0
const COL_DATE := 1

# Category row colour.
const COLOR_CATEGORY := Color(0.9, 0.85, 0.6)   # warm yellow
# Document row colour.
const COLOR_DOC      := Color(0.75, 0.85, 0.75)  # soft green

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _conn: Object = null           # MCPServerConnection (or null)
var _vault_path: String = ""
var _all_docs: Array = []          # cached result of last query

# ---------------------------------------------------------------------------
# Initialisation
# ---------------------------------------------------------------------------

## Called by ScansortPanel._build_ui() immediately after instantiation
## so the tree is usable before a vault is opened.
func _ready() -> void:
	hide_root = true
	columns = 2
	set_column_expand(COL_NAME, true)
	set_column_clip_content(COL_NAME, true)
	set_column_expand(COL_DATE, false)
	set_column_custom_minimum_width(COL_DATE, 80)
	select_mode = Tree.SELECT_ROW
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_selected.connect(_on_item_selected)


## Attach vault connection + path, then populate. Called by ScansortPanel.
func init(conn: Object, vault_path: String, _password: String) -> void:
	_conn = conn
	_vault_path = vault_path
	refresh()


## Repopulate from the vault via MCP.
func refresh() -> void:
	clear()
	_all_docs.clear()

	if _conn == null or _vault_path.is_empty():
		return

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": _vault_path}
	)
	if not result.get("ok", false):
		push_warning("[FileTree] query_documents failed: %s" % result.get("error", "unknown"))
		return

	_all_docs = result.get("documents", [])
	_populate(_all_docs)


## Clear the tree and reset state (called on vault close).
func clear_vault() -> void:
	clear()
	_all_docs.clear()
	_conn = null
	_vault_path = ""


# ---------------------------------------------------------------------------
# Tree population
# ---------------------------------------------------------------------------

func _populate(docs: Array) -> void:
	clear()

	# Group documents by category.
	var by_category: Dictionary = {}
	for doc: Dictionary in docs:
		var cat: String = str(doc.get("category", "uncategorized"))
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(doc)

	# Sort category names alphabetically.
	var sorted_cats: Array = by_category.keys()
	sorted_cats.sort()

	var tree_root: TreeItem = create_item()  # hidden root

	for cat: String in sorted_cats:
		var cat_docs: Array = by_category[cat]

		# Category header item.
		var cat_item: TreeItem = create_item(tree_root)
		cat_item.set_text(COL_NAME, "%s/ (%d)" % [cat, cat_docs.size()])
		cat_item.set_custom_color(COL_NAME, COLOR_CATEGORY)
		cat_item.set_selectable(COL_NAME, false)
		cat_item.set_selectable(COL_DATE, false)
		cat_item.set_meta("is_category", true)

		# Sort docs within category by display name.
		cat_docs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var da: String = str(a.get("display_name", a.get("original_filename", "")))
			var db: String = str(b.get("display_name", b.get("original_filename", "")))
			return da < db
		)

		for doc: Dictionary in cat_docs:
			var doc_id: int = int(doc.get("doc_id", 0))
			var display: String = str(doc.get("display_name", doc.get("original_filename", "unknown")))
			var date: String   = str(doc.get("doc_date", ""))
			var sender: String = str(doc.get("sender", ""))
			var desc: String   = str(doc.get("description", ""))

			var doc_item: TreeItem = create_item(cat_item)
			doc_item.set_text(COL_NAME, display)
			doc_item.set_custom_color(COL_NAME, COLOR_DOC)
			doc_item.set_tooltip_text(COL_NAME, "%s\nSender: %s\n%s" % [display, sender, desc])
			doc_item.set_text(COL_DATE, date)
			doc_item.set_custom_color(COL_DATE, Color(0.6, 0.6, 0.6))
			doc_item.set_meta("doc_id", doc_id)
			doc_item.set_meta("is_category", false)


# ---------------------------------------------------------------------------
# Signal handler
# ---------------------------------------------------------------------------

func _on_item_selected() -> void:
	var sel: TreeItem = get_selected()
	if sel == null:
		return
	if sel.get_meta("is_category", false):
		return  # category header — ignore
	var doc_id: int = int(sel.get_meta("doc_id", -1))
	if doc_id >= 0:
		document_selected.emit(doc_id)
