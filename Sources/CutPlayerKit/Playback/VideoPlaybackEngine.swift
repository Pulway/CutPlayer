import Foundation
import CFFmpeg

/// 视频播放引擎：libavcodec 解码（后台线程）→ 有界帧队列 → 按时间取帧
/// 音频时钟由外部（mpv audio-only）提供。
/// 线程模型（关键）：**seek 是请求式的**——seek() 只登记请求并立即返回，
/// 由解码线程在安全时机（nextFrame 返回后）自行执行 decoder.seek，
/// 与解码天然串行，杜绝「等待解码退出 + 并发 flush」导致的 libavcodec 崩溃。
/// 帧带 generation 标记，seek 后旧代帧不再被取用。
public final class VideoPlaybackEngine {
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var fps: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var decoderPixelFormat: AVPixelFormat = AV_PIX_FMT_NONE
    /// 解码器/容器声明的 color_range：1=MPEG(limited/tv)，2=JPEG(full/pc)，0=未指定
    /// （注意 FFmpeg 枚举语义：1 是 limited、2 是 full，别写反）
    public private(set) var decoderColorRange = 0
    /// 最终判定的输入范围（决定 YUV→RGB 矩阵与导出的范围修正）
    /// 判定规则（三档）：
    ///  1) 手动覆盖（数据库，按文件记住）优先
    ///  2) 声明为 limited(=1) → 直接按 limited（老实文件，零风险）
    ///  3) 声明为 full(=2) 或未指定 → 抽查实际像素：出现越出 64~940 的样本 → full；
    ///     否则判定"声明不可信"，按 limited（相机常见：标 pc、数据其实是 limited）
    public private(set) var inputIsFullRange = false
    /// 判定来源（界面显示 / 诊断）
    public private(set) var rangeSource = "默认"
    /// 判定结果回调（**保证在主线程**）
    public var onRangeResolved: ((Bool, String) -> Void)?
    /// 线程安全的判定结果读取（主线程比对导出/渲染口径时用）
    public var resolvedFullRange: Bool {
        lock.lock(); defer { lock.unlock() }
        return inputIsFullRange
    }
    private func notifyRange(_ isFull: Bool, _ source: String) {
        DispatchQueue.main.async { [weak self] in self?.onRangeResolved?(isFull, source) }
    }
    /// 仍需抽查的帧数（只查打开后的前若干帧，成本可忽略）
    private var rangeProbeFramesLeft = 0
    private static let limitedLow = 60      // 10bit 合法下界 64，留余量
    private static let limitedHigh = 944    // 10bit 合法上界 940，留余量
    public private(set) var isEOF = false
    public private(set) var isOpen = false

    public private(set) var queueDepth = 0
    private let decoder = FFmpegVideoDecoder()
    private struct QueuedFrame {
        let frame: UnsafeMutablePointer<AVFrame>
        let generation: Int
    }
    private var frames: [QueuedFrame] = []
    private let lock = NSLock()
    private let maxQueue = 6
    private var decodeRunning = false
    private var decodeFrameCount = 0
    private let exitSemaphore = DispatchSemaphore(value: 0)
    /// 打开/关闭解耦：打开在后台串行队列执行，避免阻塞主线程
    private let openQueue = DispatchQueue(label: "cutplayer.engine.open", qos: .userInitiated)
    private var openToken = 0

    // 异步 seek 请求
    private var seekGeneration = 0
    private var pendingSeek: (generation: Int, time: Double)?
    /// seek 目标：解码追到目标之前，落后于目标的帧只丢弃不显示
    private var seekTarget: Double?
    /// 本次 seek 的起始时刻（用于兜底超时）
    private var seekStartedAt: Date?

    public init() {}

    deinit {
        stopDecodingAndWait()
        clearFrames()
        decoder.close()
    }

    public func open(url: String) -> Bool {
        stopDecodingAndWait()
        clearFrames()
        decoder.close()
        guard decoder.open(url: url) else { return false }
        applyDecoderInfo()
        startDecoding()
        return true
    }

