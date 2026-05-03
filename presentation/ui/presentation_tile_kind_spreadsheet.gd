class_name Presentation_TileKindSpreadsheet
extends "presentation_tile_kind_base.gd"
## Presentation tile annotation kind: presentation_tile_spreadsheet.
##
## Represents a spreadsheet tile on a slide. All geometry is inherited from
## Presentation_TileKindBase. This subclass only declares the kind identity.
##
## kind:         &"presentation_tile_spreadsheet"
## display_name: "Spreadsheet Tile"
## owning_plugin: &"presentation"


func _init() -> void:
	super()
	name = &"presentation_tile_spreadsheet"
	display_name = "Spreadsheet Tile"
