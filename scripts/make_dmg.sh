#!/bin/bash
# 打包 DMG 安装包：App + Applications 快捷方式 + 使用手册 + 安装说明 + 卷图标
# 用法: ./scripts/make_dmg.sh [版本号] [架构]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}"
ARCH="${2:-arm64}"
APP="build/CutPlayer.app"
OUT="build/CutPlayer-${VERSION}-${ARCH}.dmg"
STAGE="$(mktemp -d)/dmg"
RW="$(mktemp -d)/rw.dmg"

[ -d "$APP" ] || { echo "✘ 找不到 $APP，先跑 ./scripts/build_app.sh"; exit 1; }

echo "▶ 准备 DMG 内容 (v${VERSION} ${ARCH})…"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CutPlayer.app"
ln -s /Applications "$STAGE/Applications"
cp docs/使用手册.md docs/使用手册.txt "$STAGE/" 2>/dev/null || true
cp LICENSE "$STAGE/开源许可证-GPL-3.0.txt" 2>/dev/null || true

# GPL/LGPL 合规：分发捆绑了 FFmpeg / libmpv 的二进制时，需随附许可证与源码获取途径
cat > "$STAGE/第三方组件许可说明.txt" <<'NOTICE'
本 App 内捆绑了以下第三方组件，它们各自遵循自己的许可证：

1) FFmpeg  — https://ffmpeg.org/legal.html
   用途：视频解码、片段导出
   许可证：LGPL-2.1-or-later；本构建启用了 GPL 组件（x264 / x265 等），
           因此按 GPL-2.0-or-later 分发。
   源码：https://ffmpeg.org/download.html （或对应版本的可执行文件源码包）

2) mpv / libmpv — https://github.com/mpv-player/mpv
   用途：音频解码与播放时钟
   许可证：LGPL-2.1-or-later；本构建（Homebrew）含 GPL 组件，按 GPL-2.0-or-later 分发。
   源码：https://github.com/mpv-player/mpv

3) SQLite — https://sqlite.org/copyright.html
   用途：本地记忆数据库（Public Domain）

上述组件的完整许可证文本随各自源码分发。若你需要重新链接这些库以替换为
自行修改的版本，可用仓库中的 scripts/build_app.sh 重新打包（依赖通过
`brew install ffmpeg mpv` 获取）。

CutPlayer 自身代码以 GPL-3.0-or-later 授权，见同目录《开源许可证-GPL-3.0.txt》。
NOTICE

cat > "$STAGE/安装说明.txt" <<TXT
CutPlayer ${VERSION} 安装说明
========================================

1) 把左边的 CutPlayer 拖到右边的 Applications（应用程序）快捷方式里。

2) 首次打开：
   本版本是本地构建，只做了临时签名、未做 Apple 开发者签名与公证，
   直接双击会被 macOS 拦下（提示"无法验证开发者"或"已损坏"）。
   请二选一：
     · 在「应用程序」里右键点 CutPlayer → 选「打开」→ 再点「打开」
     · 或在终端执行一次：
         xattr -dr com.apple.quarantine /Applications/CutPlayer.app

3) 详细功能与每个按钮的说明，见同盘的：
     《使用手册.md》（推荐，支持目录与表格排版）
     《使用手册.txt》（纯文本版）

系统要求：Apple Silicon（M 系列）Mac + macOS 14 或更高
TXT

# 先做可读写映像，写入卷图标后转成压缩只读
MOUNT="$(mktemp -d)"
hdiutil create -volname "CutPlayer ${VERSION}" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
hdiutil attach "$RW" -nobrowse -mountpoint "$MOUNT" >/dev/null
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
hdiutil detach "$MOUNT" >/dev/null
rm -f "$OUT"          # hdiutil convert 不会覆盖已存在的输出
hdiutil convert "$RW" -format UDZO -o "$OUT" >/dev/null
rm -rf "$RW" "$STAGE" "$MOUNT"

echo "▶ 校验…"
hdiutil verify "$OUT" | tail -1
codesign --verify --deep --strict "$APP" && echo "  签名校验：通过"
echo "✔ 完成: $OUT"
