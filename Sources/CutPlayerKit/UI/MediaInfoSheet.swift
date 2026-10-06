import SwiftUI

/// 媒体信息面板
struct MediaInfoSheet: View {
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    private let labels: [String: String] = [
        "demuxer": "封装格式",
        "video-format": "视频编码",
        "video-codec": "视频解码器",
        "audio-codec": "音频解码器",
        "video-params/pixelformat": "像素格式",
        "container-fps": "帧率",
        "video-bitrate": "视频码率 (bps)",
        "audio-bitrate": "音频码率 (bps)",
        "video-params/w": "宽度",
        "video-params/h": "高度",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("媒体信息")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let url = player.currentURL {
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            let info = player.mediaInfo
            if info.isEmpty {
                Text("暂无信息")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(labels.keys.sorted(), id: \.self) { key in
                        if let value = info[key] {
                            GridRow {
                                Text(labels[key] ?? key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(value)
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("监看 LUT")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(player.lutPath.map { ($0 as NSString).lastPathComponent } ?? "无")
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("亮度曲线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(player.curve.isActive ? "已启用（仅预览）" : "关闭")
                        .font(.caption)
                }
                Spacer()
                Text("时长 \(formatClock(player.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func formatClock(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
