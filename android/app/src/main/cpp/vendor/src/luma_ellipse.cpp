#include "vision/luma_ellipse_detector.hpp"
#include "vision/green_luma_threshold.hpp"
#include "runtime/monotonic_clock.hpp"
#include <algorithm>
#include <stdexcept>

namespace vision
{
namespace
{
double squares(int n)
{
    return double(n) * (n + 1) * (2.0 * n + 1) / 6;
}
} // namespace

LumaEllipseDetector::LumaEllipseDetector(const DetectorConfig &config) : Detector(config)
{
    if (config_.mode != "luma_ellipse")
        throw std::invalid_argument("LumaEllipseDetector requires luma_ellipse mode");
}
void LumaEllipseDetector::prepare_buffers(int width, int height)
{
    // A modest working set, not a full-frame worst-case allocation. Resize
    // then clear to construct/touch storage now, before the first target.
    // All vectors may still grow for complex scenes; no candidates are lost.
    const size_t desired = std::min<size_t>(32768, std::max<size_t>(height, size_t(width) * 2 + 1));
    size_t working = 1;
    while (working < desired)
        working *= 2; // Keep later vector growth aligned with the 32768 component limit.
    previous_runs_.resize(size_t(width) / 2 + 1);
    previous_runs_.clear();
    current_runs_.resize(size_t(width) / 2 + 1);
    current_runs_.clear();
    luma_components_.resize(working);
    luma_components_.clear();
    luma_runs_.resize(working);
    luma_runs_.clear();
    luma_heads_.resize(working);
    luma_heads_.clear();
    luma_next_.resize(working);
    luma_next_.clear();
    ellipse_spans_.resize(size_t(height) * 2 + 1);
    ellipse_spans_.clear();
}
Target LumaEllipseDetector::detect_frame(const uint8_t *y_plane,
                                         const uint8_t *vu_plane,
                                         int width,
                                         int height,
                                         int y_row_bytes,
                                         int vu_row_bytes)
{
    return detect_nv21_luma(y_plane, vu_plane, width, height, y_row_bytes, vu_row_bytes);
}

bool LumaEllipseDetector::green_dominant(const uint8_t *y_plane,
                                         const uint8_t *vu_plane,
                                         int y_row_bytes,
                                         int vu_row_bytes,
                                         const Rect &bounds,
                                         double cx,
                                         double cy,
                                         double vx,
                                         double vy,
                                         double cov) const
{
    if (config_.ellipse_green_min_fraction == 0)
        return true;
    // Colour is evaluated separately from the Y component: the bright core
    // may be white, and its green halo may fall below luma_threshold.
    const double scale2 = double(config_.ellipse_color_scale) * config_.ellipse_color_scale;
    const double det = vx * vy - cov * cov;
    const double half_height = 2 * config_.ellipse_color_scale * std::sqrt(vy);
    const int top = std::max(bounds.y, int(std::ceil(cy - half_height)));
    const int bottom = std::min(bounds.y + bounds.h - 1, int(std::floor(cy + half_height)));
    int64_t samples = 0, green = 0, sum_gr = 0, sum_gb = 0;
    for (int row = top; row <= bottom; ++row)
    {
        const double dy = row - cy;
        const double radius2 = (4 * scale2 * det - (vx - cov * cov / vy) * dy * dy) / vy;
        if (radius2 < 0)
            continue;
        const double centre = cx + cov / vy * dy, radius = std::sqrt(radius2);
        const int left = std::max(bounds.x, int(std::ceil(centre - radius)));
        const int right = std::min(bounds.x + bounds.w - 1, int(std::floor(centre + radius)));
        const auto *ys = y_plane + size_t(row) * y_row_bytes;
        const auto *vus = vu_plane + size_t(row / 2) * vu_row_bytes;
        for (int x = left; x <= right; ++x)
        {
            // Ignore dark background, but do not exclude the white core from
            // the denominator. One green pixel must not validate a white lamp.
            if (ys[x] < config_.green_y_min)
                continue;
            const uint8_t v = vus[x & ~1], u = vus[(x & ~1) + 1];
            const int d = int(u) - 128, e = int(v) - 128;
            ++samples;
            green += ys[x] >= required_green_luma(config_, u, v);
            // Unclipped BT.601 G-R / G-B: neutral white contributes zero;
            // red/blue distractors subtract instead of being ignored.
            sum_gr += -100 * d - 617 * e;
            sum_gb += -616 * d - 208 * e;
        }
    }
    return samples > 0 && green >= double(samples) * config_.ellipse_green_min_fraction &&
           sum_gr > 0 && sum_gb > 0;
}

LumaEllipseDetector::Blob LumaEllipseDetector::find_luma_ellipse(const uint8_t *y_plane,
                                                                 const uint8_t *vu_plane,
                                                                 int y_row_bytes,
                                                                 int vu_row_bytes,
                                                                 const Rect &roi,
                                                                 const Rect &color_bounds)
{
    const auto begin = ::runtime::monotonic_us();
    luma_components_.clear();
    luma_runs_.clear();
    previous_runs_.clear();
    current_runs_.clear();
    //获取一个像素段所属于的连通域,如果不是最大的连通域,则将其合并到最大的连通域中
    const auto root = [&](int label)
    {
        int r = label;
        while (luma_components_[r].parent != r)
            r = luma_components_[r].parent;
        while (label != r)
        {
            int next = luma_components_[label].parent;
            luma_components_[label].parent = r;
            label = next;
        }
        return r;
    };
    const auto merge = [&](int a, int b)
    {
        a = root(a);
        b = root(b);
        if (a == b)
            return a;
        if (luma_components_[a].pixels < luma_components_[b].pixels)
            std::swap(a, b);

        //a pixels >= b pixels, so a absorbs b. Update a's moments and bounding box.
        auto &to = luma_components_[a];
        auto &from = luma_components_[b];
        from.parent = a;
        to.min_x = std::min(to.min_x, from.min_x);
        to.max_x = std::max(to.max_x, from.max_x);
        to.min_y = std::min(to.min_y, from.min_y);
        to.max_y = std::max(to.max_y, from.max_y);
        to.pixels += from.pixels;
        to.sum_x += from.sum_x;
        to.sum_y += from.sum_y;
        to.sum_luma += from.sum_luma;
        to.sum_xx += from.sum_xx;
        to.sum_yy += from.sum_yy;
        to.sum_xy += from.sum_xy;
        return a;
    };
    // Full-resolution Y runs; no RGB conversion, chroma lookup, Hough accumulator,
    // visited bitmap or per-pixel flood-fill queue. Reuse run/component capacity.
    for (int y = roi.y; y < roi.y + roi.h; ++y)
    {
        current_runs_.clear();
        const auto *row = y_plane + size_t(y) * y_row_bytes;
        size_t previous_cursor = 0;
        int x = roi.x;
        while (x < roi.x + roi.w)
        {
            if (row[x] < config_.luma_threshold)
            {
                ++x;
                continue;
            }
            int first = x;
            int64_t luma = 0;
            do
            {
                luma += row[x++];
            } while (x < roi.x + roi.w && row[x] >= config_.luma_threshold);
            int last = x - 1, n = last - first + 1, label = int(luma_components_.size());
            // Bound memory and work in pathological bright speckle/checkerboard
            // scenes. Fail this search rather than return a stale target or OOM.
            if (luma_components_.size() >= 32768)
            {
                ++profile_.ellipse_overflow;
                profile_.threshold_us += ::runtime::monotonic_us() - begin;
                profile_.fine_samples += uint64_t(y - roi.y) * roi.w + (x - roi.x);
                ++profile_.fine_passes;
                return Blob::None;
            }
            int64_t sx = int64_t(n) * (first + last) / 2;
            luma_components_.push_back({label,
                                        first,
                                        last,
                                        y,
                                        y,
                                        n,
                                        sx,
                                        int64_t(n) * y,
                                        luma,
                                        squares(last) - squares(first - 1),
                                        double(n) * y * y,
                                        double(sx) * y});
            int r = label;
            //如果上一行的cursor index段的尾部仍然小于当前行当前段的首部,则继续向后移动cursor index,直到上一行的cursor index段的尾部大于等于当前行当前段的首部
            while (previous_cursor < previous_runs_.size() &&
                   previous_runs_[previous_cursor].last + 1 < first)
                ++previous_cursor;
            for (size_t i = previous_cursor; i < previous_runs_.size(); ++i)
            {
                const auto &previous = previous_runs_[i];
                if (previous.first > last + 1)
                    break;
                r = merge(r, previous.label);
            }
            current_runs_.push_back({first, last, r});
            luma_runs_.push_back({first, last, y, label});
        }
        previous_runs_.swap(current_runs_);
    }
    profile_.threshold_us += ::runtime::monotonic_us() - begin;
    profile_.fine_samples += uint64_t(roi.w) * roi.h;
    ++profile_.fine_passes;
    const auto fit_begin = ::runtime::monotonic_us();
    // Bucket runs by component once, avoiding candidates x all-runs scans.
    //构造每一个连通域的所有像素段的链表
    luma_heads_.assign(luma_components_.size(), -1);
    luma_next_.resize(luma_runs_.size());
    for (int i = 0; i < int(luma_runs_.size()); ++i)
    {
        int r = root(luma_runs_[i].label);
        //i像素段所属于连通域链表中下一个元素的索引
        luma_next_[i] = luma_heads_[r];
        //后一个元素的next指向前一个元素的索引,直到链表的末尾为-1,然后链表头就是最后一个元素的索引,这样就构造了一个链表,每个连通域的所有像素段都在这个链表中
        luma_heads_[r] = i;
    }
    // 在满足椭圆约束的连通域中选择总亮度最大的候选，并返回其包围盒。
    Blob best = Blob::None;
    int64_t best_total_luma = -1;
    for (int label = 0; label < int(luma_components_.size()); ++label)
    {
        const auto &c = luma_components_[label];
        //不处理不是根节点的连通域,因为根节点才是连通域的代表,其他节点都是被合并到根节点的
        if (c.parent != label)
            continue;
        ++profile_.ellipse_candidates;
        const int w = c.max_x - c.min_x + 1, h = c.max_y - c.min_y + 1;
        if (c.pixels < std::max(config_.ellipse_min_pixels, config_.pixels_threshold) ||
            w * h < config_.area_threshold)
        {
            ++profile_.ellipse_reject_size;
            continue;
        }
        // A clipped component is not evidence of a complete ellipse. In a local
        // search this forces same-frame reacquisition in the full acquisition ROI.
        if (c.min_x == roi.x || c.min_y == roi.y || c.max_x == roi.x + roi.w - 1 ||
            c.max_y == roi.y + roi.h - 1)
        {
            ++profile_.ellipse_reject_clipped;
            continue;
        }
        const double cx = double(c.sum_x) / c.pixels, cy = double(c.sum_y) / c.pixels;
        // Add each square pixel's intrinsic variance (1/12).
        const double vx = c.sum_xx / c.pixels - cx * cx + 1.0 / 12,
                     vy = c.sum_yy / c.pixels - cy * cy + 1.0 / 12;
        const double cov = c.sum_xy / c.pixels - cx * cy;
        const double delta = std::hypot(vx - vy, 2 * cov);
        const double major = (vx + vy + delta) / 2, minor = (vx + vy - delta) / 2;
        const double det = vx * vy - cov * cov;
        // A rasterized true 2:1 ellipse can measure slightly over 2 by moments
        // (24x12 semi axes -> ~2.015). Allow 1% ratio quantization tolerance.
        const double ratio_limit = config_.ellipse_max_axis_ratio * 1.01;
        if (minor <= 0 || det <= 0 || 4 * std::sqrt(minor) < 3 ||
            major > ratio_limit * ratio_limit * minor)
        {
            ++profile_.ellipse_reject_ratio;
            continue;
        }
        // Uniform filled ellipse: semi axes = 2*sqrt(covariance eigenvalues).
        // Rasterize its horizontal spans analytically; count exact mask IoU
        // against this connected component, NOT every bright pixel in its box.
        const int top = int(std::ceil(cy - 2 * std::sqrt(vy)));
        const int bottom = int(std::floor(cy + 2 * std::sqrt(vy)));
        ellipse_spans_.assign(size_t(bottom - top + 1), {1, 0});
        int64_t predicted = 0, intersection = 0;
        for (int y = top; y <= bottom; ++y)
        {
            const double dy = y - cy;
            const double radius2 = (4 * det - (vx - cov * cov / vy) * dy * dy) / vy;
            if (radius2 < 0)
                continue;
            const double centre = cx + cov / vy * dy, radius = std::sqrt(radius2);
            int left = int(std::ceil(centre - radius - 1e-9)),
                right = int(std::floor(centre + radius + 1e-9));
            ellipse_spans_[size_t(y - top)] = {left, right};
            predicted += std::max(0, right - left + 1);
        }
        for (int i = luma_heads_[label]; i >= 0; i = luma_next_[i])
        {
            const auto &r = luma_runs_[i];
            if (r.y < top || r.y > bottom)
                continue;
            const auto span = ellipse_spans_[size_t(r.y - top)];
            intersection +=
                std::max(0, std::min(r.last, span.second) - std::max(r.first, span.first) + 1);
        }
        const auto united = c.pixels + predicted - intersection;
        if (united <= 0)
            continue;
        const double iou = double(intersection) / united;
        if (iou < config_.ellipse_min_iou)
        {
            ++profile_.ellipse_reject_iou;
            continue;
        }
        if (!green_dominant(
                y_plane, vu_plane, y_row_bytes, vu_row_bytes, color_bounds, cx, cy, vx, vy, cov))
        {
            ++profile_.ellipse_reject_color;
            continue;
        }
        ++profile_.ellipse_accepted;
        const double brightness = double(c.sum_luma) / c.pixels;
        // Geometry is an acceptance gate, not part of the ranking. Compare
        // integrated Y over each accepted component, including during tracking.
        // Keep the first candidate on ties for deterministic selection.
        if (!best || c.sum_luma > best_total_luma)
        {
            best = {c.min_x, c.min_y, w, h, c.pixels, w * h, int(cx), int(cy), float(brightness)};
            best.ellipse_axis_ratio = float(std::sqrt(major / minor));
            best.total_luma = c.sum_luma;
            best_total_luma = c.sum_luma;
            profile_.ellipse_axis_ratio = best.ellipse_axis_ratio;
            profile_.ellipse_iou = float(iou);
        }
    }
    profile_.blob_us += ::runtime::monotonic_us() - fit_begin;
    return best;
}

Target LumaEllipseDetector::detect_nv21_luma(
    const uint8_t *y, const uint8_t *vu, int width, int height, int y_row_bytes, int vu_row_bytes)
{
    const auto full = full_roi(width, height);
    Blob blob = Blob::None;
    if (last_)
        blob = find_luma_ellipse(y, vu, y_row_bytes, vu_row_bytes, tracking_roi(full), full);
    if (!blob)
        blob = find_luma_ellipse(y, vu, y_row_bytes, vu_row_bytes, full, full);
    if (!blob)
    {
        reset();
        return {};
    }
    last_ = blob;
    return to_target(last_);
}
} // namespace vision
