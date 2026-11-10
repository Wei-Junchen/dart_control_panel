#pragma once
#include "vision/detector.hpp"
#include <utility>
#include <vector>

namespace vision
{
class LumaEllipseDetector final : public Detector
{
public:
    explicit LumaEllipseDetector(const DetectorConfig &config);

private:
    struct Run
    {
        int first = 0, last = 0, label = -1;
    };
    std::vector<Run> previous_runs_, current_runs_;
    struct LumaComponent
    {
        int parent, min_x, max_x, min_y, max_y, pixels;
        int64_t sum_x, sum_y, sum_luma;
        double sum_xx, sum_yy, sum_xy;
    };
    struct LumaRun
    {
        int first, last, y, label;
    };
    std::vector<LumaComponent> luma_components_;
    std::vector<LumaRun> luma_runs_;
    std::vector<int> luma_heads_, luma_next_;
    std::vector<std::pair<int, int>> ellipse_spans_;
    Blob find_luma_ellipse(const uint8_t *y,
                           const uint8_t *vu,
                           int y_row_bytes,
                           int vu_row_bytes,
                           const Rect &roi,
                           const Rect &color_bounds);
    bool green_dominant(const uint8_t *y,
                        const uint8_t *vu,
                        int y_row_bytes,
                        int vu_row_bytes,
                        const Rect &bounds,
                        double cx,
                        double cy,
                        double vx,
                        double vy,
                        double cov) const;
    Target detect_nv21_luma(const uint8_t *y,
                            const uint8_t *vu,
                            int width,
                            int height,
                            int y_row_bytes,
                            int vu_row_bytes);

    void prepare_buffers(int width, int height) override;
    Target detect_frame(const uint8_t *y_plane,
                        const uint8_t *vu_plane,
                        int width,
                        int height,
                        int y_row_bytes,
                        int vu_row_bytes) override;
};
} // namespace vision