    /// 异步打开（UI 用）：打开流程包含「等旧解码线程退出」+「avformat 探测」，
    /// 在主线程同步执行会让切视频时整个界面卡住、点击丢失。
    /// 串行队列保证 decoder 不会被并发访问；token 保证快速连点时只认最后一次。
    public func openAsync(url: String, completion: @escaping (Bool) -> Void) {
        lock.lock()
        openToken += 1
        let token = openToken
        lock.unlock()
        openQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = token != self.openToken
            self.lock.unlock()
            if stale {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.stopDecodingAndWait()
            self.clearFrames()
            self.decoder.close()
            let ok = self.decoder.open(url: url)
            if ok { self.applyDecoderInfo(); self.startDecoding() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 把解码器信息同步到引擎（宽高/fps/时长/色彩）
    /// 同时初始化"输入范围"判定：声明 limited 就照单全收；声明 full/未指定则先按
    /// limited（安全默认，且符合"相机标签撒谎"这一常见情况），随后用实际像素复核。
    private func applyDecoderInfo() {
        width = decoder.width
        height = decoder.height
        fps = decoder.fps
        duration = decoder.duration
        decoderPixelFormat = decoder.pixelFormat
        decoderColorRange = decoder.colorRange
        isEOF = false
        isOpen = true
        applyDeclaredRange()
    }

    /// 纯按声明决定初始判定 + 是否需要用实际像素复核
    private func applyDeclaredRange() {
        let declared = decoderColorRange
        lock.lock()
        if declared == 1 {                     // MPEG = limited/tv：老实文件，直接采信
            rangeProbeFramesLeft = 0
            inputIsFullRange = false
            rangeSource = "标签 limited"
        } else {                               // full(2) 或未指定(0)：可能是撒谎的标签
            rangeProbeFramesLeft = 12          // 抽查前 12 帧
            inputIsFullRange = false           // 安全默认：按 limited 渲染
            rangeSource = "标签 full（抽查中）"
        }
        let result = inputIsFullRange
        let source = rangeSource
        lock.unlock()
        notifyRange(result, source)
    }

    /// 手动覆盖（数据库里按文件记住的模式）
    public func overrideRange(mode: String) {
        lock.lock()
        switch mode {
        case "full":
            inputIsFullRange = true
            rangeSource = "手动 full"
        case "limited":
            inputIsFullRange = false
            rangeSource = "手动 limited"
        default:
            lock.unlock()
            applyDeclaredRange()
            return
        }
        rangeProbeFramesLeft = 0
        let result = inputIsFullRange
        let source = rangeSource
        lock.unlock()
        notifyRange(result, source)
    }

    /// 抽查一帧的亮度平面：出现越出 limited 合法区间（10bit 64~940）的样本 → full
    private func probeRange(_ frame: UnsafeMutablePointer<AVFrame>) {
        guard let base = frame.pointee.data.0 else { return }
        let w = Int(frame.pointee.width)
        let h = Int(frame.pointee.height)
        let stride = Int(frame.pointee.linesize.0) / 2      // 16bit 字为单位
        guard w > 0, h > 0, stride > 0 else { return }
        var outside = 0
        var total = 0
        base.withMemoryRebound(to: UInt16.self, capacity: stride * h) { p in
            var y = 0
            while y < h {                                    // 每 8 行/列取一个样本
                var x = 0
                while x < w {
                    let v = Int(p[y * stride + x])
                    if v < Self.limitedLow || v > Self.limitedHigh { outside += 1 }
                    total += 1
                    x += 8
                }
                y += 8
            }
        }
        lock.lock()
        rangeProbeFramesLeft -= 1
        let enoughEvidence = total > 0 && outside > max(total / 2000, 8)   // >0.05% 且至少 8 点
        let finished = rangeProbeFramesLeft <= 0
        var changed = false
        if enoughEvidence, !inputIsFullRange {
            inputIsFullRange = true
            rangeSource = "像素抽查 full"
            rangeProbeFramesLeft = 0
            changed = true
        } else if finished {
            rangeSource = "像素抽查 limited（标签不可信）"
            changed = true
        }
        let result = inputIsFullRange
        let source = rangeSource
        lock.unlock()
        if changed { notifyRange(result, source) }
    }

    public func close() {
        stopDecodingAndWait()
        clearFrames()
        decoder.close()
        isOpen = false
        isEOF = false
        queueDepth = 0
    }

    /// 请求 seek（异步）：立即返回；解码线程在安全时机执行。
    /// seek 后旧代帧会被取帧逻辑忽略，直到新代帧入队。
    public func seek(to seconds: Double) {
        lock.lock()
        seekGeneration += 1
        pendingSeek = (seekGeneration, seconds)
        seekTarget = seconds
        seekStartedAt = Date()
        lock.unlock()
    }

    /// 取 pts ≤ t+0.001 的最新一帧（当前代；只读，不移出队列）；无可用帧返回 nil
    public func frameForTime(_ t: Double) -> UnsafeMutablePointer<AVFrame>? {
        lock.lock()
        defer { lock.unlock() }
        var best: UnsafeMutablePointer<AVFrame>?
        var bestPTS = -1.0
        for qf in frames where qf.generation == seekGeneration {
            let p = decoder.pts(of: qf.frame)
            if p <= t + 0.001 && p > bestPTS {
                best = qf.frame
                bestPTS = p
            }
        }
        return best
    }

    /// 帧时间戳（秒）；诊断用
    public func pts(of frame: UnsafeMutablePointer<AVFrame>) -> Double {
        decoder.pts(of: frame)
    }

    /// 取帧（所有权转移）：返回 pts ≤ t+0.001 的最新一帧（当前代）并移出队列，
    /// 同时丢弃所有更旧的过期帧；调用方负责 av_frame_unref。
    /// 无可用帧时返回 nil（显示端保持上一帧）。
    ///
    /// seek 追赶期（方案 A）：
    /// - **丢弃**所有落后目标的帧，而不是"按住不放"——队列只有 6 帧，
    ///   按住会让解码器因队满停摆（旧实现要等 0.8s 超时才解锁，这就是"卡一下"的主因）
    /// - 丢弃只为让路，**不会拿去显示**：追赶期一律返回 nil，画面保持上一帧，
    ///   直到精确帧解出来才切换（避免先闪一张关键帧的观感问题）
    public func takeFrameForTime(_ t: Double) -> UnsafeMutablePointer<AVFrame>? {
        lock.lock()
        defer { lock.unlock() }

        if let st = seekTarget {
            let newestPTS = frames.last.map { decoder.pts(of: $0.frame) } ?? -1
            let stalled = seekStartedAt.map { Date().timeIntervalSince($0) > 1.5 } ?? false
            if newestPTS < st - 0.05 && !stalled {
                dropFramesBehind(st - 0.05)
                queueDepth = frames.count
                return nil
            }
            if stalled { seekTarget = nil }   // 兜底：解码异常时不要永远按住画面
        }

        var bestIdx = -1
        var bestPTS = -1.0
        for (i, qf) in frames.enumerated() where qf.generation == seekGeneration {
            let p = decoder.pts(of: qf.frame)
            if p <= t + 0.001 && p > bestPTS {
                bestIdx = i
                bestPTS = p
            }
        }
        guard bestIdx >= 0 else {
            return nil
        }
        // 丢弃所有更旧的过期帧（含旧代帧）
        for _ in 0..<bestIdx {
            let old = frames.removeFirst()
            av_frame_unref(old.frame)
        }
        let best = frames.removeFirst()
        queueDepth = frames.count
        return best.frame
    }

    /// 丢弃所有 pts < threshold 的帧（含旧代帧）；调用方需持有 lock
    private func dropFramesBehind(_ threshold: Double) {
        var i = 0
        while i < frames.count {
            let qf = frames[i]
            if qf.generation != seekGeneration || decoder.pts(of: qf.frame) < threshold {
                av_frame_unref(qf.frame)
                frames.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    // MARK: - 内部：解码循环（seek 在循环内执行，天然串行）

    private func startDecoding() {
        guard isOpen, !decodeRunning else { return }
        decodeRunning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                self.decodeRunning = false
                self.exitSemaphore.signal()
            }
            while self.decodeRunning {
                // 处理挂起的 seek 请求（在解码线程内执行，与解码串行）
                let req: (generation: Int, time: Double)?
                self.lock.lock()
                req = self.pendingSeek
                self.pendingSeek = nil
                self.lock.unlock()
                if let req {
                    self.clearFrames()
                    self.decoder.seek(to: req.time)
                    self.isEOF = false
                    continue
                }
                // 队列满 → 暂停解码（等显示端消费；避免滑窗空转导致队列永远领先播放时间）
                var full = false
                self.lock.lock()
                full = self.frames.count >= self.maxQueue
                self.lock.unlock()
                if full {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                guard let frame = self.decoder.nextFrame() else {
                    // EOF：不退出线程——进入等待模式，seek 请求到来时恢复解码
                    if !self.isEOF {
                        self.guiLog("decode: EOF（进入等待 seek 模式）")
                        self.isEOF = true
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                if self.isEOF { self.isEOF = false }
                self.lock.lock()
                let gen = self.seekGeneration
                self.frames.append(QueuedFrame(frame: frame, generation: gen))
                let needProbe = self.rangeProbeFramesLeft > 0
                let ptsNow = self.decoder.pts(of: frame)
                let count = self.frames.count
                self.lock.unlock()
                // 注意：抽查必须**在解锁之后**（probeRange 内部还要拿同一把非递归锁，
                // 放在锁里会自死锁——解码线程一停，整个播放/自检就挂住）
                if needProbe { self.probeRange(frame) }
                self.queueDepth = count
                self.decodeFrameCount += 1
                if self.decodeFrameCount % 30 == 0 || ptsNow < 0.05 {
                    self.guiLog("decode: pts=\(String(format: "%.2f", ptsNow)) 队列=\(count) gen=\(gen) 总帧=\(self.decodeFrameCount)")
                }
            }
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

    /// 停止解码并等待退出（open/close/deinit 用；解码卡死时 5s 超时强制继续）
    private func stopDecodingAndWait() {
        guard decodeRunning else { return }
        decodeRunning = false
        _ = exitSemaphore.wait(timeout: .now() + 5)
        if decodeRunning {
            NSLog("VideoPlaybackEngine: 解码循环未在 5s 内退出（强制继续）")
        }
    }

    private func clearFrames() {
        lock.lock()
        for qf in frames { av_frame_unref(qf.frame) }
        frames.removeAll()
        queueDepth = 0
        lock.unlock()
    }
}
