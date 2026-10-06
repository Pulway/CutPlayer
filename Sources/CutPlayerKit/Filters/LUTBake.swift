import Foundation

/// LUT/曲线 烘焙：供 Metal 渲染管线使用
/// - 解析 .cube → 复合（曲线∘LUT）→ 2D 条带布局（Metal 纹理）
/// - 曲线 → 1D 采样表
public enum LUTBake {
    /// 解析 .cube，返回 (N, values)（r-fastest 顺序，N³×3）
    /// 注意：Swift Character 是字素簇，CRLF 是一个字符——split(separator:"\n") 匹配不到！
    /// 必须先用 NSString 级替换（按 UTF-16 码元）把 \r\n / \r 归一为 \n
    public static func parseCube(path: String) -> (Int, [Float])? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var text: String?
        for enc in [String.Encoding.utf8, .isoLatin1, .ascii] {
            if let s = String(data: data, encoding: enc) { text = s; break }
        }
        guard var text else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var size = 0
        var values: [Float] = []
        values.reserveCapacity(4096)
        for rawLine in normalized.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                continue
            }
            if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN") || line.hasPrefix("LUT_1D") { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count >= 3 {
                values.append(parts[0])
                values.append(parts[1])
                values.append(parts[2])
            }
        }
        guard size > 0, values.count == size * size * size * 3 else { return nil }
        return (size, values)
    }

    /// 复合 LUT：输出 = 纯 LUT 网格（曲线**不**复合进来——曲线由 Metal shader 单独应用，
    /// 保证截图/导出只含 LUT、预览才叠加曲线；否则曲线会被应用两次）
    /// 返回 (N, values) r-fastest
    @MainActor
    public static func composedValues(lutPath: String?, curve: CurveModel?) -> (Int, [Float])? {
        let lutActive = lutPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let curveActive = curve?.isActive ?? false
        guard lutActive || curveActive else { return nil }

        var size = 17
        var lutValues: [Float]? = nil
        if lutActive, let lutPath, let (n, data) = parseCube(path: lutPath) {
            size = n
            lutValues = data
        }
        let total = size * size * size
        var out = [Float](repeating: 0, count: total * 3)
        if let lutValues, lutValues.count >= total * 3 {
            for i in 0..<total {
                out[i * 3] = lutValues[i * 3]
                out[i * 3 + 1] = lutValues[i * 3 + 1]
                out[i * 3 + 2] = lutValues[i * 3 + 2]
            }
        } else {
            for i in 0..<total {
                let ri = i % size
                let gi = (i / size) % size
                let bi = i / (size * size)
                out[i * 3] = Float(ri) / Float(size - 1)
                out[i * 3 + 1] = Float(gi) / Float(size - 1)
                out[i * 3 + 2] = Float(bi) / Float(size - 1)
            }
        }
        return (size, out)
    }

    /// 2D 条带布局（Metal 纹理）：N 个 N×N 瓦片排一行（宽 N*N，高 N）
    /// 瓦片列 = b（蓝通道），瓦片内 (r,g)：像素 (px, py) = (b*n + r, g)
    /// 每 texel RGBA，A=1 —— 与 shader 采样（tile=b, x=r, y=g）严格一致
    /// 行宽按 256 字节对齐（macOS Metal bytesPerRow 要求），行尾补零
    public static func stripFromValues(n: Int, values: [Float]) -> [Float] {
        let texW = n * n
        let rowBytes = texW * 16
        let alignedRowBytes = (rowBytes + 255) & ~255
        let rowFloats = alignedRowBytes / 4   // 含 padding 的每行 float 数
        var strip = [Float](repeating: 0, count: rowFloats * n)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = (r + n * (g + n * b)) * 3
                    let px = b * n + r
                    // 行内 texel 偏移 px*4 + 行偏移 g*rowFloats（行尾 padding 保持零）
                    let idx = px * 4 + g * rowFloats
                    strip[idx] = values[i]
                    strip[idx + 1] = values[i + 1]
                    strip[idx + 2] = values[i + 2]
                    strip[idx + 3] = 1
                }
            }
        }
        return strip
    }

    /// 曲线 1D 采样表（256 级，RGBA）
    @MainActor
    public static func curveSamples(_ curve: CurveModel?) -> [Float]? {
        guard let curve, curve.isActive else { return nil }
        var samples = [Float](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let y = Float(curve.value(at: Double(i) / 255.0))
            samples[i * 4] = y
            samples[i * 4 + 1] = y
            samples[i * 4 + 2] = y
            samples[i * 4 + 3] = 1
        }
        return samples
    }
}
