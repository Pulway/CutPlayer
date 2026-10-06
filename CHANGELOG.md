# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)，格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [未发布]

## [0.1.1] - 2026-10-06

首个对外打包分发的版本（含安装包与使用手册）。

### 新增
- **应用图标**：CoreGraphics 程序化绘制（`scripts/make_icon.swift`），超椭圆轮廓 + 蓝色渐变 + "被斜切开的视频框"
- **DMG 打包脚本** `scripts/make_dmg.sh`：App + Applications 快捷方式 + 使用手册 + 安装说明 + 卷图标
- **Makefile 目标**：`help` / `build` / `test` / `assets` / `app` / `selftest` / `dmg` / `icon`
- **使用手册**（`docs/使用手册.md` / `.txt`）：逐按钮说明、快捷键总表、常见问题
- **架构文档**（`docs/ARCHITECTURE.md`）：模块地图、设计取舍、踩坑记录
- 非全屏也可点击视频标题收起/展开播放列表；进全屏记住状态、退出后恢复
- 侧栏宽度写入偏好设置，**重启后记住**；窗口变窄时宽度平滑收敛
- 亮度曲线面板改为**独立浮动窗口**，调曲线时画面完整可见、不被遮挡
- 曲线**端点可上下拖动**（抬黑场/压白场），但不可删除以防误删
- 右键菜单作用于**整个选中集**（多选批量套用/清除 LUT、批量移除）
- 删除当前播放的视频时，**自动切换到列表第一条**；列表删空则停止播放并清空画面
- 调试环境变量：`CUTPLAYER_OPEN_FILE` / `CUTPLAYER_HIDE_SIDEBAR` / `CUTPLAYER_OPEN_CURVE`

### 修复
- 导入文件后按 ⇧ 连选失效：锚点缺失导致退化成"跳转到该条"；现锚点三级兜底（上次点击 → 当前播放 → 已选中第一条）
- 非全屏隐藏侧栏时，标题被窗口红绿灯压住 → 自动避让并随收起动画平滑过渡
- 图标自带投影，与系统投影叠加导致 Dock 里阴影过重 → 去掉自带投影
- 分发到其他机器提示"**已损坏**"：签名顺序错误（先签 App 再签内部 dylib 会让封条失效）→ 改为先签内部、最后签 App，并加自动校验
- 「导入 LUT 到库…」与「清除当前 LUT」快捷键冲突（均为 ⇧⌘L）→ 后者改为 ⌥⌘L

### 变更
- 移除上一代 OpenGL 路线的全部死代码（`PlayerGLView` / `PlayerEmbedView` / `LUTShader`、`MPVClient` 中的 mpv 渲染 API），**不再依赖 OpenGL**
- 导出预设以 H.265 为中心：默认 H.265 10bit 4:2:2 硬件编码 → MP4（访达可预览）
- 侧栏默认宽度 260pt

## [0.1.0] - 2026-10-04

首个可运行版本，完成四项核心需求与工程打通。

### 新增
- **播放管线**：FFmpeg 解码 + Metal 渲染；libmpv 仅负责音频与时钟（`vo=null`）
- **监看 LUT**：`.cube` 实时套用；文件级 + 目录级自动记忆；多选批量设置；LUT 库
- **亮度曲线**：单调三次样条编辑器，作用于 LUT **之后**，**只影响预览**
- **截图**：16bit PNG，带 LUT、不带曲线
- **片段导出**：按入点/出点截取，带 LUT、不带曲线；多种画质预设
- **输入色彩范围三级判定**：手动覆盖 → 标签 → 像素抽查，按文件记住
- **声画同步**：seek/换片时按住音频，目标帧绘制完成才释放；落后帧直接丢弃
- **播放列表**：拖放导入、文件夹递归扫描、多选、拖动排序、断点续播
- **界面**：整片白色自绘 chrome、无系统工具栏与分割线、顶/底栏自动隐藏
- **工程**：无头端到端自检（PSNR 判定 LUT/曲线/导出链路）、轻量单元测试 harness、`build_app.sh` 自动捆绑依赖并重签

[未发布]: https://github.com/exampleuser/CutPlayer/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/exampleuser/CutPlayer/releases/tag/v0.1.1
[0.1.0]: https://github.com/exampleuser/CutPlayer/releases/tag/v0.1.0
