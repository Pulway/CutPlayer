import Foundation
import UniformTypeIdentifiers
import Combine

/// 播放列表条目
public final class PlaylistItem: ObservableObject, Identifiable, Hashable {
    public let id = UUID()
    public let url: URL
    @Published public var lut: String?
    @Published public var duration: Double?
    @Published public var isCurrent = false

    public init(url: URL, lut: String? = nil) {
        self.url = url
        self.lut = lut
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (l: PlaylistItem, r: PlaylistItem) -> Bool { l.id == r.id }

    public var fileName: String { url.lastPathComponent }
}

@MainActor
public final class PlaylistModel: ObservableObject {
    @Published public private(set) var items: [PlaylistItem] = []
    @Published public var selection: Set<PlaylistItem.ID> = []
    @Published public private(set) var currentID: PlaylistItem.ID?

    private let db: LUTDatabase

    public init(db: LUTDatabase) {
        self.db = db
    }

    public var currentItem: PlaylistItem? {
        items.first { $0.id == currentID }
    }

    // MARK: - 导入

    @discardableResult
    public func add(urls: [URL]) -> [PlaylistItem] {
        var added: [PlaylistItem] = []
        for url in urls {
            guard Self.isPlayable(url), !items.contains(where: { $0.url == url }) else { continue }
            let item = PlaylistItem(url: url, lut: db.lut(forFile: url.path))
            items.append(item)
            added.append(item)
        }
        return added
    }

    public func addFolder(url: URL) {
        let fm = FileManager.default
        var files: [URL] = []
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if Self.isPlayable(fileURL) { files.append(fileURL) }
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        _ = add(urls: files)
    }

    // MARK: - 播放

    public func select(_ item: PlaylistItem) {
        for it in items { it.isCurrent = (it.id == item.id) }
        if item.isCurrent { currentID = item.id }
        // 同步 List 高亮（selection 驱动）
        selection = [item.id]
    }

    public func playNext() -> PlaylistItem? {
        guard let idx = items.firstIndex(where: { $0.id == currentID }), idx + 1 < items.count else { return nil }
        return items[idx + 1]
    }

    public func playPrevious() -> PlaylistItem? {
        guard let idx = items.firstIndex(where: { $0.id == currentID }), idx > 0 else { return nil }
        return items[idx - 1]
    }

    /// 拖动排序（列表 onMove）
    public func move(fromOffsets: IndexSet, toOffset: Int) {
        let path = "/tmp/cutplayer_gui.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(("PLAYLIST move: from=\(fromOffsets) to=\(toOffset)\n").data(using: .utf8)!)
            try? fh.close()
        }
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    // MARK: - 批量 LUT

    /// 对选中文件统一设置监看 LUT（并写入记忆库：文件 + 所在目录）
    public func setLUT(_ lut: String?, for items: [PlaylistItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            item.lut = lut
        }
        let paths = items.map(\.url.path)
        if let lut {
            db.setLUT(lut, forFiles: paths)
        } else {
            for p in paths { db.clearLUT(forFile: p) }
        }
    }

    public func remove(_ items: [PlaylistItem]) {
        let ids = Set(items.map(\.id))
        self.items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let cid = currentID, ids.contains(cid) {
            currentID = nil
        }
    }

    public func removeAll() {
        items.removeAll()
        selection.removeAll()
        currentID = nil
    }

    /// 清空选择（点击列表空白处用）；**不影响**正在播放的条目
    public func clearSelection() {
        selection.removeAll()
    }

    // MARK: - 文件类型

    public static let playableExtensions: Set<String> = [
        // 视频
        "mp4", "mkv", "mov", "m4v", "webm", "avi", "mpg", "mpeg", "ts", "m2ts",
        "mts", "wmv", "flv", "3gp", "mxf", "vob", "ogv", "m2v", "dv", "y4m", "rmvb", "rm",
        "avchd", "hevc", "h265", "h264", "m1v", "m2p", "f4v", "nsv", "wtv", "asf",
        // 音频
        "mp3", "wav", "flac", "aac", "m4a", "opus", "ogg", "wma", "aiff", "ac3", "dts", "alac",
    ]

    public static func isPlayable(_ url: URL) -> Bool {
        playableExtensions.contains(url.pathExtension.lowercased())
    }
}
