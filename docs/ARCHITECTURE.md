# CutPlayer 架构说明

面向想改动/移植本项目的开发者。使用说明见 [使用手册](使用手册.md)。

---

## 1. 一句话架构

> **画面自己画，声音交给 mpv，记忆交给 SQLite。**

```
                    ┌──────────────────────── 预览链（只影响你看到的画面）────────────────────────┐
 视频文件 ──► FFmpeg(libavcodec) ──► 帧队列 ──► Metal 渲染 ──► 3D LUT ──► 亮度曲线 ──► 屏幕
              (软/硬件解码)          (滑窗)      (rgba16Float)  (strip纹理)  (1D 纹理)
                    │                                                                  │
                    │                                                          离屏再渲染一次
                    │                                                                  ▼
                    └────────────► 截图：16bit PNG（带 LUT，不带曲线）◄───────────────┘

 音频/时钟：libmpv（vo=null, vid=no）——只出声与提供 time-pos
 导出：内置 ffmpeg 子进程 `-vf lut3d`（带 LUT，**永不带曲线**）
```

**为什么这样切分**：mpv 的视频输出无法精细控制"LUT 之后再加曲线、但截图/导出不要曲线"这条链路，
也无法保证 4:2:2 10bit 软解 + 4K60 全尺寸的性能与色彩处理；所以视频解码与渲染全部自研，
mpv 退化成"音频解码 + 时钟"。

---

## 2. 模块地图

