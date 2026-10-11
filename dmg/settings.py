# dmgbuild 配置：dmgbuild -s settings.py -D app=<ClashLite.app> -D background=<background.tiff> ClashLite <输出.dmg>
# 窗口尺寸与图标位置需与 background.swift 保持一致

import os.path

app = defines["app"]  # noqa: F821
app_name = os.path.basename(app)

format = "ULFO"  # lzfse 压缩，macOS 10.11 起支持
filesystem = "APFS"

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
icon_locations = {
    app_name: (180, 190),
    "Applications": (460, 190),
}
