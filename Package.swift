// swift-tools-version:5.9
import PackageDescription

// CutPlayer — 监看级本地视频播放器（macOS arm64 先行）
// 音频与时钟: libmpv（视频由 FFmpeg + Metal 自绘管线负责）
// 导出内核: FFmpeg 子进程
// 记忆库: SQLite
let package = Package(
    name: "CutPlayer",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        // C shim：把 /opt/homebrew/include/mpv 的头文件暴露成 Swift 可 import 的模块
        .target(
            name: "CMPV",
            path: "Sources/CMPV",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ]
        ),
        // C shim：FFmpeg 解码 API
        .target(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ]
        ),
        // 核心库：播放核心、滤镜链、LUT 记忆库、曲线、截图/导出服务、UI
        .target(
            name: "CutPlayerKit",
            dependencies: ["CMPV", "CFFmpeg"],
            path: "Sources/CutPlayerKit",
            swiftSettings: [
                // 让 clang importer 在编译 CMPV 模块时能找到 mpv 头文件
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CoreGraphics"),
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("mpv"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("avformat"),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"),
            ]
        ),
        // 可执行入口（极薄，只调 CutPlayerKit）
        .executableTarget(
            name: "CutPlayer",
            dependencies: ["CutPlayerKit"],
            path: "Sources/CutPlayer"
        ),
        // 自研单元测试（CLT 无 XCTest，用轻量 harness，headless 运行）
        .executableTarget(
            name: "CutPlayerTests",
            dependencies: ["CutPlayerKit"],
            path: "Tests/CutPlayerTests"
        ),
    ]
)
