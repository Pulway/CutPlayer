import AppKit
import SwiftUI
import Metal
import MetalKit
import CFFmpeg

/// Metal 渲染视图：YUV→RGB + 监看 LUT（2D 条带）+ 亮度曲线 全在 GPU 完成
/// 帧来源由 frameForTime 回调提供（模型负责解码队列与同步）
public final class MetalVideoView: NSView {
    // 帧提供：按目标时间取一帧（take 语义——所有权转移给视图，视图负责 av_frame_unref；nil = 无新帧）
    public var frameForTime: ((Double) -> UnsafeMutablePointer<AVFrame>?)?
    /// 当前播放时间（秒），用于选帧
    public var timeSource: (() -> Double)?
    /// 是否处于播放/活动状态（暂停时只渲染一次）
    public var isActive: (() -> Bool)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let metalLayer = CAMetalLayer()
    private var pipeline: MTLRenderPipelineState?
    private var screenshotPipeline: MTLRenderPipelineState?

    // 纹理
    private var texY: MTLTexture?
    private var texU: MTLTexture?
    private var texV: MTLTexture?
    private var lutTexture: MTLTexture?
    private var curveTexture: MTLTexture?
    private var lutSize: Float = 0
    /// 诊断：LUT/曲线纹理是否已成功烘焙
    public private(set) var lutApplied = false
    public private(set) var curveApplied = false

    // 状态
    private var frameWidth = 0
    private var frameHeight = 0
    /// 色度平面尺寸（随像素格式变化：4:2:0 高度减半 / 4:4:4 宽度不减）
    private var frameChromaW = 0
    private var frameChromaH = 0
    private var currentFullRange = false
    /// 解码器声明的 color_range（FFmpeg 语义：1=limited/tv，2=full/pc，0=未指定）
    public var decoderColorRange = 0
    /// 输入是否 full range —— 由模型/引擎统一判定（标签 + 像素抽查 + 手动覆盖），
    /// 视图只消费结论，绝不自己按标签猜（历史 bug：把 1/2 语义写反）
    public var inputIsFullRange = false
    private var lastUploadedPTS = -1.0
    /// 帧间隔（秒）：由模型按视频帧率设置，用于判断"已显示的帧是否仍覆盖当前时间"
    public var frameInterval: Double = 1.0 / 25.0
    /// 上次 layout 的尺寸 / 时刻：拖动分栏时避免重复重活、并在拖动中暂缓绘制
    private var lastLayoutSize = CGSize.zero
    private var lastLayoutChangeAt = Date.distantPast
    private var drawableResizeTask: DispatchWorkItem?
    /// 拖动/缩放期间的最低绘制间隔（避免每帧都抢 drawable，把主线程让给鼠标事件）
    private let resizeDrawInterval: TimeInterval = 0.05
    private var lastDrawAt = Date.distantPast
    private var renderTimer: Timer?
    private var needsRedraw = true

    // 顶点：全屏四边形（x,y,u,v），随视图比例适配
    private var vertexBuffer: MTLBuffer?
    private static let quadVertices: [Float] = [
        -1, -1, 0, 1,
         1, -1, 1, 1,
        -1,  1, 0, 0,
         1,  1, 1, 0,
    ]

    public init() {
        guard let d = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal 不可用")
        }
        device = d
        commandQueue = d.makeCommandQueue()!
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = d
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        layer = metalLayer
        buildPipelines()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { false }

    /// 请求立即重绘（seek/暂停后）
    public func requestRedraw() {
        needsRedraw = true
    }

