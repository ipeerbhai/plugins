extends RefCounted
## UI scale helper for plugin dialogs.
##
## Window-derived dialogs (AcceptDialog, ConfirmationDialog, FileDialog) are
## top-level OS windows and don't inherit `content_scale_factor` from the
## main viewport. Minerva sets the root's content_scale_factor when the user
## bumps the UI scale (via menuMain.gd / app_shell_base.gd) but sub-windows
## stay at 1.0 until each one explicitly mirrors the root.
##
## Call ScansortUiScale.apply_to(self) from each dialog's _ready() to honor
## the user's chosen scale. Safe in headless tests — returns silently when
## no SceneTree is available.

## Apply the root viewport's content_scale_factor to `window`.
## No-op if window is null, has no content_scale_factor property, or no
## SceneTree is active (e.g. headless test_in_memory paths).
static func apply_to(window) -> void:
	if window == null:
		return
	var loop = Engine.get_main_loop()
	if loop == null or not ("root" in loop):
		return
	var root = loop.root
	if root == null:
		return
	if "content_scale_factor" in window:
		window.content_scale_factor = root.content_scale_factor
