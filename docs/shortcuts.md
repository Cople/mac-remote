# 快捷键

快捷键模式会根据当前应用的 Bundle ID 自动适配，网页同步显示实际组合键。

| 应用 | 操作 | 快捷键 |
| --- | --- | --- |
| 腾讯视频 | 全屏切换 | fn F |
| 爱奇艺 | 全屏切换 | ⌘ F |
| 优酷 | 上一集 / 下一集 | ⌥ ← / ⌥ → |
| 其他应用 | 全屏、上一个、下一个 | F、[、] |

## 读取菜单快捷键

应用获得辅助功能权限后，可用以下命令导出当前前台应用公开的菜单快捷键，以及其窗口是否提供全屏、缩放按钮：

```sh
"dist/Mac Remote.app/Contents/MacOS/MacRemote" --list-shortcuts
```

只读取菜单，不触发任何操作。未显示在菜单栏中的播放器内部快捷键可能无法获取，菜单修饰键字段也不保证包含系统级 Fn 组合键。

## 全屏与最大化

系统全屏、桌面内最大化、播放器内部全屏是不同操作。支持原生窗口控件的应用可通过辅助功能调用全屏或缩放按钮；自定义播放器仍可能需要专用快捷键。

较新 macOS 的填满桌面快捷键为 Fn-Control-F，还原为 Fn-Control-R；系统全屏通常可用 Control-Command-F 切换。具体支持取决于应用和系统版本。

参考：[Apple 窗口快捷键](https://support.apple.com/guide/mac-help/mchl9674d0b0/mac)、[Apple 全屏操作](https://support.apple.com/guide/voiceover/vo36642/mac)。