```
Sources/
├── CutPlayer/                   可执行入口（极薄）
│   └── main.swift               正常模式 → CutPlayerApp.main()
│                                测试模式 → 无头分支（不建窗口、不抢前台、不显示 Dock 图标）
├── CutPlayerKit/
│   ├── App/
│   │   ├── CutPlayerApp.swift   SwiftUI App / 菜单命令 / AppDelegate（全局按键监听）
│   │   └── SelfTestRunner.swift 无头端到端自检（PSNR 判定、导出校验、性能基准）
│   ├── Playback/
│   │   ├── MPVClient.swift          libmpv 封装：**只负责音频与时钟**
│   │   ├── VideoPlaybackEngine.swift 解码线程 + 帧队列 + seek 调度（generation 标记）
│   │   ├── FFmpegVideoDecoder.swift  libavcodec 解码、像素格式/色彩范围探测
│   │   ├── FrameQueue.swift          滑窗帧队列（maxQueue = 6）
│   │   ├── MetalVideoView.swift      MTKView 子类：LUT + 曲线渲染、离屏截图、帧回调
│   │   └── LUTTexture.swift          3D LUT(.cube) → 2D strip 纹理；曲线 → 1D 纹理
│   ├── Filters/
│   │   └── FilterChain.swift         仅剩 ffmpeg 参数转义（导出用）
│   ├── Data/
│   │   └── LUTDatabase.swift         SQLite：LUT 记忆 / 播放进度 / 输入范围 / LUT 库
│   ├── Services/
│   │   ├── ClipExportService.swift   导出流程编排（进度、取消、完成态）
│   │   └── ClipExportCommand.swift   导出参数构造（-ss 位置、-t 时长、预设）
│   └── UI/
│       ├── PlayerModel.swift         总协调器（播放状态、LUT、曲线、seek、声画同步）
│       ├── ContentView.swift         窗口根视图（自绘 chrome + 分栏）
│       ├── SplitContainer.swift      NSSplitView 包装：无分割线、帘幕式收起动画
│       ├── PlaylistSidebar.swift     播放列表（自绘选中态、多选、右键菜单、拖放）
│       ├── PlayerAreaView.swift      顶栏 / 画面 / 底栏（自动隐藏）
│       ├── CurveEditorView.swift     亮度曲线编辑器（浮动窗口）
│       ├── ExportSheet.swift         导出面板
│       └── ...
├── CMPV/       C shim：`#include <mpv/client.h>`（仅音频/时钟 API）
└── CFFmpeg/    C shim：FFmpeg 解码 API
```

---

## 3. 关键设计决策

### 3.1 为什么 mpv 只做音频

| 需求 | mpv 视频输出 | 自研 FFmpeg + Metal |
|---|---|---|
| LUT 先生效、曲线作用于"LUT 之后" | 靠 `vf` 链，但截图层难以剥离 | 渲染管线里两步清楚分层 |
| 截图/导出**不带**曲线 | 需要两套滤镜链 + 两套渲染路径 | 离屏渲染时跳过曲线即可 |
| 4:2:2 10bit 4K 性能 | 受 mpv 内部缩放/色彩管理影响 | 自己控制纹理格式与色度平面 |
| 帧精确 seek / 丢帧策略 | 受 mpv 时钟驱动，不够直接 | 自己掌控队列与丢帧规则 |

结论：mpv 保留**音频解码 + 时钟**（`vo=null`、`vid=no`），其余全部自研。

### 3.2 色彩范围（limited / full）三级判定

这是"画面发灰 / 死黑"的根因。判定顺序：

1. **手动覆盖**（数据库按文件记住的用户选择）——最高优先级；
2. 素材标签声明 **limited(tv)** → 直接采信；
3. 标签声明 **full(pc)** 或未声明 → **抽查像素**：10bit 数据若大量超出 `60…944` 区间，
   说明实际是 full；否则判定"标签撒谎"，按 limited 处理。

> FFmpeg 枚举易记混：`AVCOL_RANGE_MPEG = 1 = limited(tv)`，`AVCOL_RANGE_JPEG = 2 = full(pc)`。

### 3.3 声画同步（"音频等画面"策略）

问题：seek 或换片后，音频会立刻从新位置出声，而视频首帧还在解码 → "声音先跑、画面追"。

做法：

1. seek/换片时**按住音频**（`mpv pause`，视频侧继续解码）；
2. 等到目标帧**真正被绘制**（`onFrameDrawn` 回调）的瞬间释放音频；
3. 1.5–2.5 秒超时兜底，避免极端素材永久静音。

配套规则：**落在目标时间之后的帧直接丢弃，绝不 hold-and-stall**（帧队列滑窗 `maxQueue = 6`，
seek 用 generation 标记作废旧请求）。

### 3.4 监看 LUT 与亮度曲线的分层

- **LUT**：`.cube` 解析为 3D LUT，打包成 `1024×32` 的 **2D strip 纹理**（Metal 不支持 3D 采样的通用写法时最稳），
  在片元着色器里做三线性插值；作用对象是**解码后的原始 RGB**。
- **曲线**：单调三次样条（Fritsch–Carlson，保证不过冲）采样成 256 级 **1D 纹理**，
  在 LUT **之后**查找 —— 顺序不可颠倒，这正是需求里"曲线作用于 LUT 之后的画面"。
- **截图**：把同一帧在离屏 `rgba16Float` 目标上再渲染一次，**跳过曲线**，输出 16bit PNG。
- **导出**：交给内置 ffmpeg，`-vf lut3d='...'`，**永远不拼 curves**。

### 3.5 导出实现要点

- `-ss` 必须放在 `-i` **之前**（快速定位），时长用 `-t (end - start)`；
  若把 `-ss` 放在 `-i` 之后，`-to` 会被解释成输入时间轴，得到 0 帧文件和错误的出点。
- 默认预设是 **H.265 10bit 4:2:2 硬件编码 → MP4**（`hvc1` 标签，访达可空格预览、QuickTime 可播）。
- VideoToolbox 4K HEVC 4:2:2 10bit 约 **2.5 秒编码 1 秒素材**；x265 medium CRF14 约 **14.4 秒**。

### 3.6 界面：为什么要自绘窗口 chrome

- 需求是"整片白色、无工具栏、无分割线"；`NavigationSplitView` 的分割线由系统绘制且**无法覆盖**，
  于是改用 `NSSplitView` 包装（`SplitContainer`），把 divider 填成侧栏底色。
- 收起/展开不做"改宽度"动画（内容会被反复重排，观感"滑得很诡异"），
  而是**固定内容宽度 + 帘幕式裁剪**：60Hz 定时器驱动、smoothstep 缓动。
- 侧栏宽度写入 `UserDefaults`（`CutPlayer.sidebarWidth`），
  窗口变窄时**平滑收敛**到新上限，而不是让约束瞬移。
- `NSHostingView` 会继承窗口安全区（约 28pt），需要 `safeAreaRegions = []`，
  否则标题会莫名偏低。

### 3.7 数据与记忆

`~/Library/Application Support/CutPlayer/cutplayer.db`（SQLite）：

| 表 | 用途 |
|---|---|
| `file_luts(path, lut_path)` | 文件 ↔ LUT 精确记忆 |
| `dir_luts(dir, lut_path)` | 目录级默认 LUT |
| `lut_library(path, name, updated_at)` | 已导入的 LUT 库（按文件名去重） |
| `file_range(path, mode)` | 每个文件的输入色彩范围覆盖 |
| `playback(path, position, updated_at)` | 断点续播 |

---

## 4. 性能与验证

内置无头自检（不建窗口、不影响前台）：

```bash
build/CutPlayer.app/Contents/MacOS/CutPlayer \
  --selftest --input <视频> --lut <LUT> --outdir /tmp/cutplayer_selftest
