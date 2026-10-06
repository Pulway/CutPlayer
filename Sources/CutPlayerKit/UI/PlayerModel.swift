import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import CFFmpeg

/// 中央协调器：视频（FFmpeg 解码 + Metal 渲染）+ 音频（mpv 纯音频）+ 播放列表
/// + LUT 记忆库 + 亮度曲线 + 截图/导出
@MainActor
public final class PlayerModel: ObservableObject {
    public let client: MPVClient
    public let db: LUTDatabase
    public let playlist: PlaylistModel
    public let curve: CurveModel
    public let exporter = ClipExportService()
    /// 视频引擎（FFmpeg 解码 + 帧队列）
    public let video = VideoPlaybackEngine()
    /// Metal 渲染视图（YUV→RGB + LUT + 曲线）
    public let metalView = MetalVideoView()

    // 播放状态
    @Published public private(set) var currentURL: URL?
    @Published public private(set) var timePos: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isPaused = true
    @Published public private(set) var eof = false
    @Published public private(set) var mediaTitle = ""
    @Published public private(set) var mediaInfo: [String: String] = [:]

    // 用户设置
    @Published public var volume: Double = 100 { didSet { client.setVolume(volume) } }
    @Published public var muted = false { didSet { client.setMute(muted) } }
    @Published public var speed: Double = 1.0 { didSet { client.setSpeed(speed) } }

    // LUT / 曲线
    @Published public private(set) var lutPath: String?
    @Published public var showCurvePanel = false

    // 播放模式
    public enum PlayMode: String, CaseIterable {
        case sequential = "顺序播放"
        case noAuto = "不连播"
        case loop = "循环播放"

        var icon: String {
            switch self {
            case .sequential: return "arrow.right.to.line"
            case .noAuto: return "stop.fill"
            case .loop: return "repeat"
            }
        }
    }

    @Published public var playMode: PlayMode = .sequential

    // 片段
    @Published public var inPoint: Double?
    @Published public var outPoint: Double?
    @Published public var showExportSheet = false

    // 信息
    @Published public var showMediaInfo = false
    @Published public var statusMessage: String?
    @Published public var lastScreenshotURL: URL?
    @Published public var exportCompletedURL: URL?

    private var curveApplyTask: Task<Void, Never>?
    private var resumeAppliedForPath: String?
    private var lastPlaybackSave: TimeInterval = 0
    /// 自动连播/循环跳转标志：跳转后自动开始播放（手动切换仍默认暂停）
    private var autoAdvance = false

