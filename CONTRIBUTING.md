# 贡献指南

感谢愿意一起改进 CutPlayer。本文档说明**怎么跑起来、代码怎么写、哪些约定不能破**。

---

## 1. 环境准备

```bash
brew install ffmpeg mpv          # 构建期依赖（会被捆绑进 .app）
git clone <repo> && cd CutPlayer
./scripts/build_app.sh arm64 release
open build/CutPlayer.app
```

- 仅支持 **Apple Silicon**；`/opt/homebrew` 是 arm64 Homebrew 前缀（Intel 机器需改 `Package.swift` 与 `scripts/build_app.sh` 里的路径）
- 受限沙箱里构建若报 `sandbox_apply: Operation not permitted`，加 `CUTPLAYER_NO_SWIFT_SANDBOX=1`

---

## 2. 提交前必须跑的检查

```bash
make test        # 单元测试（自研 harness，headless）
make selftest    # 端到端自检：真实解码 → LUT → 曲线 → 截图 → 导出，再比 PSNR
```

`make selftest` 的 JSON 里 `pass` 必须为 `true`。**涉及画面、色彩、导出的改动，请在 PR 里贴出
PSNR 数值的前后对比**（例如 `lutScreenshotMatchesReference` 从 39.1 → 38.4 dB）。

---

## 3. 不能破坏的约定

这几条是这个项目的存在理由，PR 里请逐条确认：

| 约定 | 说明 |
|---|---|
| **mpv 只做音频与时钟** | 不要引入 mpv 的视频输出或渲染 API（`vo` / `render.h`）|
| **LUT 先生效，曲线在 LUT 之后** | 顺序颠倒会改变监看语义 |
| **曲线绝不进截图与导出** | 导出链只允许 `lut3d`，永远不要拼 `curves` |
| **4K 全尺寸播放** | 不引入"播放时降采样"的方案（性能问题请优化管线，别降画质）|
| **seek 不 hold-and-stall** | 落后目标时间的帧直接丢弃 |
| **音频等画面** | seek/换片时保持"目标帧绘制完成才释放音频" |
| **无第三方 Swift 依赖** | 新增依赖请先开 issue 讨论 |

---

## 4. 代码风格

- Swift 5.9，无外部依赖；`Sources/CutPlayerKit/` 下按 `App / Playback / Data / Services / UI / Filters` 分层
- **注释用中文**，重点解释"**为什么**"（尤其是踩过坑的地方），不要复述代码在做什么
- UI 文案中文；日志/自检字段英文，便于 grep
- 单个文件超过 ~600 行时考虑拆分

---

## 5. 常见改动怎么做

**新增一个导出预设** → `Sources/CutPlayerKit/Services/ClipExportService.swift` 的 `Preset` 枚举，
补上参数与"速度/用途"提示文案；`ExportSheet` 会自动列出。

**调整渲染效果（LUT/曲线）** → `Sources/CutPlayerKit/Playback/MetalVideoView.swift`（片元着色器）
与 `LUTTexture.swift`（纹理构建）。改完必须跑 `make selftest` 看 PSNR。

**改播放列表交互** → `Sources/CutPlayerKit/UI/PlaylistSidebar.swift`（点击/多选/右键/拖放）
与 `PlaylistModel.swift`（数据与选中集）。

**改窗口布局/chrome** → `ContentView.swift` + `SplitContainer.swift`（自绘分栏与帘幕动画）。
注意 `NSHostingView` 会继承窗口安全区，需要 `safeAreaRegions = []`。

**调图标** → 改 `scripts/make_icon.swift` 的参数，然后 `make icon`。
**不要在图标里画投影**（系统会自己加，叠起来会显得又重又偏）。

---

## 6. 提交与 PR

- 提交信息用中文，第一行 `类型: 摘要`，类型用 `修复/新增/重构/文档/构建`
- 一个 PR 只做一件事；行为变化请同时更新 `CHANGELOG.md` 的「未发布」段
- PR 模板里的检查项请如实勾选

## 7. 报告问题

用 [问题反馈模板](.github/ISSUE_TEMPLATE/bug_report.yml)，尽量附上：
版本、macOS 与机型、复现步骤、素材规格（`⌘I` 媒体信息或 `ffprobe`）、
必要时 `/tmp/cutplayer_gui.log`。

**请勿上传含隐私的素材**；描述规格即可。
