import SwiftUI
import AppKit

/// 把承载它的窗口配置成"浮动工具窗"，并在首次出现时摆到不遮挡画面的位置。
/// 用于亮度曲线面板：让它浮在主窗口旁，而不是覆盖在视频上。
struct FloatingWindowConfigurator: NSViewRepresentable {
    /// 期望宽度（用于挑选摆放位置，避免算出屏幕外）
    var preferredWidth: CGFloat = 470

    func makeNSView(context: Context) -> NSView { ConfigView(preferredWidth: preferredWidth) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        let preferredWidth: CGFloat
        private var configured = false

        init(preferredWidth: CGFloat) {
            self.preferredWidth = preferredWidth
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }
            configured = true
            window.level = .floating                                   // 始终浮在主窗口之上
            window.collectionBehavior.insert(.fullScreenAuxiliary)     // 全屏时也能一起显示
            // SwiftUI 建窗后会再做一次摆放，所以稍等一拍再定位
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak window] in
                guard let window else { return }
                self.position(window)
            }
        }

        /// 优先摆在主窗口右侧（顶对齐）；放不下就退到屏幕右下角
        private func position(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = window.frame.size
            let main = NSApp.windows
                .filter { $0 != window && $0.isVisible && $0.frame.width > 500 }
                .max { $0.frame.width < $1.frame.width }

            // 目标：尽量别压住画面 → 依次尝试 主窗口右侧 → 主窗口左侧 → 屏幕左下角
            var origin = NSPoint(x: visible.minX + 28, y: visible.minY + 28)
            if let main {
                let rightX = main.frame.maxX + 14
                let leftX = main.frame.minX - size.width - 14
                if rightX + size.width <= visible.maxX - 8 {
                    origin = NSPoint(x: rightX, y: main.frame.maxY - size.height)   // 右侧，顶对齐
                } else if leftX >= visible.minX + 8 {
                    origin = NSPoint(x: leftX, y: main.frame.maxY - size.height)    // 左侧，顶对齐
                }
            }
            // 兜底：别跑出屏幕
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
            window.setFrameOrigin(origin)
        }
    }
}