    public init() {
        // 纯音频模式：mpv 只负责音频与时钟（视频由 FFmpeg+Metal 渲染）
        MPVClient.audioOnlyMode = true
        guard let c = MPVClient() else {
            fatalError("libmpv 初始化失败：请确认已安装 mpv（brew install mpv）")
        }
        client = c
        db = LUTDatabase(url: Self.defaultDatabaseURL)
        playlist = PlaylistModel(db: db)
        curve = CurveModel()

        // Metal 视图 ↔ 模型 接线（take 语义：视图取走后负责 av_frame_unref）
        metalView.timeSource = { [weak self] in self?.renderTargetTime ?? 0 }
        metalView.frameForTime = { [weak self] t in self?.video.takeFrameForTime(t) }
        metalView.isActive = { [weak self] in !(self?.isPaused ?? true) }
        metalView.ptsOfFrame = { [weak self] f in self?.video.pts(of: f) ?? 0 }
        metalView.onFrameDrawn = { [weak self] pts in self?.handleFrameDrawn(pts) }
        // 输入范围判定结果 → 渲染 + 导出共用同一结论（保证所见即所得）
        video.onRangeResolved = { [weak self] isFull, source in
            guard let self else { return }
            self.metalView.inputIsFullRange = isFull
            self.metalView.requestRedraw()
            self.rangeModeDescription = source
            self.guiLog("range: \(isFull ? "full" : "limited")（\(source)）")
        }

        client.onFileLoaded = { [weak self] in self?.onFileLoaded() }
        client.onEndFile = { [weak self] reason in self?.onEndFile(reason) }
        client.onPropertyChange = { [weak self] name in self?.onPropertyChanged(name) }
        client.onError = { [weak self] msg in
            if msg.contains("Failed to open") || msg.contains("could not be opened") {
                self?.statusMessage = "无法打开文件"
            }
        }

        lutLibrary = db.lutLibrary()

        // 调试钩子（截图 / 自动化验证用，正常使用不受影响）：
        //   CUTPLAYER_HIDE_SIDEBAR=1   以"侧栏已收起"状态启动
        //   CUTPLAYER_OPEN_CURVE=1     启动即打开亮度曲线面板
        //   CUTPLAYER_OPEN_FILE=a:b    启动即把冒号分隔的文件加入播放列表并打开第一个
        //   CUTPLAYER_SCREENSHOTS_DIR  覆盖截图目录（受限沙箱下 ~/Movies 可能不可写）
        if ProcessInfo.processInfo.environment["CUTPLAYER_HIDE_SIDEBAR"] != nil {
            sidebarVisible = false
        }
        if let list = ProcessInfo.processInfo.environment["CUTPLAYER_OPEN_FILE"], !list.isEmpty {
            let urls = list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            let added = playlist.add(urls: urls)
            if let first = added.first?.url ?? urls.first {
                DispatchQueue.main.async { [weak self] in self?.open(first) }
            }
        }

        // 转发 playlist 的变化：PlaylistModel 是嵌套的 ObservableObject，
        // 它的 selection/items 变化不会自动让观察 PlayerModel 的视图重绘。
        // 症状：**暂停时**点选条目，选中态直到播放（timePos 刷新）才显示出来。
        playlist.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 曲线变化 → 防抖刷新 GPU 管线
        curve.$points.combineLatest(curve.$enabled).sink { [weak self] _ in
            self?.scheduleCurveApply()
        }.store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    public static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CutPlayer/cutplayer.db")
    }

    // MARK: - 打开文件

