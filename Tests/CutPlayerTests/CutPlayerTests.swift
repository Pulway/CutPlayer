import Foundation
import CutPlayerKit

// MARK: - LUT 记忆库

func runLUTDatabaseTests() {
    Harness.suite("LUTDatabase")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cutplayer-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = LUTDatabase(url: dir.appendingPathComponent("test.db"))

    let f1 = dir.appendingPathComponent("a.mov").path
    let f2 = dir.appendingPathComponent("b.mov").path

    db.setLUT("/LUTs/log.cube", forFiles: [f1, f2])
    Harness.equal(db.lut(forFile: f1), "/LUTs/log.cube", "批量设置后文件级记忆")
    Harness.equal(db.lut(forFile: f2), "/LUTs/log.cube", "批量设置后文件级记忆 2")
    Harness.equal(db.lut(forDirectory: dir.path), "/LUTs/log.cube", "目录级默认 LUT")

    let f3 = dir.appendingPathComponent("new.mov").path
    Harness.equal(db.lut(forFile: f3), "/LUTs/log.cube", "新文件继承目录默认 LUT")

    db.setLUT("/LUTs/special.cube", forFiles: [f1])
    Harness.equal(db.lut(forFile: f1), "/LUTs/special.cube", "文件级覆盖目录级")

    db.clearLUT(forFile: f1)
    // 清除文件级记忆后，按设计回退到目录默认（此前 setLUT(special) 已把目录默认更新为 special）
    Harness.equal(db.lut(forFile: f1), "/LUTs/special.cube", "清除文件级后回退目录默认")
    Harness.equal(db.lut(forFile: f2), "/LUTs/log.cube", "其他文件保留自己的文件级记忆")

    // 完全清除目录级 + 文件级后，才真正没有 LUT
    db.clearLUT(forDirectory: dir.path)
    Harness.nilCheck(db.lut(forFile: f1), "目录级清除后无 LUT")
    db.clearLUT(forFile: f2)
    Harness.nilCheck(db.lut(forFile: f2), "文件级清除后无 LUT")

    db.rememberPlayback(path: f1, position: 42.5, duration: 100)
    let state = db.playbackState(for: f1)
    Harness.notNil(state, "播放进度已记忆")
    if let state {
        Harness.approx(state.position, 42.5, accuracy: 0.001, "进度位置")
        Harness.approx(state.duration, 100, accuracy: 0.001, "进度时长")
    }
}

// MARK: - 亮度曲线

@MainActor
func runCurveModelTests() {
    Harness.suite("CurveModel")

    let c = CurveModel()
    Harness.check(c.isIdentity, "默认曲线为直线")
    Harness.nilCheck(c.filterPointsString(), "直线不生成滤镜点")

    c.set([CurvePoint(x: 0.8, y: 0.9), CurvePoint(x: 0.2, y: 0.1)])
    Harness.equal(c.points.first, CurvePoint(x: 0, y: 0), "左端点锁定")
    Harness.equal(c.points.last, CurvePoint(x: 1, y: 1), "右端点锁定")
    var sorted = true
    for i in 1..<c.points.count where c.points[i].x <= c.points[i - 1].x { sorted = false }
    Harness.check(sorted, "点按 x 排序")

    c.set([
        CurvePoint(x: 0.5, y: 0.4),
        CurvePoint(x: 0.5, y: 0.6),
        CurvePoint(x: 0.7, y: 0.8),
    ])
    let xs = c.points.map(\.x)
    Harness.equal(Set(xs).count, xs.count, "x 去重")

    let c2 = CurveModel()
    c2.set([CurvePoint(x: 0.5, y: 0.62)])
    c2.enabled = true
    let s = c2.filterPointsString()
    Harness.notNil(s, "激活曲线生成滤镜点串")
    if let s {
        let tokens = s.split(separator: " ")
        let firstParts = tokens.first?.split(separator: "/").compactMap { Double($0) } ?? []
        let lastParts = tokens.last?.split(separator: "/").compactMap { Double($0) } ?? []
        Harness.approx(firstParts.first ?? -1, 0, accuracy: 0.0001, "点串起点 x=0")
        Harness.approx(firstParts.last ?? -1, 0, accuracy: 0.0001, "点串起点 y=0")
        Harness.approx(lastParts.first ?? -1, 1, accuracy: 0.0001, "点串终点 x=1")
        Harness.approx(lastParts.last ?? -1, 1, accuracy: 0.0001, "点串终点 y=1")
        for t in tokens {
            let parts = t.split(separator: "/")
            Harness.equal(parts.count, 2, "点格式 x/y")
            Harness.check(Double(parts[0]) != nil && Double(parts[1]) != nil, "点值为数字")
        }
    }

    let samples = c2.sample(count: 20)
    Harness.check(samples.count >= 2, "采样点数足够")
    var monotonic = true
    for i in 1..<samples.count where samples[i].y + 0.0001 < samples[i - 1].y { monotonic = false }
    Harness.check(monotonic, "采样单调不减")
    Harness.approx(samples.first?.y ?? -1, 0, accuracy: 0.0001, "采样起点 y=0")
    Harness.approx(samples.last?.y ?? -1, 1, accuracy: 0.0001, "采样终点 y=1")

    Harness.approx(c2.value(at: 0), 0, accuracy: 0.001, "value(at:0)=0")
    Harness.approx(c2.value(at: 1), 1, accuracy: 0.001, "value(at:1)=1")
}

