import Foundation

/// 滤镜参数的转义工具。
///
/// 说明：本项目的监看 LUT 与亮度曲线都由自己的 Metal 管线实现（见 `MetalVideoView`），
/// 不走 mpv/ffmpeg 的滤镜链——所以这里只剩下导出片段时给 ffmpeg 拼
/// `lut3d='...'` 需要的转义函数。
///
/// 核心规则：**导出只带监看 LUT，绝不带亮度曲线**（曲线仅用于预览）。
public enum FilterChain {
    /// FFmpeg 滤镜参数值引号：`'value'`（路径含空格/逗号/中文时也安全）
    public static func ffmpegQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
