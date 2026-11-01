# Mac Remote

原生 macOS 菜单栏遥控器，通过同一局域网内的手机浏览器控制 Mac。支持 macOS 13 及以上。

## 使用

1. 从 GitHub Releases 下载 `MacRemote-universal.zip`，解压后放入「应用程序」。
2. 启动应用，授予辅助功能权限，并允许本地网络访问。
3. 点击菜单栏图标，手机扫码打开遥控页。

支持播放暂停、快进快退、长按倍速、全屏、弹幕、媒体按键、音量和通知清理。已适配腾讯视频、爱奇艺和优酷，见[快捷键说明](docs/shortcuts.md)。

默认端口 **18765**，被占用时依次顺延。菜单栏可开关配对密钥；开启时使用 **6 位数字配对码**。

## 开发

需要 Xcode 和 Swift 5.9+；测试另需 Node.js。

```sh
./Scripts/build.sh             # 当前架构
./Scripts/build.sh --universal # Apple Silicon + Intel
open "dist/Mac Remote.app"
./Scripts/test.sh
```

## 自动打包

推送代码、提交 PR 或手动运行 Actions，自动测试并生成通用 ZIP 包和 SHA-256 校验文件，可在运行记录的 Artifacts 中下载。

推送版本标签会同步设置应用版本并发布 GitHub Release：

```sh
git tag v1.0.0
git push origin v1.0.0
```

本地打包自动复用固定签名证书；CI 需配置同一证书的两个 Secrets，见[签名配置](docs/signing.md)。PR 预览包使用临时签名。应用未公证。

图标来自 [Remix Icon 4.6.0](https://github.com/Remix-Design/RemixIcon/tree/v4.6.0)，遵循 [Apache 2.0](Sources/MacRemote/Resources/RemixIcon/License)。