```

判定项（`pass` 全为 true 才算通过）：

| 检查 | 含义 |
|---|---|
| `lutApplied` | 截图与无 LUT 源帧差异显著（LUT 确实生效）|
| `lutScreenshotMatchesReference` | 截图 vs ffmpeg 参考渲染 PSNR 达标 |
| `curveAppliesOnlyToPreview` | 带/不带曲线截图差异大，但导出不受影响 |
| `exportLUTOnly` | 导出与"LUT-only 参考"接近、与"带曲线参考"相差大 |
| `mp4ExportCorrect` | 导出容器/时长/编码正确 |
| `headless_noWindow` | 测试模式确实没有创建窗口 |

实测参考值（4K 素材、Apple Silicon）：

| 指标 | 数值 |
|---|---|
| 4K50 10bit 4:2:2 软解 | ≈ 90 fps |
| Metal 截图 vs ffmpeg 参考（带 LUT） | ≈ 39.1 dB |
| 同上（无 LUT，纯通路） | ≈ 47.0 dB |
| 导出 vs 参考（仅 LUT） | ≈ 39.6 dB |
| 导出 vs 参考（若误带曲线） | ≈ 21.7 dB（明显掉下来 = 曲线确实没进导出）|
| seek 响应 | 140–450 ms |

---

## 5. 移植到 Windows 的路线

内核层（FFmpeg / libmpv / SQLite）天然跨平台：

1. **渲染层**：Metal → D3D11 / Vulkan（或 libplacebo）。着色器逻辑（strip LUT、1D 曲线）可直接翻译。
2. **音频**：libmpv 的音频输出在 Windows 可用，接口不变。
3. **UI 层**：SwiftUI 不可移植，需要重写（Qt 6/QML 或 C#/.NET + WinUI）。
   `PlayerModel` 的状态机、`LUTDatabase` 的 schema、导出参数构造都可以照搬。
4. **不共享**：AppKit 相关的窗口 chrome、`NSHostingView` 安全区等技巧。

---

## 6. 踩过的坑（给后来者）

| 现象 | 原因 | 处理 |
|---|---|---|
| 4:2:0 素材下半部分画面错乱（PSNR 8dB） | 色度平面按 `w/2 × h` 拷贝，实际应为 `w/2 × h/2` | 按像素格式计算色度尺寸（4:2:0 / 4:2:2 / 4:4:4 各不相同）|
| 自检截图 PSNR 只有 13–18 dB | 拿只读的 `frameForTime` 导致队列停顿，比对的是不同时刻的帧 | 改为"取帧并排空队列"的循环 |
| 导出挂住、CPU 打满 | ProRes 4444 4K 写入 233MB/s，且 x265 很慢 | 预设改为硬件 HEVC 优先；完成提示放进面板内联显示 |
| 解码线程卡死 | 在持有非递归锁时调用 `probeRange` | 探测移出锁外 |
| 测试用的 GUI 窗口"自己关了" | 测试模式建了真窗口并 `NSApp.terminate` | `main.swift` 加真正的无头分支（`.prohibited`，不建窗口）|
| 签名后分发提示"已损坏" | 先签 App 再签内部 dylib，导致封条立即失效 | 顺序反过来：**先内部 dylib，最后签 App** |
| Dock 图标阴影又重又偏 | 图标里烘焙了投影，系统又叠了一层 | 图标只画圆角方块本体，投影交给系统 |

---

## 7. 代码规模

约 **24 个 Swift 文件 / 6000 行**（不含测试与资源），无第三方 Swift 依赖。
