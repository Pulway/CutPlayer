import SwiftUI

/// 主界面：左侧播放列表 + 右侧播放区
///
/// 分栏交给 AppKit 的 NSSplitView（见 SplitContainer）：
/// - 拖动是系统级处理，跟手（SwiftUI 自绘分栏每个鼠标事件都要重建视图树，必然滞后）
/// - 不画分割线，分割区用侧栏底色填充，视觉无缝
public struct ContentView: View {
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.openWindow) private var openWindow
    /// 侧栏宽度：写入 UserDefaults，重启后沿用上次的值（默认 260）
    @AppStorage("CutPlayer.sidebarWidth") private var storedSidebarWidth: Double = 260
    /// 进全屏前的侧栏可见性：退出全屏时恢复它（而不是无条件打开）
    @State private var sidebarBeforeFullScreen = true

    public init() {}

    private var sidebarWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(storedSidebarWidth) },
                set: { storedSidebarWidth = Double($0) })
    }

    public var body: some View {
        SplitContainer(player: player,
                       sidebarVisible: $player.sidebarVisible,
                       sidebarWidth: sidebarWidthBinding)
        .ignoresSafeArea(edges: .top)          // 顶栏贴到窗口顶端（自绘 chrome，无系统工具栏）
        .background(Color.white)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            player.isFullScreen = true
            sidebarBeforeFullScreen = player.sidebarVisible   // 记住用户的选择
            withAnimation { player.sidebarVisible = false }   // 全屏默认让画面占满
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            player.isFullScreen = false
            // 恢复进全屏前的状态：用户若在非全屏收起了侧栏，退出后仍是收起
            withAnimation { player.sidebarVisible = sidebarBeforeFullScreen }
        }
        // 曲线面板改为独立浮动窗口：把"请求标志"翻译成打开窗口
        .onChange(of: player.showCurvePanel) { _, wants in
            guard wants else { return }
            player.showCurvePanel = false
            openWindow(id: "curve")
        }
        .onAppear {
            if player.showCurvePanel || ProcessInfo.processInfo.environment["CUTPLAYER_OPEN_CURVE"] != nil {
                player.showCurvePanel = false
                openWindow(id: "curve")
            }
        }
        .sheet(isPresented: $player.showExportSheet) {
            ExportSheet()
        }
        .sheet(isPresented: $player.showMediaInfo) {
            MediaInfoSheet()
        }
        .alert("导出完成", isPresented: .init(
            get: { player.exportCompletedURL != nil },
            set: { if !$0 { player.exportCompletedURL = nil } }
        )) {
            if let url = player.exportCompletedURL {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    player.exportCompletedURL = nil
                }
                Button("好") { player.exportCompletedURL = nil }
            }
        } message: {
            Text("片段已导出到：\(player.exportCompletedURL?.path ?? "")")
        }
    }
}
