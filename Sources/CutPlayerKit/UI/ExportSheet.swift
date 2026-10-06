import SwiftUI
import AppKit

/// 片段导出面板：入出点 + 画质预设 + 进度
struct ExportSheet: View {
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    @State private var preset: ClipExportCommand.Preset = .hevc422HW
    @State private var inText = ""
    @State private var outText = ""
    @State private var customURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出片段")
                        .font(.headline)
                    if let url = player.currentURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("入点 (秒)").font(.caption).foregroundStyle(.secondary)
                    TextField("0.000", text: $inText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("出点 (秒)").font(.caption).foregroundStyle(.secondary)
                    TextField("0.000", text: $outText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("").font(.caption)
                    Button("用当前入出点") {
                        inText = player.inPoint.map { String(format: "%.3f", $0) } ?? ""
                        outText = player.outPoint.map { String(format: "%.3f", $0) } ?? ""
                    }
                    .controlSize(.small)
                }
            }

            Picker("画质预设", selection: $preset) {
                ForEach(ClipExportCommand.Preset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.radioGroup)

            Label(preset.note, systemImage: "speedometer")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("输出到")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(customURL?.path ?? defaultOutputPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") {
                        let def = "\(player.currentURL?.deletingPathExtension().lastPathComponent ?? "clip")_export.\(preset.fileExtension)"
                        if let url = OpenPanels.pickExportDestination(defaultName: def) {
                            customURL = url
                        }
                    }
                    .controlSize(.small)
                }
                Label("导出内容：带监看 LUT，不含亮度曲线", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if player.exporter.isRunning {
                VStack(spacing: 6) {
                    ProgressView(value: player.exporter.progress)
                    HStack {
                        Text("\(Int(player.exporter.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { player.exporter.cancel() }
                            .controlSize(.small)
                    }
                }
            } else {
                if let done = player.exporter.completedOutput {
                    Label("导出完成：\(done.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    HStack {
                        Text(done.deletingLastPathComponent().path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([done])
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    if let err = player.exporter.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    Spacer()
                    Button(player.exporter.completedOutput != nil ? "再导出一次" : "开始导出") {
                        startExport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            inText = player.inPoint.map { String(format: "%.3f", $0) } ?? ""
            outText = player.outPoint.map { String(format: "%.3f", $0) } ?? ""
            if !player.exporter.isRunning { player.exporter.clearCompletion() }
        }
        // 面板内已经提示完成 → 清掉主窗口那条"关闭面板后才弹"的提示
        .onChange(of: player.exporter.completedOutput) { _, newValue in
            if newValue != nil { player.exportCompletedURL = nil }
        }
    }

    private var defaultOutputPath: String {
        let dir = PlayerModel.exportsDirectory()
        let name = "\(player.currentURL?.deletingPathExtension().lastPathComponent ?? "clip")_export.\(preset.fileExtension)"
        return dir.appendingPathComponent(name).path
    }

    private func startExport() {
        guard let url = player.currentURL else { return }
        let dur = player.duration
        let start = min(max(parseTime(inText) ?? player.inPoint ?? 0, 0), max(dur - 0.02, 0))
        let end = min(max(parseTime(outText) ?? player.outPoint ?? dur, start + 0.02), dur)
        // 关键：把面板里解析出的入出点**显式**传给导出（以前选了自定义路径就丢了）
        if let customURL {
            player.exportClip(preset: preset, to: customURL, start: start, end: end)
        } else {
            player.inPoint = start
            player.outPoint = end
            player.exportClip(preset: preset, start: start, end: end)
        }
    }

    private func parseTime(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // 支持 "12.5" / "1:02.5" / "1:02:03.5"
        let parts = t.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
