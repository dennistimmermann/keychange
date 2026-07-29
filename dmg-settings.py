# dmgbuild settings for the release disk image. dmgbuild writes the Finder
# layout (.DS_Store) directly instead of scripting Finder, which is why it works
# on a headless CI runner where create-dmg's AppleScript silently fails.
#
#   dmgbuild -s dmg-settings.py -D app=export/Keychange.app Keychange Keychange.dmg
#
# Geometry matches docs/background.tiff (source: docs/background.html):
# 660×400 window, 128pt icons centered at (165, 210) and (495, 210).

app = defines.get("app", "export/Keychange.app")  # noqa: F821

files = [(app, "Keychange.app")]
symlinks = {"Applications": "/Applications"}

background = "docs/background.tiff"
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 12
icon_locations = {
    "Keychange.app": (165, 210),
    "Applications": (495, 210),
}

format = "UDZO"