    /// 清空当前显示（切换文件时调用：避免旧视频帧 + 新 LUT 的错误组合）
    public func clearDisplay() {
        texY = nil
        texU = nil
        texV = nil
        frameWidth = 0
        frameHeight = 0
        needsRedraw = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            metalLayer.contentsScale = window?.backingScaleFactor ?? 2
            updateDrawableSize()
            startRenderLoop()
        } else {
            stopRenderLoop()
        }
    }

    public override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0, size != lastLayoutSize else { return }
        lastLayoutSize = size
        lastLayoutChangeAt = Date()
        // 只改 layer 的 frame（廉价，系统会把已有 drawable 拉伸显示）；
        // drawableSize 的重分配（= 新建 4K 纹理）延后到停稳，避免拖动中反复分配 → 掉帧
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        scheduleDrawableResize()
        // 尺寸变化必须重绘：否则暂停时缩放窗口，drawable 变了但画面没重画，
        // 旧内容被拉伸 → 视频变形（一播放就恢复，因为那时每帧都在重绘）
        needsRedraw = true
    }

    /// 停稳 80ms 后再重设 drawableSize 并重绘（拖动过程中不做昂贵分配）
    private func scheduleDrawableResize() {
        drawableResizeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateDrawableSize()
            self.needsRedraw = true
        }
        drawableResizeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
    }

    /// 必须显式设置 drawableSize（默认 0×0 → viewport 0×0 → 黑屏）
    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard target != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = target
    }

    // MARK: - 管线

    private func buildPipelines() {
        guard let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return }
        guard let vs = lib.makeFunction(name: "vs_main"),
              let fs = lib.makeFunction(name: "fs_main") else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)

        // 截图管线：输出到 rgba16Float 离屏纹理
        let sdesc = MTLRenderPipelineDescriptor()
        sdesc.vertexFunction = vs
        sdesc.fragmentFunction = fs
        sdesc.colorAttachments[0].pixelFormat = .rgba16Float
        screenshotPipeline = try? device.makeRenderPipelineState(descriptor: sdesc)
    }

    // MARK: - LUT / 曲线

    /// 设置监看 LUT 与曲线（烘焙成 GPU 纹理）
    @MainActor
    public func setColorPipeline(lutPath: String?, curve: CurveModel?) {
        lutApplied = false
        if let (n, values) = LUTBake.composedValues(lutPath: lutPath, curve: curve) {
            let strip = LUTBake.stripFromValues(n: n, values: values)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: n * n, height: n, mipmapped: false)
            desc.usage = [.shaderRead]
            if let tex = device.makeTexture(descriptor: desc) {
                // macOS 要求 bytesPerRow 256 字节对齐
                let bpr = (n * n * 16 + 255) & ~255
                strip.withUnsafeBytes { buf in
                    tex.replace(region: MTLRegionMake2D(0, 0, n * n, n),
                                mipmapLevel: 0,
                                withBytes: buf.baseAddress!,
                                bytesPerRow: bpr)
                }
                lutTexture = tex
                lutSize = Float(n)
                lutApplied = true
            }
        } else {
            lutTexture = nil
            lutSize = 0
        }

        curveApplied = false
        if let samples = LUTBake.curveSamples(curve) {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: 256, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let tex = device.makeTexture(descriptor: desc) {
                samples.withUnsafeBytes { buf in
                    tex.replace(region: MTLRegionMake2D(0, 0, 256, 1),
                                mipmapLevel: 0,
                                withBytes: buf.baseAddress!,
                                bytesPerRow: 256 * 16)
                }
                curveTexture = tex
                curveApplied = true
            }
        } else {
            curveTexture = nil
        }
        needsRedraw = true
    }

    // MARK: - 诊断日志（GUI 黑屏排查用）
    private var diagTick = 0
    private func guiLog(_ msg: String) {
        let path = "/tmp/cutplayer_gui.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write((msg + "\n").data(using: .utf8)!)
            try? fh.close()
        }
    }

    // MARK: - 渲染循环

    private func startRenderLoop() {
        guard renderTimer == nil else { return }
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.renderTick()
        }
        RunLoop.main.add(renderTimer!, forMode: .common)
    }

    private func stopRenderLoop() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    private func renderTick() {
        guard window != nil, window!.occlusionState.contains(.visible) else {
            diagTick += 1
            if diagTick % 120 == 1 { guiLog("renderTick: 窗口不可见 occluded") }
            return
        }
        let active = isActive?() ?? false
        // 正在拖动分栏/缩放窗口：降低绘制频率（最多 20Hz），把主线程留给鼠标事件。
        // 停稳后恢复正常帧率并重绘一次正确尺寸。
        if Date().timeIntervalSince(lastLayoutChangeAt) < 0.12,
           Date().timeIntervalSince(lastDrawAt) < resizeDrawInterval {
            needsRedraw = true
            return
        }
        guard needsRedraw || active else {
            diagTick += 1
            if diagTick % 120 == 1 { guiLog("renderTick: 非活动且无重绘请求") }
            return
        }
        let target = timeSource?() ?? 0
        var gotFrame = false
        var drawnPTS = -1.0
        // 已显示的帧若仍覆盖当前时间，就**不重复取帧/上传**：
        // 一帧 4K 10bit 422 约 33MB，拖动分栏/缩放窗口时每次重绘都重传会非常卡
        let covered = lastUploadedPTS >= 0
            && target >= lastUploadedPTS - 0.001
            && target < lastUploadedPTS + max(frameInterval, 0.001) - 0.001
        if !covered, let frame = frameForTime?(target) {
            gotFrame = true
            drawnPTS = ptsOfFrame?(frame) ?? -1
            upload(frame)
            av_frame_unref(frame)
        } else if !covered, diagTick % 30 == 1 {
            guiLog("renderTick: 取帧失败 t=\(target)")
        }
        let drew = drawFrame()
        lastDrawAt = Date()
        needsRedraw = false
        if drew, drawnPTS >= 0 { onFrameDrawn?(drawnPTS) }
        diagTick += 1
        if diagTick % 60 == 1 {
            guiLog("renderTick: t=\(target) frame=\(gotFrame) drew=\(drew) pause=\(isActive?() ?? true)")
        }
    }

    private func upload(_ frame: UnsafeMutablePointer<AVFrame>) {
        let w = Int(frame.pointee.width)
        let h = Int(frame.pointee.height)
        // 输入范围由引擎判定（见 VideoPlaybackEngine.applyDeclaredRange/probeRange）
        currentFullRange = inputIsFullRange
        // 色度平面尺寸**随像素格式变化**，不能一律按 w/2 × h：
        //   4:2:0 → w/2 × h/2（高度减半！按整高拷贝会读越界，画面下半部分色度全错）
        //   4:2:2 → w/2 × h
        //   4:4:4 → w   × h
        let fmtName = av_get_pix_fmt_name(AVPixelFormat(rawValue: frame.pointee.format))
            .map { String(cString: $0) } ?? ""
        let chromaW: Int
        let chromaH: Int
        if fmtName.contains("444") {
            chromaW = w; chromaH = h
        } else if fmtName.contains("420") || fmtName.contains("p010") || fmtName.contains("nv12") {
            chromaW = max(w / 2, 1); chromaH = max(h / 2, 1)
        } else {
            chromaW = max(w / 2, 1); chromaH = h          // 4:2:2 及默认
        }
        if w != frameWidth || h != frameHeight || chromaW != frameChromaW || chromaH != frameChromaH {
            frameWidth = w
            frameHeight = h
            frameChromaW = chromaW
            frameChromaH = chromaH
            let lumaDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
            lumaDesc.usage = [.shaderRead]
            let chromaDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Unorm, width: chromaW, height: chromaH, mipmapped: false)
            chromaDesc.usage = [.shaderRead]
            texY = device.makeTexture(descriptor: lumaDesc)
            texU = device.makeTexture(descriptor: chromaDesc)
            texV = device.makeTexture(descriptor: chromaDesc)
        }
        guard let texY, let texU, let texV else { return }
        let l0 = Int(frame.pointee.linesize.0)
        let l1 = Int(frame.pointee.linesize.1)
        if let p = frame.pointee.data.0 {
            texY.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                         withBytes: p, bytesPerRow: l0)
        }
        if let p = frame.pointee.data.1 {
            texU.replace(region: MTLRegionMake2D(0, 0, chromaW, chromaH), mipmapLevel: 0,
                         withBytes: p, bytesPerRow: l1)
        }
        if let p = frame.pointee.data.2 {
            texV.replace(region: MTLRegionMake2D(0, 0, chromaW, chromaH), mipmapLevel: 0,
                         withBytes: p, bytesPerRow: l1)
        }
    }

    /// 回调：某一帧真正完成上屏（参数为该帧 pts，秒）。用于测量 seek 延迟。
    public var onFrameDrawn: ((Double) -> Void)?
    /// 取帧 pts（秒）；由模型接到解码引擎
    public var ptsOfFrame: ((UnsafeMutablePointer<AVFrame>) -> Double)?

    @discardableResult
    private func drawFrame() -> Bool {
        guard let pipeline, let texY, let texU, let texV,
              let drawable = metalLayer.nextDrawable() else {
            return false
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        // 必须显式设置 viewport（默认可能为 0×0，导致无像素输出）
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                    width: Double(metalLayer.drawableSize.width),
                                    height: Double(metalLayer.drawableSize.height),
                                    znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipeline)
        // 顶点：按当前 bounds 做 aspect fit（每次绘制计算，窗口变化立即生效）
        // 存入实例变量保活（GPU 异步执行期间 buffer 必须存活）
        let verts = Self.aspectFitVertices(frameWidth: frameWidth, frameHeight: frameHeight,
                                           boundsWidth: bounds.width, boundsHeight: bounds.height)
        if diagTick % 300 == 1 {
            guiLog("aspect: frame=\(frameWidth)x\(frameHeight) bounds=\(bounds.width)x\(bounds.height) verts=\(verts.map { String(format: "%.2f", $0) }.joined(separator: ","))")
        }
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * 4, options: [])
        if let vb = vertexBuffer {
            enc.setVertexBuffer(vb, offset: 0, index: 0)
        }
        enc.setFragmentTexture(texY, index: 0)
        enc.setFragmentTexture(texU, index: 1)
        enc.setFragmentTexture(texV, index: 2)
        enc.setFragmentTexture(lutTexture, index: 3)
        enc.setFragmentTexture(curveTexture, index: 4)
        var params = SIMD4<Float>(lutSize, curveTexture != nil ? 1 : 0, currentFullRange ? 1 : 0, 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    // MARK: - 截图（带 LUT，可选曲线；渲染到离屏 16bit 纹理并回读）

    /// 截图当前帧：withCurve=false 时只有 LUT（核心需求）
    public func captureFrame(_ frame: UnsafeMutablePointer<AVFrame>, withCurve: Bool) -> NSBitmapImageRep? {
        upload(frame)
        let w = frameWidth, h = frameHeight
        guard w > 0, h > 0, let texY, let texU, let texV, let screenshotPipeline else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: desc) else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                    width: Double(w), height: Double(h),
                                    znear: 0, zfar: 1))
        enc.setRenderPipelineState(screenshotPipeline)
        // 截图用完整 uv 顶点（不 aspect 裁切——截图必须输出完整画面）
        let fullQuad: [Float] = [
            -1, -1, 0, 1,
             1, -1, 1, 1,
            -1,  1, 0, 0,
             1,  1, 1, 0,
        ]
        if let fvb = device.makeBuffer(bytes: fullQuad, length: fullQuad.count * 4, options: []) {
            enc.setVertexBuffer(fvb, offset: 0, index: 0)
        }
        enc.setFragmentTexture(texY, index: 0)
        enc.setFragmentTexture(texU, index: 1)
        enc.setFragmentTexture(texV, index: 2)
        enc.setFragmentTexture(lutTexture, index: 3)
        enc.setFragmentTexture(withCurve ? curveTexture : nil, index: 4)
        var params = SIMD4<Float>(lutSize, withCurve && curveTexture != nil ? 1 : 0, currentFullRange ? 1 : 0, 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // 回读 rgba16Float（每像素 8 字节 = 4×half）→ 8-bit RGB
        var halves = [UInt16](repeating: 0, count: w * h * 4)
        target.getBytes(&halves, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let bpr = w * 4
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<halves.count {
            let v = Float(Float16(bitPattern: halves[i]))
            let c = min(max(v, 0), 1)
            out[i] = UInt8((c * 255).rounded())
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: bpr, bitsPerPixel: 32
        ), let data = rep.bitmapData else { return nil }
        memcpy(data, &out, h * bpr)
        return rep
    }

    // MARK: - 几何

    /// aspect-fit（contain）顶点：视频完整显示、保持原始比例，窗口更宽时左右留黑、更高时上下留黑
    /// 每次绘制按当前 bounds 计算，保证窗口变化后立即正确
    private static func aspectFitVertices(frameWidth: Int, frameHeight: Int,
                                          boundsWidth: CGFloat, boundsHeight: CGFloat) -> [Float] {
        let vw = max(frameWidth, 1)
        let vh = max(frameHeight, 1)
        let bw = max(Double(boundsWidth), 1)
        let bh = max(Double(boundsHeight), 1)
        let videoAspect = Double(vw) / Double(vh)
        let viewAspect = bw / bh
        if videoAspect > viewAspect {
            // 视频更宽 → 画面高度缩小居中，上下留黑（uv 全 0-1，画面完整）
            let h = Float(viewAspect / videoAspect)
            return [
                -1, -h, 0, 1,
                 1, -h, 1, 1,
                -1,  h, 0, 0,
                 1,  h, 1, 0,
            ]
        } else {
            // 窗口更宽 → 画面宽度缩小居中，左右留黑
            let w = Float(videoAspect / viewAspect)
            return [
                -w, -1, 0, 1,
                 w, -1, 1, 1,
                -w,  1, 0, 0,
                 w,  1, 1, 0,
            ]
        }
    }

    // MARK: - 着色器源码（MSL）

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex VOut vs_main(uint vid [[vertex_id]], constant float4 *quad [[buffer(0)]]) {
        VOut o;
        o.pos = float4(quad[vid].xy, 0.0, 1.0);
        o.uv = quad[vid].zw;
        return o;
    }

    fragment float4 fs_main(VOut in [[stage_in]],
        texture2d<float> texY [[texture(0)]],
        texture2d<float> texU [[texture(1)]],
        texture2d<float> texV [[texture(2)]],
        texture2d<float> lutTex [[texture(3)]],
        texture2d<float> curveTex [[texture(4)]],
        constant float4 &params [[buffer(0)]])
    {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // 10-bit 值存在 16-bit 字里（0..1023），R16Unorm 采样后乘 65535/1023 还原 0..1
        float y = texY.sample(s, in.uv).r * (65535.0 / 1023.0);
        float u = texU.sample(s, in.uv).r * (65535.0 / 1023.0);
        float v = texV.sample(s, in.uv).r * (65535.0 / 1023.0);
        // BT.709 YUV→RGB：按 color_range 选择矩阵（pc=full / tv=limited）
        float3 rgb;
        if (params.z > 0.5) {
            // full range（PC）：无偏移无缩放
            float uc = u - 0.5;
            float vc = v - 0.5;
            rgb = float3(
                y + 1.5748 * vc,
                y - 0.1873 * uc - 0.4681 * vc,
                y + 1.8556 * uc);
        } else {
            // limited range（TV）：16-235 缩放 + 128 色度偏移
            float yv = max(y - 16.0 / 255.0, 0.0) * 1.164;
            float uc = u - 128.0 / 255.0;
            float vc = v - 128.0 / 255.0;
            rgb = float3(
                yv + 1.793 * vc,
                yv - 0.213 * uc - 0.533 * vc,
                yv + 2.112 * uc);
        }
        rgb = clamp(rgb, 0.0, 1.0);
        // 监看 LUT（2D 条带：tile 列 = b，瓦片内 x=r, y=g；texel-center 采样）
        // x 轴总宽 n*n（瓦片内 n 列），y 轴总高 n（瓦片内 n 行）
        if (params.x > 0.0) {
            float n = params.x;
            float tile = clamp(rgb.b, 0.0, 0.999999) * n;
            float tileCol = floor(tile);
            float2 uvL = float2(
                (rgb.r * (n - 1.0) + 0.5) / n / n + tileCol / n,
                (rgb.g * (n - 1.0) + 0.5) / n);
            rgb = lutTex.sample(s, uvL).rgb;
        }
        // 亮度曲线（LUT 之后）
        if (params.y > 0.5) {
            rgb = float3(curveTex.sample(s, float2(rgb.r, 0.5)).r,
                         curveTex.sample(s, float2(rgb.g, 0.5)).r,
                         curveTex.sample(s, float2(rgb.b, 0.5)).r);
        }
        return float4(rgb, 1.0);
    }
    """
}

/// SwiftUI 包装
public struct MetalPlayerView: NSViewRepresentable {
    private let view: MetalVideoView

    public init(view: MetalVideoView) {
        self.view = view
    }

    public func makeNSView(context: Context) -> NSView {
        view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
