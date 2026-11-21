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

### Swift 单测资源

直接运行 `swift test`、筛选用例和性能脚本都使用同一套资源管理，需要 PATH 中可用的 Python 3。首次清理偏好时使用 Xcode 工具链编译辅助程序，后续复用。测试代码通过 `TestRunResources.directory` 创建各自的样本目录，通过 `newDefaultsDomain()` 取得独立的真实偏好域。同一用例需要模拟重启时，把取得的域名传给多个实例。

每个使用这些资源的测试进程在 `.nyaeh-verification/unit-runs/` 下持有独立文件锁。普通通过和断言失败都会回收数据库、WAL/SHM、样本和已登记的偏好；使用真实偏好的轮次在清除后第 1、5、15 秒复查整批 plist，以捕获 macOS 延迟落盘。被强制终止的进程由后续单测或验证入口回收。只保留用于复查偏好回写的精简登记，最长 30 天。完整验收若在 Swift 单测阶段失败，错误输出和退出码可在对应会话的 `unit-tests.log` 和报告中查看。

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

### 一次性专项验证

用 `./script/verify.sh scratch -- <命令> [参数…]` 执行临时探针或截图脚本。命令在新建的专项工作目录启动，继承终端输出，并将退出码返回给调用方。通过 `NYAEH_PROJECT_ROOT` 读取项目，生成的临时源码、样本和截图放在当前目录。需要交付的文件由命令显式复制到自己指定的外部路径。

```bash
./script/verify.sh scratch -- sh -c 'printf "fixture\n" > sample.txt && test -s sample.txt'
```

通过本轮 PATH 调用带 `-scheme` 的 `xcodebuild` 时会自动使用本轮的 DerivedData，嵌套脚本同样生效。若脚本通过 `xcrun` 或绝对路径绕过 PATH，请显式传入 `-derivedDataPath "$NYAEH_SCRATCH_DERIVED_DATA"`。临时 SwiftPM 工程在本轮目录内构建，命令也可使用 `NYAEH_SCRATCH_DIR` 指定专用输出。成功后工作目录立即回收；失败或中断现场保留 7 天，由后续验证入口清理。普通开发构建继续用现有缓存。刚退出的 QA 宿主会预留最多 15 秒让 AppKit 写回窗口状态，再清除偏好并复查。已结案 QA 的独立偏好域会在后续验证入口和记录过期前再次检查。

如果需要验证Xcode shell：

```bash
xcodebuild -project Packaging/NyaEH/NyaEH.xcodeproj -scheme NyaEH -configuration Debug build
```

Release 构建可使用Xcode shell；默认版本写在 Xcode project 中，也可以在命令行覆盖：

```bash
xcodebuild -project Packaging/NyaEH/NyaEH.xcodeproj -scheme NyaEH -configuration Release build MARKETING_VERSION=1.6.0 CURRENT_PROJECT_VERSION=160
```

## 本地发行候选

将独立公开更新签名密钥对应的公钥通过 `NYAEH_SPARKLE_PUBLIC_KEY` 提供给构建脚本。私钥留在 Keychain 中，不导出或提交。

```bash
./script/build_public_candidate.sh /private/tmp/NyaEH-Public-1.6.0-160.app.zip
```

脚本只在本机构建、裁剪、ad-hoc 签名、校验和打包，不负责上传或公证。打包前会检查 Xcode 已编译分层图标 `AppIcon.icon`，且包内图标字段和资源齐全。当前默认版本为 1.6.0（build 160）；修改发布版本时同步更新 Xcode 工程、脚本和更新日志。GitHub 普通 Release 不代表通过 Apple 公证；当前包仍为 ad-hoc 签名，须保留未公证提示。Developer ID 签名和 Apple 公证另行完成。

### 发布公开更新

1. 使用公开版独立密钥签署最终 ZIP，保存签名、长度、SHA-256、版本和构建号。签署后不要重打包。公开密钥与 App 内的 `SUPublicEDKey` 必须一致。
2. 先上传新 ZIP 到公开版仓库的对应 Release，验证下载字节与本地一致。再按发布版本生成更新记录，使用 Release 资产的公开下载 URL，不使用带令牌的 API 地址。
3. 先创建草稿 Release 并上传、下载验证 ZIP，再发布为普通 Release 并设为 Latest（不勾选预览版）。随后在 `updates/appcast.xml` 顶部加入新版本，保留历史条目，重新签署并验签后提交推送，避免更新源先指向不可下载的资产。tag 指向发布准备提交，更新源使用后续独立提交；不要修改已发布 ZIP、重用 tag 或覆盖旧资产。
4. 用不带 `Authorization` 的请求验证 GitHub Contents API、raw 更新清单和 Release ZIP。比较下载到的清单与签名版本，并核对 ZIP 的 SHA-256、大小和构建号。完整自动升级要用已安装的较低公开版本做隔离测试。

签署清单时使用公开版的 Keychain 账户：

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update --account com.gazelee.NyaEH.public updates/appcast.xml
.build/artifacts/sparkle/Sparkle/bin/sign_update --account com.gazelee.NyaEH.public --verify updates/appcast.xml
```

私有版不会自动切换到公开版。首次切换需要手动安装；不要复用私有 appcast、密钥或更新令牌。

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
