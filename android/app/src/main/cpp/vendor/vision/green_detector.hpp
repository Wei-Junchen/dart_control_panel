#pragma once
#include "vision/detector.hpp"
#include <array>
#include <vector>

namespace vision
{
class GreenDetector final : public Detector
{
public:
    explicit GreenDetector(const DetectorConfig &config = {});

private:
    // A run is expressed in sampled-grid columns, not byte/pixel offsets.
    // Keeping only the previous and current rows is enough for 8-connected
    // component labelling and avoids full-frame mask/visited/queue buffers.
    struct Run
    {
        int first = 0;
        int last = 0;
        int label = -1;
    };
    struct Component
    {
        int parent = -1;
        int min_x = 0, max_x = 0, min_y = 0, max_y = 0;
        int pixels = 0;
        int64_t sum_x = 0, sum_y = 0, sum_luma = 0;
    };
    void prepare_buffers(int width, int height) override;
    void build_required_y_lut();
    Target detect_frame(const uint8_t *y_plane,
                        const uint8_t *vu_plane,
                        int width,
                        int height,
                        int y_row_bytes,
                        int vu_row_bytes) override;
    const std::vector<Blob> &find_score_blobs(const uint8_t *y_plane,
                                              const uint8_t *vu_plane,
                                              int y_row_bytes,
                                              int vu_row_bytes,
                                              const Rect &roi);
    const std::vector<Blob> &find_chroma_block_blobs(const uint8_t *y_plane,
                                                     const uint8_t *vu_plane,
                                                     int y_row_bytes,
                                                     int vu_row_bytes,
                                                     const Rect &roi);
    Blob acquire_from_chroma_blocks(const uint8_t *y_plane,
                                    const uint8_t *vu_plane,
                                    int y_row_bytes,
                                    int vu_row_bytes,
                                    const Rect &full);
    bool score_candidate(uint8_t y, uint8_t u, uint8_t v) const;
    int find_root(int label);
    int merge_components(int lhs, int rhs);

    // Constructor fills every entry before lookup; no redundant zero-fill.
    std::array<uint16_t, 65536> required_y_lut_;
    std::vector<Run> previous_runs_;
    std::vector<Run> current_runs_;
    std::vector<Component> components_;
    // Refinement runs inside coarse iteration: these must not alias.
    std::vector<Blob> fine_blobs_;
    std::vector<Blob> coarse_blobs_;
};
} // namespace vision
