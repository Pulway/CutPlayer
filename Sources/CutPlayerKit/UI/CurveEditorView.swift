import SwiftUI

/// 亮度曲线编辑器（修图风格）
struct CurveEditorView: View {
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("亮度曲线")
                        .font(.headline)
                    Text("作用于 LUT 之后的画面 · 不影响截图与导出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { player.curve.enabled },
                    set: { player.curve.enabled = $0 }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Text("预设:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(CurveModel.Preset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        player.curve.set(preset.points())
                        player.curve.enabled = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("重置") { player.curve.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            HStack(spacing: 16) {
                CurveCanvas(model: player.curve)
                    .frame(width: 300, height: 300)

                VStack(alignment: .leading, spacing: 10) {
                    Text("操作说明").font(.caption.bold())
                    Text("• 点击曲线空白处添加控制点\n• 拖动控制点调整形状\n• 双击控制点删除（端点不可删）\n• 端点可上下拖动：抬黑场 / 压白场")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        Text("中间控制点").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text("端点（可拖黑场/白场）").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if player.curve.isActive {
                        Label("曲线已应用到播放画面", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// 曲线画布
struct CurveCanvas: View {
    @ObservedObject var model: CurveModel

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)

            ZStack {
                // 网格 + 曲线绘制
                Canvas { ctx, size in
                    let s = min(size.width, size.height)
                    // 背景
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                    // 网格线（每 0.1）
                    for i in 0...10 {
                        let t = CGFloat(i) / 10
                        var line = Path()
                        line.move(to: CGPoint(x: t * s, y: 0))
                        line.addLine(to: CGPoint(x: t * s, y: s))
                        ctx.stroke(line, with: .color(Color.white.opacity(i == 5 ? 0.25 : 0.1)), lineWidth: 1)
                        var line2 = Path()
                        line2.move(to: CGPoint(x: 0, y: t * s))
                        line2.addLine(to: CGPoint(x: s, y: t * s))
                        ctx.stroke(line2, with: .color(Color.white.opacity(i == 5 ? 0.25 : 0.1)), lineWidth: 1)
                    }
                    // 对角线参考
                    var diag = Path()
                    diag.move(to: CGPoint(x: 0, y: s))
                    diag.addLine(to: CGPoint(x: s, y: 0))
                    ctx.stroke(diag, with: .color(Color.white.opacity(0.35)), lineWidth: 1)
                    // 曲线（样条采样）
                    let samples = model.sample(count: 65)
                    guard samples.count > 1 else { return }
                    var path = Path()
                    for (i, p) in samples.enumerated() {
                        let pt = CGPoint(x: p.x * s, y: s - p.y * s)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
                }

                // 点击曲线添加控制点
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        let x = min(max(Double(loc.x / side), 0.02), 0.98)
                        let y = min(max(model.value(at: x), 0.02), 0.98)
                        model.add(point: CurvePoint(x: x, y: y))
                    }

                // 控制点拖拽
                ForEach(Array(model.points.enumerated()), id: \.offset) { i, point in
                    let isEndpoint = i == 0 || i == model.points.count - 1
                    Circle()
                        .fill(isEndpoint ? Color.orange : Color.accentColor)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: isEndpoint ? 12 : 11, height: isEndpoint ? 12 : 11)
                        .shadow(radius: 2)
                        .position(x: point.x * side, y: side - point.y * side)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let y = min(max(1 - Double(value.location.y / side), 0), 1)
                                    if isEndpoint {
                                        // 端点也可拖动：X 固定（0 / 1），只调整输出值
                                        // —— 就是照片曲线里的"抬黑场 / 压白场"
                                        model.update(point: point,
                                                     to: CurvePoint(x: point.x, y: y))
                                    } else {
                                        let x = min(max(Double(value.location.x / side), 0.02), 0.98)
                                        model.update(point: point,
                                                     to: CurvePoint(x: x, y: min(max(y, 0.02), 0.98)))
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            if !isEndpoint { model.remove(point: point) }   // 端点不可删
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
