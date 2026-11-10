#pragma once

#include <chrono>
#include <cstdint>

namespace runtime
{

// Monotonic elapsed-time clock in microseconds, independent of the board SDK.
// Its epoch is unspecified: use differences, not calendar timestamps.
inline uint64_t monotonic_us()
{
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                                     std::chrono::steady_clock::now().time_since_epoch())
                                     .count());
}

} // namespace runtime