    public func open(_ url: URL, force: Bool = false) {
        // 同一个文件已在播放：只同步选中状态，不重复加载
        // （行点击手势与 List selection 可能都会触发一次 open）
        if !force, currentURL == url, video.isOpen {
            if let item = playlist.items.first(where: { $0.url == url }) { playlist.select(item) }
            return
        }
        let tStart = CFAbsoluteTimeGetCurrent()
        currentURL = url
        mediaTitle = url.lastPathComponent
        // 清空旧画面：避免「旧视频帧 + 新视频 LUT」的错误组合
        metalView.clearDisplay()
        duration = 0
        timePos = 0
        eof = false
        inPoint = nil
        outPoint = nil
        mediaInfo = [:]

        if let item = playlist.items.first(where: { $0.url == url }) {
            playlist.select(item)
        } else {
            let item = playlist.add(urls: [url]).first
            if let item { playlist.select(item) }
        }

        // 输入色彩范围：数据库里的手动覆盖优先，其次引擎自动判定
        let savedRangeMode = db.rangeMode(forFile: url.path)
        rangeMode = savedRangeMode

        // 自动记忆：目录 ↔ LUT
        let remembered = db.lut(forFile: url.path)
        if let remembered {
            if FileManager.default.fileExists(atPath: remembered) {
                setLUT(remembered, record: false)
            } else {
                statusMessage = "记忆的 LUT 文件不存在：\(remembered)"
            }
        } else {
            setLUT(nil, record: false)
        }

        // 切换文件与 seek 同理：mpv 的 loadfile 会立刻出声，而解码器还在探测文件（数百 ms）。
        // 因此先把音频按住、把渲染目标钉在新文件起点，等首帧上屏后再解除
        //（否则 mpv 的 time-pos 还可能停留在上一个文件的位置，导致画面快进追赶）。
        let wasPlaying = !isPaused
        pinnedRenderTarget = 0
        if wasPlaying {
            client.pause()
            audioHoldActive = true
        }

        // 视频解码：**异步**打开（等旧解码线程退出 + avformat 探测都可能在主线程卡住界面）
        // 音频交给 mpv 异步加载，不阻塞
        let tOpen = CFAbsoluteTimeGetCurrent()
        let openedURL = url
        video.openAsync(url: url.path) { [weak self] ok in
            guard let self else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - tOpen) * 1000
            // 快速连点时，旧请求的完成回调要丢弃
            guard self.currentURL == openedURL else {
                self.guiLog(String(format: "open: 丢弃过期完成 %@ (%.0fms)", openedURL.lastPathComponent, ms))
                return
            }
            if ok {
                self.duration = self.video.duration
                self.metalView.decoderColorRange = self.video.decoderColorRange
                if self.video.fps > 0 { self.metalView.frameInterval = 1.0 / self.video.fps }
                self.applyRangeMode()
                self.refreshMediaInfo()
                self.metalView.requestRedraw()
                self.guiLog(String(format: "open: %@ 视频就绪=%.0fms size=%@", openedURL.lastPathComponent,
                                   ms, "\(self.video.width)x\(self.video.height)"))
                if wasPlaying {
                    // 等新文件首帧上屏后再放行音频（此处之后画的帧必定属于新文件：
                    // 队列已在后台清空并重新打开解码器）
                    self.guiLog("open: 音频已按住，等首帧上屏")
                }
                self.pendingOpenRelease = openedURL
                self.openReleaseFallback?.cancel()
                self.openReleaseFallback = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard let self, self.pendingOpenRelease != nil else { return }
                    self.guiLog("open: 首帧 2.5s 未上屏，兜底解除")
                    self.finishOpenRelease()
                }
            } else {
                self.statusMessage = "无法打开视频流：\(openedURL.lastPathComponent)"
                self.guiLog(String(format: "open: %@ 失败=%.0fms", openedURL.lastPathComponent, ms))
                self.finishOpenRelease()   // 打不开也不能把音频一直按着
            }
        }
        let tLoad = CFAbsoluteTimeGetCurrent()
        client.loadFile(url.path)
        guiLog(String(format: "open: %@ 主线程总耗时=%.0fms（其中 loadFile=%.0fms）",
                      url.lastPathComponent,
                      (CFAbsoluteTimeGetCurrent() - tStart) * 1000,
                      (CFAbsoluteTimeGetCurrent() - tLoad) * 1000))

        // 封面：解码出第一帧后重绘（不自动播放时也显示本视频的第一帧，而非上一个视频的残留帧）
        Task { [weak self] in
            for _ in 0..<40 {   // 最多 2s（异步打开可能较慢）
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.currentURL == openedURL else { return }
                if self.video.frameForTime(0) != nil {
                    self.metalView.requestRedraw()
                    return
                }
            }
            self?.metalView.requestRedraw()
        }
    }

    /// 从播放列表移除条目。
    /// 若被移除的正是当前播放项：自动把**列表第一条**设为当前播放；
    /// 列表已空则停止播放并清空画面（否则会出现"界面没有当前项、画面还在播"的错位）。
    public func removeFromPlaylist(_ items: [PlaylistItem]) {
        guard !items.isEmpty else { return }
        let removing = Set(items.map(\.id))
        let currentRemoved = playlist.currentID.map { removing.contains($0) } ?? false
        playlist.remove(items)
        guard currentRemoved else { return }
        if let first = playlist.items.first {
            open(first.url, force: true)
        } else {
            closeCurrent()
        }
    }

    /// 停止播放并清空当前状态（播放列表被清空时用）
    public func closeCurrent() {
        currentURL = nil
        mediaTitle = ""
        duration = 0
        timePos = 0
        inPoint = nil
        outPoint = nil
        mediaInfo = [:]
        lutPath = nil
        client.stop()
        video.close()
        metalView.clearDisplay()
        applyChain()
        metalView.requestRedraw()
        statusMessage = "播放列表已空"
    }

    public func openNext() {
        guard let next = playlist.playNext() else { return }
        open(next.url)
    }

    public func openPrevious() {
        guard let prev = playlist.playPrevious() else { return }
        open(prev.url)
    }

    private func onFileLoaded() {
        if duration <= 0 { duration = client.duration ?? 0 }
        // 自动连播/循环：加载完成后自动播放
        if autoAdvance {
            autoAdvance = false
            if isPaused { togglePlay() }
        }
        // 断点续播
        guard let url = currentURL else { return }
        if resumeAppliedForPath != url.path,
           let state = db.playbackState(for: url.path),
           state.duration > 10,
           state.position > 5,
           state.position < state.duration - 5 {
            resumeAppliedForPath = url.path
            seekTo(state.position)
        }
    }

    private func onEndFile(_ reason: String) {
        savePlaybackState()
        if reason == "eof" { eof = true }
    }

    /// eof-reached 触发（keep-open=yes 下 mpv 不卸载文件，end-file 事件不触发，
    /// 但 eof-reached 属性会置 true）——按播放模式处理连播/循环
    private var handledEOF = false
    private func handlePlayModeAtEOF() {
        guard !handledEOF else { return }
        handledEOF = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.handledEOF = false
            switch self.playMode {
            case .sequential:
                if let next = self.playlist.playNext() {
                    self.autoAdvance = true
                    self.open(next.url)
                }
            case .noAuto:
                break // 停在结尾，不自动连播
            case .loop:
                self.seekTo(0)
                if self.isPaused { self.togglePlay() }
            }
        }
    }

    private func savePlaybackState() {
        guard let url = currentURL, let pos = client.timePos else { return }
        let dur = client.duration ?? 0
        if dur > 3 { db.rememberPlayback(path: url.path, position: pos, duration: dur) }
    }

    // MARK: - 播放控制

    public func togglePlay() {
        // seek 按住期间用户主动操作优先：直接结束按住（避免"按不动"）
        if audioHoldActive {
            audioHoldActive = false
            pinnedRenderTarget = nil
        }
        client.togglePause()
    }

    // MARK: - seek
    //
    // 关键约束：**绝不能回读 mpv 的 time-pos 当作解码目标**。
    // mpv_set_property("time-pos") 之后，time-pos 在若干毫秒内可能读取失败
    // （getDouble 返回 nil），旧代码 `client.timePos ?? 0` 会把解码引擎 seek 到 0，
    // 症状就是「点了进度条，画面从开头以解码速度快进着追赶音频」。
    // 因此这里统一用调用方给出的目标值：mpv 与解码引擎共用同一个数字。

    public func seekRelative(_ seconds: Double) {
        performSeek(to: (client.timePos ?? timePos) + seconds, driveMPV: true)
    }

    public func seekFraction(_ fraction: Double) {
        guard duration > 0 else { return }
        performSeek(to: fraction * duration, driveMPV: true)
    }

    public func seekTo(_ seconds: Double) {
        performSeek(to: seconds, driveMPV: true)
    }

    /// 逐帧步进：mpv 负责音频/时钟，解码引擎按 ±1 帧跟随（不重复驱动 mpv）
    public func stepFrame(back: Bool = false) {
        client.frameStep(back: back)
        let step = video.fps > 0 ? 1.0 / video.fps : 0.04
        performSeek(to: (client.timePos ?? timePos) + (back ? -step : step), driveMPV: false)
    }

    /// seek 目标：mpv 时钟追上它之前，忽略观察到的位置跳变（避免自我对抗）
    private var pendingSeekTarget: Double?
    private var pendingSeekDeadline = Date.distantPast
    private var settleTask: Task<Void, Never>?

    // MARK: seek 的声画同步策略（方案 A + C）
    //
    // A：seek 时先把 mpv 音频按住，等目标帧解出来再一起从新位置开始，
    //    避免「声音先跑、画面随后追」的声画不同步。
    // C：追赶期由引擎先给一张关键帧占位（不空等、也不快进扫描），
    //    精确帧就绪后替换。
    // 计时：记录「关键帧占位上屏」「精确帧上屏」两个时刻，写入 /tmp/cutplayer_gui.log。

    private var audioHoldActive = false
    private var pinnedRenderTarget: Double?
    @Published public private(set) var lastSeekLatencyMs: Double?

    /// 是否处于全屏（由 ContentView 的全屏通知维护）
    @Published public var isFullScreen = false
    /// 侧栏（播放列表）是否显示：点击视频标题切换（全屏/非全屏都可用）
    @Published public var sidebarVisible = true

    /// 切换侧栏显示（入口：播放区顶栏的视频标题）
    public func toggleSidebar() {
        sidebarVisible.toggle()
    }

    /// 已导入的 LUT 库（二级菜单直接用）
    @Published public private(set) var lutLibrary: [String] = []

    /// 输入色彩范围模式：auto / limited / full（按文件记住）
    @Published public private(set) var rangeMode: String = "auto"
    /// 当前判定结果的人类可读描述（界面 tooltip）
    @Published public private(set) var rangeModeDescription: String = ""

    /// 切换输入范围模式：写库 + 立即生效（重绘）
    public func setRangeMode(_ mode: String) {
        rangeMode = mode
        if let url = currentURL { db.setRangeMode(mode, forFile: url.path) }
        applyRangeMode()
        metalView.requestRedraw()
    }

    /// 把当前模式应用到引擎（auto 交给引擎的自动判定）
    private func applyRangeMode() {
        video.overrideRange(mode: rangeMode)
        metalView.inputIsFullRange = video.resolvedFullRange
    }

    /// 当前渲染目标时间（渲染循环与测试共用的唯一口径）：
    /// seek/打开按住期间用钉住的目标值（此时 mpv 时钟不可信），
    /// 否则用 mpv 音频时钟；都取不到时退回模型记录的 timePos（**绝不退化成 0**）。
    public var renderTargetTime: Double {
        if let pinned = pinnedRenderTarget { return pinned }
        return client.timePos ?? timePos
    }

    private struct SeekTrace {
        let target: Double
        let started: CFAbsoluteTime
        let driveMPV: Bool
        let wasPlaying: Bool
        var audioReleasedMs: Double?
    }
    private var seekTrace: SeekTrace?

    /// 打开新文件时的"首帧放行"（等首帧上屏再让 mpv 出声）
    private var pendingOpenRelease: URL?
    private var openReleaseFallback: Task<Void, Never>?

    /// 放行打开时按住的音频（不 seek：mpv 已在文件起点/续播点）
    private func finishOpenRelease() {
        pendingOpenRelease = nil
        openReleaseFallback?.cancel()
        openReleaseFallback = nil
        pinnedRenderTarget = nil      // 无论有没有按住音频，都要解除渲染目标钉住
        guard audioHoldActive else { return }
        audioHoldActive = false
        client.play()
        guiLog("open: 首帧已上屏，音频放行（声画同时开始）")
    }

    private func performSeek(to rawTarget: Double, driveMPV: Bool) {
        let d = duration > 0 ? duration : (client.duration ?? 0)
        let target = min(max(rawTarget, 0), max(d - 0.05, 0))
        let wasPlaying = !isPaused

        if driveMPV {
            client.pause()          // A：先按住音频
            audioHoldActive = true
        }
        pinnedRenderTarget = target // 按住期间 mpv 时钟不可信，渲染目标钉在目标值上
        pendingSeekTarget = target
        pendingSeekDeadline = Date().addingTimeInterval(3)
        video.seek(to: target)
        timePos = target
        seekTrace = SeekTrace(target: target, started: CFAbsoluteTimeGetCurrent(),
                              driveMPV: driveMPV, wasPlaying: wasPlaying,
                              audioReleasedMs: nil)
        metalView.requestRedraw()
        waitForDecodedFrame(at: target, driveMPV: driveMPV, wasPlaying: wasPlaying)
    }

    /// 驱动绘制的轮询 + 兜底超时。
    /// 注意：**不能**在这里判断"目标帧是否就绪"——目标帧一旦被显示端取走就会从队列消失，
    /// 轮询会一直找不到它（旧实现因此把音频按满 3 秒，表现为"卡顿数秒才出声"）。
    /// 真正的放行时机是精确帧上屏回调 handleFrameDrawn。
    private func waitForDecodedFrame(at target: Double, driveMPV: Bool, wasPlaying: Bool) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            for _ in 0..<30 {   // 最多 ~1.5s
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                self.metalView.requestRedraw()
                if self.seekTrace == nil { return }   // 精确帧已上屏，音频已在回调里放行
            }
            // 兜底：1.5s 仍未上屏（窗口被遮挡、片尾等）→ 不能让音频一直停着
            self?.releaseAudioHold(target: target, driveMPV: driveMPV, wasPlaying: wasPlaying)
        }
    }

    private func releaseAudioHold(target: Double, driveMPV: Bool, wasPlaying: Bool) {
        pinnedRenderTarget = nil
        if driveMPV, audioHoldActive {
            audioHoldActive = false
            client.seekAbsolute(target)     // 按住期间 mpv 没动，这里一次性落位
            if wasPlaying { client.play() } // 与画面同时开始
        }
    }

    /// 每帧上屏回调：精确帧上屏 = 放行音频 + 记录延迟（占位帧 / 精确帧 / 音频）
    private func handleFrameDrawn(_ pts: Double) {
        // 打开新文件：首帧上屏即放行音频（若有 seek 在飞，交给 seek 的放行逻辑）
        if pendingOpenRelease != nil, seekTrace == nil {
            finishOpenRelease()
        }
        guard var tr = seekTrace else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - tr.started) * 1000
        if pts >= tr.target - 0.06 {
            releaseAudioHold(target: tr.target, driveMPV: tr.driveMPV, wasPlaying: tr.wasPlaying)
            let audioMs = (CFAbsoluteTimeGetCurrent() - tr.started) * 1000
            tr.audioReleasedMs = audioMs
            seekTrace = tr
            lastSeekLatencyMs = ms
            guiLog(String(format: "seek: 目标=%.3f 精确帧上屏=%.0fms 音频放行=%.0fms",
                          tr.target, ms, audioMs))
            seekTrace = nil
            settleTask?.cancel()
        }
    }

    private func guiLog(_ msg: String) {
        let path = "/tmp/cutplayer_gui.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write((msg + "\n").data(using: .utf8)!)
            try? fh.close()
        }
    }

    public func markIn() { inPoint = timePos }
    public func markOut() { outPoint = timePos }
    public func clearMarks() { inPoint = nil; outPoint = nil }

    // MARK: - 打开面板

    public func pickAndOpenFiles() {
        guard let urls = OpenPanels.pickFiles() else { return }
        let added = playlist.add(urls: urls)
        if let first = added.first { open(first.url) }
    }

    public func pickAndOpenFolder() {
        guard let url = OpenPanels.pickFolder() else { return }
        playlist.addFolder(url: url)
        if let first = playlist.items.first { open(first.url) }
    }

    /// 给播放列表当前选中的文件统一设置 LUT
    // MARK: - LUT 库与批量套用

    /// 当前选中的条目；没有选中时退回"当前播放的文件"
    public var lutTargets: [PlaylistItem] {
        let selected = playlist.items.filter { playlist.selection.contains($0.id) }
        if !selected.isEmpty { return selected }
        if let current = playlist.currentItem { return [current] }
        return []
    }

    /// 把 LUT 套用到当前选择（多选则批量；未选中则当前文件）
    public func applyLUT(_ path: String?) {
        let targets = lutTargets
        guard !targets.isEmpty else {
            statusMessage = "请先在播放列表里选择文件"
            return
        }
        if let path {
            setLUT(path, for: targets)
            statusMessage = "已为 \(targets.count) 个文件设置监看 LUT：\((path as NSString).lastPathComponent)"
        } else {
            clearLUT(for: targets)
            statusMessage = "已清除 \(targets.count) 个文件的监看 LUT"
        }
    }

    /// 导入到 LUT 库（不套用）；同名已存在则不导入并返回 false
    @discardableResult
    public func importLUTToLibrary(_ path: String) -> Bool {
        let added = db.addLUTToLibrary(path)
        lutLibrary = db.lutLibrary()
        if added {
            statusMessage = "已导入 LUT：\((path as NSString).lastPathComponent)"
        } else {
            statusMessage = "已存在同名 LUT，跳过：\((path as NSString).lastPathComponent)"
        }
        return added
    }

    public func removeLUTFromLibrary(_ path: String) {
        db.removeLUTFromLibrary(path)
        lutLibrary = db.lutLibrary()
    }

    /// 【从访达选择 LUT】挑一个 LUT 直接套用到当前选择（**不进库**，两件事互不耦合）
    public func pickLUTFromFinder() {
        guard let url = OpenPanels.pickLUT() else { return }
        applyLUT(url.path)
    }

    /// 【导入 LUT】把一个或多个 LUT 加入 LUT 库备选（**不套用**到任何视频；同名自动跳过）
    public func importLUTFromFinder() {
        guard let urls = OpenPanels.pickLUTs(), !urls.isEmpty else { return }
        var added = 0
        var skipped: [String] = []
        for u in urls {
            if db.addLUTToLibrary(u.path) { added += 1 } else { skipped.append(u.lastPathComponent) }
        }
        lutLibrary = db.lutLibrary()
        if skipped.isEmpty {
            statusMessage = "已导入 \(added) 个 LUT"
        } else if added == 0 {
            statusMessage = "全部跳过（同名已存在）：\(skipped.joined(separator: "、"))"
        } else {
            statusMessage = "已导入 \(added) 个；跳过同名 \(skipped.count) 个"
        }
    }

    public func pickLUTForSelection() {
        pickLUTFromFinder()
    }

    public func pickLUTForCurrent() {
        pickLUTFromFinder()
    }

    public func savePlaybackStateOnQuit() {
        savePlaybackState()
    }

    // MARK: - LUT

    /// 设置监看 LUT；record=true 时写入记忆库（文件 + 目录）
    public func setLUT(_ path: String?, record: Bool = true) {
        lutPath = path
        applyChain()
        if record {
            if let url = currentURL {
                if let path {
                    db.setLUT(path, forFiles: [url.path])
                } else {
                    db.clearLUT(forFile: url.path)
                }
            }
            if let item = playlist.currentItem {
                item.lut = path
            }
        }
    }

    /// 批量给播放列表选中的文件设置 LUT（含记忆库写入）
    public func setLUT(_ path: String, for items: [PlaylistItem]) {
        playlist.setLUT(path, for: items)
        if let current = playlist.currentItem, items.contains(current) {
            setLUT(path, record: false)
        }
    }

    public func clearLUT(for items: [PlaylistItem]) {
        playlist.setLUT(nil, for: items)
        if let current = playlist.currentItem, items.contains(current) {
            setLUT(nil, record: false)
        }
    }

    // MARK: - 亮度曲线（LUT 之后生效；不影响截图/导出）

    public func toggleCurvePanel() {
        showCurvePanel.toggle()
    }

    private func scheduleCurveApply() {
        curveApplyTask?.cancel()
        curveApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 防抖 80ms
            guard !Task.isCancelled, let self else { return }
            self.applyChain()
        }
    }

    /// 把 LUT+曲线烘焙进 Metal 渲染管线（显示路径；截图/导出不受曲线影响）
    private func applyChain() {
        metalView.setColorPipeline(lutPath: lutPath, curve: curve)
    }

    // MARK: - 截图（带 LUT，不带曲线；从 Metal 管线 16bit 回读）

    public func screenshot() {
        guard currentURL != nil else {
            statusMessage = "没有可截图的视频"
            return
        }
        let t = client.timePos ?? 0
        guard let frame = video.takeFrameForTime(t) else {
            statusMessage = "没有可用的视频帧"
            return
        }
        defer { av_frame_unref(frame) }
        guard let rep = metalView.captureFrame(frame, withCurve: false),
              let png = rep.representation(using: .png, properties: [:]) else {
            statusMessage = "截图失败"
            return
        }
        let dir = Self.screenshotsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(baseName(for: currentURL))_\(Self.timestamp()).png"
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url)
            lastScreenshotURL = url
            statusMessage = "截图已保存：\(url.path)"
        } catch {
            statusMessage = "截图写入失败：\(error.localizedDescription)"
        }
    }

    public static func screenshotsDirectory() -> URL {
        // 可用 CUTPLAYER_SCREENSHOTS_DIR 覆盖（无头测试/受限沙箱下 ~/Movies 可能不可写）
        if let override = ProcessInfo.processInfo.environment["CUTPLAYER_SCREENSHOTS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("CutPlayer/Screenshots")
    }

    private func baseName(for url: URL?) -> String {
        (url?.deletingPathExtension().lastPathComponent ?? "frame")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: - 片段导出（带 LUT，不带曲线，最高画质预设）

    /// 导出片段：显式传入入出点（面板里手填的时间必须生效，不能只看 player.inPoint/outPoint）
    public func exportClip(preset: ClipExportCommand.Preset, to output: URL? = nil,
                           start explicitStart: Double? = nil, end explicitEnd: Double? = nil) {
        guard let url = currentURL else {
            statusMessage = "没有可导出的视频"
            return
        }
        let dur = duration
        let start = min(max(explicitStart ?? inPoint ?? 0, 0), max(dur - 0.02, 0))
        let end = min(max(explicitEnd ?? outPoint ?? dur, start + 0.02), dur)

        let out: URL
        if let output {
            out = output
        } else {
            let dir = Self.exportsDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(baseName(for: url))_\(Self.timestamp())_\(start.formatSeconds())_\(end.formatSeconds()).\(preset.fileExtension)"
            out = dir.appendingPathComponent(name)
        }

        // 与预览同一口径：判定为 limited 就强制 limited→full（覆盖撒谎的 pc 标签），
        // 判定为 full 则原样解释。这样导出与预览必然一致（所见即所得）。
        exporter.export(input: url, start: start, end: end, lut: lutPath, preset: preset, output: out, forceLimitedRange: !video.resolvedFullRange) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let u):
                self.exportCompletedURL = u
                self.statusMessage = "导出完成：\(u.path)"
                self.guiLog(String(format: "export: 完成 %@ 区间=%.3f~%.3f (%@)",
                                   u.lastPathComponent, start, end, preset.rawValue))
            case .failure(let error):
                self.statusMessage = error.localizedDescription
                self.guiLog("export: 失败 \(error.localizedDescription)")
            }
        }
        guiLog(String(format: "export: 开始 %@ 区间=%.3f~%.3f 时长=%.3fs 预设=%@ LUT=%@",
                      out.lastPathComponent, start, end, end - start, preset.rawValue,
                      lutPath.map { ($0 as NSString).lastPathComponent } ?? "无"))
    }

    public static func exportsDirectory() -> URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("CutPlayer/Exports")
    }

    // MARK: - 媒体信息

    private func refreshMediaInfo() {
        var info: [String: String] = [:]
        info["video-params/w"] = "\(video.width)"
        info["video-params/h"] = "\(video.height)"
        info["container-fps"] = String(format: "%.2f", video.fps)
        info["duration"] = String(format: "%.2f", video.duration)
        if let desc = av_get_pix_fmt_name(video.decoderPixelFormat) {
            info["video-params/pixelformat"] = String(cString: desc)
        }
        info["demuxer"] = client.getString("demuxer") ?? ""
        info["audio-codec"] = client.getString("audio-codec") ?? ""
        mediaInfo = info
    }

    // MARK: - 属性联动

    private func onPropertyChanged(_ name: String) {
        switch name {
        case "time-pos":
            // 读取失败时保持既有位置，绝不退化成 0（否则会误判为"跳回开头"）
            guard let newPos = client.timePos else { break }
            if let target = pendingSeekTarget, Date() < pendingSeekDeadline {
                // 我们自己发起的 seek：mpv 时钟追上目标前，不据此反向驱动解码引擎
                if abs(newPos - target) < 0.3 { pendingSeekTarget = nil }
            } else {
                pendingSeekTarget = nil
                if timePos - newPos > 0.5 {
                    // 外部跳变（EOF 重播 / 别处发起的 seek）→ 解码引擎跟上，否则画面卡在旧帧
                    video.seek(to: newPos)
                    metalView.requestRedraw()
                }
            }
            timePos = newPos
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPlaybackSave > 5 {
                lastPlaybackSave = now
                savePlaybackState()
            }
        case "duration":
            duration = client.duration ?? 0
        case "pause":
            // seek 按住期间 mpv 是被我们暂停的，不反映到 UI（否则播放按钮会闪一下）
            if audioHoldActive { break }
            isPaused = client.isPaused
            if !isPaused { eof = false }
            savePlaybackState()
        case "eof-reached":
            eof = client.eofReached
            if eof { handlePlayModeAtEOF() }
        case "media-title":
            if let t = client.getString("media-title"), !t.isEmpty {
                mediaTitle = t
            }
        default:
            break
        }
    }
}

extension Double {
    func formatSeconds() -> String {
        String(format: "%02d_%02d_%02d", Int(self) / 3600, (Int(self) % 3600) / 60, Int(self) % 60)
    }
}
