import Foundation
import AppKit
import CMPV

/// libmpv 客户端封装 —— **只负责音频与时钟**。
///
/// 视频由自有管线渲染（FFmpeg 解码 → Metal，见 `VideoPlaybackEngine` / `MetalVideoView`），
/// 所以这里不需要 mpv 的渲染 API（`vo=null --vid=no`），只需要它的音频输出与 time-pos 时钟。
/// 线程模型：所有 mpv 调用集中在主线程（事件泵经 wakeup callback 调度到 main queue）。
public final class MPVClient {
    public private(set) var handle: OpaquePointer!

    // 事件回调
    public var onFileLoaded: (() -> Void)?
    public var onEndFile: ((String) -> Void)?
    public var onVideoReconfig: (() -> Void)?
    public var onPropertyChange: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    /// 初始化完成（mpv_initialize 成功后）回调
    public var onInitialized: (() -> Void)?

    // 观察的属性（id → 属性名）
    private let observed: [(id: UInt64, name: String)] = [
        (1, "time-pos"),
        (2, "duration"),
        (3, "pause"),
        (4, "eof-reached"),
        (5, "path"),
        (6, "media-title"),
        (7, "width"),
        (8, "height"),
        (9, "video-format"),
        (10, "video-bitrate"),
        (11, "audio-format"),
        (12, "container-fps"),
        (13, "video-params/pixelformat"),
        (14, "playlist-count"),
    ]

    public private(set) var isInitialized = false
    private var timePosCoalescePending = false
    private var lastTimePosPublish: TimeInterval = 0

    /// 本地暂停状态（由属性变更事件驱动，渲染线程读取不抢核心锁）
    public private(set) var pausedLocal = true

    /// 纯音频模式：视频由自有 FFmpeg+Metal 管线渲染，mpv 只负责音频与时钟
    public static var audioOnlyMode = false

    /// 诊断：verbose 日志（经 onError 回调输出）
    public static var verboseLog = false

    // MARK: - init / teardown

    /// 第一阶段：创建句柄 + 设置选项（**不**调用 mpv_initialize）
    /// 初始化分两阶段：init → initialize()
    public init?() {
        guard let m = mpv_create() else { return nil }
        handle = m

        // 基础选项（必须在 mpv_initialize 之前）
        // 注意：vo 不在 init 设置——必须在 initialize() 时按嵌入/渲染API路径选择，
        // 先设 libmpv 再改 macos 会导致 "Video output macos not found"
        mpv_set_option_string(m, "hwdec", "videotoolbox-copy")
        mpv_set_option_string(m, "keep-open", "yes")
        mpv_set_option_string(m, "osc", "no")
        mpv_set_option_string(m, "osd-level", "0")
        mpv_set_option_string(m, "sub-auto", "fuzzy")
        mpv_set_option_string(m, "audio-file-auto", "fuzzy")
        mpv_set_option_string(m, "input-default-bindings", "no")
        mpv_set_option_string(m, "input-vo-keyboard", "no")
        mpv_set_option_string(m, "ytdl", "no")
        mpv_set_option_string(m, "video-sync", "display-resample")
        mpv_set_option_string(m, "screenshot-format", "png")
        mpv_set_option_string(m, "screenshot-high-bit-depth", "yes")
        mpv_set_option_string(m, "screenshot-tag-colorspace", "yes")
        mpv_set_option_string(m, "volume", "100")
        mpv_set_option_string(m, "cache", "yes")
        if Self.audioOnlyMode {
            // 纯音频：无需渲染上下文，直接初始化
            mpv_set_option_string(m, "vo", "null")
            mpv_set_option_string(m, "vid", "no")
            _ = initialize()
        }
    }

