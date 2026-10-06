# 发布流程

从改版本号到 GitHub Release，全程约 10 分钟。

## 0. 前置

- 本地已 `brew install ffmpeg mpv`
- 仓库已配好 remote，且 `main` 分支干净

## 1. 改版本号（三处要同步）

```bash
# ① Info.plist：版本号 + 构建号（构建号每次 +1）
plutil -replace CFBundleShortVersionString -string 0.1.2 Resources/Info.plist
plutil -replace CFBundleVersion -integer 3 Resources/Info.plist

# ② README 顶部与文档里的版本引用
grep -rn "0\.1\.1" README.md docs/*.md | head
```

## 2. 更新 CHANGELOG

在 `CHANGELOG.md` 把「未发布」段改成新版本段并写日期，然后新开一个空的「未发布」段。

## 3. 本地全量验证

```bash
make test          # 单元测试
make selftest      # 端到端自检，pass 必须为 true
make dmg           # 出安装包（会自动校验签名与 DMG CRC）
```

手工抽查一次安装包：

```bash
hdiutil attach build/CutPlayer-0.1.2-arm64.dmg -readonly -nobrowse -mountpoint /tmp/m
ls /tmp/m                                   # 应有 App、Applications、手册、许可证、第三方说明
open /tmp/m/CutPlayer.app                   # 从 DMG 直接跑一次，确认能启动
hdiutil detach /tmp/m
```

## 4. 提交并打 tag

```bash
git add -A
git commit -m "发布 0.1.2"
git tag v0.1.2          # 注意：tag 必须与 Info.plist 版本号一致，CI 会校验
git push && git push --tags
```

## 5. CI 自动发布

推 tag 后 `.github/workflows/release.yml` 会：

1. 校验 tag 与 `Info.plist` 版本一致（不一致直接失败，避免发错版本）
2. 构建 App → 打 DMG → 生成 `SHA256SUMS.txt`
3. 创建 GitHub Release，附上 DMG 与校验和，正文含安装步骤与"首次打开需右键"提示

到 Actions 页面确认绿灯，然后在 Releases 里检查附件与说明。

## 6. 发布后

- 把 Release 里的 `SHA256SUMS.txt` 内容贴到群/论坛时一并给出（方便别人校验）
- 若发现严重问题，**不要删 Release**：改版本号发 0.1.3，并在 Release 说明里标注"建议升级"
- （可选）提交 Homebrew Cask：

```ruby
cask "cutplayer" do
  version "0.1.2"
  sha256 "<SHA256SUMS 里的值>"
  url "https://github.com/exampleuser/CutPlayer/releases/download/v#{version}/CutPlayer-#{version}-arm64.dmg"
  name "CutPlayer"
  desc "监看级本地视频播放器（LUT / 曲线 / 片段导出）"
  homepage "https://github.com/exampleuser/CutPlayer"
  app "CutPlayer.app"
end
```

## 附：签名与公证（可选，但强烈建议迟早做）

当前分发的是**临时签名**版本，用户首次打开需要右键 → 打开。要消除这一步，需要 Apple Developer 账号：

```bash
# 前提：钥匙串里有 Developer ID Application 证书
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <你的名字> (TEAMID)" build/CutPlayer.app

# 打包 DMG 后提交公证（需先存好 app-specific password 或 API Key）
xcrun notarytool submit build/CutPlayer-0.1.2-arm64.dmg \
  --keychain-profile "<profile>" --wait
xcrun stapler staple build/CutPlayer-0.1.2-arm64.dmg
```

`stapler staple` 之后，DMG 在别人机器上双击即可打开，无需任何右键操作。
把这两步接进 `release.yml` 即可全自动。
