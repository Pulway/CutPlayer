// CMPV — 桥接头文件：把 libmpv 的 C API 以模块形式暴露给 Swift。
// 只用到音频/时钟相关的 client API（视频渲染由自有 Metal 管线负责，不经过 mpv）。
// 依赖系统安装的 mpv 头文件（Homebrew: /opt/homebrew/include/mpv/*.h）
#ifndef CMPV_H
#define CMPV_H

#include <mpv/client.h>

#endif /* CMPV_H */
