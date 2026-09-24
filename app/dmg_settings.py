# dmgbuild settings: the app on the left, Applications on the right, the arrow between them.
#   dmgbuild -s app/dmg_settings.py -D app="build/First Edit.app" "FirstEdit" dist/First-Edit-X.dmg
import os

app = defines.get("app", "build/First Edit.app")  # noqa: F821 (dmgbuild injects `defines`)
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
# The icon actool compiled out of app/make_icon.py's layered document: the
# same picture the Dock shows, flattened by actool at every size it declares,
# so the disk image is not the one place with an older one.
badge_icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = "builtin-arrow"
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (165, 190), "Applications": (495, 190)}
