import Foundation
import CFFmpeg

/// 基于 libavcodec 的视频解码器（只解视频，不做任何滤镜）
/// 帧以 AVFrame 引用形式返回（调用方负责 av_frame_unref），避免拷贝。
/// 注意：所有方法必须在同一线程串行调用（avformat/avcodec 非线程安全），
/// seek 与 nextFrame 的并发由上层（VideoPlaybackEngine）协调。
final class FFmpegVideoDecoder {
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var streamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1000)
    private var pendingFrames: [UnsafeMutablePointer<AVFrame>] = []

    var width: Int { codecCtx.map { Int($0.pointee.width) } ?? 0 }
    var height: Int { codecCtx.map { Int($0.pointee.height) } ?? 0 }
    var pixelFormat: AVPixelFormat { codecCtx.map { $0.pointee.pix_fmt } ?? AV_PIX_FMT_NONE }
    /// color_range：AVCOL_RANGE_JPEG(1)=full(pc) / AVCOL_RANGE_MPEG(2)=limited(tv) / 0=未指定
    var colorRange: Int { codecCtx.map { Int($0.pointee.color_range.rawValue) } ?? 0 }
    var duration: Double = 0
    var fps: Double = 0

    deinit {
        close()
    }

    func open(url: String) -> Bool {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let ret = avformat_open_input(&ctx, url, nil, nil)
        guard ret == 0, let ctx else { return false }
        fmtCtx = ctx
        avformat_find_stream_info(ctx, nil)

        guard let stream = findVideoStream() else { return false }
        streamIndex = stream.pointee.index
        timeBase = stream.pointee.time_base

        if stream.pointee.duration != Int64.min {
            duration = Double(stream.pointee.duration) * av_q2d(stream.pointee.time_base)
        } else if fmtCtx!.pointee.duration != Int64.min {
            duration = Double(fmtCtx!.pointee.duration) / Double(AV_TIME_BASE)
        }
        if stream.pointee.avg_frame_rate.den > 0, stream.pointee.avg_frame_rate.num > 0 {
            fps = Double(stream.pointee.avg_frame_rate.num) / Double(stream.pointee.avg_frame_rate.den)
        }

        guard let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id) else { return false }
        guard let cc = avcodec_alloc_context3(codec) else { return false }
        codecCtx = cc
        avcodec_parameters_to_context(cc, stream.pointee.codecpar)
        // 多线程解码（与 mpv/ffmpeg CLI 相同的加速路径）
        cc.pointee.thread_count = 0
        cc.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        return avcodec_open2(cc, codec, nil) >= 0
    }

    private func findVideoStream() -> UnsafeMutablePointer<AVStream>? {
        guard let fmtCtx else { return nil }
        let n = Int(fmtCtx.pointee.nb_streams)
        for i in 0..<n {
            let s = fmtCtx.pointee.streams[i]!
            if s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                return s
            }
        }
        return nil
    }

    func close() {
        for f in pendingFrames { av_frame_unref(f) }
        pendingFrames.removeAll()
        if codecCtx != nil {
            var p = codecCtx
            avcodec_free_context(&p)
            codecCtx = nil
        }
        if fmtCtx != nil {
            var f = fmtCtx
            avformat_close_input(&f)
            fmtCtx = nil
        }
    }

    /// 阻塞读取下一帧（含解包+解码）；返回的帧由调用方 av_frame_unref
    /// 一包可能解出多帧（B 帧重排），全部入队、逐个返回，保证不丢帧
    func nextFrame() -> UnsafeMutablePointer<AVFrame>? {
        guard let fmtCtx, let codecCtx else { return nil }
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        while true {
            let r = av_read_frame(fmtCtx, packet)
            if r < 0 {
                if ffmpeg_is_eof(r) != 0 {
                    drainDecoder(codecCtx)
                }
                break
            }
            if packet!.pointee.stream_index == streamIndex {
                // send 可能返回 EAGAIN（frame 线程忙）——必须重试，绝不能丢包：
                // 丢包 → 帧不完整 → frame 线程等 slice → receive_frame 永久阻塞（解码线程卡死）
                var sent = avcodec_send_packet(codecCtx, packet)
                var tries = 0
                while sent == ff_av_error_eagain() && tries < 200 {
                    Thread.sleep(forTimeInterval: 0.002)
                    sent = avcodec_send_packet(codecCtx, packet)
                    tries += 1
                }
                if sent == 0 {
                    drainDecoder(codecCtx)
                    if !pendingFrames.isEmpty {
                        return pendingFrames.removeFirst()
                    }
                }
            }
            av_packet_unref(packet)
        }
        return nil
    }

    /// 把解码器缓冲里所有可用帧取出（送空包后也会被调用一次）
    private func drainDecoder(_ codecCtx: UnsafeMutablePointer<AVCodecContext>) {
        while true {
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            let r = avcodec_receive_frame(codecCtx, frame)
            if r == 0 {
                if let ref = takeRef(frame) {
                    pendingFrames.append(ref)
                }
            } else {
                break
            }
        }
    }

    private func takeRef(_ frame: UnsafeMutablePointer<AVFrame>?) -> UnsafeMutablePointer<AVFrame>? {
        guard let frame else { return nil }
        let ref = av_frame_alloc()
        av_frame_ref(ref, frame)
        return ref
    }

    /// 帧时间戳（秒）
    func pts(of frame: UnsafeMutablePointer<AVFrame>) -> Double {
        if frame.pointee.pts != Int64.min {
            return Double(frame.pointee.pts) * av_q2d(timeBase)
        }
        return 0
    }

    /// 跳转到指定时间（秒）；必须在无并发读取时调用
    func seek(to seconds: Double) {
        guard let fmtCtx, let codecCtx else { return }
        for f in pendingFrames { av_frame_unref(f) }
        pendingFrames.removeAll()
        let tb = av_q2d(timeBase)
        let target = Int64(seconds / tb)
        let r = avformat_seek_file(fmtCtx, streamIndex, Int64.min, target, Int64.max, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        if ProcessInfo.processInfo.environment["CUTPLAYER_DECODER_DEBUG"] != nil {
            let msg = "decoder.seek: \(seconds)s -> ts=\(target) timeBase=\(tb) ret=\(r)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
    }
}
