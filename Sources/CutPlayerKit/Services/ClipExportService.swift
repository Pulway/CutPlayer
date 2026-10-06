import Foundation

/// FFmpeg 导出命令构造（纯函数，便于单测）
public enum ClipExportCommand {
    /// 导出预设
    /// 说明：目标是「最高画质 + 能在访达 QuickLook 里直接看」，
    /// 因此统一输出 MP4（H.265 带 hvc1 标签，QuickTime/QuickLook 才认）。
    public enum Preset: String, CaseIterable, Identifiable {
        case hevc422HW = "H.265 10bit 4:2:2（硬件加速·推荐）"
        case hevc420HW = "H.265 10bit 4:2:0（硬件·体积更小）"
        case hevc422SW = "H.265 10bit 4:2:2（x265 慢速·画质最优）"
        case h264 = "H.264 8bit（兼容性最好）"
        case lossless = "FFV1 无损（归档用·体积大）"

        public var id: String { rawValue }

        /// 视频编码参数
        var videoArgs: [String] {
            switch self {
            case .hevc422HW:
                // VideoToolbox 硬件编码：保留 10bit 4:2:2（HEVC Rext），速度约为软编的 5 倍
                return ["-c:v", "hevc_videotoolbox", "-profile:v", "main42210",
                        "-q:v", "80", "-pix_fmt", "yuv422p10le", "-tag:v", "hvc1"]
            case .hevc420HW:
                return ["-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                        "-q:v", "80", "-pix_fmt", "p010le", "-tag:v", "hvc1"]
            case .hevc422SW:
                return ["-c:v", "libx265", "-preset", "medium", "-crf", "14",
                        "-pix_fmt", "yuv422p10le", "-tag:v", "hvc1"]
            case .h264:
                return ["-c:v", "libx264", "-preset", "medium", "-crf", "14", "-pix_fmt", "yuv420p"]
            case .lossless:
                return ["-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv422p10le"]
            }
        }

        var audioArgs: [String] {
            switch self {
            case .hevc422HW, .hevc420HW, .hevc422SW, .h264:
                return ["-c:a", "aac", "-b:a", "320k"]
            case .lossless:
                return ["-c:a", "flac"]
            }
        }

        public var fileExtension: String {
            switch self {
            case .lossless: return "mkv"
            default: return "mp4"     // QuickLook 可直接预览
            }
        }

        /// 是否为 MP4/MOV 家族（决定要不要 +faststart）
        var isMP4Family: Bool { fileExtension == "mp4" }

        /// 面板上显示的备注（速度/体积预期）
        public var note: String {
            switch self {
            case .hevc422HW: return "推荐：保留 10bit 4:2:2，硬件编码约 2.5 秒/秒（4K），约 70 Mbps"
            case .hevc420HW: return "硬件编码，色度降到 4:2:0，体积更小"
            case .hevc422SW: return "画质最优但很慢：4K 约 14 秒/秒，导出期间建议暂停播放"
            case .h264: return "8bit 4:2:0，任何设备都能播，适合发给别人"
            case .lossless: return "FFV1 无损，体积巨大，用于归档（非 MP4）"
            }
        }
    }

    /// 生成 ffmpeg 参数数组
    /// - 注意：只带监看 LUT（`lut3d=...`），**绝不包含亮度曲线**（核心需求）
    /// - seek 语义：`-ss` 必须放在 `-i` **之前**（输入定位），时长用 `-t`。
    ///   若把 `-ss` 放在 `-i` 之后，`-to` 会按**输入时间轴**解释，
    ///   传 (end-start) 会导致提前截断甚至生成 0 帧文件（历史 bug）。
    public static func arguments(
        input: URL,
        start: Double,
        end: Double,
        lut: String?,
        preset: Preset,
        output: URL,
        forceLimitedRange: Bool = false
    ) -> [String] {
        let dur = max(end - start, 0.02)
        var args: [String] = ["-y", "-hide_banner", "-nostdin"]
        // 输入定位（关键帧定位 + 精确重编码，帧精确且快速）
        args += ["-ss", fmtTime(start)]
        args += ["-i", input.path]
        args += ["-t", fmtTime(dur)]
        if let lut, !lut.isEmpty {
            // forceLimitedRange：部分素材容器标签（pc）与数据真实语义（limited）冲突，
            // ffmpeg 会被误导——强制 limited→full 解释后再套 LUT，保证与预览一致
            let rangeFix = forceLimitedRange ? "scale=in_range=limited:out_range=full," : ""
            args += ["-vf", "\(rangeFix)lut3d=\(FilterChain.ffmpegQuote(lut))"]
        }
        args += ["-map", "0:v:0", "-map", "0:a?"]
        args += preset.videoArgs
        args += preset.audioArgs
        args += ["-sn", "-dn"]
        if preset.isMP4Family { args += ["-movflags", "+faststart"] }
        args += ["-progress", "pipe:1", "-nostats"]
        args += [output.path]
        return args
    }

