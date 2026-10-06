// CFFmpeg — 桥接 FFmpeg 的 C API 给 Swift 使用
#ifndef CFFMPEG_H
#define CFFMPEG_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/frame.h>
#include <libavutil/pixdesc.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/rational.h>
#include <libavutil/error.h>

// AVERROR_EOF 是复杂宏，Swift 导入不了，用辅助函数
static inline int ffmpeg_is_eof(int r) { return r == AVERROR_EOF; }

#endif /* CFFMPEG_H */

// AVERROR(EAGAIN)：宏无法从 Swift 导入，提供可移植的等价物
#include <errno.h>
static inline int ff_av_error_eagain(void) { return -EAGAIN; }