    /// 第二阶段：mpv_initialize
    @discardableResult
    public func initialize() -> Bool {
        guard !isInitialized, let m = handle else { return isInitialized }
        if mpv_initialize(m) < 0 { return false }

        // 日志：warn 级别以上经 onError 回调（自检/调试用）
        mpv_request_log_messages(m, Self.verboseLog ? "v" : "warn")

        // 观察属性
        for (id, name) in observed {
            let format: mpv_format = name == "pause" || name == "eof-reached"
                ? MPV_FORMAT_FLAG
                : (name == "time-pos" || name == "duration" || name == "container-fps" ? MPV_FORMAT_DOUBLE : MPV_FORMAT_STRING)
            mpv_observe_property(m, id, name, format)
        }

        // wakeup callback → 事件泵
        mpv_set_wakeup_callback(m, { ctx in
            guard let ctx else { return }
            let client = Unmanaged<MPVClient>.fromOpaque(ctx).takeUnretainedValue()
            client.scheduleEventPump()
        }, Unmanaged.passUnretained(self).toOpaque())

        isInitialized = true
        onInitialized?()
        return true
    }

    deinit {
        if let h = handle { mpv_terminate_destroy(h) }
    }

    // MARK: - 事件泵

    private func scheduleEventPump() {
        DispatchQueue.main.async { [weak self] in
            self?.pumpEvents()
        }
    }

