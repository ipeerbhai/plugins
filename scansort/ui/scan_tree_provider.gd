extends RefCounted
## Base contract for scan_tree data providers.
##
## A provider supplies the nested node structure that scan_tree renders.
## Subclasses override get_tree_data(). Providers may call MCP tools, so
## get_tree_data() is async — callers must await it.
##
## Node shape (Dictionary):
##   kind:     "folder" | "file"
##   name:     String  — display text in the name column
##   key:      String  — stable identity (e.g. "doc:42" or an absolute path)
##   date:     String  — text for the date column (files; "" for folders)
##   tooltip:  String  — name-column tooltip ("" for none)
##   children: Array   — nested nodes (folders only; ignored for files)
##
## The same scan_tree component is used for the source pane, the vault
## destination pane, and the disk destination pane — only the bound
## provider differs.
##
## No class_name — off-tree plugin script; loaded via preload().

## Override: return an Array of node Dictionaries (the tree's top level).
## Async — implementations may await MCP calls.
func get_tree_data() -> Array:
	return []

## Optional: a short human label for the provider's source, for pane headers.
func get_source_label() -> String:
	return ""
