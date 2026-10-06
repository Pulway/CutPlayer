#!/bin/bash
# 构建并打包 CutPlayer.app（arm64）
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-arm64}"
CONFIG="${2:-release}"
export PATH="/opt/homebrew/bin:$PATH"

# 外层已有沙箱（如 DSH workspace-write）时，SwiftPM 自己的 sandbox-exec 会
# "Operation not permitted"，此时用 CUTPLAYER_NO_SWIFT_SANDBOX=1 关闭内层沙箱。
SWIFT_SANDBOX_FLAG=""
[ -n "${CUTPLAYER_NO_SWIFT_SANDBOX:-}" ] && SWIFT_SANDBOX_FLAG="--disable-sandbox"

echo "▶ 编译 ($ARCH, $CONFIG)..."
arch -arm64 swift build -c "$CONFIG" --arch "$ARCH" $SWIFT_SANDBOX_FLAG

BIN_DIR=$(arch -arm64 swift build -c "$CONFIG" --arch "$ARCH" $SWIFT_SANDBOX_FLAG --show-bin-path)
BIN="$BIN_DIR/CutPlayer"

APP="build/CutPlayer.app"
FR="$APP/Contents/Frameworks"
echo "▶ 组装 $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FR"

cp "$BIN" "$APP/Contents/MacOS/CutPlayer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 应用图标：缺失时用 scripts/make_icon.swift 现场生成
if [ ! -f Resources/AppIcon.icns ] && [ -f scripts/make_icon.swift ]; then
  echo "  生成应用图标…"
  arch -arm64 swift scripts/make_icon.swift build/AppIcon.iconset >/dev/null 2>&1 || true
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns 2>/dev/null || true
fi
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "  应用图标已嵌入"
else
  echo "  ⚠ 未找到应用图标（Resources/AppIcon.icns）"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 主程序：libmpv 引用改为 @rpath + 添加 rpath
LIBMPV="/opt/homebrew/opt/mpv/lib/libmpv.dylib"
if [ -f "$LIBMPV" ]; then
  cp "$LIBMPV" "$FR/libmpv.dylib"
  OLD_INSTALL=$(otool -L "$BIN" | awk '/libmpv/{print $1; exit}')
  [ -n "$OLD_INSTALL" ] && install_name_tool -change "$OLD_INSTALL" "@rpath/libmpv.dylib" "$APP/Contents/MacOS/CutPlayer"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CutPlayer"
  echo "  libmpv.dylib 已捆绑"
else
  echo "  ⚠ 未找到 $LIBMPV，应用将依赖系统 brew 环境"
fi

# 捆绑 ffmpeg（含 libmpv 与 ffmpeg 的传递依赖闭包）
FFMPEG_BIN="$(arch -arm64 /opt/homebrew/bin/brew --prefix ffmpeg 2>/dev/null || true)/bin/ffmpeg"
if [ -n "$FFMPEG_BIN" ] && [ -x "$FFMPEG_BIN" ]; then
  cp "$FFMPEG_BIN" "$APP/Contents/Resources/ffmpeg"
  echo "  ffmpeg 已捆绑"
else
  echo "  ⚠ 未找到 ffmpeg，导出功能将依赖系统 PATH"
fi

# --- 传递闭包收集依赖 ---
# 两种引用风格都要处理：
#  1) /opt/homebrew/... 绝对路径
#  2) @rpath/xxx（Homebrew 部分库用 @rpath + 自身 LC_RPATH 指向 brew）
# otool -L 首行是文件自身（带冒号），NR>1 跳过
FR="$APP/Contents/Frameworks"

copy_dep() { # $1 = 依赖路径（绝对或 @rpath/x），$2 = 引用它的文件
  local dep="$1" src="" name
  case "$dep" in
    @rpath/*)
      name=$(basename "$dep")
      # 按引用文件的 LC_RPATH 逐个尝试
      while read -r rp; do
        if [ -f "$rp/$name" ]; then src="$rp/$name"; break; fi
      done < <(otool -l "$2" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}')
      [ -n "$src" ] || src="/opt/homebrew/lib/$name"
      ;;
    *)
      name=$(basename "$dep")
      src="$dep"
      ;;
  esac
  if [ ! -f "$FR/$name" ] && [ -f "$src" ]; then
    cp "$src" "$FR/$name" 2>/dev/null || true
    chmod +w "$FR/$name" 2>/dev/null || true
  fi
}

collect_deps() { # $1 = 文件路径
  while read -r dep; do copy_dep "$dep" "$1"; done < <(otool -L "$1" | awk 'NR>1 && (/\/opt\/homebrew\// || /@rpath\//){print $1}')
}
ROOTS="$APP/Contents/Resources/ffmpeg $FR/libmpv.dylib"
for r in $ROOTS; do [ -f "$r" ] && collect_deps "$r"; done
# 新收集的 dylib 也要收集它们的依赖，直到闭包稳定
while true; do
  NEW=""
  for f in $FR/*.dylib; do
    [ -f "$f" ] || continue
    while read -r dep; do
      name=$(basename "$dep")
      if [ ! -f "$FR/$name" ]; then
        copy_dep "$dep" "$f"
        [ -f "$FR/$name" ] && NEW="$NEW $name"
      fi
    done < <(otool -L "$f" | awk 'NR>1 && (/\/opt\/homebrew\// || /@rpath\//){print $1}')
  done
  [ -z "$NEW" ] && break
done
echo "  收集依赖 dylib: $(ls "$FR" | wc -l | tr -d ' ') 个"

# --- 引用归一化：/opt/homebrew 绝对引用 → @rpath/<basename> ---
# （@rpath/xxx 引用保持不变——bundle 内统一 rpath 到 Frameworks 即可解析）
fix_refs() { # $1 = 文件路径
  while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$1" 2>/dev/null || true
  done < <(otool -L "$1" | awk 'NR>1 && /\/opt\/homebrew\//{print $1}')
}
for f in "$APP/Contents/Resources/ffmpeg" "$APP/Contents/MacOS/CutPlayer" $FR/*.dylib; do
  [ -f "$f" ] || continue
  fix_refs "$f"
done
for f in $FR/*.dylib; do
  [ -f "$f" ] || continue
  install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/Resources/ffmpeg" 2>/dev/null || true

# --- 签名（顺序关键：先内部、后 App 本体） ---
# 之前是先签 App 再签内部 dylib，结果 App 的签名封条立刻失效：
# 本机运行没事，但分发出去（DMG/拷贝到别的机器）会被 Gatekeeper 判为"已损坏"。
# 正确顺序：先把 Resources/Frameworks 里的可执行文件与 dylib 逐个签好，最后再签 App。
for f in "$APP/Contents/Resources/ffmpeg" $FR/*.dylib; do
  [ -f "$f" ] || continue
  codesign --force --sign - "$f" 2>/dev/null || true
done
codesign --force --sign - "$APP"

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "  签名校验：通过"
else
  echo "  ⚠ 签名校验未通过（本机仍可运行，但分发可能被拦截）"
fi

echo "✔ 完成: $APP"
