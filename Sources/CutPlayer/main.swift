import CutPlayerKit
import Foundation
import AppKit

// CutPlayer 入口
//
// 无头测试模式（--selftest / --decbench / --seektest / --enginetest / --seekprobe / --modelseek）：
// 只跑测试：不创建任何窗口、不抢前台、不显示 Dock 图标。
// 绝不能走 CutPlayerApp.main()——那会建出 WindowGroup 窗口，
// 而且自检结束时的 terminate 会让用户以为"软件自己关了"。
if SelfTestDriver.shouldRun {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        await SelfTestDriver.run()   // run() 内部会自行 exit
        exit(0)
    }
    app.run()
} else {
    // 正常模式：启动 GUI 应用
    CutPlayerApp.main()
}
