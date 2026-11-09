#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <cmath>

namespace vision
{
struct DetectorConfig
{
    std::string mode = "nv21_green";
    int luma_threshold = 80; // Experimental starting value; calibrate on real Y frames.
    int ellipse_min_pixels = 9;
    float ellipse_max_axis_ratio = 2.0f;
    float ellipse_min_iou = 0.90f;
    float ellipse_green_min_fraction = 0.25f; // 0 disables the ellipse colour gate.
    float ellipse_color_scale = 1.5f;         // Expand fitted semi-axes to include the green halo.
    // The production path performs a cheap Y/UV-domain green test directly
    // inside the configured acquisition ROI.
    int green_y_min = 20; //YUV空间内绿色的亮度阈值,低于该值的像素点不考虑为绿色
    int green_g_min = 50; //RGB空间内(从YUV转换得到的)绿色的亮度阈值,低于该值的像素点不考虑为绿色
    int green_score_min = 60; // 2*G-R-B, in nominal 8-bit RGB units
    int green_rg_min = 20;    // G-R
    int green_gb_min = 20;    // G-B

    // Optional explicit acquisition ROI in output/view coordinates. If width
    // and height are both zero, the whole output frame is used.
    int roi_x = 0;
    int roi_y = 0;
    int roi_width = 0;
    int roi_height = 0;
    int search_radius = 20;
    int area_threshold = 1;
    int pixels_threshold = 1;
    // Sampling steps in image pixels/rows, NOT memory row sizes.
    // External JSON/debug keys remain x_stride/y_stride for compatibility.
    int sample_step_x = 1;
    int sample_step_y = 1;
};

inline bool valid_detector_strategy(const DetectorConfig &c)
{
    return (c.mode == "nv21_green" || c.mode == "luma_ellipse") && c.luma_threshold >= 0 &&
           c.luma_threshold <= 255 && c.ellipse_min_pixels >= 9 &&
           c.ellipse_min_pixels <= 1000000 && std::isfinite(c.ellipse_max_axis_ratio) &&
           c.ellipse_max_axis_ratio >= 1 && c.ellipse_max_axis_ratio <= 2 &&
           std::isfinite(c.ellipse_min_iou) && c.ellipse_min_iou > 0 && c.ellipse_min_iou <= 1 &&
           std::isfinite(c.ellipse_green_min_fraction) && c.ellipse_green_min_fraction >= 0 &&
           c.ellipse_green_min_fraction <= 1 && std::isfinite(c.ellipse_color_scale) &&
           c.ellipse_color_scale >= 1 && c.ellipse_color_scale <= 2;
}

struct DetectorRoi
{
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
};

struct Target
{
    bool found = false;
    int x = -1;
    int y = -1;
    int pixels = 0;
    int area = 0;
    int rect_x = 0;
    int rect_y = 0;
    int rect_w = 0;
    int rect_h = 0;
    float brightness = 0.0f;
    // Selected ellipse diagnostics for video overlay only; zero for green mode.
    float ellipse_axis_ratio = 0.0f;
    int64_t total_luma = 0;
};

// 最近一次检测的融合扫描/归并耗时，以及 coarse/fine 实际工作量。
struct DetectorProfile
{
    // Opt-in CPU clock measurement; absent/zero is not evidence of idle CPU.
    bool cpu_valid = false;
    uint64_t cpu_us = 0;
    uint64_t threshold_us = 0;
    uint64_t blob_us = 0;
    uint64_t coarse_samples = 0;
    uint64_t fine_samples = 0;
    int coarse_passes = 0;
    int fine_passes = 0;
    // Ground diagnostic counters only; do not add CSV/UDP fields.
    uint32_t ellipse_candidates = 0, ellipse_accepted = 0;
    uint32_t ellipse_reject_size = 0, ellipse_reject_ratio = 0;
    uint32_t ellipse_reject_clipped = 0, ellipse_reject_iou = 0;
    uint32_t ellipse_reject_color = 0;
    uint32_t ellipse_overflow = 0;
    float ellipse_axis_ratio = 0, ellipse_iou = 0;
};

} // namespace vision
