import Foundation
import Combine

/// 亮度曲线模型（修图风格）
/// 单位空间 0...1；x = 输入亮度，y = 输出亮度。
/// 端点 (0,0) 与 (1,1) 锁定；中间点可增删拖动。
/// 插值用 Fritsch–Carlson 单调三次样条，保证不产生过冲（不回环）。
public struct CurvePoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

@MainActor
public final class CurveModel: ObservableObject {
    @Published public private(set) var points: [CurvePoint]
    @Published public var enabled: Bool = false

    public init() {
        points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    /// 是否为纯直线（无实际调整）
    public var isIdentity: Bool {
        points.count == 2
            && points[0] == CurvePoint(x: 0, y: 0)
            && points[1] == CurvePoint(x: 1, y: 1)
    }

    public var isActive: Bool { enabled && !isIdentity }

    public func reset() {
        points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        enabled = false
    }

    /// 设置控制点：去重、排序、端点锁定、夹取到 [0,1]
    public func set(_ pts: [CurvePoint]) {
        var clamped = pts.map {
            CurvePoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1))
        }
        clamped.sort { $0.x < $1.x }
        var dedup: [CurvePoint] = []
        for p in clamped where dedup.last?.x != p.x {
            dedup.append(p)
        }
        var result = dedup
        if result.first?.x != 0 { result.insert(CurvePoint(x: 0, y: 0), at: 0) }
        if result.last?.x != 1 { result.append(CurvePoint(x: 1, y: 1)) }
        if !result.isEmpty {
            result[0] = CurvePoint(x: 0, y: result[0].y)
            result[result.count - 1] = CurvePoint(x: 1, y: result[result.count - 1].y)
        }
        points = result
    }

    public func add(point: CurvePoint) {
        var p = points
        p.append(point)
        set(p)
    }

    /// 删除中间控制点（端点不可删）
    public func remove(point: CurvePoint) {
        guard points.count > 2,
              point != points.first, point != points.last,
              let idx = points.firstIndex(of: point) else { return }
        var p = points
        p.remove(at: idx)
        points = p
    }

    public func update(point: CurvePoint, to new: CurvePoint) {
        guard let idx = points.firstIndex(of: point) else { return }
        var p = points
        p[idx] = new
        set(p)
    }

    // MARK: - 样条采样

    /// Fritsch–Carlson 单调三次样条采样，输出 `count` 个点（含端点）
    public func sample(count: Int) -> [CurvePoint] {
        let pts = points
        guard pts.count >= 2, count >= 2 else { return [] }
        let n = pts.count
        var dx = [Double](repeating: 0, count: n - 1)
        var dy = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            dx[i] = pts[i + 1].x - pts[i].x
            dy[i] = pts[i + 1].y - pts[i].y
        }
        var m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            m[i] = dx[i] == 0 ? 0 : dy[i] / dx[i]
        }
        m[n - 1] = m[n - 2]
        // Fritsch–Carlson：符号一致用调和平均，否则置 0
        var mSmooth = m
        for i in 1..<(n - 1) {
            let s0 = m[i - 1], s1 = m[i]
            if (s0 > 0 && s1 > 0) || (s0 < 0 && s1 < 0) {
                mSmooth[i] = 2.0 / (1.0 / s0 + 1.0 / s1)
            } else {
                mSmooth[i] = 0
            }
        }
        var out: [CurvePoint] = []
        var targetSteps = max(1, count - 1)
        for i in 0..<(n - 1) {
            let x0 = pts[i].x, y0 = pts[i].y
            let x1 = pts[i + 1].x, y1 = pts[i + 1].y
            let h = x1 - x0
            let segSteps = max(1, Int((Double(targetSteps) * h).rounded(.up)))
            for k in 0..<segSteps {
                let t = Double(k) / Double(segSteps)
                let t2 = t * t, t3 = t2 * t
                let h00 = 2 * t3 - 3 * t2 + 1
                let h10 = t3 - 2 * t2 + t
                let h01 = -2 * t3 + 3 * t2
                let h11 = t3 - t2
                let y = h00 * y0 + h10 * h * mSmooth[i] + h01 * y1 + h11 * h * mSmooth[i + 1]
                out.append(CurvePoint(x: x0 + t * h, y: min(max(y, 0), 1)))
            }
        }
        if out.last != pts[n - 1] { out.append(pts[n - 1]) }
        return out
    }

    /// 曲线上某 x 对应的 y（自然三次样条，与 ffmpeg curves 滤镜的默认插值一致）
    public func value(at x: Double) -> Double {
        let pts = points
        guard pts.count >= 2 else { return x }
        let xx = min(max(x, 0), 1)
        guard xx > pts[0].x, xx < pts[pts.count - 1].x else {
            if xx <= pts[0].x { return pts[0].y }
            return pts[pts.count - 1].y
        }
        let n = pts.count
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { h[i] = pts[i + 1].x - pts[i].x }
        // 自然三次样条：三对角系统（M[0]=M[n-1]=0）
        var a = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            a[i] = h[i - 1]
            b[i] = 2 * (h[i - 1] + h[i])
            c[i] = h[i]
            d[i] = 6 * ((pts[i + 1].y - pts[i].y) / h[i] - (pts[i].y - pts[i - 1].y) / h[i - 1])
        }
        b[0] = 1
        b[n - 1] = 1
        // Thomas 算法
        var cp = [Double](repeating: 0, count: n)
        var dp = [Double](repeating: 0, count: n)
        cp[0] = c[0] / b[0]
        dp[0] = d[0] / b[0]
        for i in 1..<n {
            let m = b[i] - a[i] * cp[i - 1]
            if i < n - 1 { cp[i] = c[i] / m }
            dp[i] = (d[i] - a[i] * dp[i - 1]) / m
        }
        var m2 = [Double](repeating: 0, count: n)
        m2[n - 1] = dp[n - 1]
        if n >= 2 {
            for i in stride(from: n - 2, through: 0, by: -1) {
                m2[i] = dp[i] - cp[i] * m2[i + 1]
            }
        }
        // 定位段并求值
        var i = 0
        while i < n - 2 && pts[i + 1].x < xx { i += 1 }
        let t = min(max((xx - pts[i].x) / h[i], 0), 1)
        let t2 = t * t, t3 = t2 * t
        let y = (1 - t) * pts[i].y + t * pts[i + 1].y
            + (h[i] * h[i] / 6) * ((t3 - t) * m2[i + 1]
            + ((1 - t) * (1 - t) * (1 - t) - (1 - t)) * m2[i])
        return min(max(y, 0), 1)
    }

    /// 生成给 FFmpeg curves 滤镜的 point 串，如 "0/0 0.3/0.45 1/1"
    /// 直接用原始控制点（ffmpeg 内部用同样的 Catmull-Rom 插值）
    public func filterPointsString(maxPoints: Int = 32) -> String? {
        guard isActive else { return nil }
        let pts = points
        guard !pts.isEmpty else { return nil }
        let step = max(1, Int(ceil(Double(pts.count) / Double(maxPoints))))
        var sel: [CurvePoint] = []
        for i in stride(from: 0, to: pts.count, by: step) { sel.append(pts[i]) }
        if let last = pts.last, sel.last != last { sel.append(last) }
        return sel.map { "\(Self.fmt($0.x))/\(Self.fmt($0.y))" }.joined(separator: " ")
    }

    private static func fmt(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        return String(format: "%.3f", r)
    }

    // MARK: - 预设

    public enum Preset: String, CaseIterable, Identifiable {
        case identity = "正常"
        case lift = "提亮"
        case darken = "压暗"
        case contrast = "对比度"
        case softContrast = "柔和对比"
        case filmic = "胶片感"

        public var id: String { rawValue }

        public func points() -> [CurvePoint] {
            switch self {
            case .identity:
                return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
            case .lift:
                return [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.62), CurvePoint(x: 1, y: 1)]
            case .darken:
                return [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.38), CurvePoint(x: 1, y: 1)]
            case .contrast:
                return [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.12), CurvePoint(x: 0.75, y: 0.88), CurvePoint(x: 1, y: 1)]
            case .softContrast:
                return [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1)]
            case .filmic:
                return [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.33), CurvePoint(x: 0.6, y: 0.62), CurvePoint(x: 0.9, y: 0.9), CurvePoint(x: 1, y: 1)]
            }
        }
    }
}
