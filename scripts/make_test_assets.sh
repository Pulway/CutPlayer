#!/bin/bash
# 生成测试资产：10-bit 4K 样本 + 测试 LUT（.cube）
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."
mkdir -p TestAssets

# 选 ffmpeg：优先用打包好的 App 内那份（自包含、已签名，不受系统 ffmpeg 影响），
# 其次才是 Homebrew / PATH 里的。可用 FFMPEG=/path/to/ffmpeg 覆盖。
FFMPEG="${FFMPEG:-}"
if [ -z "$FFMPEG" ]; then
  if [ -x "build/CutPlayer.app/Contents/Resources/ffmpeg" ]; then
    FFMPEG="build/CutPlayer.app/Contents/Resources/ffmpeg"
  else
    FFMPEG="$(command -v ffmpeg || true)"
  fi
fi
[ -n "$FFMPEG" ] && [ -x "$FFMPEG" ] || {
  echo "✘ 找不到 ffmpeg。请先 brew install ffmpeg，或先 ./scripts/build_app.sh 打包（用 App 内置的那份）"
  exit 1
}
echo "▶ 使用 ffmpeg: $FFMPEG"

echo "▶ 生成 10-bit 4K 测试视频（H.265 10bit, 4s）..."
"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=3840x2160:rate=24" \
  -f lavfi -i "sine=frequency=440:duration=4" \
  -t 4 -pix_fmt yuv420p10le \
  -c:v libx265 -preset fast -crf 18 \
  -c:a aac -b:a 128k \
  TestAssets/sample_4k10bit.mkv

echo "▶ 生成测试 LUT（提亮+轻微对比：out = 0.88*in + 0.06）..."
python3 - <<'PY'
size = 17
with open("TestAssets/test_lift.cube", "w") as f:
    f.write("TITLE \"CutPlayer Test Lift\"\n")
    f.write("LUT_3D_SIZE %d\n" % size)
    f.write("DOMAIN_MIN 0.0 0.0 0.0\n")
    f.write("DOMAIN_MAX 1.0 1.0 1.0\n")
    for r in range(size):
        for g in range(size):
            for b in range(size):
                def x(i): return min(max(0.88*(i/(size-1)) + 0.06, 0.0), 1.0)
                f.write("%.6f %.6f %.6f\n" % (x(r), x(g), x(b)))
print("done: TestAssets/test_lift.cube")
PY

ls -la TestAssets/
echo "✔ 测试资产就绪"
