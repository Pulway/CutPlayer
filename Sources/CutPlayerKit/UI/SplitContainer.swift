import SwiftUI
import AppKit

/// 无分割线的 NSSplitView：分割区用侧栏底色填充，视觉上完全无缝
final class CutSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        NSColor(white: 0.965, alpha: 1).setFill()
        rect.fill()
    }
    override var dividerThickness: CGFloat { 1 }
}

/// 侧栏面板容器：内容宽度**固定**，容器负责裁剪。
///
/// 收起/展开时是"拉窗帘"式的滑出滑入，而不是把 SwiftUI 内容一路压扁重排。
final class SidebarPaneView: NSView {
    let host: NSHostingView<AnyView>
    /// 内容固定宽度（动画期间保持不变）
    private(set) var contentWidth: CGFloat
    /// 动画期间为 true：不做"内容宽度对齐面板宽度"的动作
    private(set) var isAnimating = false
    private var settleTask: DispatchWorkItem?

    init(host: NSHostingView<AnyView>, width: CGFloat) {
        self.host = host
        self.contentWidth = width
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.965, alpha: 1).cgColor
        layer?.masksToBounds = true
        host.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        host.autoresizingMask = [.height]          // 高度跟随，宽度自己管
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame.size.height = bounds.height
        guard !isAnimating else { return }
        // 拖动/动画期间内容宽度保持固定（不被压扁重排）；
        // 停稳 120ms 后再对齐到最终宽度（位移极小，几乎察觉不到）
        settleTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.isAnimating, !self.isHidden else { return }
            // 面板过窄说明正处在收起/展开过程：此时把内容宽度同步过去会让
            // 内容位置算错、露出旧画面（表现为"中间那行字/图标闪一下"）
            guard self.bounds.width >= 80 else { return }
            guard abs(self.host.frame.width - self.bounds.width) > 0.5 else { return }
            self.contentWidth = self.bounds.width
            self.host.frame.size.width = self.bounds.width
            self.host.frame.origin.x = 0
        }
        settleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    func beginAnimation() { isAnimating = true }
    func setContentOffset(_ offset: CGFloat) { host.frame.origin.x = offset }
    func setContentWidth(_ w: CGFloat) {
        contentWidth = w
        host.frame.size.width = w
    }
    func endAnimation() {
        isAnimating = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

/// 左右分栏容器：**用 AppKit 的 NSSplitView** 而不是 SwiftUI 布局。
///
/// - 拖动：系统级处理，跟手（SwiftUI 自绘分栏每个鼠标事件都要重建视图树，必然滞后）
/// - 收起/展开：自己按真实时间驱动的 60Hz 逐帧动画（不依赖系统位置动画，
///   因为全屏切换时窗口在做系统动画，系统位置动画会被随后的布局打断）
struct SplitContainer: NSViewRepresentable {
    let player: PlayerModel
    @Binding var sidebarVisible: Bool
    @Binding var sidebarWidth: CGFloat
    var minSidebar: CGFloat = 260
    var maxSidebar: CGFloat = 1000

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CutSplitView {
        let split = CutSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let sideHost = NSHostingView(rootView: AnyView(PlaylistSidebar().environmentObject(player)))
        let detail = NSHostingView(rootView: AnyView(PlayerAreaView().environmentObject(player)))
        // 不向 SwiftUI 内容注入窗口安全区（标题栏 28pt），否则侧栏内容会被整体顶下去
        sideHost.safeAreaRegions = []
        detail.safeAreaRegions = []

        let initial = min(max(sidebarWidth, minSidebar), maxSidebar)
        let pane = SidebarPaneView(host: sideHost, width: initial)
        split.addArrangedSubview(pane)
        split.addArrangedSubview(detail)

        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        context.coordinator.sidebarPane = pane
        context.coordinator.detailHost = detail
        context.coordinator.desiredWidth = initial
        context.coordinator.observeFrameChanges(of: split)
        if sidebarVisible {
            DispatchQueue.main.async { split.setPosition(initial, ofDividerAt: 0) }
        } else {
            // 启动即"侧栏收起"：初始就按收起状态摆放（否则会先显示一帧再收起）
            pane.setContentWidth(initial)
            pane.setContentOffset(-initial)
            pane.isHidden = true
            DispatchQueue.main.async {
                split.setPosition(0, ofDividerAt: 0)
                split.adjustSubviews()
            }
        }
        return split
    }

    func updateNSView(_ split: CutSplitView, context: Context) {
        context.coordinator.parent = self
        guard let pane = context.coordinator.sidebarPane else { return }
        let coordinator = context.coordinator

        if !sidebarVisible {
            guard !pane.isHidden else { return }
            coordinator.animate(split: split, pane: pane, to: 0) {
                pane.isHidden = true
                split.adjustSubviews()
            }
        } else if pane.isHidden {
            // 原子化展开：锁住内容尺寸 → 面板归零 → 推内容到屏幕外 → 解除隐藏 → 动画
            // （顺序很重要，任何一步被打断都会露出"已展开"的一帧）
            pane.beginAnimation()
            pane.setContentWidth(coordinator.desiredWidth)
            pane.setContentOffset(-coordinator.desiredWidth)
            coordinator.collapsing = true
            split.setPosition(0, ofDividerAt: 0)
            pane.isHidden = false
            coordinator.collapsing = false
            coordinator.animate(split: split, pane: pane, to: coordinator.desiredWidth)
        } else if !coordinator.isAnimating, abs(pane.frame.width - coordinator.desiredWidth) > 1 {
            // 外部改宽度（例如恢复默认）；动画/拖动过程中不插手
            pane.setContentWidth(coordinator.desiredWidth)
            pane.setContentOffset(0)
            split.setPosition(coordinator.desiredWidth, ofDividerAt: 0)
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var parent: SplitContainer
        weak var sidebarPane: SidebarPaneView?
        weak var detailHost: NSView?
        /// 收起/动画期间放开最小宽度约束（否则 setPosition(0) 会被夹到 minSidebar）
        var collapsing = false
        /// AppKit 侧的"可信宽度"：不受动画中间值污染
        var desiredWidth: CGFloat = 340
        private var animTimer: Timer?
        private var animStart: CFTimeInterval = 0
        private var animFrom: CGFloat = 0
        private var animTo: CGFloat = 0
        private weak var animSplit: NSSplitView?
        private weak var animPane: SidebarPaneView?
        private var animCompletion: (() -> Void)?
        private let animDuration: TimeInterval = 0.26

        private var frameObserver: NSObjectProtocol?

        init(_ parent: SplitContainer) { self.parent = parent }

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func observeFrameChanges(of split: NSSplitView) {
            split.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: split, queue: .main
            ) { [weak self] _ in
                guard let self, let split = self.sidebarPane?.superview as? NSSplitView else { return }
                self.splitViewFrameChanged(split)
            }
        }

        var isAnimating: Bool { animTimer != nil }

        func splitView(_ splitView: NSSplitView,
                       constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            collapsing ? 0 : parent.minSidebar
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            maxAllowed(for: splitView)
        }

        /// 当前窗口宽度下允许的最大侧栏宽度（播放区至少留 420pt）
        func maxAllowed(for split: NSSplitView) -> CGFloat {
            max(parent.minSidebar, min(parent.maxSidebar, split.bounds.width - 420))
        }

        /// 窗口尺寸变化（如退出全屏窗口变窄）时**平滑**收敛宽度，
        /// 而不是让约束把它瞬间夹小（那就是"宽度骤变"）
        func splitViewFrameChanged(_ split: NSSplitView) {
            guard let pane = sidebarPane else { return }
            let maxW = maxAllowed(for: split)
            if isAnimating {
                // 动画中：只修正目标，不另起一段动画
                animTo = min(animTo, maxW)
                return
            }
            guard !pane.isHidden, desiredWidth > maxW + 1 else { return }
            desiredWidth = maxW
            if abs(parent.sidebarWidth - maxW) > 1 { parent.sidebarWidth = maxW }
            animate(split: split, pane: pane, to: maxW)
        }

        /// 按**真实经过时间**驱动的逐帧动画：
        /// 不用 asyncAfter 预排帧（全屏切换时主线程忙，早帧会被挤到一起 → 前慢后快）
        func animate(split: NSSplitView, pane: SidebarPaneView, to target: CGFloat,
                     completion: (() -> Void)? = nil) {
            animTimer?.invalidate()
            animSplit = split
            animPane = pane
            animCompletion = completion
            animFrom = pane.frame.width
            animTo = target
            animStart = CACurrentMediaTime()
            collapsing = true
            pane.beginAnimation()

            guard abs(animTo - animFrom) > 1 else {
                collapsing = false
                pane.setContentOffset(0)
                pane.endAnimation()
                completion?()
                return
            }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            animTimer = timer
            tick()          // 立刻画第一帧，避免闪现旧状态
        }

        private func tick() {
            guard let split = animSplit, let pane = animPane else { finishAnimation(); return }
            // 窗口在动画过程中变窄时，同步收敛目标宽度
            animTo = min(animTo, maxAllowed(for: split))
            let elapsed = CACurrentMediaTime() - animStart
            let t = min(max(elapsed / animDuration, 0), 1)
            let eased = CGFloat(t * t * (3 - 2 * t))          // smoothstep
            let paneW = animFrom + (animTo - animFrom) * eased
            split.setPosition(paneW, ofDividerAt: 0)
            pane.setContentOffset(paneW - pane.contentWidth)  // 内容右缘贴住面板右缘
            if t >= 1 { finishAnimation() }
        }

        private func finishAnimation() {
            animTimer?.invalidate()
            animTimer = nil
            collapsing = false
            animPane?.endAnimation()
            animCompletion?()
            animCompletion = nil
        }

        /// 拖动结束后把实际宽度写回 SwiftUI 状态。
        /// **动画期间必须忽略**：否则会把动画中间宽度（比如 250pt）当成用户设置写回去，
        /// 表现就是"改好的宽度被忘了 / 下次展开变成很窄（标题折行）"。
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let pane = sidebarPane, !pane.isHidden,
                  !collapsing, !isAnimating else { return }
            let w = pane.frame.width
            guard w >= parent.minSidebar - 1 else { return }
            desiredWidth = w
            if abs(parent.sidebarWidth - w) > 1 { parent.sidebarWidth = w }
        }
    }
}
