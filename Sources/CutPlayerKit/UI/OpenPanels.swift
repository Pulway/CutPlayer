import SwiftUI
import UniformTypeIdentifiers

/// NSOpenPanel 辅助
public enum OpenPanels {
    public static func pickFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "打开文件"
        panel.allowedContentTypes = [.movie, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.urls : nil
    }

    public static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "打开文件夹（递归扫描视频）"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    /// 选单个 LUT（用于"从访达选择 LUT"，只能选一个）
    public static func pickLUT() -> URL? {
        let panel = lutPanel()
        panel.allowsMultipleSelection = false
        panel.title = "选择监看 LUT"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    /// 选多个 LUT（用于"导入 LUT"，支持一次导入一批）
    public static func pickLUTs() -> [URL]? {
        let panel = lutPanel()
        panel.allowsMultipleSelection = true
        panel.title = "导入 LUT（可多选）"
        panel.prompt = "导入"
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private static func lutPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let exts = ["cube", "3dl", "csp", "m3d", "dat"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    public static func pickExportDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出片段"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
