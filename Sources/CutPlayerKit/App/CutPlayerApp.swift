import SwiftUI
import AppKit

/// CutPlayer 应用入口
public struct CutPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("CutPlayer") {
            ContentView()
                .environmentObject(player)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear {
                    appDelegate.player = player
                    appDelegate.installKeyBindings(player)
                }
        }
        .windowStyle(.hiddenTitleBar)

        // 亮度曲线：独立浮动窗口（而不是覆盖画面的 sheet），调曲线时画面完整可见
        Window("亮度曲线", id: "curve") {
            CurveEditorView()
                .environmentObject(player)
                .background(FloatingWindowConfigurator())
        }
        .defaultSize(width: 470, height: 640)
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("文件") {
                Button("打开文件…") { appDelegate.openFiles() }
                    .keyboardShortcut("o")
                Button("打开文件夹…") { appDelegate.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("导出片段…") { player.showExportSheet = true }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(player.currentURL == nil)
                Button("截图") { player.screenshot() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(player.currentURL == nil)
            }

            CommandMenu("播放") {
                Button("播放 / 暂停") { player.togglePlay() }
                Button("下一个") { player.openNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("上一个") { player.openPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("标记入点") { player.markIn() }
                    .keyboardShortcut("[")
                Button("标记出点") { player.markOut() }
                    .keyboardShortcut("]")
                Button("清除入出点") { player.clearMarks() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
            }

            CommandMenu("颜色") {
                Button("从访达选择 LUT…") { appDelegate.pickLUT() }
                    .keyboardShortcut("l", modifiers: [.command])
                Button("导入 LUT 到库…") { appDelegate.importLUT() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("亮度曲线") { player.showCurvePanel = true }
                    .keyboardShortcut("d", modifiers: [.command])
                Divider()
                Button("清除当前 LUT") { player.setLUT(nil) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }

            CommandMenu("显示") {
                Button("媒体信息") { player.showMediaInfo = true }
                    .keyboardShortcut("i", modifiers: [.command])
            }
        }
    }
}

/// 应用代理：文件拖放、按键绑定、自检驱动、退出清理
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public var player: PlayerModel?
    private var keyMonitor: Any?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 窗口背景改纯白：侧栏顶部（窗口工具栏区域）原本是浅灰 #F5F5F5，
        // 与播放区纯白顶栏相接时会出现色阶"交界缝"
        DispatchQueue.main.async {
            for w in NSApp.windows {
                w.backgroundColor = .white
                // 自绘 chrome：没有系统标题栏/工具栏。
                // 注意**不能**开 isMovableByWindowBackground——那会把分栏拖动条的拖拽
                // 也当成拖窗口，导致侧栏宽度调不了；改为在顶部栏显式放 WindowDragArea
                w.isMovableByWindowBackground = false
            }
        }
        // 自检/基准测试一律走 main.swift 的无头分支，这里不再驱动它们
    }

    /// 全局按键（无修饰键时）；文本框聚焦时不拦截
    public func installKeyBindings(_ player: PlayerModel) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let fr = event.window?.firstResponder, fr is NSTextView || fr is NSTextField {
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard flags.isEmpty else { return event }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case " ": player.togglePlay(); return nil
                case "s": player.screenshot(); return nil
                case "[": player.markIn(); return nil
                case "]": player.markOut(); return nil
                case "e": player.showExportSheet = true; return nil
                case "f": event.window?.toggleFullScreen(nil); return nil
                case "m": player.muted.toggle(); return nil
                case "i": player.showMediaInfo = true; return nil
                default: break
                }
            }
            switch event.keyCode {
            case 123: player.seekRelative(-5); return nil   // ←
            case 124: player.seekRelative(5); return nil    // →
            case 125: player.seekRelative(-30); return nil  // ↓
            case 126: player.seekRelative(30); return nil   // ↑
            default: return event
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 禁用窗口状态保存/恢复（否则崩溃后每次启动弹「恢复窗口」对话框，阻塞无头自检）
    public func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    public func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    public func applicationWillTerminate(_ notification: Notification) {
        player?.savePlaybackStateOnQuit()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 菜单动作

    public func openFiles() {
        guard let player else { return }
        if let urls = OpenPanels.pickFiles() {
            let added = player.playlist.add(urls: urls)
            if let first = added.first {
                player.open(first.url)
            }
        }
    }

    public func openFolder() {
        guard let player else { return }
        if let url = OpenPanels.pickFolder() {
            player.playlist.addFolder(url: url)
            if let first = player.playlist.items.first {
                player.open(first.url)
            }
        }
    }

    /// 从访达选择 LUT：直接套用到当前选择（不进库）
    public func pickLUT() {
        guard let player else { return }
        player.pickLUTFromFinder()
    }

    /// 导入 LUT 到库：只作为备选（不套用）
    public func importLUT() {
        guard let player else { return }
        player.importLUTFromFinder()
    }
}
