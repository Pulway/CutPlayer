import Foundation
import SQLite3

/// LUT 记忆库（SQLite）
/// - file_luts：精确到文件 的 LUT 记忆
/// - dir_luts：目录级默认 LUT（批量设置时自动记录目录）
/// - playback：播放进度记忆（断点续播）
public final class LUTDatabase {
    private var db: OpaquePointer?
    public let url: URL

    public init(url: URL) {
        self.url = url
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if sqlite3_open(url.path, &db) == SQLITE_OK {
            migrate()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func migrate() {
        // 注意：sqlite3_exec 支持多语句；不能用 prepare_v2（只执行第一条）
        let schema = """
        CREATE TABLE IF NOT EXISTS file_luts (
            path TEXT PRIMARY KEY,
            lut TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS dir_luts (
            dir TEXT PRIMARY KEY,
            lut TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playback (
            path TEXT PRIMARY KEY,
            pos REAL NOT NULL,
            dur REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS file_range (
            path TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS lut_library (
            path TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        guard let db else { return }
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    // MARK: - LUT lookup

    /// 取某文件的监看 LUT：先精确匹配文件，再回退到所在目录的默认 LUT
    public func lut(forFile path: String) -> String? {
        if let row = query("SELECT lut FROM file_luts WHERE path = ?", [path]).first,
           let lut = row["lut"], !lut.isEmpty {
            return lut
        }
        let dir = (path as NSString).deletingLastPathComponent
        return query("SELECT lut FROM dir_luts WHERE dir = ?", [dir]).first?["lut"]
    }

    public func lut(forDirectory dir: String) -> String? {
        query("SELECT lut FROM dir_luts WHERE dir = ?", [dir]).first?["lut"]
    }

    /// 批量设置：记录到具体文件 + 各自所在目录
    public func setLUT(_ lut: String, forFiles paths: [String]) {
        guard !paths.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let dirs = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        for p in paths {
            upsert(table: "file_luts", row: ["path": p, "lut": lut, "updated_at": String(now)])
        }
        for d in dirs {
            upsert(table: "dir_luts", row: ["dir": d, "lut": lut, "updated_at": String(now)])
        }
    }

    public func setLUT(_ lut: String, forDirectory dir: String) {
        upsert(table: "dir_luts", row: ["dir": dir, "lut": lut, "updated_at": String(Date().timeIntervalSince1970)])
    }

    public func clearLUT(forFile path: String) {
        exec("DELETE FROM file_luts WHERE path = ?", [path])
    }

    public func clearLUT(forDirectory dir: String) {
        exec("DELETE FROM dir_luts WHERE dir = ?", [dir])
    }

    // MARK: - LUT 库（预先导入的监看 LUT，供二级菜单直接套用）

    /// 已导入的 LUT（最近导入的排前面）
    public func lutLibrary() -> [String] {
        query("SELECT path FROM lut_library ORDER BY updated_at DESC", []).compactMap { $0["path"] }
    }

    /// 库里是否已有同名 LUT（按文件名判重；同名即视为同一个，不重复导入）
    public func libraryHasName(_ name: String) -> Bool {
        !query("SELECT 1 FROM lut_library WHERE name = ? LIMIT 1", [name]).isEmpty
    }

    /// 加入库；同名的已存在则**不导入**并返回 false
    @discardableResult
    public func addLUTToLibrary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if libraryHasName(name) { return false }
        upsert(table: "lut_library", row: [
            "path": path,
            "name": name,
            "updated_at": String(Date().timeIntervalSince1970),
        ])
        return true
    }

    public func removeLUTFromLibrary(_ path: String) {
        exec("DELETE FROM lut_library WHERE path = ?", [path])
    }

    // MARK: - 输入色彩范围模式（auto / limited / full，按文件记住）

    /// 取某文件的范围模式；默认 auto（交给自动判定）
    public func rangeMode(forFile path: String) -> String {
        query("SELECT mode FROM file_range WHERE path = ?", [path]).first?["mode"] ?? "auto"
    }

    public func setRangeMode(_ mode: String, forFile path: String) {
        upsert(table: "file_range", row: [
            "path": path,
            "mode": mode,
            "updated_at": String(Date().timeIntervalSince1970),
        ])
    }

    // MARK: - Playback resume

    public func rememberPlayback(path: String, position: Double, duration: Double) {
        upsert(table: "playback", row: [
            "path": path,
            "pos": String(position),
            "dur": String(duration),
            "updated_at": String(Date().timeIntervalSince1970),
        ])
    }

    public func playbackState(for path: String) -> (position: Double, duration: Double)? {
        guard let row = query("SELECT pos, dur FROM playback WHERE path = ?", [path]).first,
              let pos = Double(row["pos"] ?? ""),
              let dur = Double(row["dur"] ?? "") else { return nil }
        return (pos, dur)
    }

    // MARK: - SQL helpers

    @discardableResult
    private func exec(_ sql: String, _ params: [String] = []) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func query(_ sql: String, _ params: [String] = []) -> [[String: String]] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        var rows: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                if let text = sqlite3_column_text(stmt, i) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = ""
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ params: [String], to stmt: OpaquePointer?) {
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, SQLITE_TRANSIENT)
        }
    }

    private func upsert(table: String, row: [String: String]) {
        let cols = row.keys.joined(separator: ",")
        let marks = row.keys.map { _ in "?" }.joined(separator: ",")
        let updates = row.keys.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let sql = "INSERT INTO \(table) (\(cols)) VALUES (\(marks)) ON CONFLICT DO UPDATE SET \(updates)"
        exec(sql, Array(row.values))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
