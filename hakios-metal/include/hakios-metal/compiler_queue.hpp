#pragma once

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>

namespace hakios::metal {

// Mesa's shared compiler is not reentrant. A running turn finishes, then all
// waiting foreground work goes before specialization / prewarm work.
class CompilerQueue {
public:
    struct Stats { uint64_t foregroundWaitNs, depth, peak; };

    void lock(bool background) {
        const auto began = std::chrono::steady_clock::now();
        std::unique_lock<std::mutex> lock(mutex_);
        ++waiting_;
        if (!background) ++foreground_;
        if (waiting_ > peak_) peak_ = waiting_;
        ready_.wait(lock, [&] { return !busy_ && (!background || foreground_ == 0); });
        --waiting_;
        if (!background) {
            --foreground_;
            foregroundWaitNs_ += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - began).count());
        }
        busy_ = true;
    }

    void unlock() {
        std::lock_guard<std::mutex> lock(mutex_);
        busy_ = false;
        ready_.notify_all();
    }

    Stats takeStats() {
        std::lock_guard<std::mutex> lock(mutex_);
        Stats out{foregroundWaitNs_, waiting_, peak_};
        foregroundWaitNs_ = 0;
        peak_ = waiting_;
        return out;
    }

private:
    std::mutex mutex_;
    std::condition_variable ready_;
    bool busy_ = false;
    uint64_t waiting_ = 0, foreground_ = 0, peak_ = 0, foregroundWaitNs_ = 0;
};

} // namespace hakios::metal
