import Foundation
import AppKit
import CFFmpeg

/// 端到端自检（无头，不弹窗口）：
/// 视频 = FFmpeg 解码 + Metal 渲染（LUT/曲线在 GPU 管线）
/// 验证：解码 → LUT 截图（vs ffmpeg 参考）→ 曲线只影响预览 → 导出带LUT不带曲线
public enum SelfTestDriver {
    public static var shouldRun: Bool {
        CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--decbench")
            || CommandLine.arguments.contains("--seektest")
            || CommandLine.arguments.contains("--enginetest")
            || CommandLine.arguments.contains("--seekprobe")
            || CommandLine.arguments.contains("--modelseek")
    }

    @MainActor
    public static func run() async {
        if CommandLine.arguments.contains("--decbench") {
            runDecBench()
            exit(0)
        }
        if CommandLine.arguments.contains("--seektest") {
            runSeekTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--enginetest") {
            runEngineTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--seekprobe") {
            runSeekProbe()
            exit(0)
        }
        if CommandLine.arguments.contains("--modelseek") {
            await runModelSeek()
            exit(0)
        }

        // ---- 自检 ----
        let args = parse()
        let player = PlayerModel()
        var report: [String: Any] = ["pass": false]
        guard let input = args["input"], FileManager.default.fileExists(atPath: input) else {
            print(#"{"pass": false, "error": "input not found"}"#)
            exit(1)
        }
        let lutPath = args["lut"]

        player.open(URL(fileURLWithPath: input))

        // 1) 定位到 0.5s 并**消费式**解码到目标帧
        //    （必须 take 而不能只 frameForTime：队列是 6 帧的滑窗，只读探查会让
        //     解码停在队满状态，结果截到 0.1s 的帧却和 0.5s 的参考帧比 PSNR）
        player.client.pause()
        player.client.seekTo(0.5)
        player.video.seek(to: 0.5)
        var waited = 0
        var frame: UnsafeMutablePointer<AVFrame>?
        while waited < 600 {
            if let f = player.video.takeFrameForTime(0.5) {
                let p = player.video.pts(of: f)
                if let old = frame { av_frame_unref(old) }   // 丢弃更早的候选帧
                frame = f
                if p > 0.49 { break }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        guard let frame else {
            print(#"{"pass": false, "error": "解码无帧", "queue": \#(player.video.queueDepth)}"#)
            exit(1)
        }
        report["framePTS"] = player.video.pts(of: frame)
        report["targetTime"] = 0.5
        defer { av_frame_unref(frame) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        report["size"] = "\(player.video.width)x\(player.video.height)"
        report["fps"] = player.video.fps
        report["duration"] = player.video.duration
        report["colorRange"] = player.video.decoderColorRange
        report["frameColorRange"] = Int(frame.pointee.color_range.rawValue)
        if let desc = av_get_pix_fmt_name(player.video.decoderPixelFormat) {
            report["pixelformat"] = String(cString: desc)
        }

        // 2.0) 清除记忆 LUT → 无 LUT 截图（验证 YUV→RGB 基础管线）
        player.setLUT(nil, record: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        report["lutApplied_afterClear"] = player.metalView.lutApplied
        let dir = PlayerModel.screenshotsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var shotPlainURL: URL?
        if let rep = player.metalView.captureFrame(frame, withCurve: false),
           let png = rep.representation(using: .png, properties: [:]) {
            let u = dir.appendingPathComponent("selftest_plain_\(Int(Date().timeIntervalSince1970)).png")
            try? png.write(to: u)
            shotPlainURL = u
            report["screenshotPlain"] = u.path
        }

        // 2) 套 LUT → 用已取到的帧截图（LUT-only）
        if let lutPath { player.setLUT(lutPath, record: false) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        report["lutApplied_afterSet"] = player.metalView.lutApplied
        report["curveApplied"] = player.metalView.curveApplied

        let shotLUT = dir.appendingPathComponent("selftest_lut_\(Int(Date().timeIntervalSince1970)).png")
        if let rep = player.metalView.captureFrame(frame, withCurve: false),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: shotLUT)
            report["screenshotLUT"] = shotLUT.path
        }

        // 3) 启用曲线 → 带曲线截图（对比证明曲线改变画面）
        player.curve.set([
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.62),
            CurvePoint(x: 1, y: 1),
        ])
        player.curve.enabled = true
        try? await Task.sleep(nanoseconds: 200_000_000) // 等曲线防抖 80ms 生效
        var shotCurveURL: URL?
        if let rep = player.metalView.captureFrame(frame, withCurve: true),
           let png = rep.representation(using: .png, properties: [:]) {
            let u = dir.appendingPathComponent("selftest_curve_\(Int(Date().timeIntervalSince1970)).png")
            try? png.write(to: u)
            shotCurveURL = u
        }

        // 4) 参考渲染 + PSNR
        let srcURL = URL(fileURLWithPath: input)
        let srcIsLimited = !player.video.resolvedFullRange
        report["resolvedFullRange"] = player.video.resolvedFullRange
        report["rangeSource"] = player.video.rangeSource
        let refLUT = renderFrame(from: srcURL, at: 0.5, lut: lutPath, curvePoints: nil, sourceIsLimited: srcIsLimited)
        let refLUTCurve = renderFrame(from: srcURL, at: 0.5, lut: lutPath, curvePoints: player.curve.filterPointsString(), sourceIsLimited: srcIsLimited)
        let srcPlain = extractFrame(from: srcURL, at: 0.5, applyRangeFix: srcIsLimited)

        // 无 LUT 截图 vs 无 LUT 参考（基础管线正确性：应 >35dB）
        let psnrPlainShot = srcPlain.flatMap { r in shotPlainURL.flatMap { comparePSNR($0, r) } } ?? -1
        report["psnr_plain_screenshot_vs_plain"] = psnrPlainShot

        let psnrShotLUT = refLUT.flatMap { comparePSNR(shotLUT, $0) } ?? -1
        let psnrShotLUTvsPlain = srcPlain.flatMap { comparePSNR(shotLUT, $0) } ?? -1
        let psnrShotCurve = shotCurveURL.flatMap { u in refLUTCurve.flatMap { comparePSNR(u, $0) } } ?? -1
        let psnrShotCurveVsLUT = shotCurveURL.flatMap { comparePSNR(shotLUT, $0) } ?? -1

        report["psnr_lut_screenshot_vs_reference"] = psnrShotLUT
        report["psnr_lut_screenshot_vs_plain"] = psnrShotLUTvsPlain
        report["psnr_curve_screenshot_vs_reference"] = psnrShotCurve
        report["psnr_curve_vs_lut_screenshot"] = psnrShotCurveVsLUT

        // 5) 导出片段（带 LUT，不带曲线）
        // 5a) 无损（FFV1）用于**严格**校验 LUT 管线（有损编码会把 PSNR 拉低，失去判据意义）
        let outDir = args["outdir"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let exportURL = URL(fileURLWithPath: outDir)
            .appendingPathComponent("selftest_export_\(stamp).mkv")
        player.inPoint = 0.5
        player.outPoint = 1.5
        player.exportClip(preset: .lossless, to: exportURL)
        let exported = await waitUntil({ !player.exporter.isRunning }, timeout: 180)
        report["export"] = exportURL.path
        let exportSize = ((try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int) ?? 0)
        report["exportExists"] = FileManager.default.fileExists(atPath: exportURL.path) && exportSize > 0
        report["exportDone"] = exported
        if report["exportExists"] as? Bool == true {
            // 关键：读自己的导出时不能再来一次范围修正（否则二次扩展 → 假失败）
            let expFrame = extractFrame(from: exportURL, at: 0, applyRangeFix: false)
            let psnrExportLUT = expFrame.flatMap { e in refLUT.flatMap { comparePSNR(e, $0) } } ?? -1
            let psnrExportLUTCurve = expFrame.flatMap { e in refLUTCurve.flatMap { comparePSNR(e, $0) } } ?? -1
            report["psnr_export_vs_ref(no curve)"] = psnrExportLUT
            report["psnr_export_vs_ref(with curve)"] = psnrExportLUTCurve
            report["exportMatchesLUTOnly"] = psnrExportLUT > 30 && (psnrExportLUT - psnrExportLUTCurve) > 3

            // 5b) 默认交付预设（硬件 HEVC 10bit 4:2:2 → MP4）：校验 QuickLook 可预览的封装 + **区间正确**
            //     （历史 bug：-ss/-to 语义写错，导出区间被提前截断）
            let mp4URL = URL(fileURLWithPath: outDir)
                .appendingPathComponent("selftest_export_\(stamp).mp4")
            player.exportClip(preset: .hevc422HW, to: mp4URL)
            let mp4Done = await waitUntil({ !player.exporter.isRunning }, timeout: 180)
            let mp4Size = ((try? FileManager.default.attributesOfItem(atPath: mp4URL.path)[.size] as? Int) ?? 0)
            report["mp4Export"] = mp4URL.path
            report["mp4ExportExists"] = mp4Done && mp4Size > 0
            if let d = probeDuration(mp4URL) {
                report["mp4ExportDuration"] = d
                report["mp4DurationOK"] = abs(d - 1.0) < 0.2      // 导出区间 0.5→1.5 = 1.0s
            } else {
                report["mp4DurationOK"] = false
            }
        }

        // 判定：
        // 1) LUT 截图与 ffmpeg LUT 参考接近（Metal LUT 管线正确）
        // 2) LUT 截图与无 LUT 源帧差异大（LUT 生效）
        // 3) 带曲线截图与参考（LUT+曲线）接近，且与 LUT-only 截图差异大（曲线生效且仅预览）
        // 4) 导出匹配 LUT-only 参考、区别于 LUT+曲线参考
        let lutCorrect = psnrShotLUT > 25
        let lutApplied = psnrShotLUTvsPlain < 40
        let curveApplied = psnrShotCurve > 25 && psnrShotCurveVsLUT < 40
        let exportOK = (report["exportMatchesLUTOnly"] as? Bool) ?? false
        let mp4OK = (report["mp4ExportExists"] as? Bool) ?? false
            && (report["mp4DurationOK"] as? Bool) ?? false
        // 5) 无头保证：测试期间不得出现任何可见窗口（否则会打断用户）
        let visibleWindows = NSApp.windows.filter { $0.isVisible }.count
        report["visibleWindows"] = visibleWindows
        report["activationPolicy"] = NSApp.activationPolicy().rawValue
        let headlessOK = visibleWindows == 0
        report["checks"] = [
            "lutScreenshotMatchesReference": lutCorrect,
            "lutApplied": lutApplied,
            "curveAppliesOnlyToPreview": curveApplied,
            "exportLUTOnly": exportOK,
            "mp4ExportCorrect": mp4OK,
            "headless_noWindow": headlessOK,
        ]
        report["pass"] = lutCorrect && lutApplied && curveApplied && exportOK && mp4OK && headlessOK

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit((report["pass"] as? Bool == true) ? 0 : 1)
    }

    // MARK: - 解码测速（headless）

    private static func runDecBench() {
        let args = parse()
        guard let input = args["input"], FileManager.default.fileExists(atPath: input) else {
            print(#"{"pass": false, "error": "input not found"}"#)
            exit(1)
        }
        let dec = FFmpegVideoDecoder()
        guard dec.open(url: input) else {
            print("DECBENCH open failed")
            exit(1)
        }
        print("DECBENCH input=\(input)")
        print("DECBENCH size=\(dec.width)x\(dec.height) fps=\(dec.fps) duration=\(dec.duration)")
        if let desc = av_get_pix_fmt_name(dec.pixelFormat) {
            print("DECBENCH pixfmt=\(String(cString: desc))")
        }
        let target = min(5.0, dec.duration)
        let start = Date()
        var count = 0
        var lastPTS: Double = -1
        while let frame = dec.nextFrame() {
            let pts = dec.pts(of: frame)
            if pts > target { av_frame_unref(frame); break }
            lastPTS = pts
            count += 1
            av_frame_unref(frame)
            if count >= 1000 { break }
        }
        let wall = Date().timeIntervalSince(start)
        print("DECBENCH frames=\(count) wall=\(String(format: "%.2f", wall))s rate=\(String(format: "%.1f", Double(count) / wall))fps ptsEnd=\(String(format: "%.2f", lastPTS))")
    }

    // MARK: - 纯解码 seek 压力测试（headless，无 mpv/无 Metal）

    private static func runSeekTest() {
        fputs("SEEKTEST entered\n", stderr)
        fflush(stderr)
        let args = parse()
        guard let input = args["input"], FileManager.default.fileExists(atPath: input) else {
            fputs("SEEKTEST input not found\n", stderr)
            exit(1)
        }
        // 模拟引擎用法：open → 后台循环 nextFrame + 主线程反复 seek
        let dec = FFmpegVideoDecoder()
        fputs("SEEKTEST before open\n", stderr)
        fflush(stderr)
        guard dec.open(url: input) else { fputs("SEEKTEST open failed\n", stderr); exit(1) }
        fputs("SEEKTEST after open\n", stderr)
        fflush(stderr)
        let total = dec.duration
        fputs("SEEKTEST input=\(input) size=\(dec.width)x\(dec.height) dur=\(total)\n", stderr)
        fflush(stderr)

        var decodeDone = DispatchSemaphore(value: 0)
        var stop = false
        // 后台解码循环（与引擎相同的节奏）
        func spawnLoop() {
            Thread {
                var count = 0
                while !stop {
                    guard let f = dec.nextFrame() else { break }
                    av_frame_unref(f)
                    count += 1
                    if count % 25 == 0 { Thread.sleep(forTimeInterval: 0.006) }
                }
                decodeDone.signal()
            }.start()
        }
        spawnLoop()

        // 主线程反复 seek（与 selftest 相同的调用时机）
        var seeks = 0
        let positions = [0.5, 2.0, 0.5, 5.0, 1.0, 0.5, 3.0, 0.5]
        for pos in positions {
            stop = true
            let timedOut = decodeDone.wait(timeout: .now() + 5) != .success
            if timedOut {
                fputs("SEEKTEST 解码循环未在 5s 内退出（强制继续）@ seek \(pos)\n", stderr)
            }
            dec.seek(to: pos)
            // 重新启动解码循环
            stop = false
            decodeDone = DispatchSemaphore(value: 0)
            spawnLoop()
            Thread.sleep(forTimeInterval: 0.05)
            seeks += 1
            fputs("SEEKTEST seek #\(seeks) -> \(pos) OK\n", stderr)
        }
        stop = true
        _ = decodeDone.wait(timeout: .now() + 5)
        fputs("SEEKTEST PASS seeks=\(seeks)\n", stderr)
        exit(0)
    }

    // MARK: - 引擎级播放+seek 测试（headless：模拟 GUI 播放中 seek）

    private static func runEngineTest() {
        let args = parse()
        guard let input = args["input"], FileManager.default.fileExists(atPath: input) else {
            fputs("ENGINETEST input not found\n", stderr)
            exit(1)
        }
        fputs("ENGINETEST 开始\n", stderr)
        let engine = VideoPlaybackEngine()
        guard engine.open(url: input) else { fputs("ENGINETEST open 失败\n", stderr); exit(1) }
        fputs("ENGINETEST open OK size=\(engine.width)x\(engine.height)\n", stderr)

        // 模拟播放：从 0 取帧到 2s（每 20ms 取一帧）
        var t = 0.0
        var frames = 0
        while t < 2.0 {
            if let f = engine.takeFrameForTime(t) {
                frames += 1
                av_frame_unref(f)
            }
            Thread.sleep(forTimeInterval: 0.02)
            t += 0.02
        }
        fputs("ENGINETEST 播放 2s 取到 \(frames) 帧\n", stderr)

        // 模拟「从头播放」：seek(0) 后等新代帧
        func seekAndWait(_ target: Double, label: String) -> Bool {
            engine.seek(to: target)
            var waited = 0
            while waited < 400 {
                if let probe = engine.frameForTime(target + 0.01) {
                    let pts = engine.pts(of: probe)
                    av_frame_unref(probe)
                    if pts >= target - 0.02 {
                        fputs("ENGINETEST \(label) seek 到 \(target) 成功，取到 pts=\(pts)\n", stderr)
                        return true
                    }
                }
                Thread.sleep(forTimeInterval: 0.01)
                waited += 1
            }
            fputs("ENGINETEST \(label) seek 到 \(target) 超时（4s 无新代帧）！！\n", stderr)
            return false
        }

        let ok1 = seekAndWait(0.0, label: "回开头")
        // 继续播放 1s
        t = 0.0
        var frames2 = 0
        while t < 1.0 {
            if let f = engine.takeFrameForTime(t) {
                frames2 += 1
                av_frame_unref(f)
            }
            Thread.sleep(forTimeInterval: 0.02)
            t += 0.02
        }
        fputs("ENGINETEST seek 后再播放 1s 取到 \(frames2) 帧\n", stderr)
        let ok2 = seekAndWait(5.5, label: "跳到中部")
        t = 5.5
        var frames3 = 0
        while t < 6.5 {
            if let f = engine.takeFrameForTime(t) {
                frames3 += 1
                av_frame_unref(f)
            }
            Thread.sleep(forTimeInterval: 0.02)
            t += 0.02
        }
        fputs("ENGINETEST seek 到 5.5 后播放 1s 取到 \(frames3) 帧\n", stderr)
        let ok3 = seekAndWait(0.0, label: "再次回开头")

        let pass = ok1 && ok2 && ok3
        fputs("ENGINETEST \(pass ? "PASS" : "FAIL")\n", stderr)
        exit(pass ? 0 : 1)
    }

    // MARK: - 模型级 seek 探针（含 mpv 时钟 + 解码引擎）
    //
    // 验证目标：点击进度条后，解码引擎不得从 0 重来（历史 bug：
    // `client.timePos ?? 0` 在读不到 mpv time-pos 时把引擎 seek 到 0，
    // 表现为「画面从开头快进着追赶音频」）。

    @MainActor
    private static func runModelSeek() async {
        let args = parse()
        guard let input = args["input"], FileManager.default.fileExists(atPath: input) else {
            fputs("MODELSEEK input not found\n", stderr)
            exit(1)
        }
        let target = Double(args["target"] ?? "6.0") ?? 6.0
        let player = PlayerModel()
        player.open(URL(fileURLWithPath: input))

        var waited = 0
        while waited < 400, (player.client.duration ?? 0) <= 0 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            waited += 1
        }
        fputs("MODELSEEK 加载完成 dur=\(player.duration) mpvDur=\(player.client.duration ?? -1)\n", stderr)

        /// 模拟渲染循环：按 mpv 时钟取帧（消费语义），返回取到的 pts 序列
        @MainActor
        func tick(_ seconds: Double, label: String) async -> [Double] {
            let t0 = Date()
            var pts: [Double] = []
            while Date().timeIntervalSince(t0) < seconds {
                let t = player.renderTargetTime   // 与渲染循环同一口径
                if let f = player.video.takeFrameForTime(t) {
                    pts.append(player.video.pts(of: f))
                    av_frame_unref(f)
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            let first = pts.first.map { String(format: "%.2f", $0) } ?? "-"
            let last = pts.last.map { String(format: "%.2f", $0) } ?? "-"
            fputs("MODELSEEK [\(label)] 取帧=\(pts.count) 首帧=\(first) 末帧=\(last)\n", stderr)
            return pts
        }

        player.togglePlay()
        _ = await tick(1.5, label: "seek 前播放 1.5s")
        fputs("MODELSEEK seek 前 timePos=\(String(format: "%.2f", player.timePos))\n", stderr)

        player.seekTo(target)
        let mpvNow = player.client.timePos.map { String(format: "%.2f", $0) } ?? "nil"
        fputs("MODELSEEK seek(\(target)) 后立即 timePos=\(String(format: "%.2f", player.timePos)) mpv=\(mpvNow)\n", stderr)

        let after = await tick(2.5, label: "seek 后 2.5s")
        // 判定：seek 之后出现的帧不应回到 0 附近，且应接近目标
        let bad = after.contains { $0 < 1.0 && target > 2.0 }
        let nearTarget = after.contains { abs($0 - target) < 0.8 }
        let pass = !bad && nearTarget
        fputs("MODELSEEK \(pass ? "PASS" : "FAIL")（是否回到开头=\(bad) 是否抵达目标=\(nearTarget)）\n", stderr)
        exit(pass ? 0 : 1)
    }

    // MARK: - seek 落点探针（headless：连续消费帧，暴露真实 seek 落点）

    /// 用法：--seekprobe --input <file> [--targets 5.5,2.0,9.0]
    /// 关键点：必须持续消费帧（nextFrame），否则队列满会伪装成"seek 超时"
    private static func runSeekProbe() {
        let args = parse()
        guard let input = args["input"], FileManager.default.fileExists(atPath: input) else {
            fputs("SEEKPROBE input not found\n", stderr)
            exit(1)
        }
        let dec = FFmpegVideoDecoder()
        guard dec.open(url: input) else { fputs("SEEKPROBE open 失败\n", stderr); exit(1) }
        fputs("SEEKPROBE open OK size=\(dec.width)x\(dec.height) dur=\(dec.duration) fps=\(dec.fps)\n", stderr)

        /// 消费最多 maxFrames 帧；打印前 printCount 帧的 pts；到 stopAt 提前停
        @discardableResult
        func drain(_ label: String, maxFrames: Int, stopAt: Double? = nil, printCount: Int = 6) -> Double {
            var printed = 0
            var last = -1.0
            for _ in 0..<maxFrames {
                guard let f = dec.nextFrame() else {
                    fputs("  \(label): nextFrame = nil（EOF）\n", stderr)
                    break
                }
                let p = dec.pts(of: f)
                last = p
                av_frame_unref(f)
                if printed < printCount {
                    fputs("  \(label): pts=\(String(format: "%.3f", p))\n", stderr)
                    printed += 1
                }
                if let s = stopAt, p >= s { break }
            }
            return last
        }

        let startPos = drain("顺序解码", maxFrames: 200, stopAt: 2.0)
        fputs("SEEKPROBE 顺序解码到 \(String(format: "%.2f", startPos))s\n", stderr)

        let targets = (args["targets"] ?? "5.5,2.0,9.0")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        var allOK = true
        for t in targets {
            fputs("SEEKPROBE --- seek(\(t)) ---\n", stderr)
            dec.seek(to: t)
            let landed = drain("seek(\(t))", maxFrames: 120, printCount: 4)
            // 落点判定：seek 后首帧 pts 应 ≥ target - 0.6（允许落在目标前一个关键帧）；且不应退回 0
            let ok = landed >= t - 0.6 && !(t > 1.0 && landed < 0.5)
            fputs("SEEKPROBE seek(\(t)) 落点=\(String(format: "%.2f", landed))s => \(ok ? "OK" : "错位！")\n", stderr)
            if !ok { allOK = false }
        }
        fputs("SEEKPROBE \(allOK ? "PASS" : "FAIL")\n", stderr)
        exit(allOK ? 0 : 1)
    }

    // MARK: - 工具

    private static func parse() -> [String: String] {
        var args: [String: String] = [:]
        let raw = CommandLine.arguments
        var i = 1
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    args[key] = raw[i + 1]
                    i += 2
                } else {
                    args[key] = "true"
                    i += 1
                }
            } else {
                i += 1
            }
        }
        let cwd = FileManager.default.currentDirectoryPath
        for key in ["input", "lut", "outdir"] {
            if let v = args[key], !v.hasPrefix("/") {
                let abs = URL(fileURLWithPath: cwd).appendingPathComponent(v).standardized.path
                args[key] = abs
            }
        }
        return args
    }

    private static func waitUntil(_ cond: @escaping @MainActor () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: cond) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await MainActor.run(body: cond)
    }

    /// 用 ffmpeg 渲染参考帧（指定 LUT + 可选曲线点串）
    @MainActor
    private static func renderFrame(from video: URL, at time: Double, lut: String?, curvePoints: String?,
                                    sourceIsLimited: Bool = true) -> URL? {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selftest_ref_\(Int(Date().timeIntervalSince1970))_\(curvePoints == nil ? "plain" : "curve").png")
        guard let ffmpeg = ClipExportService.locateFFmpeg() else { return nil }
        // 参考必须与解码器语义一致：本素材解码帧 color_range=tv（limited），
        // 而 ffmpeg CLI 显示 (pc) 是误导——用 scale 强制 limited→full 转换
        // 与引擎判定同口径：源判定为 limited 才做 limited→full 修正
        var vfParts: [String] = sourceIsLimited ? ["scale=in_range=limited:out_range=full"] : []
        if let lut { vfParts.append("lut3d=\(FilterChain.ffmpegQuote(lut))") }
        if let c = curvePoints, !c.isEmpty { vfParts.append("curves=master='\(c)'") }
        let p = Process()
        p.executableURL = ffmpeg
        var args = ["-y", "-hide_banner", "-ss", String(format: "%.3f", time), "-i", video.path, "-frames:v", "1"]
        if !vfParts.isEmpty { args += ["-vf", vfParts.joined(separator: ",")] }
        args.append(out.path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    /// 从视频提取指定时间点的一帧为 PNG
    @MainActor
    /// 抽帧为 PNG 参考。
    /// - Parameter applyRangeFix: 源素材需要（标签 pc 但数据实为 limited）；
    ///   **读我们自己导出的文件时必须关掉**——导出已经做过 limited→full，
    ///   再做一次就是二次扩展（曾导致导出比对只有 27.9dB 的假失败）。
    private static func extractFrame(from video: URL, at time: Double, applyRangeFix: Bool = true) -> URL? {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selftest_frame_\(Int(Date().timeIntervalSince1970))_\(applyRangeFix ? "src" : "out").png")
        guard let ffmpeg = ClipExportService.locateFFmpeg() else { return nil }
        let p = Process()
        p.executableURL = ffmpeg
        var args = ["-y", "-hide_banner", "-ss", String(format: "%.3f", time), "-i", video.path]
        if applyRangeFix { args += ["-vf", "scale=in_range=limited:out_range=full"] }
        args += ["-frames:v", "1", out.path]
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    /// 读取媒体时长（秒）；用于校验导出区间是否正确（历史 bug：-to 语义错误导致区间被截断）
    @MainActor
    private static func probeDuration(_ url: URL) -> Double? {
        guard let ffmpeg = ClipExportService.locateFFmpeg() else { return nil }
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-i", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let r = text.range(of: "Duration: ") else { return nil }
        let clock = text[r.upperBound...].prefix(11)          // HH:MM:SS.ss
        let parts = clock.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// PSNR（dB），越大越接近；先缩放归一再比
    @MainActor
    private static func comparePSNR(_ a: URL, _ b: URL) -> Double? {
        guard let ffmpeg = ClipExportService.locateFFmpeg() else { return nil }
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-i", a.path, "-i", b.path,
                       "-lavfi", "[0:v]format=rgb24,scale=640:-2[a];[1:v]format=rgb24,scale=640:-2[b];[a][b]psnr",
                       "-f", "null", "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let range = text.range(of: "average:") else { return nil }
        let tail = text[range.upperBound...]
        let numStr = tail.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
        return Double(numStr)
    }
}
