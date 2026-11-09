#include "vision/detector.hpp"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <time.h>

namespace vision
{
namespace
{

inline int clamp_int(int value, int low, int high)
{
    return value < low ? low : (value > high ? high : value);
}

} // namespace

const Detector::Blob Detector::Blob::None{};
Detector::Detector(const DetectorConfig &config) : config_(config)
{
    if (!valid_detector_strategy(config_))
        throw std::invalid_argument("invalid detector strategy");
    config_.sample_step_x = std::max(config_.sample_step_x, 1);
    config_.sample_step_y = std::max(config_.sample_step_y, 1);
    config_.search_radius = std::max(config_.search_radius, 1);
}
void Detector::reset()
{
    last_ = Blob::None;
}
void Detector::prepare_frame_size(int width, int height)
{
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1))
        throw std::invalid_argument("detector frame size must be positive and even");
    if (width == width_ && height == height_)
        return;
    prepare_buffers(width, height);
    width_ = width;
    height_ = height;
    reset();
}
// 显式 ROI 优先；未配置 ROI 时处理整帧，不再保留 edge_x/edge_y 隐式裁剪。
Detector::Rect Detector::full_roi(int width, int height) const
{
    if (config_.roi_width > 0 && config_.roi_height > 0)
    {
        const int left = clamp_int(config_.roi_x, 0, std::max(width - 1, 0));
        const int top = clamp_int(config_.roi_y, 0, std::max(height - 1, 0));
        const int right = clamp_int(left + config_.roi_width, left + 1, width);
        const int bottom = clamp_int(top + config_.roi_height, top + 1, height);
        return {left, top, right - left, bottom - top};
    }
    return {0, 0, width, height};
}

DetectorRoi Detector::acquisition_roi(int width, int height) const
{
    const Rect roi = full_roi(width, height);
    return {roi.x, roi.y, roi.w, roi.h};
}

Detector::Rect Detector::tracking_roi(const Rect &full) const
{
    const int right_bound = full.x + full.w;
    const int bottom_bound = full.y + full.h;
    const int radius = config_.search_radius;
    const int left = clamp_int(last_.cx - radius, full.x, right_bound - 1);
    const int top = clamp_int(last_.cy - radius, full.y, bottom_bound - 1);
    const int right = clamp_int(last_.cx + radius, left + 1, right_bound);
    const int bottom = clamp_int(last_.cy + radius, top + 1, bottom_bound);
    return {left, top, right - left, bottom - top};
}

Target Detector::to_target(const Blob &blob) const
{
    Target target;
    target.found = true;
    target.x = blob.cx;
    target.y = blob.cy;
    target.pixels = blob.pixels;
    target.area = blob.area;
    target.rect_x = blob.x;
    target.rect_y = blob.y;
    target.rect_w = blob.w;
    target.rect_h = blob.h;
    target.brightness = blob.brightness;
    target.ellipse_axis_ratio = blob.ellipse_axis_ratio;
    target.total_luma = blob.total_luma;
    return target;
}

Target Detector::detect_nv21(const uint8_t *y_plane,
                             const uint8_t *vu_plane,
                             int width,
                             int height,
                             int y_row_bytes,
                             int vu_row_bytes,
                             size_t y_size,
                             size_t vu_size)
{
    profile_ = {};
    Target none;
    // stride is the byte distance between adjacent rows, not the visible
    // width. A cropped plane may start inside an aligned row, so the last
    // row needs only visible width bytes, not a complete trailing stride.
    // Division avoids overflowing stride * rows for malformed metadata.
    if (!y_plane || !vu_plane || width <= 0 || height <= 0 || (width & 1) != 0 ||
        (height & 1) != 0 || y_row_bytes < width || vu_row_bytes < width ||
        y_size < static_cast<size_t>(width) || vu_size < static_cast<size_t>(width) ||
        static_cast<size_t>(height - 1) > (y_size - width) / static_cast<size_t>(y_row_bytes) ||
        static_cast<size_t>(height / 2 - 1) > (vu_size - width) / static_cast<size_t>(vu_row_bytes))
    {
        reset();
        return none;
    }
    static const bool profile_cpu = []
    {
        const char *value = std::getenv("DART_PROFILE_DETECT_CPU");
        return value && std::strcmp(value, "1") == 0;
    }();
    timespec cpu_begin{}, cpu_end{};
    const bool have_cpu = profile_cpu && clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu_begin) == 0;
    if (width != width_ || height != height_)
        prepare_frame_size(width, height);
    const Target target = detect_frame(y_plane, vu_plane, width, height, y_row_bytes, vu_row_bytes);
    if (have_cpu && clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu_end) == 0)
    {
        const int64_t ns = (int64_t(cpu_end.tv_sec) - int64_t(cpu_begin.tv_sec)) * 1000000000LL +
                           int64_t(cpu_end.tv_nsec) - int64_t(cpu_begin.tv_nsec);
        profile_.cpu_valid = ns >= 0;
        profile_.cpu_us = ns >= 0 ? uint64_t(ns / 1000) : 0;
    }
    return target;
}

} // namespace vision