    private func pumpEvents() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { break }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            handleEvent(id, event)
        }
    }

    private func handleEvent(_ id: mpv_event_id, _ event: UnsafeMutablePointer<mpv_event>) {
        switch id {
        case MPV_EVENT_FILE_LOADED:
            onFileLoaded?()
        case MPV_EVENT_END_FILE:
            if let data = event.pointee.data {
                let reason = data.assumingMemoryBound(to: mpv_end_file_reason.self).pointee
                onEndFile?(reasonName(reason))
            } else {
                onEndFile?("unknown")
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            if let data = event.pointee.data {
                let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                if let name = prop.name {
                    let propName = String(cString: name)
                    handlePropertyChange(propName)
                }
            }
        case MPV_EVENT_VIDEO_RECONFIG:
            onVideoReconfig?()
        case MPV_EVENT_LOG_MESSAGE:
            if let data = event.pointee.data {
                let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                if let text = msg.text {
                    let s = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { onError?(s) }
                }
            }
        case MPV_EVENT_QUEUE_OVERFLOW:
            onError?("mpv event queue overflow")
        default:
            break
        }
    }

    private func reasonName(_ r: mpv_end_file_reason) -> String {
        switch r {
        case MPV_END_FILE_REASON_EOF: return "eof"
        case MPV_END_FILE_REASON_STOP: return "stop"
        case MPV_END_FILE_REASON_QUIT: return "quit"
        case MPV_END_FILE_REASON_ERROR: return "error"
        default: return "redirect"
        }
    }

    private func handlePropertyChange(_ name: String) {
        if name == "pause" {
            // 事件驱动更新本地状态（避免渲染线程高频读属性抢核心锁）
            pausedLocal = getFlag("pause") ?? true
        }
        if name == "time-pos" {
            // 合并发布，避免 60fps 刷爆 SwiftUI
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastTimePosPublish > 0.066 else { return }
            lastTimePosPublish = now
        }
        onPropertyChange?(name)
    }

    // MARK: - 属性

    public func getString(_ name: String) -> String? {
        guard let s = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(s) }
        return String(cString: s)
    }

    public func getDouble(_ name: String) -> Double? {
        var v = 0.0
        let r = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        return r == 0 ? v : nil
    }

    public func getInt64(_ name: String) -> Int64? {
        var v: Int64 = 0
        let r = mpv_get_property(handle, name, MPV_FORMAT_INT64, &v)
        return r == 0 ? v : nil
    }

    public func getFlag(_ name: String) -> Bool? {
        var v: Int32 = 0
        let r = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v)
        return r == 0 ? (v != 0) : nil
    }

    @discardableResult
    public func setString(_ name: String, _ value: String) -> Bool {
        mpv_set_property_string(handle, name, value) == 0
    }

    @discardableResult
    public func setDouble(_ name: String, _ value: Double) -> Bool {
        var v = value
        return mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v) == 0
    }

    @discardableResult
    public func setFlag(_ name: String, _ value: Bool) -> Bool {
        var v: Int32 = value ? 1 : 0
        return mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v) == 0
    }

    // MARK: - 命令

    @discardableResult
    public func command(_ args: [String]) -> Bool {
        var cargs: [UnsafePointer<CChar>?] = args.map { s -> UnsafePointer<CChar>? in
            guard let c = strdup(s) else { return nil }
            return UnsafePointer(c)
        }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        return mpv_command(handle, &cargs) == 0
    }

    // MARK: - 播放控制

    public func loadFile(_ path: String, startAt: Double? = nil) {
        _ = command(["loadfile", path, "replace"])
        if let startAt { _ = setDouble("time-pos", startAt) }
    }

    public func play() { _ = setFlag("pause", false) }
    public func pause() { _ = setFlag("pause", true) }
    public func togglePause() { _ = command(["cycle", "pause"]) }
    public func seek(_ seconds: Double) { _ = command(["seek", String(seconds), "relative+exact"]) }
    public func seekTo(_ seconds: Double) { _ = setDouble("time-pos", seconds) }
    /// 绝对跳转（精确）：mpv 的 seek flags 必须合并成一个参数（absolute+exact），
    /// 拆成两个参数会被判为非法调用
    public func seekAbsolute(_ seconds: Double) { _ = command(["seek", String(seconds), "absolute+exact"]) }
    public func seekPercent(_ p: Double) { _ = command(["seek", String(p), "absolute-percent+exact"]) }
    public func frameStep(back: Bool = false) { _ = command([back ? "frame-back-step" : "frame-step"]) }
    public func stop() { _ = command(["stop"]) }

    public var timePos: Double? { getDouble("time-pos") }
    public var duration: Double? { getDouble("duration") }
    public var isPaused: Bool { getFlag("pause") ?? false }
    public var eofReached: Bool { getFlag("eof-reached") ?? false }

    public func setSpeed(_ v: Double) { _ = setDouble("speed", v) }
    public func setVolume(_ v: Double) { _ = setDouble("volume", v) }
    public func setMute(_ v: Bool) { _ = setFlag("mute", v) }
    public func setAspect(_ v: String) { _ = setString("video-aspect-override", v) }
    public func setAudioTrack(_ id: Int64) { _ = setInt64("aid", id) }
    public func setSubtitleTrack(_ id: Int64) { _ = setInt64("sid", id) }
    public func setSubtitleVisibility(_ v: Bool) { _ = setFlag("sub-visibility", v) }

    @discardableResult
    public func setInt64(_ name: String, _ value: Int64) -> Bool {
        var v = value
        return mpv_set_property(handle, name, MPV_FORMAT_INT64, &v) == 0
    }

    /// 设置视频滤镜链（LUT / 曲线）
    public func setVF(_ vf: String) {
        _ = setString("vf", vf)
    }

    /// 设置 GPU 3D LUT（--lut，libplacebo 原生）：nil/空 = 清除
    public func setLUTOption(_ path: String?) {
        _ = setString("lut", path ?? "")
    }

    /// 截图（video 模式：捕获经过滤镜链的视频帧，不带 OSD/字幕）
    @discardableResult
    public func screenshot(to path: String) -> Bool {
        command(["screenshot-to-file", path, "video"])
    }

    /// 媒体信息快照
    public func mediaInfo() -> [String: String] {
        var info: [String: String] = [:]
        let keys = [
            "demuxer", "video-format", "video-codec", "audio-codec",
            "video-params/pixelformat", "container-fps", "video-bitrate",
            "audio-bitrate", "video-params/w", "video-params/h",
        ]
        for k in keys {
            if let v = getString(k), !v.isEmpty { info[k] = v }
        }
        return info
    }
}
