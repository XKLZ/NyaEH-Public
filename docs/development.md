# NyaEH 开发指南

[返回首页](../README.md) · [使用指南](user-guide.md)

## 开发者说明

NyaEH 的核心代码是 SwiftPM 包：包名是 `NyaEH`，主模块是 `NyaEHCore`。源码和 Xcode 打包外壳同在公开版仓库。

主要产品：

- `NyaEHCore`：library product，包含 UI、Stores、Services、Models、Database 和 Support。
- `NyaEHDevRunner`：SwiftPM 开发运行 executable。
- `NyaEHScene`：共享 SwiftUI `Scene` 入口。
- `Packaging/NyaEH`：Xcode macOS app shell，负责 app 名称、图标、Bundle ID、sandbox、签名、hardened runtime、Info.plist 和 distributable `.app` 构建。

常用开发命令：

```bash
swift build
swift test
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/semantic_series_verify.sh
```

Codex Run button 当前指向：

```bash
./script/build_and_run.sh
```

`./script/build_and_run.sh` 启动持久的 **NyaEH 开发版**（`dist/NyaEHDev.app`），继续使用 `.nyaeh-dev`。脚本先在临时目录构建完整的新包，成功后才按路径、Bundle ID 和启动时间停止已登记的旧实例并替换；构建失败不影响旧实例。开发版语言设置的“立即重启”也调用此脚本，可能需要等待重新构建。缺少配套启动参数时直接双击开发包会显示启动错误，绝不回退到正式数据库或 Keychain。

### 一次性验收与清理

统一验收入口：

```bash
./script/verify.sh                         # 构建、Swift/Python 测试、启动检查，完成后关闭并清理
./script/build_and_run.sh --verify         # 仅构建与一次性启动检查，同样清理
./script/verify.sh --ui                    # 合成图库人工验收，等待显式结束
./script/verify.sh --ui --sandbox          # 独立 Bundle ID 的 Xcode 沙盒宿主
./script/verify.sh status
./script/verify.sh restart <会话ID>         # 重启同一未清理会话，仍需人工验收
./script/verify.sh finish <会话ID> --passed # 确认人工验收通过，停止并清理
./script/verify.sh finish <会话ID> --failed # 停止，失败现场保留 7 天
./script/verify.sh cleanup --expired
./script/verify.sh cleanup <会话ID>        # 主动清理已登记会话
```

每轮会话使用独立 ID，应用显示“**NyaEH 验收版 · 短 ID**”；沙盒版另标“沙盒”。同一工作区只能运行一个验收实例，切换宿主前先结束上一轮。界面操作请使用命令输出的确切应用路径或 Bundle ID。验收图库仅包含脚本生成的漫画，不读取正式凭据；启动日志、就绪记录和资源清单位于 Git 忽略的 `.nyaeh-verification/`。

成功后清理本轮应用、数据库/WAL/SHM、缓存、备份、偏好和合成文件；失败、中断或待人工验收现场保留 7 天，下次调用入口时清理到期且已停止的会话。精简报告保留 30 天，无后台定时任务。持久开发图库、共享 `.build` 和 Xcode DerivedData 不自动清理。

废纸篓只清理本轮登记、且路径及文件身份仍匹配的合成文件，绝不清空整个废纸篓。清理失败会保留重试记录并在报告中标为未完成。锁屏或无法完成界面操作时维持 `pending-ui`，不能以构建成功代替界面通过。不要修改会话清单或手工移动会话目录。

验收启动必须收到会话 ID、PID、宿主及实际数据路径匹配的应用就绪记录；仅有同名进程不算通过。沙盒包通过 Xcode 命令行覆盖测试标识，并仅对测试产物使用本地 ad-hoc 签名，报告记录这一差异。

如果需要验证Xcode shell：

```bash
xcodebuild -project Packaging/NyaEH/NyaEH.xcodeproj -scheme NyaEH -configuration Debug build
```

Release 构建可使用Xcode shell；默认版本写在 Xcode project 中，也可以在命令行覆盖：

```bash
xcodebuild -project Packaging/NyaEH/NyaEH.xcodeproj -scheme NyaEH -configuration Release build MARKETING_VERSION=1.5.1 CURRENT_PROJECT_VERSION=151
```

## 本地发行候选

将独立公开更新签名密钥对应的公钥通过 `NYAEH_SPARKLE_PUBLIC_KEY` 提供给构建脚本。私钥留在 Keychain 中，不导出或提交。

```bash
./script/build_public_candidate.sh /private/tmp/NyaEH-Public-1.5.1.app.zip
```

脚本只在本机构建、裁剪、ad-hoc 签名、校验和打包。候选包不是正式发布资产。公开版从独立仓库以匿名请求访问 Sparkle 更新源；私有版不会自动切换到公开版。

## 维护脚本

`script/fill_unknown_language_japanese.py` 可把本地数据库中缺失语言、且没有现有 `language:*` tag 的书批量补为日语，并同步 `library_books.tags`、`library_books.language_code`、`tags` 和 `book_tags`。

脚本默认 dry-run，默认数据库为：

```text
~/Library/Application Support/NyaEH/NyaEH.sqlite
```

建议先退出 NyaEH 并预览：

```bash
script/fill_unknown_language_japanese.py
```

确认后再写入；写入前默认创建 `.bak-时间戳` 备份：

```bash
script/fill_unknown_language_japanese.py --apply
```

默认只处理已有 tag 或 gallery metadata 痕迹的 unknown 语言记录。若要处理所有 unknown 且没有 `language:*` tag 的书，可加：

```bash
script/fill_unknown_language_japanese.py --apply --include-unscanned
```

## 性能验证

开发者可运行独立的大书库性能验证（5 千、1 万、3 万条合成记录）：

```bash
./script/performance_verify.sh
```
