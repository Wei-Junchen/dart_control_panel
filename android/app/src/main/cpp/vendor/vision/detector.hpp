#pragma once
#include "vision/detector_types.hpp"
#include <memory>

namespace vision
{
// Common input validation, ROI/tracking geometry and diagnostic timing only.
// Algorithm selection happens once in make_detector(), never inside GreenDetector.
class Detector
{
public:
    virtual ~Detector() = default;

    // NV21/YVU420SP input. Row sizes are byte distances between adjacent rows,
    // including alignment padding; they may exceed the visible pixel width.
    // Sampling density is controlled separately by config.sample_step_x/y.
    Target detect_nv21(const uint8_t *y_plane,
                       const uint8_t *vu_plane,
                       int width,
                       int height,
                       int y_row_bytes,
                       int vu_row_bytes,
                       size_t y_size,
                       size_t vu_size);

    void reset();
    // Cold path: reserve/touch predictable scratch before capture or flight arm.
    // Idempotent for unchanged geometry; detect_nv21 still supports lazy preparation.
    void prepare_frame_size(int width, int height);
    const DetectorConfig &config() const
    {
        return config_;
    }
    DetectorRoi acquisition_roi(int width, int height) const;
    const char *mode_name() const
    {
        return config_.mode.c_str();
    }
    DetectorProfile last_profile() const
    {
        return profile_;
    }

protected:
    explicit Detector(const DetectorConfig &config);
    struct Rect
    {
        int x, y, w, h;
    };
    struct Blob
    {
        int x = 0, y = 0, w = 0, h = 0;
        int pixels = 0;
        int area = 0;
        int cx = -1, cy = -1;
        float brightness = 0.0f;
        float ellipse_axis_ratio = 0.0f;
        int64_t total_luma = 0;

        // Every detected blob contains at least one pixel, so pixels==0 is a
        // collision-free empty sentinel and replaces a separate state flag.
        static const Blob None;
        explicit operator bool() const noexcept
        {
            return pixels != 0;
        }
    };

    Rect full_roi(int width, int height) const;
    Rect tracking_roi(const Rect &full) const;
    Target to_target(const Blob &blob) const;
    virtual void prepare_buffers(int width, int height) = 0;
    virtual Target detect_frame(const uint8_t *y_plane,
                                const uint8_t *vu_plane,
                                int width,
                                int height,
                                int y_row_bytes,
                                int vu_row_bytes) = 0;
    DetectorConfig config_;
    DetectorProfile profile_{};
    Blob last_ = Blob::None;

private:
    int width_ = 0;
    int height_ = 0;
};

std::unique_ptr<Detector> make_detector(const DetectorConfig &config);
} // namespace vision