    private static func fmtTime(_ t: Double) -> String {
        String(format: "%.3f", max(t, 0))
    }
}

/// 导出错误
public enum ExportError: LocalizedError {
    case ffmpegNotFound
    case ffmpegFailed(code: Int32)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return "找不到 ffmpeg，请安装或随应用捆绑。"
        case .ffmpegFailed(let code): return "导出失败（ffmpeg 退出码 \(code)）"
        case .launchFailed(let msg): return "无法启动 ffmpeg：\(msg)"
        }
    }
}

/// 片段导出服务：运行 FFmpeg 子进程，解析进度，支持取消
@MainActor
public final class ClipExportService: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var currentOutput: URL?
    /// 最近一次成功导出的文件（面板内提示用；避免"关掉面板才弹完成"的观感）
    @Published public private(set) var completedOutput: URL?
    @Published public private(set) var errorMessage: String?

    private var process: Process?
    private var pipe: Pipe?

    public init() {}

    public static func locateFFmpeg() -> URL? {
        // 1) 应用内捆绑
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            return bundled
        }
        // 2) PATH
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    public func export(
        input: URL,
        start: Double,
        end: Double,
        lut: String?,
        preset: ClipExportCommand.Preset,
        output: URL,
        forceLimitedRange: Bool = false,
        onComplete: ((Result<URL, Error>) -> Void)? = nil
    ) {
        guard !isRunning else { return }
        guard let ffmpeg = Self.locateFFmpeg() else {
            errorMessage = ExportError.ffmpegNotFound.localizedDescription
            onComplete?(.failure(ExportError.ffmpegNotFound))
            return
        }
        let args = ClipExportCommand.arguments(input: input, start: start, end: end, lut: lut, preset: preset, output: output, forceLimitedRange: forceLimitedRange)
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = args

        let outPipe = Pipe()
        p.standardOutput = outPipe
        let errPipe = Pipe()
        p.standardError = errPipe
        // 排水：避免 stderr 写满阻塞
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            _ = fh.availableData
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        process = p
        pipe = outPipe
        isRunning = true
        progress = 0
        errorMessage = nil
        completedOutput = nil
        currentOutput = output

        let duration = max(end - start, 0.001)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            var latest: Double?
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0] == "out_time_us" {
                    latest = (Double(parts[1]) ?? 0) / 1_000_000
                } else if parts.count == 2 && parts[0] == "out_time_ms" {
                    latest = (Double(parts[1]) ?? 0) / 1_000_000
                }
            }
            if let latest {
                let prog = min(max(latest / duration, 0), 1)
                DispatchQueue.main.async {
                    self.progress = prog
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isRunning = false
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    self.progress = 1
                    self.completedOutput = output
                    onComplete?(.success(output))
                } else {
                    let err = ExportError.ffmpegFailed(code: proc.terminationStatus)
                    self.errorMessage = err.localizedDescription
                    onComplete?(.failure(err))
                }
            }
        }

        do {
            try p.run()
        } catch {
            isRunning = false
            let err = ExportError.launchFailed(error.localizedDescription)
            errorMessage = err.localizedDescription
            onComplete?(.failure(err))
        }
    }

    public func cancel() {
        process?.terminate()
    }

    /// 面板重开时清掉上次的完成状态
    public func clearCompletion() {
        completedOutput = nil
        errorMessage = nil
    }
}
