#include "vision/green_detector.hpp"
#include "vision/green_luma_threshold.hpp"
#include "runtime/monotonic_clock.hpp"
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace vision
{
GreenDetector::GreenDetector(const DetectorConfig &config) : Detector(config)
{
    if (config_.mode != "nv21_green")
        throw std::invalid_argument("GreenDetector requires nv21_green mode");
    build_required_y_lut();
}
void GreenDetector::prepare_buffers(int width, int /*height*/)
{
    previous_runs_.reserve(width / 2 + 1);
    current_runs_.reserve(width / 2 + 1);
    // Normal scenes contain only a few runs. Reserve enough for several rows
    // without recreating a full-frame-sized allocation; pathological noise is
    // still handled by normal vector growth.
    components_.reserve(width * 2 + 1);
}

//TO-DO 后续参数可以使用实际收集数据实现离线标定,使用svm等自动计算出最优的参数,或者使用深度学习模型进行检测,但是需要考虑到模型的大小和推理速度,所以这里暂时使用手动调参的方式
bool GreenDetector::score_candidate(uint8_t yy, uint8_t uu, uint8_t vv) const
{
    return yy >= required_y_lut_[(static_cast<unsigned>(vv) << 8) | uu];
}

void GreenDetector::build_required_y_lut()
{
    // The three colour-dominance tests depend only on the shared NV21 U/V
    // pair. The remaining green threshold is monotonic in Y, so cache the
    // first accepted Y for every possible (V,U) pair. 256 means impossible.
    for (int v = 0; v < 256; ++v)
        for (int u = 0; u < 256; ++u)
            required_y_lut_[(v << 8) | u] =
                required_green_luma(config_, static_cast<uint8_t>(u), static_cast<uint8_t>(v));
}

int GreenDetector::find_root(int label)
{
    int root = label;
    while (components_[root].parent != root)
        root = components_[root].parent;
    while (components_[label].parent != label)
    {
        const int next = components_[label].parent;
        components_[label].parent = root;
        label = next;
    }
    return root;
}

int GreenDetector::merge_components(int lhs, int rhs)
{
    lhs = find_root(lhs);
    rhs = find_root(rhs);
    if (lhs == rhs)
        return lhs;
    if (components_[lhs].pixels < components_[rhs].pixels)
        std::swap(lhs, rhs);
    Component &to = components_[lhs];
    Component &from = components_[rhs];
    from.parent = lhs;
    to.min_x = std::min(to.min_x, from.min_x);
    to.max_x = std::max(to.max_x, from.max_x);
    to.min_y = std::min(to.min_y, from.min_y);
    to.max_y = std::max(to.max_y, from.max_y);
    to.pixels += from.pixels;
    to.sum_x += from.sum_x;
    to.sum_y += from.sum_y;
    to.sum_luma += from.sum_luma;
    return lhs;
}

const std::vector<GreenDetector::Blob> &GreenDetector::find_score_blobs(const uint8_t *y_plane,
                                                                        const uint8_t *vu_plane,
                                                                        int y_row_bytes,
                                                                        int vu_row_bytes,
                                                                        const Rect &roi)
{
    const uint64_t scan_begin_us = ::runtime::monotonic_us();
    const int sx = config_.sample_step_x;
    const int sy = config_.sample_step_y;
    const int sample_w = (roi.w + sx - 1) / sx;
    components_.clear();
    previous_runs_.clear();
    current_runs_.clear();
    for (int y = roi.y; y < roi.y + roi.h; y += sy)
    {
        current_runs_.clear();
        const uint8_t *const y_row = y_plane + static_cast<size_t>(y) * y_row_bytes;
        const uint8_t *const vu_row = vu_plane + static_cast<size_t>(y / 2) * vu_row_bytes;
        int column = 0;
        while (column < sample_w)
        {
            int x = roi.x + column * sx;
            const int uv_x = x & ~1;
            if (!score_candidate(y_row[x], vu_row[uv_x + 1], vu_row[uv_x]))
            {
                ++column;
                continue;
            }
            const int first = column;
            int64_t sum_luma = 0;
            do
            {
                x = roi.x + column * sx;
                sum_luma += y_row[x];
                ++column;
                if (column >= sample_w)
                    break;
                x = roi.x + column * sx;
            } while (score_candidate(y_row[x], vu_row[(x & ~1) + 1], vu_row[x & ~1]));
            const int last = column - 1;
            const int first_x = roi.x + first * sx;
            const int last_x = roi.x + last * sx;
            const int pixels = last - first + 1;
            const int label = static_cast<int>(components_.size());
            components_.push_back({label,
                                   first_x,
                                   last_x,
                                   y,
                                   y,
                                   pixels,
                                   static_cast<int64_t>(pixels) * (first_x + last_x) / 2,
                                   static_cast<int64_t>(pixels) * y,
                                   sum_luma});
            int root = label;
            for (const Run &previous : previous_runs_)
            {
                if (previous.last + 1 < first)
                    continue;
                if (previous.first > last + 1)
                    break;
                root = merge_components(root, previous.label);
            }
            current_runs_.push_back({first, last, root});
        }
        previous_runs_.swap(current_runs_);
    }
    profile_.threshold_us += ::runtime::monotonic_us() - scan_begin_us;
    profile_.fine_samples +=
        static_cast<uint64_t>(sample_w) * static_cast<uint64_t>((roi.h + sy - 1) / sy);
    ++profile_.fine_passes;

    const uint64_t blob_begin_us = ::runtime::monotonic_us();
    auto &blobs = fine_blobs_;
    blobs.clear();
    for (int label = 0; label < static_cast<int>(components_.size()); ++label)
    {
        if (find_root(label) != label)
            continue;
        const Component &component = components_[label];
        const int bw = component.max_x - component.min_x + 1;
        const int bh = component.max_y - component.min_y + 1;
        const int area = bw * bh;
        if (component.pixels < config_.pixels_threshold || area < config_.area_threshold)
            continue;
        blobs.push_back({component.min_x,
                         component.min_y,
                         bw,
                         bh,
                         component.pixels,
                         area,
                         static_cast<int>(component.sum_x / component.pixels),
                         static_cast<int>(component.sum_y / component.pixels),
                         static_cast<float>(component.sum_luma) / component.pixels});
    }
    profile_.blob_us += ::runtime::monotonic_us() - blob_begin_us;
    return blobs;
}

const std::vector<GreenDetector::Blob> &
GreenDetector::find_chroma_block_blobs(const uint8_t *y_plane,
                                       const uint8_t *vu_plane,
                                       int y_row_bytes,
                                       int vu_row_bytes,
                                       const Rect &roi)
{
    const uint64_t scan_begin_us = ::runtime::monotonic_us();
    const int right = roi.x + roi.w;
    const int bottom = roi.y + roi.h;
    const int block_left = roi.x & ~1;
    const int block_top = roi.y & ~1;
    const int block_right = (right + 1) & ~1;
    const int block_bottom = (bottom + 1) & ~1;
    const int block_columns = (block_right - block_left) / 2;
    const int block_rows = (block_bottom - block_top) / 2;
    components_.clear();
    previous_runs_.clear();
    current_runs_.clear();

    for (int block_y = block_top; block_y < block_bottom; block_y += 2)
    {
        current_runs_.clear();
        int column = 0;
        while (column < block_columns)
        {
            const auto block_luma = [&](int block_column) -> int
            {
                const int block_x = block_left + block_column * 2;
                const uint8_t *const vu_row =
                    vu_plane + static_cast<size_t>(block_y / 2) * vu_row_bytes;
                const uint16_t required =
                    required_y_lut_[(static_cast<unsigned>(vu_row[block_x]) << 8) |
                                    vu_row[block_x + 1]];
                if (required > 255)
                    return -1;
                int brightest = -1;
                for (int y = std::max(block_y, roi.y); y < std::min(block_y + 2, bottom); ++y)
                {
                    const uint8_t *const y_row = y_plane + static_cast<size_t>(y) * y_row_bytes;
                    for (int x = std::max(block_x, roi.x); x < std::min(block_x + 2, right); ++x)
                    {
                        if (y_row[x] >= required)
                            brightest = std::max(brightest, static_cast<int>(y_row[x]));
                    }
                }
                return brightest;
            };

            int luma = block_luma(column);
            if (luma < 0)
            {
                ++column;
                continue;
            }
            const int first = column;
            int64_t sum_luma = 0;
            do
            {
                sum_luma += luma;
                ++column;
                if (column >= block_columns)
                    break;
                luma = block_luma(column);
            } while (luma >= 0);
            const int last = column - 1;
            const int first_x = std::max(block_left + first * 2, roi.x);
            const int last_x = std::min(block_left + last * 2 + 1, right - 1);
            const int first_y = std::max(block_y, roi.y);
            const int last_y = std::min(block_y + 1, bottom - 1);
            const int blocks = last - first + 1;
            const int label = static_cast<int>(components_.size());
            // Coarse moments use block centres only for candidate ranking. The
            // returned target is always recomputed from fine pixel samples.
            components_.push_back({label,
                                   first_x,
                                   last_x,
                                   first_y,
                                   last_y,
                                   blocks,
                                   static_cast<int64_t>(blocks) * (first_x + last_x) / 2,
                                   static_cast<int64_t>(blocks) * (first_y + last_y) / 2,
                                   sum_luma});
            int root = label;
            for (const Run &previous : previous_runs_)
            {
                if (previous.last + 1 < first)
                    continue;
                if (previous.first > last + 1)
                    break;
                root = merge_components(root, previous.label);
            }
            current_runs_.push_back({first, last, root});
        }
        previous_runs_.swap(current_runs_);
    }
    profile_.threshold_us += ::runtime::monotonic_us() - scan_begin_us;
    profile_.coarse_samples += static_cast<uint64_t>(block_columns) * block_rows;
    ++profile_.coarse_passes;

    const uint64_t blob_begin_us = ::runtime::monotonic_us();
    auto &blobs = coarse_blobs_;
    blobs.clear();
    for (int label = 0; label < static_cast<int>(components_.size()); ++label)
    {
        if (find_root(label) != label)
            continue;
        const Component &component = components_[label];
        const int bw = component.max_x - component.min_x + 1;
        const int bh = component.max_y - component.min_y + 1;
        blobs.push_back({component.min_x,
                         component.min_y,
                         bw,
                         bh,
                         component.pixels,
                         bw * bh,
                         static_cast<int>(component.sum_x / component.pixels),
                         static_cast<int>(component.sum_y / component.pixels),
                         static_cast<float>(component.sum_luma) / component.pixels});
    }
    profile_.blob_us += ::runtime::monotonic_us() - blob_begin_us;
    return blobs;
}

GreenDetector::Blob GreenDetector::acquire_from_chroma_blocks(const uint8_t *y_plane,
                                                              const uint8_t *vu_plane,
                                                              int y_row_bytes,
                                                              int vu_row_bytes,
                                                              const Rect &full)
{
    const std::vector<Blob> &coarse =
        find_chroma_block_blobs(y_plane, vu_plane, y_row_bytes, vu_row_bytes, full);
    Blob best = Blob::None;
    for (const Blob &candidate : coarse)
    {
        // Expand by one chroma block so the fine pass can recover boundary
        // pixels and a soft halo. Align to the configured sampled-grid phase.
        const int sx = config_.sample_step_x;
        const int sy = config_.sample_step_y;
        int left = std::max(candidate.x - 2, full.x);
        int top = std::max(candidate.y - 2, full.y);
        left = full.x + ((left - full.x) / sx) * sx;
        top = full.y + ((top - full.y) / sy) * sy;
        const int right = std::min(candidate.x + candidate.w + 2, full.x + full.w);
        const int bottom = std::min(candidate.y + candidate.h + 2, full.y + full.h);
        const Rect refine{left, top, right - left, bottom - top};
        for (const Blob &blob :
             find_score_blobs(y_plane, vu_plane, y_row_bytes, vu_row_bytes, refine))
        {
            if (!best || blob.brightness > best.brightness ||
                (blob.brightness == best.brightness && blob.pixels > best.pixels))
            {
                best = blob;
            }
        }
    }
    return best;
}

Target GreenDetector::detect_frame(const uint8_t *y_plane,
                                   const uint8_t *vu_plane,
                                   int width,
                                   int height,
                                   int y_row_bytes,
                                   int vu_row_bytes)
{
    const Rect full = full_roi(width, height);
    auto &blobs = fine_blobs_;
    blobs.clear();
    //如果上一次检测到目标,则在上一次目标位置附近的ROI内进行检测,否则在整个ROI内进行检测
    if (last_)
    {
        const Rect local = tracking_roi(full);
        find_score_blobs(y_plane, vu_plane, y_row_bytes, vu_row_bytes, local);
    }
    //如果上一帧没有检测到目标,或者上一個if语句中的局部没有检测到目标,则在整个ROI内进行检测
    if (blobs.empty())
    {
        const Blob acquired =
            acquire_from_chroma_blocks(y_plane, vu_plane, y_row_bytes, vu_row_bytes, full);
        // Fine passes leave their candidates in the shared scratch buffer.
        // Acquisition returns only the global winner, not the last fine pass.
        blobs.clear();
        if (acquired)
            blobs.push_back(acquired);
    }

    if (blobs.empty())
    {
        reset();
        return {};
    }

    size_t selected = 0;
    if (!last_)
    {
        for (size_t i = 1; i < blobs.size(); ++i)
        {
            //选取亮度最高的目标,如果亮度相同则选取像素点最多的目标
            if (blobs[i].brightness > blobs[selected].brightness ||
                (blobs[i].brightness == blobs[selected].brightness &&
                 blobs[i].pixels > blobs[selected].pixels))
                selected = i;
        }
    }
    //如果上一帧检测到目标,则选取距离上一帧目标中心点最近的目标,以实现目标跟踪
    else
    {
        int64_t best = std::numeric_limits<int64_t>::max();
        for (size_t i = 0; i < blobs.size(); ++i)
        {
            const int64_t dx = blobs[i].cx - last_.cx;
            const int64_t dy = blobs[i].cy - last_.cy;
            const int64_t distance = dx * dx + dy * dy;
            if (distance < best)
            {
                best = distance;
                selected = i;
            }
        }
    }
    last_ = blobs[selected];
    return to_target(last_);
}

} // namespace vision
