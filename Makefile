.PHONY: build test assets app selftest dmg icon clean help

VERSION := $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
ARCH    ?= arm64

help:                ## 显示所有可用目标
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s "$$(printf '\t')"

build:               ## 开发构建（debug）
	arch -$(ARCH) swift build --arch $(ARCH)

test:                ## 单元测试（headless，自研 harness）
	arch -$(ARCH) swift run --arch $(ARCH) CutPlayerTests

assets:              ## 生成合成测试素材（4K 10bit 视频 + 测试 LUT）
	./scripts/make_test_assets.sh

app:                 ## 打包 .app（release，自动捆绑 mpv/ffmpeg 依赖并签名）
	./scripts/build_app.sh $(ARCH) release

selftest: app        ## 端到端自检（LUT/曲线/截图/导出 PSNR 判定）
	build/CutPlayer.app/Contents/MacOS/CutPlayer --selftest \
		--input TestAssets/sample_4k10bit.mkv \
		--lut   TestAssets/test_lift.cube \
		--outdir /tmp/cutplayer_selftest

icon:                ## 重新生成应用图标（scripts/make_icon.swift → Resources/AppIcon.icns）
	arch -$(ARCH) swift scripts/make_icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

dmg: app             ## 打包 DMG 安装包（含手册与 Applications 快捷方式）
	./scripts/make_dmg.sh $(VERSION) $(ARCH)

clean:               ## 清理构建产物
	rm -rf .build build
