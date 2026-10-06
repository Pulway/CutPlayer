import SwiftUI
import UniformTypeIdentifiers

/// 左侧播放列表：单选/⌘加选/⇧连选、批量套用监看 LUT、拖放导入、上下文菜单
struct PlaylistSidebar: View, Equatable {
    /// 无外部输入 → 恒等：配合 .equatable() 让父视图重绘（如拖动分栏改宽度）时
    /// 跳过本视图 body 重建
    static func == (lhs: Self, rhs: Self) -> Bool { true }

    @EnvironmentObject private var player: PlayerModel
    /// 拖动排序中：selection 变化不触发打开（避免拖动误切换）
    @State private var isDraggingRow = false
    @State private var showLUTPanel = false
    /// ⇧ 连选的锚点（上一次点击的条目）
    @State private var lastClickedID: PlaylistItem.ID?

    /// 侧栏底色：比纯白暗一点点（0.965），与右侧播放区形成柔和的层次
    static let sidebarTint = Color(white: 0.965)

    var body: some View {
        VStack(spacing: 0) {
            header
            if player.playlist.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("播放列表为空")
                        .foregroundStyle(.secondary)
                    Text("拖入视频文件或文件夹")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 注意：**不用** List 的 selection 绑定。
                // 原生选中高亮会画在 listRowBackground 之上，导致"当前播放（蓝）+ 被选中（原生蓝）"
                // 叠成两层蓝底。这里自己处理点击与 ⌘/⇧ 修饰键，底色完全自绘。
                List {
                    ForEach(player.playlist.items) { item in
                        PlaylistRow(item: item)
                            .listRowBackground(rowBackground(for: item))
                            .contentShape(Rectangle())
                            .onTapGesture { handleRowClick(item) }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 5)
                                    .onChanged { _ in isDraggingRow = true }
                                    .onEnded { _ in
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                            isDraggingRow = false
                                        }
                                    }
                            )
                            .contextMenu { rowMenu(item) }
                    }
                    .onMove { offsets, dest in
                        player.playlist.move(fromOffsets: offsets, toOffset: dest)
                    }
                    .onDelete { offsets in
                        player.removeFromPlaylist(offsets.map { player.playlist.items[$0] })
                    }
                    // 列表下方空白处：点击清空选择（只清选择，不影响正在播放的条目）
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .contentShape(Rectangle())
                        .onTapGesture { player.playlist.clearSelection() }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)    // 露出外层纯白底
            }
        }
        .background(Self.sidebarTint)                // 比播放区纯白**暗一丁点**，形成柔和区分
        .environment(\.colorScheme, .light)          // 白底 → 文字按浅色模式渲染

        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    /// 自绘头部（替代系统窗口工具栏）：
    /// 顶部留出红绿灯高度，下面一行是标题 + 三个按钮（LUT / 打开文件 / 打开文件夹），同组右对齐
    private var header: some View {
        HStack(spacing: 10) {
            Text("播放列表")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()                     // 永不折行（宽度不足时其它元素先让位）
            Text("\(player.playlist.items.count) 个文件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)

            Button {
                showLUTPanel.toggle()
            } label: {
                Image(systemName: "camera.filters")
            }
            .buttonStyle(.plain)
            .help("监看 LUT：为选中的文件套用，或管理 LUT 库（导入 / 删除）")
            .disabled(player.lutTargets.isEmpty && player.lutLibrary.isEmpty)
            .popover(isPresented: $showLUTPanel, arrowEdge: .bottom) {
                LUTLibraryPanel(isPresented: $showLUTPanel).environmentObject(player)
            }

            Button {
                player.pickAndOpenFiles()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("打开文件 (⌘O)")

            Button {
                player.pickAndOpenFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("打开文件夹并递归扫描 (⇧⌘O)")
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 34)          // 避让窗口红绿灯
        .padding(.bottom, 10)
        .background(
            ZStack {
                Self.sidebarTint
                WindowDragArea()    // 侧栏头部同属标题栏区域，可拖动窗口
            }
        )
    }

    /// 行底色：当前播放（蓝）> 其他选中（灰）> 透明
    /// 由于不再使用 List 的 selection 绑定，这里画的就是**唯一**的选中视觉。
    /// 形状是内缩的圆角矩形（贴近 macOS 原生选中样式），而不是铺满整行。
    private func rowBackground(for item: PlaylistItem) -> some View {
        Group {
            if item.isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.9))
            } else if player.playlist.selection.contains(item.id) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
            } else {
                Color.clear
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
    }

    /// 自己处理点击：普通点击 = 单选并切换视频；⌘ = 加/减选；⇧ = 区间连选
    private func handleRowClick(_ item: PlaylistItem) {
        guard !isDraggingRow else { return }
        let flags = NSEvent.modifierFlags
        let items = player.playlist.items

        if flags.contains(.shift) {
            // 锚点（连选起点）三级兜底：上次点击的条目 → 当前播放项 → 已选中的第一条。
            // 少了后两级时：导入文件后"自动播放的那条"没有点击记录，
            // ⇧ 点击会退化成普通点击（变成跳转），而不是连选。
            let anchorID = lastClickedID
                ?? player.playlist.currentID
                ?? player.playlist.selection.first
            if let anchor = anchorID,
               let a = items.firstIndex(where: { $0.id == anchor }),
               let b = items.firstIndex(where: { $0.id == item.id }) {
                let range = a <= b ? a...b : b...a
                player.playlist.selection = Set(items[range].map(\.id))
            } else {
                player.playlist.selection = [item.id]   // 没有可参照的锚点：只选它
            }
            return                      // 连选不切换视频
        }
        if flags.contains(.command) {
            if player.playlist.selection.contains(item.id) {
                player.playlist.selection.remove(item.id)
            } else {
                player.playlist.selection.insert(item.id)
            }
            lastClickedID = item.id
            return                      // 加选不切换视频
        }
        lastClickedID = item.id
        player.open(item.url)           // 普通点击：单选 + 打开（open 内部会同步选中态）
    }

    private var lutMenuTitle: String {
        let targets = player.lutTargets
        if targets.count > 1 { return "LUT（\(targets.count) 个）" }
        if let one = targets.first { return "LUT：\(one.fileName)" }
        return "LUT"
    }

    /// 右键菜单的作用对象：
    /// 命中项**在选中集里** → 作用于整个选中集（多选批量操作）；
    /// 命中项不在选中集里 → 只作用于它自己（不影响现有选择）。
    /// 之前无论选了多少都只处理右键命中的那一条，是 bug。
    private func menuTargets(for item: PlaylistItem) -> [PlaylistItem] {
        let sel = player.playlist.selection
        guard sel.contains(item.id) else { return [item] }
        let targets = player.playlist.items.filter { sel.contains($0.id) }
        return targets.isEmpty ? [item] : targets
    }

    @ViewBuilder
    private func rowMenu(_ item: PlaylistItem) -> some View {
        // 作用对象：命中项在选中集里 → 整个选中集；否则只有它自己
        let targets = menuTargets(for: item)

        Button("播放") { player.open(item.url, force: true) }
        Divider()
        Button("从访达选择 LUT…") { pickLUT(for: targets) }
        if !player.lutLibrary.isEmpty {
            Menu("套用已导入的 LUT") {
                ForEach(player.lutLibrary, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        player.setLUT(path, for: targets)
                    }
                }
            }
        }
        Button("清除监看 LUT") { player.clearLUT(for: targets) }
        Divider()
        Button("从列表移除", role: .destructive) { player.removeFromPlaylist(targets) }
    }

    private func pickLUT(for items: [PlaylistItem]) {
        guard let url = OpenPanels.pickLUT() else { return }
        player.setLUT(url.path, for: items)      // 只套用，不进库（入库用「导入 LUT…」）
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

/// LUT 库面板（弹出）：
/// - 点某一行 → 套用到当前所选
/// - 鼠标悬浮某一行 → 行尾出现垃圾桶；删除需确认（不再有冗余的"从库中移除"入口）
/// - 导入 LUT…（可多选，同名自动跳过） / 从访达选择 LUT…（单选，只套用不入库）
struct LUTLibraryPanel: View {
    @EnvironmentObject private var player: PlayerModel
    /// 套用/清除后自动关闭二级菜单（点一下就生效，没必要留着）
    @Binding var isPresented: Bool
    @State private var hovering: String?
    @State private var pendingDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("监看 LUT").font(.headline)
                Spacer()
                Text(targetText).font(.caption).foregroundStyle(.secondary)
            }

            if player.lutLibrary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("还没有导入 LUT")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("用下面的「导入 LUT…」把常用 LUT 加进来，之后一键套用")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(player.lutLibrary, id: \.self) { path in
                            lutRow(path)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            HStack(spacing: 8) {
                Button("导入 LUT…") { player.importLUTFromFinder() }
                    .help("把一个或多个 LUT 加入备选库（同名自动跳过），不会套用到视频")
                Button("从访达选择 LUT…") {
                    player.pickLUTFromFinder()
                    if !player.lutTargets.isEmpty { isPresented = false }
                }
                .help("选一个 LUT 直接套用到所选视频（不加入库）")
            }

            Button("清除所选文件的监看 LUT") {
                player.applyLUT(nil)
                isPresented = false
            }
            .disabled(player.lutTargets.isEmpty)
        }
        .padding(14)
        .frame(width: 340)
        .confirmationDialog(
            "删除这个 LUT？",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let p = pendingDelete { player.removeLUTFromLibrary(p) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只会从 LUT 库里移除，不会删除磁盘上的文件。\n\((pendingDelete as NSString?)?.lastPathComponent ?? "")")
        }
    }

    private var targetText: String {
        let n = player.lutTargets.count
        if n == 0 { return "未选择文件" }
        return n == 1 ? "将套用到 1 个文件" : "将套用到 \(n) 个文件"
    }

    private func lutRow(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let isApplied = player.lutPath == path
        return HStack(spacing: 7) {
            Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isApplied ? Color.accentColor : Color.secondary.opacity(0.4))
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if hovering == path {
                Button {
                    pendingDelete = path
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("从 LUT 库中删除")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(hovering == path ? Color.secondary.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if player.lutTargets.isEmpty {
                player.statusMessage = "请先在播放列表里选择文件"
            } else {
                player.applyLUT(path)
                isPresented = false          // 已套用 → 关闭面板
            }
        }
        .onHover { inside in
            if inside { hovering = path } else if hovering == path { hovering = nil }
        }
        .help(path)
    }
}

/// 播放列表行：文件名 + 时长 + LUT 徽标
struct PlaylistRow: View {
    @ObservedObject var item: PlaylistItem

    var body: some View {
        HStack(spacing: 8) {
            if item.isCurrent {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 12)
            } else {
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                // 蓝底（当前播放）时文字转白，保证对比度
                .foregroundStyle(item.isCurrent ? Color.white : Color.primary)
            Spacer(minLength: 4)
            if let lut = item.lut {
                // onAccent（蓝底当前播放）= 白底徽标；其余 = 灰底徽标（比选中行灰底更深一档）
                LUTBadge(name: (lut as NSString).lastPathComponent,
                         style: item.isCurrent ? .onAccent : .neutral)
            }
            if let d = item.duration, d > 0 {
                Text(formatTime(d))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(item.isCurrent ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.vertical, 2)
        // 关键：内容（尤其是文件名文字）不参与命中测试，点击直接落到 List 行上。
        // 否则文字会吃掉 mouse-down，表现为"点文件名没反应"，且 ⌘/⇧ 多选失效。
        .allowsHitTesting(false)
    }

    private func formatTime(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// LUT 徽标样式
enum LUTBadgeStyle {
    case onAccent   // 当前播放（蓝底）→ 白字 + 半透明白胶囊
    case neutral    // 未选中 → 灰底（比"多选非当前"行底色更深一档）
    case warn       // 保留：橙色（例如提示类场景）
}

/// LUT 徽标
struct LUTBadge: View {
    let name: String
    var style: LUTBadgeStyle = .neutral

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 8))
            Text(name)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(fill))
        .foregroundStyle(foreground)
        .help(name)
    }

    private var fill: Color {
        switch style {
        case .onAccent: return Color.white.opacity(0.28)
        // 不透明浅灰：半透明灰会与被选中行的灰底**叠加变深**，
        // 这里固定成"叠在白底上时"的那一档，任何行底色上都一致
        case .neutral:  return Color(white: 0.80)
        case .warn:     return Color.orange.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch style {
        case .onAccent: return .white
        case .neutral:  return Color(white: 0.26)
        case .warn:     return .orange
        }
    }
}
