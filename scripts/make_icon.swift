import AppKit
import CoreGraphics
import Foundation

// CutPlayer 应用图标生成器
// 设计：蓝色渐变圆角方块（macOS squircle）+ 白色"视频框 + 播放三角"，
//       视频框右上角被斜切一分为二（Cut = 剪切），切缝露出底色。

let canvas = 1024.0
let cs = CGColorSpaceCreateDeviceRGB()

/// 超椭圆（squircle）路径：macOS 图标轮廓比普通圆角矩形更"方"
func squirclePath(in rect: CGRect, n: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * CGFloat(copysign(pow(abs(ct), 2.0 / n), ct))
        let y = cy + b * CGFloat(copysign(pow(abs(st), 2.0 / n), st))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 画一个尺寸为 px 的图标
func renderIcon(px: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = CGFloat(px) / canvas          // 缩放：所有几何按 1024 画布定义
    ctx.scaleBy(x: s, y: s)

    // ---- 背景 squircle + 渐变 ----
    let inset: CGFloat = 92
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let squircle = squirclePath(in: rect)

    // 注意：**不要**在图里烘焙投影。macOS 在 Dock / 访达 / 程序切换器里
    // 会自行给非方形图标加投影，自带投影会叠成两层，显得又重又偏。
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 渐变填充（上浅下深）
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let top = NSColor(srgbRed: 0.36, green: 0.58, blue: 1.00, alpha: 1).cgColor
    let bottom = NSColor(srgbRed: 0.09, green: 0.24, blue: 0.76, alpha: 1).cgColor
    if let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    // 顶部高光
    if let gloss = CGGradient(colorsSpace: cs,
                              colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                       NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                              locations: [0, 1]) {
        ctx.drawLinearGradient(gloss, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    }

    // ---- 前景：视频框 + 播放三角，被一条斜线切成两块 ----
    let frame = CGRect(x: 262, y: 352, width: 500, height: 340)
    let corner: CGFloat = 52
    let stroke: CGFloat = 34

    // 斜切线：45°，切掉视频框右上角（过顶边 x≈650 与右边 y≈580）
    let cutA = CGPoint(x: 610, y: 732)
    let cutB = CGPoint(x: 800, y: 542)

    /// 半平面裁剪多边形：以直线为界，保留法线正/负方向那一侧
    /// （之前这里算错成一个小三角并被推到画布外，导致前景被整块裁掉）
    func halfPlane(keepNormalPositive: Bool) -> CGPath {
        let dx = cutB.x - cutA.x, dy = cutB.y - cutA.y
        let len = (dx * dx + dy * dy).squareRoot()
        let ux = dx / len, uy = dy / len            // 单位方向（沿直线）
        let nx = -uy, ny = ux                       // 单位法线（垂直直线）
        let sign: CGFloat = keepNormalPositive ? 1 : -1
        let big: CGFloat = 4000
        let ox = nx * sign * big, oy = ny * sign * big
        // 多边形 = 直线段 + 沿**法线**方向延展出去的一块
        // （之前错误地沿直线方向延展，得到一条细带，于是把前景整块裁掉了）
        let p = CGMutablePath()
        // 半平面 = 沿直线方向拉长(±big) × 沿法线方向加宽(big)
        // （两个方向都用直线方向会退化成一条细带，把内容裁光）
        let a1 = CGPoint(x: cutA.x - ux * big, y: cutA.y - uy * big)
        let b1 = CGPoint(x: cutB.x + ux * big, y: cutB.y + uy * big)
        p.move(to: a1)
        p.addLine(to: b1)
        p.addLine(to: CGPoint(x: b1.x + ox, y: b1.y + oy))
        p.addLine(to: CGPoint(x: a1.x + ox, y: a1.y + oy))
        p.closeSubpath()
        return p
    }

    func drawContent() {
        // 视频框
        let framePath = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(framePath)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(stroke)
        ctx.strokePath()
        // 播放三角
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: 452, y: 402))
        tri.addLine(to: CGPoint(x: 452, y: 642))
        tri.addLine(to: CGPoint(x: 646, y: 522))
        tri.closeSubpath()
        ctx.addPath(tri)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
    }

    // 左下块（含播放三角）
    ctx.saveGState()
    ctx.addPath(halfPlane(keepNormalPositive: false))
    ctx.clip()
    drawContent()
    ctx.restoreGState()

    // 右上角被切下的小块：沿法线方向平移一点，形成"切开来"的观感
    ctx.saveGState()
    ctx.addPath(halfPlane(keepNormalPositive: true))
    ctx.clip()
    ctx.translateBy(x: 26, y: 26)
    drawContent()
    ctx.restoreGState()

    ctx.restoreGState()   // squircle clip
    return ctx.makeImage()
}

// ---- 输出 .iconset ----
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    guard let img = renderIcon(px: px) else { print("渲染失败: \(name)"); continue }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try? data.write(to: url)
}
// 额外输出一张 1024 预览图，便于肉眼检查
if let img = renderIcon(px: 1024) {
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("preview_1024.png"))
    }
}
print("已输出 iconset: \(outDir)")
