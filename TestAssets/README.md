# TestAssets（不随仓库分发）

本目录存放**本地测试素材**，默认已被 `.gitignore` 排除，原因：

- 体积大（4K 测试视频动辄几十上百 MB）
- 可能包含**个人拍摄素材**，不适合公开
- 第三方 LUT 通常有独立授权，不能随代码一起分发

## 生成合成测试素材

```bash
./scripts/make_test_assets.sh
```

会生成：

| 文件 | 说明 |
|---|---|
| `sample_4k10bit.mkv` | 4 秒 4K (3840×2160) HEVC 10bit 合成测试图（含 440Hz 音轨）|
| `test_lift.cube` | 17³ 测试 LUT（提亮 + 轻微对比：`out = 0.88*in + 0.06`）|

## 跑端到端自检

```bash
build/CutPlayer.app/Contents/MacOS/CutPlayer \
  --selftest \
  --input "TestAssets/sample_4k10bit.mkv" \
  --lut   "TestAssets/test_lift.cube" \
  --outdir /tmp/cutplayer_selftest
```

想用真实素材（LOG 灰片 + 监看 LUT）测试也可以，把文件放进本目录即可——
它们不会被提交。