// MARK: - 滤镜链

func runFilterChainTests() {
    Harness.suite("FilterChain 转义")

    // 导出滤镜串里 LUT 路径要能安全转义（含空格/中文/单引号）
    Harness.equal(FilterChain.ffmpegQuote("/LUTs/log.cube"), "'/LUTs/log.cube'", "普通路径")
    Harness.equal(FilterChain.ffmpegQuote("/My LUTs/曲线.cube"), "'/My LUTs/曲线.cube'", "含空格与中文")
    Harness.equal(FilterChain.ffmpegQuote("a'b"), "'a\\'b'", "单引号转义")
}

// MARK: - 导出命令

func runClipExportCommandTests() {
    Harness.suite("ClipExportCommand")

    let args = ClipExportCommand.arguments(
        input: URL(fileURLWithPath: "/v/a.mov"),
        start: 0.5, end: 1.5,
        lut: "/LUTs/log.cube",
        preset: .hevc422HW,
        output: URL(fileURLWithPath: "/out/x.mp4")
    )
    Harness.check(args.contains("lut3d='/LUTs/log.cube'"), "导出命令含 LUT")
    Harness.check(!args.joined(separator: " ").contains("curves"), "导出命令不含曲线（核心需求）")

    let args2 = ClipExportCommand.arguments(
        input: URL(fileURLWithPath: "/v/a.mov"),
        start: 1.25, end: 3.5,
        lut: nil,
        preset: .hevc422HW,
        output: URL(fileURLWithPath: "/out/x.mp4")
    )
    // seek 语义（历史 bug 就是把这两个写反了：-ss 放在 -i 之后、-to 当相对时长，
    // 结果导出区间被提前截断，甚至生成 0 帧文件）
    let iIdx = args2.firstIndex(of: "-i")!
    let ssIdx = args2.firstIndex(of: "-ss")!
    Harness.check(ssIdx < iIdx, "-ss 在 -i 之前（输入定位，帧精确）")
    Harness.equal(args2[ssIdx + 1], "1.250", "入点秒数")
    let tIdx = args2.firstIndex(of: "-t")!
    Harness.equal(args2[tIdx + 1], "2.250", "-t 为片段时长")
    Harness.check(!args2.contains("-to"), "不再使用语义含糊的 -to")

    // QuickLook 可预览：视频预设统一输出 mp4（无损归档除外）
    for preset in ClipExportCommand.Preset.allCases where preset != .lossless {
        Harness.equal(preset.fileExtension, "mp4", "\(preset.rawValue) 输出 mp4")
    }

    for preset in ClipExportCommand.Preset.allCases {
        let a = ClipExportCommand.arguments(
            input: URL(fileURLWithPath: "/v/a.mov"),
            start: 0, end: 1,
            lut: nil,
            preset: preset,
            output: URL(fileURLWithPath: "/out/x.\(preset.fileExtension)")
        )
        Harness.check(a.contains("-c:v"), "预设 \(preset.rawValue) 含视频编码")
        Harness.check(a.contains("-map"), "预设 \(preset.rawValue) 含轨道映射")
    }
}

// MARK: - 入口

@main
struct TestMain {
    @MainActor
    static func main() {
        runLUTDatabaseTests()
        runCurveModelTests()
        runFilterChainTests()
        runClipExportCommandTests()
        exit(Harness.summary() ? 0 : 1)
    }
}
