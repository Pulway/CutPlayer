import SwiftUI
import UniformTypeIdentifiers

/// 顶栏高度同步（与底栏一致）
private struct ControlBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 播放区：视频画面 + 顶部信息条 + 底部控制条
struct PlayerAreaView: View, Equatable {
    /// 无外部输入 → 恒等：配合 .equatable() 让父视图重绘（如拖动分栏改宽度）时
    /// 跳过本视图 body 重建
    static func == (lhs: Self, rhs: Self) -> Bool { true }

    @EnvironmentObject private var player: PlayerModel
    @FocusState private var focused: Bool
    /// 控制栏自动隐藏：鼠标活动后 2 秒隐藏；移动/进入窗口即显示
    @State private var controlsVisible = true
    @State private var lastMouseActivity = Date()
    @State private var lastMouseLoc = NSPoint.zero
    @State private var controlBarHeight: CGFloat = 64
    /// 进度条拖动中的临时值（松手才真正 seek，避免拖动过程连续 seek 造成快进声画）
    @State private var scrubValue: Double?

    private let controlTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if player.currentURL == nil {
                VStack(spacing: 14) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 46))
                        .foregroundStyle(.tertiary)
                    Text("拖入视频 / 音频文件，或使用「文件」菜单打开")
                        .foregroundStyle(.secondary)
                    Text("支持 10bit 4K 硬解 · 监看 LUT · 亮度曲线 · 截图 · 片段导出")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                MetalPlayerView(view: player.metalView)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // 顶栏与底栏等高（测量底栏实际高度），两者都是完整白色不透明矩形
                topBar
                    .frame(maxWidth: .infinity)
                    .frame(height: max(controlBarHeight, 40))   // 强制与底栏等高
                    .background(
                        ZStack {
                            Color.white
                            WindowDragArea()      // 顶栏 = 标题栏区域，可拖动窗口
                        }
                    )
                    .offset(y: controlsVisible ? 0 : -(controlBarHeight + 30))
                Spacer(minLength: 0)
                controlsBar
                    .frame(maxWidth: .infinity)
                    .padding(.leading, -1)                      // 同上：盖住分割线
                    .background(
                        ZStack {
                            Color.white
                            GeometryReader { geo in
                                Color.clear.preference(key: ControlBarHeightKey.self, value: geo.size.height)
                            }
                        }
                    )
                    .onPreferenceChange(ControlBarHeightKey.self) { h in
                        controlBarHeight = h
                    }
                    .offset(y: controlsVisible ? 0 : (controlBarHeight + 30))
            }
            // 关键：叠层整体延伸到窗口顶端（放在 ZStack 上才生效；只加在内层 VStack 上时，
            // 顶栏会从标题栏下方开始，上方露出一条视频黑边 → 就是那条"神秘黑条"）
            .ignoresSafeArea(edges: .top)
            .clipped()                                  // 滑出时裁掉，不露出画面外
            .environment(\.colorScheme, .light)          // 白底 → 文字一律按浅色模式渲染
            .allowsHitTesting(controlsVisible)
            .animation(.easeOut(duration: 0.28), value: controlsVisible)
        }
        .ignoresSafeArea(edges: .top)                   // ZStack 也上探，确保顶栏贴到窗口顶端
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            lastMouseLoc = NSEvent.mouseLocation
        }
        .onReceive(controlTimer) { _ in
            let loc = NSEvent.mouseLocation
            let inWindow = mouseInAppWindow()
            let moved = loc != lastMouseLoc
            let clicked = NSEvent.pressedMouseButtons != 0
            if (moved || clicked) && inWindow {
                lastMouseActivity = Date()
                controlsVisible = true
            }
            lastMouseLoc = loc
            if Date().timeIntervalSince(lastMouseActivity) > 2.0 {
                controlsVisible = false
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    /// 鼠标是否在本 app 任意可见窗口内（屏幕坐标，原点左下）
    /// 不依赖 keyWindow：app 失去焦点（点了别处）后 keyWindow 会变，导致误判
    private func mouseInAppWindow() -> Bool {
        let loc = NSEvent.mouseLocation
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(loc) }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // 标题：**仅全屏下**可点击，用来展开/收起播放列表（非全屏不提供任何隐藏侧栏的入口）
                Text(player.mediaTitle.isEmpty ? "未打开文件" : player.mediaTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture { player.toggleSidebar() }
                    .help(player.sidebarVisible ? "点击隐藏播放列表" : "点击显示播放列表")
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                HStack(spacing: 8) {
                    Text("\(formatClock(player.timePos)) / \(formatClock(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let px = player.mediaInfo["video-params/pixelformat"] {
                        Text(px).font(.caption).foregroundStyle(.secondary)
                    }
                    if let w = player.mediaInfo["video-params/w"], let h = player.mediaInfo["video-params/h"] {
                        Text("\(w)×\(h)").font(.caption).foregroundStyle(.secondary)
                    }
                    if player.speed != 1.0 {
                        Text("\(player.speed, specifier: "%.2g")×")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            if player.curve.isActive {
                Label("曲线", systemImage: "waveform.path.ecg")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.2)))
                    .foregroundStyle(.purple)
            }
            if let lut = player.lutPath {
                LUTBadge(name: (lut as NSString).lastPathComponent)
            }
            Button {
                player.showMediaInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .help("媒体信息 (⌘I)")
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        // 与侧栏收起/展开动画同步，避免避让量"跳"变
        .animation(.easeInOut(duration: 0.26), value: player.sidebarVisible)
    }

    /// 顶栏左侧内边距：侧栏收起且非全屏时，窗口红绿灯会压在顶栏上，需要避让
    private var leadingInset: CGFloat {
        (!player.sidebarVisible && !player.isFullScreen) ? 78 : 16
    }

    // MARK: - 控制条

    private var controlsBar: some View {
        VStack(spacing: 6) {
            // 进度条
            HStack(spacing: 8) {
                Text(formatClock(player.timePos))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { scrubValue ?? (player.duration > 0 ? player.timePos : 0) },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            if let v = scrubValue, player.duration > 0 {
                                player.seekFraction(v / player.duration)
                            }
                            scrubValue = nil
                        }
                    }
                )
                .disabled(player.duration <= 0)
                Text(formatClock(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { player.openPrevious() } label: { Image(systemName: "backward.end.fill") }
                    .disabled(player.currentURL == nil)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                }
                .disabled(player.currentURL == nil)
                Button { player.openNext() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(player.currentURL == nil)

                Divider().frame(height: 20)

                // 播放模式：顺序 / 不连播 / 循环
                Menu {
                    Picker("播放模式", selection: $player.playMode) {
                        ForEach(PlayerModel.PlayMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: player.playMode.icon)
                        .foregroundStyle(player.playMode == .sequential ? Color.secondary : Color.accentColor)
                }
                .help("播放模式：\(player.playMode.rawValue)（播完自动进入下一个 / 停在结尾 / 循环重播）")

                Button { player.markIn() } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "chevron.left.to.line")
                        Text("IN").font(.system(size: 7))
                    }
                }
                .help("标记入点 [")
                Button { player.markOut() } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "chevron.right.to.line")
                        Text("OUT").font(.system(size: 7))
                    }
                }
                .help("标记出点 ]")
                Button { player.clearMarks() } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "xmark.circle")
                        Text("清除").font(.system(size: 7))
                    }
                }
                .help("清除入点/出点 (⇧⌘X)")
                .disabled(player.inPoint == nil && player.outPoint == nil)
                if player.inPoint != nil || player.outPoint != nil {
                    Text("\(player.inPoint.map(formatClock) ?? "—") → \(player.outPoint.map(formatClock) ?? "—")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button { player.screenshot() } label: { Image(systemName: "camera") }
                    .help("截图（带 LUT，不含曲线）(S)")
                Button { player.showCurvePanel = true } label: {
                    Image(systemName: "waveform.path.ecg")
                }
                .help("亮度曲线 (⌘D)")

                // 输入色彩范围：自动判定 / 手动覆盖（按文件记住）
                Menu {
                    Picker("输入色彩范围", selection: Binding(
                        get: { player.rangeMode },
                        set: { player.setRangeMode($0) }
                    )) {
                        Text("自动判定").tag("auto")
                        Text("limited（16–235）").tag("limited")
                        Text("full（0–255）").tag("full")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: player.rangeMode == "auto"
                          ? "circle.lefthalf.filled" : "circle.righthalf.filled")
                        .foregroundStyle(player.rangeMode == "auto" ? Color.secondary : Color.accentColor)
                }
                .help("输入色彩范围：\(player.rangeModeDescription)（选错会导致画面发灰或死黑）")
                .disabled(player.currentURL == nil)
                Button { player.showExportSheet = true } label: { Image(systemName: "scissors") }
                    .help("导出片段（带 LUT，不含曲线）(E)")

                Divider().frame(height: 20)

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        Button("\(s, specifier: "%.2g")×") { player.speed = s }
                    }
                } label: {
                    Text("\(player.speed, specifier: "%.2g")×")
                        .monospacedDigit()
                }
                .frame(width: 52)

                Button { player.muted.toggle() } label: {
                    Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Slider(value: $player.volume, in: 0...150)
                    .frame(width: 90)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    // 进入全屏 = 向外箭头；已在全屏 = 向内箭头（方向相反）
                    Image(systemName: player.isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .help("全屏 (F)")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 工具

    private func formatClock(_ t: Double) -> String {
        let total = Int(t)
        let ms = Int((t - Double(total)) * 100)
        return String(format: "%d:%02d:%02d.%02d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var pending = providers.count
        var urls: [URL] = []
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                pending -= 1
                if pending == 0 {
                    Task { @MainActor in
                        let folderURLs = urls.filter { $0.hasDirectoryPath }
                        let fileURLs = urls.filter { !$0.hasDirectoryPath }
                        let added = player.playlist.add(urls: fileURLs)
                        for f in folderURLs { player.playlist.addFolder(url: f) }
                        if let first = added.first {
                            player.open(first.url)
                        } else if let first = player.playlist.items.first {
                            player.open(first.url)
                        }
                    }
                }
            }
        }
        return true
    }
}
