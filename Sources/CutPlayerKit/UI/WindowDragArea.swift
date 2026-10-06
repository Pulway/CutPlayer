import SwiftUI
import AppKit

/// 自绘 chrome 用：让一块区域可以拖动窗口。
///
/// 背景：窗口开启了 `isMovableByWindowBackground` 后，**任何**透明区域的拖拽
/// 都会被 AppKit 当作"拖动窗口"，导致分栏拖动条失效。因此改为关闭该开关，
/// 只在顶部栏/侧栏头部这类"标题栏区域"显式放一个可拖动视图。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        // 自己处理 mouseDown：不要让系统再按"背景拖动"处理一次
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // 只接收落在自己范围内的点击（按钮等上层视图仍优先）
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}
