# Sniplet

**截得刚刚好。** A free, open-source, native screenshot utility for macOS.

Capture, annotate, beautify, then share — without leaving the selection. Built with Swift, SwiftUI/AppKit and ScreenCaptureKit. No account, cloud service, analytics, or network entitlement in the app.

[官网 / Website](https://sniplet.elazer.wang/) · [下载 / Downloads](https://github.com/rockythink/Sniplet/releases/latest) · [反馈 / Issues](https://github.com/rockythink/Sniplet/issues)

## Download & install

**v0.5.0 · build 11 · macOS 14+ · Universal (Apple Silicon + Intel)**

- [Download DMG](https://github.com/rockythink/Sniplet/releases/download/v0.5.0/Sniplet-0.5.0-universal.dmg)
- [Download ZIP](https://github.com/rockythink/Sniplet/releases/download/v0.5.0/Sniplet-0.5.0-universal.zip)
- [SHA-256 checksums](https://github.com/rockythink/Sniplet/releases/download/v0.5.0/SHA256SUMS)

Official v0.5.0 downloads are Developer ID signed, securely timestamped, Apple-notarized and stapled. Both app and DMG passed Gatekeeper assessment as `Notarized Developer ID`. This does not certify every feature or hardware/system combination.

打开 DMG，把 **Sniplet.app** 拖进 **Applications / 应用程序**。启动后在菜单栏找裁剪图标；默认截图快捷键是 **Shift + Command + A（⇧⌘A）**。

macOS 将读取屏幕画面的权限称为“屏幕录制”或“录屏与系统音频录制”。首次截图时按应用引导，在系统设置中允许 `/Applications/Sniplet.app`。Sniplet 只抓取单帧，不录制视频、音频或鼠标指针。系统如要求重开，请手动退出再打开；不要重置所有应用的权限或移除安全隔离属性。

## Features

| 功能 | 行为 |
| --- | --- |
| 截取 | 默认入口悬停/单击选窗口，拖动截区域；另有独立窗口与整屏入口。区域限制在起始显示器，不跨屏拼接 |
| 原位编辑 | 工具条就在选区旁；箭头、矩形、画笔、文字、马赛克、高亮，支持移动、调整、删除、撤销与重做 |
| 调整取景框 | 拖动四角或四边缩放；在“选择”工具下拖动没有标注的位置移动。沿用冻结底图，不重新读取屏幕；窗口/整屏截图也可在原始底图内缩放。缩放时标注保持对齐原始像素，支持整步撤销与重做 |
| 选区提示框 | 设置 → 截图外观，可自选颜色与实线、虚线、点线；截图与编辑共用设置，仅影响操作提示，不印进最终图或 OCR |
| 默认美化 | 原图、轻柔、细框、展示四种预设；圆角、阴影与边框可调，并可设为之后截图的默认 |
| 输出 | 复制、保存 PNG、钉图与独立拖出手柄。使用同一版本的最终成图，不导出工具条、控制点或可恢复图层 |
| 拖出 | 真实拖动后才准备数据；同一项提供最终 PNG 文件 URL、PNG/TIFF 和文件承诺，兼顾文件型与图像型接收端；取消继续编辑 |
| 钉图 | 多张只读最终图独立缩放、移动、复制和关闭 |
| 本地 OCR | Vision 中文/英文识别；只识别处理后的最终图。编辑、撤销或取消会使旧结果失效 |
| 本地历史 | 最终 PNG 与缩略图，可按日期、文件名和已完成 OCR 搜索。可关闭、删除、清空；默认最多 500 张且图片合计不超过 1 GiB |
| 可选功能 | OCR 和临时复制标记可独立选择；不检测或联动其他应用 |

### 快捷键与操作

- 默认区域入口 **⇧⌘A**；窗口 **⌃⌥⌘5**；整屏 **⌃⌥⌘3**。设置内可改绑、清除、恢复默认；原有自定义不会被覆盖。
- **Return / ⌘C**：复制最终图并完成；文字编辑或选中文字时，⌘C 优先文本复制。
- **⌘S** 保存 PNG；**⌘Return** 不复制、只存入历史并关闭；**⌘Z / ⇧⌘Z** 撤销 / 重做。
- 画完一个标注后工具保持不变，可连续标注；单键切换工具：**V** 选择、**A** 箭头、**R** 矩形、**P** 画笔、**T** 文字、**M** 马赛克、**H** 高亮。
- 拖动中 **Esc** 还原本次操作；使用绘图工具时第一次 Esc 回到选择，在选择工具下再按 Esc 才丢弃当前截图。跨应用拖出请用侧边独立手柄，不是拖动标注画布。

## Privacy & boundaries

- App Sandbox + Hardened Runtime。业务 entitlement 只有 `app-sandbox` 和 `files.user-selected.read-write`；无网络、麦克风、相机、辅助功能控制、输入监控或 iCloud 权限。
- 不为编辑底图另存副本，不保存可恢复图层或撤销栈。历史只保存最终图及其 OCR。编辑中崩溃或强退不能恢复未完成截图。
- 兼容文件型拖放会暂存**最终 PNG**，和历史开关独立。取消删除本次文件；接收后延迟 10 分钟清理，供源界面关闭后的读取。退出打断的过期清理在下次拖出时补做，也可能由系统清理临时目录。
- 复制使用 `currentHostOnly`，不轮询系统剪贴板。你主动导出到聊天、云盘或其他联网应用后，后续处理由接收方决定。
- 马赛克是视觉像素化，不是密码学不可恢复保证。已经主动复制出去的图像或文字，不能被后续打码追溯撤回。
- SwiftData 明确关闭 CloudKit；关闭历史不自动删除旧记录，清空需要明确确认。本地历史不是加密保险箱。
- 官网是独立 Cloudflare 静态站，不含分析/广告脚本。托管服务仍可能处理正常访问日志；网站的托管网络行为与本机应用权限是两回事。

## Build from source

Toolchain used for v0.5.0: **Xcode 27.1 / Swift 6.4**, XcodeGen 2.46.0. Source uses Swift 6 complete concurrency checking and MainActor default isolation. Minimum deployment target is macOS 14.

`project.yml` is the project configuration source; regenerate after configuration changes. The checked-in Xcode project is generated, not maintained separately.

### Contributor / local unsigned development build

You do **not** need the maintainer's certificate. Override the official signing settings for your own local build:

```sh
xcodegen generate --spec project.yml
xcodebuild -project Sniplet.xcodeproj -scheme Sniplet \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/ContributorDerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS= build
```

On an Intel development machine, change `arch=arm64` to `arch=x86_64`. An ad-hoc development build is not an official public download and may need its own screen-capture permission. Do not replace a signed installation you depend on with a differently signed build and expect its TCC authorization to transfer.

### Isolated automated tests — no desktop automation

```sh
env SNIPLET_UNIT_TESTS=1 xcodebuild \
  -project Sniplet.xcodeproj -scheme Sniplet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS= \
  -only-testing:SnipletTests test
```

The Debug-only test host does not start capture, global shortcuts, menu UI, or the real history service. Tests use synthetic images, private pasteboards and temporary directories, not the general clipboard or user screenshots. Release ignores this test-host switch. Never install the ad-hoc test host as your normal app.

### Maintainer distribution

Normal maintainer builds retain the fixed Developer ID/team/Bundle ID in `project.yml`; those identifiers are public, not private keys. Local builds use `--timestamp=none` and **are not automatically notarized**. Public packaging signs a separate copy with a secure timestamp and submits it to Apple:

```sh
xcodebuild -project Sniplet.xcodeproj -scheme Sniplet \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/ReleaseDerivedData \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

scripts/package-release.sh \
  --identity 'Developer ID Application: YOUR NAME (TEAM_ID)' \
  --notarize
```

Packaging requires the matching Developer ID identity, Xcode tools, `jq`, and configured `asc` authentication. It verifies both architectures and entitlements, notarizes/staples app and DMG, checks actual DMG/ZIP contents, and writes checksums under `.build/Distribution/Sniplet-VERSION/`. It refuses to overwrite an existing version directory. No private key, API credential or certificate is included in this repository.

## Website

Astro static site, with locally bundled Manrope and Noto Sans SC fonts. No runtime API or database.

```sh
npm --prefix website ci
npm --prefix website run dev -- --host 127.0.0.1 --port 4346
npm --prefix website run build
```

`website/src/data/release.json` holds the displayed version and download URLs. `website/wrangler.jsonc` deploys only `website/dist` to the dedicated static Worker/domain. Deployment requires the maintainer's separately authorized Cloudflare login; account IDs in the configuration are not credentials.

The homepage's editable beautification sample is **explicitly labeled an illustration**, not a real app screenshot or a screen-reading feature. The website cannot access your screen.

## Verification status

- v0.5.0: **170 tests passed / 258 parameterized runs**, 0 failures or skips, on Apple Silicon and macOS 27.0.1.
- Actual synthetic PNG smoke covered resize, source-pixel alignment, fractional annotations, one-step undo/redo, move, clamp/cancel, style preservation and unchanged PNG bytes when changing selection hints. Unattached native scroll views reproduced the old recentering drift, then verified fixed opposite edges and pointer-matched resizing at 25% and 200% zoom. No visible window or real capture was used.
- Earlier drag-path smoke covered private native file/image representations and background Objective-C file-promise callbacks.
- Public v0.5.0 app ZIP and DMG notarization were both **Accepted**; stapled tickets and Gatekeeper acceptance were verified.
- **Not separately certified:** macOS 14 runtime, real Intel hardware, every chat/browser drop target, VoiceOver, IME edge cases, or real-device performance targets. A universal binary, passing unit tests and Apple notarization are not substitutes for these checks.
- Native desktop interaction is manually tested by users; automated checks do not take over the desktop or trigger real captures.

When reporting a bug, include app version, macOS version and exact steps. Do not publish sensitive screenshots or personal logs.

## License & attribution

Sniplet is [MIT licensed](LICENSE), © 2026 Elazer.

Selection/editor interaction geometry, image effects and final-file drag payload patterns adapt portions of [CapCap](https://github.com/realskyrin/capcap), pinned to `7dd035225eaa41e6da8a5156556a8c4dd7bd028b`. The original copyright and MIT license are retained in [ThirdPartyNotices.txt](Sniplet/Resources/ThirdPartyNotices.txt), included in the app bundle. CapCap's recording, scrolling capture, cloud upload and global keyboard monitoring are not part of Sniplet.

Website font licenses: [Manrope](website/public/licenses/Manrope-OFL.txt) and [Noto Sans SC](website/public/licenses/NotoSansSC-OFL.txt), SIL Open Font License. Fonts and artwork are served locally, not through a font CDN.
