#pragma once

#include "vision/detector_types.hpp"
#include <algorithm>
#include <cstdint>

namespace vision
{
// Minimum Y accepted for this NV21 U/V pair; 256 means no byte value passes.
// Cold LUT construction only, not a per-pixel replacement for the lookup.
inline uint16_t required_green_luma(const DetectorConfig &config, uint8_t u, uint8_t v)
{
    const int d = int(u) - 128, e = int(v) - 128;
    // Byte-domain colour differences are strictly within +/-1024; G is
    // strictly within [-256,512]. Saturating only beyond these unattainable
    // bounds preserves even extreme int configurations, without int overflow.
    const int score = std::clamp(config.green_score_min, -1024, 1024);
    const int rg = std::clamp(config.green_rg_min, -1024, 1024);
    const int gb = std::clamp(config.green_gb_min, -1024, 1024);
    if (-716 * d - 825 * e < score * 256 || -100 * d - 617 * e < rg * 256 ||
        -616 * d - 208 * e < gb * 256)
        return 256;
    const int start = std::clamp(config.green_y_min, 0, 256);
    if (start == 256)
        return 256;
    // floor((298*max(Y-16,0) - 100*d - 208*e + 128)/256) >= Gmin.
    // With a positive required numerator, ceil(n/298) gives the first C=Y-16.
    const int gmin = std::clamp(config.green_g_min, -256, 512);
    const int needed = gmin * 256 + 100 * d + 208 * e - 128;
    if (needed <= 298 * std::max(start - 16, 0))
        return static_cast<uint16_t>(start);
    return static_cast<uint16_t>(std::min(16 + (needed + 297) / 298, 256));
}
} // namespace vision
