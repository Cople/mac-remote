# 签名

本地执行 `Scripts/build.sh` 时，首次生成固定的自签名代码证书，后续打包始终复用。签名资料保存在：

```text
~/Library/Application Support/Mac Remote/Signing/
```

请备份整个目录，不要删除或提交到仓库。清理 `.build`、`dist` 或重新拉取项目不会更换证书。已有目录损坏时，脚本会停止，不会自动换证书。

从旧的临时签名包迁移后，需要在「系统设置 → 隐私与安全性 → 辅助功能」中移除旧条目，再添加当前应用并开启一次。之后请保持相同的证书与 Bundle ID，并在固定位置更新应用。每次构建的代码哈希可以不同，证书身份保持不变。

## GitHub Actions

先在本机导出供 CI 使用的文件：

```sh
python3 Scripts/sign-app.py --export-ci
```

命令只显示文件路径。在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 添加：

| Secret | 内容 |
| --- | --- |
| `MAC_REMOTE_SIGNING_CERTIFICATE` | `certificate.base64` 文件的完整内容 |
| `MAC_REMOTE_SIGNING_PASSWORD` | `password.txt` 文件的完整内容 |

推送和手动构建必须提供这两个 Secrets，否则停止打包。PR 预览包不读取 Secrets，使用临时签名；安装预览包可能需要重新授权辅助功能。本地和 CI 使用同一份证书，更新时才能保持身份一致。

## 其他证书

已有代码签名身份时，可以显式指定：

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build.sh
```

也可设置 `MAC_REMOTE_SIGNING_P12`（P12 路径）和 `MAC_REMOTE_SIGNING_PASSWORD`，由脚本临时导入并在签名后清理。使用 `CODE_SIGN_IDENTITY=-` 可显式生成临时签名测试包。

本地自签名证书不会修改系统信任设置，也不等同于 Apple Developer ID 签名或公证。
