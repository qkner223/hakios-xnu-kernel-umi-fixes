#include "hakios-metal/gpu.hpp"
#include "hakios-metal/perf.h"
#include "hakios-metal/bo_cache.hpp"
#include <atomic>
#include <mutex>
#include <algorithm>
#include <list>
#include <unordered_map>

#include <cerrno>
#include <cstring>
#include <unistd.h>

namespace {
std::atomic<bool> perfEnabled{false};
std::mutex perfLock;
hm_perf_stat perfStats[HM_PERF_COUNT]{};
thread_local uint64_t boContext = 0;
std::atomic<uint64_t> boStats[HM_BO_STAT_COUNT]{};
std::atomic<int> boFitEnabled{-1};
}
uint64_t hakios_metal_bo_context(uint64_t context) {
    return std::exchange(boContext, context);
}
int hakios_metal_bo_cache_fit_enabled(void) {
    int on = boFitEnabled.load(std::memory_order_relaxed);
    if (on < 0) {
        on = access("/var/db/hakios-metal-cache/bo-cache-fit-off", F_OK) != 0;
        boFitEnabled.store(on, std::memory_order_relaxed);
    }
    return on;
}
void hakios_metal_bo_cache_fit_set(int on) { boFitEnabled.store(on != 0, std::memory_order_relaxed); }
void hakios_metal_bo_cache_take(uint64_t out[HM_BO_STAT_COUNT]) {
    for (unsigned i = 0; i < HM_BO_STAT_COUNT; ++i)
        out[i] = i < HM_BO_COUNTER_COUNT ? boStats[i].exchange(0) : boStats[i].load();
}
void hakios_metal_perf_enable(int on) { perfEnabled.store(on != 0, std::memory_order_relaxed); }
int hakios_metal_perf_enabled(void) { return perfEnabled.load(std::memory_order_relaxed); }
void hakios_metal_perf_add(unsigned slot, uint64_t wall, uint64_t cpu, uint64_t bytes) {
    std::lock_guard<std::mutex> lock(perfLock);
    auto& s = perfStats[slot];
    ++s.count; s.wall += wall; s.cpu += cpu; s.max = std::max(s.max, wall); s.bytes += bytes;
}
void hakios_metal_perf_take(hm_perf_stat out[HM_PERF_COUNT]) {
    std::lock_guard<std::mutex> lock(perfLock);
    std::copy(std::begin(perfStats), std::end(perfStats), out);
    for (auto& s : perfStats) s = {};
}

namespace hakios::metal {

namespace {
constexpr uint64_t kPage = 0x4000;  // Darwin's page; the driver rounds to its own (4 KB) inside it

// Keep the kernel object, its IOVA and its user mapping together. The existing
// queue completion thread publishes successful waits here; allocation never
// polls WAIT_FENCE (the kernel treats a zero deadline as a broken caller clock).
// The transport owns the cache so all retained mappings die before IOServiceClose.
class BoCacheTransport final : public Transport {
    struct Entry {
        uint32_t handle, flags;
        uint64_t size, key, iova = 0;
        void* cpu = nullptr;
        std::unordered_map<uint32_t, uint32_t> fences;
        bool memoryless() const { return key >> 56 == HM_BO_MEMORYLESS; }
    };
    // Maps' full-size 4x colour + Z/S pair is 96 MiB. Two retired generations
    // must fit together; a separate 128 MiB cap evicts the next frame's pair.
    static constexpr uint64_t kLimit = 256ull << 20;
    static constexpr size_t kCountLimit = 512;
    std::unique_ptr<Transport> transport_;
    std::mutex lock_;
    std::unordered_map<uint32_t, Entry> active_;
    std::list<Entry> idle_;  // oldest release first; pending fences count against the limits too
    std::unordered_map<uint32_t, uint32_t> completed_;
    uint64_t bytes_ = 0, memorylessBytes_ = 0;

    bool ready(const Entry& e) const {
        for (const auto& [queue, fence] : e.fences) {
            auto it = completed_.find(queue);
            if (it == completed_.end() || int32_t(it->second - fence) < 0) return false;
        }
        return true;
    }
    void account(const Entry& e, bool add) {
        const uint64_t delta = add ? e.size : -e.size;
        bytes_ += delta;
        boStats[HM_BO_CACHED_BYTES] += delta;
        boStats[HM_BO_CACHED_COUNT] += add ? 1 : -uint64_t(1);
        if (e.memoryless()) {
            memorylessBytes_ += delta;
            boStats[HM_BO_MEMORYLESS_BYTES] += delta;
        }
    }
    void unmapReal(uint32_t handle, void* cpu) {
        auto mark = hm_perf_begin();
        transport_->unmap(handle, cpu);
        ++boStats[HM_BO_UNMAPS];
        if (mark.wall) boStats[HM_BO_UNMAP_NS] += hm_perf_clock(CLOCK_MONOTONIC) - mark.wall;
    }
    void closeReal(const Entry& e) {
        if (e.cpu != nullptr) unmapReal(e.handle, e.cpu);
        DrmGemClose c{e.handle, 0};
        transport_->call(kGemClose, &c, sizeof(c));
    }
    void evict(std::list<Entry>::iterator it) {
        account(*it, false);
        closeReal(*it); // kernel defers a busy BO's destruction until its fence retires
        idle_.erase(it);
        ++boStats[HM_BO_EVICTIONS];
    }
    int allocate(MsmGemNew& n) {
        ++boStats[HM_BO_ALLOCATIONS];
        const uint64_t key = boContext;
        if (key >> 56 == HM_BO_MEMORYLESS) n.flags |= kBoUncleared;
        const bool cacheable = key != 0 && n.size <= kLimit;
        /* A window that grows by a row asks for one page's worth more, and a blur
         * chain at the next animation frame is the same texture a few rows shorter.
         * Exact-size matching threw all of those away; a BO at most one page (or an
         * eighth of the request) larger is the same kind of memory and serves it
         * without GEM_NEW, an IOVA lookup or a map. Nothing is allocated larger, so
         * the retained bytes do not grow. Small requests get a smaller absolute
         * allowance, so a 4 KiB texture does not hold a whole page of slack. */
        const uint64_t floorSlack = kPage / 4;
        const uint64_t slack = n.size >= 4 * kPage ? std::max<uint64_t>(kPage, n.size / 8)
                                                   : std::max<uint64_t>(floorSlack, n.size / 8);
        std::unique_lock<std::mutex> guard(lock_);
        if (cacheable) {
            /* Best fit: the smallest idle BO that is large enough and not much larger. */
            auto found = idle_.end();
            const bool fit = hakios_metal_bo_cache_fit_enabled() != 0;
            for (auto it = idle_.begin(); it != idle_.end(); ++it) {
                if (it->flags != n.flags || it->key != key) continue;
                if (it->size < n.size) continue;
                if (it->size > n.size && (!fit || it->size - n.size > slack)) continue;
                if (!ready(*it)) { ++boStats[HM_BO_BUSY]; continue; }
                if (found == idle_.end() || it->size < found->size) found = it;
            }
            if (found != idle_.end()) {
                Entry e = std::move(*found);
                const uint64_t waste = e.size - n.size;
                account(e, false);
                idle_.erase(found);
                n.handle = e.handle;
                void* cpu = e.cpu;
                e.fences.clear();
                if (e.memoryless()) ++boStats[HM_BO_MEMORYLESS_HITS];
                active_.emplace(e.handle, std::move(e));
                ++boStats[HM_BO_HITS];
                if (waste != 0) {
                    ++boStats[HM_BO_FIT_HITS];
                    boStats[HM_BO_FIT_WASTE_BYTES] += waste;
                }
                guard.unlock();
                // Match GEM_NEW's existing zero-initialization contract. Attachments
                // and memoryless storage explicitly permit undefined initial contents.
                if (!(n.flags & kBoUncleared)) {
                    auto mark = hm_perf_begin();
                    memset(cpu, 0, n.size);
                    if (mark.wall) boStats[HM_BO_ZERO_NS] += hm_perf_clock(CLOCK_MONOTONIC) - mark.wall;
                }
                return 0;
            }
        }
        guard.unlock();
        auto mark = hm_perf_begin();
        int error = transport_->call(kGemNew, &n, sizeof(n));
        hm_perf_end(HM_PERF_NEW_IOCTL, mark, n.size);
        if (mark.wall) boStats[HM_BO_ALLOC_NS] += hm_perf_clock(CLOCK_MONOTONIC) - mark.wall;
        if (error == 0) {
            ++boStats[HM_BO_NEW]; // GEM_NEW requests; kernel physical-pool misses are a separate kernel counter
            if (cacheable) {
                guard.lock();
                active_.emplace(n.handle, Entry{n.handle, n.flags, n.size, key, 0, nullptr, {}});
            }
        }
        return error;
    }
public:
    explicit BoCacheTransport(std::unique_ptr<Transport> t) : transport_(std::move(t)) {}
    ~BoCacheTransport() override {
        for (const auto& e : idle_) { account(e, false); closeReal(e); }
    }
    int call(uint32_t request, void* data, size_t size) override {
        if (request == kGemNew) return allocate(*static_cast<MsmGemNew*>(data));
        if (request == kGemInfo) {
            auto& info = *static_cast<MsmGemInfo*>(data);
            std::unique_lock<std::mutex> guard(lock_);
            auto it = active_.find(info.handle);
            if (it != active_.end() && info.info == kInfoGetIova && it->second.iova != 0) {
                info.value = it->second.iova;
                return 0;
            }
            const bool record = it != active_.end() && info.info == kInfoGetIova;
            guard.unlock();
            HMPerfScope actual(HM_PERF_IOVA);
            int error = transport_->call(request, data, size);
            if (error == 0 && record) {
                guard.lock();
                active_.at(info.handle).iova = info.value;
            }
            return error;
        }
        if (request == kGemClose) {
            std::lock_guard<std::mutex> guard(lock_);
            auto it = active_.find(static_cast<DrmGemClose*>(data)->handle);
            if (it != active_.end()) {
                Entry e = std::move(it->second);
                active_.erase(it);
                if (e.cpu == nullptr) return transport_->call(request, data, size); // failed allocation
                account(e, true);
                idle_.push_back(std::move(e));
                while (bytes_ > kLimit || idle_.size() > kCountLimit) evict(idle_.begin());
                return 0;
            }
            return transport_->call(request, data, size);
        }
        int error = transport_->call(request, data, size);
        if (error == 0 && request == kGemSubmit) {
            const auto& s = *static_cast<MsmGemSubmit*>(data);
            const auto* bos = reinterpret_cast<const MsmSubmitBo*>(uintptr_t(s.bos));
            std::lock_guard<std::mutex> guard(lock_);
            for (unsigned i = 0; i < s.nr_bos; ++i) {
                auto it = active_.find(bos[i].handle);
                if (it == active_.end()) continue;
                auto& fence = it->second.fences[s.queueid];
                if (fence == 0 || int32_t(s.fence - fence) > 0) fence = s.fence;
            }
        } else if (error == 0 && request == kWaitFence) {
            const auto& w = *static_cast<MsmWaitFence*>(data);
            std::lock_guard<std::mutex> guard(lock_);
            auto& fence = completed_[w.queueid];
            if (fence == 0 || int32_t(w.fence - fence) > 0) fence = w.fence;
        } else if (error == 0 && request == kSubmitQueueClose) {
            const uint32_t queue = *static_cast<uint32_t*>(data);
            std::lock_guard<std::mutex> guard(lock_);
            auto done = completed_.find(queue);
            auto retire = [&](Entry& e) {
                auto use = e.fences.find(queue);
                if (use != e.fences.end() && done != completed_.end() && int32_t(done->second - use->second) >= 0)
                    e.fences.erase(use);
            };
            for (auto& [handle, e] : active_) retire(e);
            for (auto& e : idle_) retire(e);
            completed_.erase(queue);
        }
        return error;
    }
    void* map(uint32_t handle, uint64_t size) override {
        std::unique_lock<std::mutex> guard(lock_);
        auto it = active_.find(handle);
        if (it != active_.end() && it->second.cpu != nullptr) return it->second.cpu;
        const bool record = it != active_.end();
        guard.unlock();
        auto mark = hm_perf_begin();
        void* cpu = transport_->map(handle, size);
        hm_perf_end(HM_PERF_MAP, mark, size);
        ++boStats[HM_BO_MAPS];
        if (mark.wall) boStats[HM_BO_MAP_NS] += hm_perf_clock(CLOCK_MONOTONIC) - mark.wall;
        if (record) {
            guard.lock();
            active_.at(handle).cpu = cpu;
        }
        return cpu;
    }
    void unmap(uint32_t handle, void* address) override {
        std::lock_guard<std::mutex> guard(lock_);
        if (active_.count(handle) == 0) unmapReal(handle, address);
    }
    int64_t nowNs() override { return transport_->nowNs(); }
};

MsmTimespec deadline(Transport& t, int64_t ns) {
    // the driver takes a deadline, not a length: a time of the clock that goes on while the machine sleeps
    // (mach_continuous_time, which is Darwin's CLOCK_MONOTONIC), as Linux's msm takes one of CLOCK_MONOTONIC
    if (ns < 0) {
        ns = 0;
    }
    int64_t at = t.nowNs() + ns;
    return MsmTimespec{at / 1000000000, at % 1000000000};
}
}  // namespace

Gpu::Gpu(std::unique_ptr<Transport> transport) : t_(new BoCacheTransport(std::move(transport))) {}

int Gpu::param(uint32_t which, uint64_t* value) {
    MsmParam p{};
    p.pipe = kPipe3D;
    p.param = which;
    int e = t_->call(kGetParam, &p, sizeof(p));
    if (e == 0) {
        *value = p.value;
    }
    return e;
}

uint32_t Gpu::chipId() {
    uint64_t v = 0;
    return param(kParamChipId, &v) == 0 ? uint32_t(v) : 0;
}

uint64_t Gpu::faults() {
    uint64_t v = 0;
    return param(kParamFaults, &v) == 0 ? v : 0;
}

bool Gpu::givenUp(uint32_t fence) {
    MsmParam p{};
    p.pipe = kPipe3D;
    p.param = kParamGivenUp;
    p.value = fence;
    return t_->call(kGetParam, &p, sizeof(p)) != 0 || p.value != 0;
}

std::unique_ptr<Bo> Gpu::newBo(uint64_t size, uint32_t flags, int* error) {
    HMPerfScope total(HM_PERF_BO, size);
    *error = 0;
    if (size == 0) {
        *error = EINVAL;
        return nullptr;
    }
    MsmGemNew n{};
    n.size = (size + kPage - 1) & ~(kPage - 1);
    n.flags = flags;
    *error = t_->call(kGemNew, &n, sizeof(n));
    if (*error != 0) {
        return nullptr;
    }
    MsmGemInfo info{};
    info.handle = n.handle;
    info.info = kInfoGetIova;
    *error = t_->call(kGemInfo, &info, sizeof(info));
    if (*error != 0) {
        DrmGemClose c{n.handle, 0};
        t_->call(kGemClose, &c, sizeof(c));
        return nullptr;
    }
    void* cpu = t_->map(n.handle, n.size);
    if (cpu == nullptr) {
        DrmGemClose c{n.handle, 0};
        t_->call(kGemClose, &c, sizeof(c));
        *error = ENOMEM;
        return nullptr;
    }
    std::unique_ptr<Bo> bo(new Bo(*this, n.handle, n.size, info.value, cpu));
    bo->counted_ = true;
    allocated_ += n.size;
    return bo;
}

std::unique_ptr<Bo> Gpu::surfaceBo(uint32_t surfaceId, SurfaceInfo* out, int* error) {
    HakiosSurface s{};
    s.surface = surfaceId;
    if ((*error = t_->call(kHakiosSurface, &s, sizeof(s))) != 0) {
        return nullptr;
    }
    MsmGemInfo info{};
    info.handle = s.handle;
    info.info = kInfoGetIova;
    if ((*error = t_->call(kGemInfo, &info, sizeof(info))) != 0) {
        DrmGemClose c{s.handle, 0};
        t_->call(kGemClose, &c, sizeof(c));
        return nullptr;
    }
    *out = SurfaceInfo{s.size, s.offset, s.rowBytes, s.width, s.height, s.pixelFormat, s.planes};
    return std::unique_ptr<Bo>(new Bo(*this, s.handle, s.size, info.value, t_->map(s.handle, s.size)));
}

void Gpu::disown(std::unique_ptr<Bo> bo) {
    if (bo == nullptr) return;
    if (bo->cpu_ != nullptr) {
        t_->unmap(bo->handle_, bo->cpu_);
        bo->cpu_ = nullptr;
    }
    bo->owned_ = false;
    if (bo->counted_) {
        allocated_ -= bo->size_;
        bo->counted_ = false;
    }
}

Bo::~Bo() { gpu_.release(*this); }

void Gpu::release(Bo& bo) {
    if (!bo.owned_) {
        return;
    }
    if (bo.counted_) {
        allocated_ -= bo.size_;
        bo.counted_ = false;
    }
    if (bo.cpu_ != nullptr) {
        t_->unmap(bo.handle_, bo.cpu_);
    }
    DrmGemClose c{bo.handle_, 0};
    t_->call(kGemClose, &c, sizeof(c));
}

int Gpu::newQueue(uint32_t priority, uint32_t* id) {
    MsmSubmitQueue q{0, priority, 0};
    int e = t_->call(kSubmitQueueNew, &q, sizeof(q));
    if (e == 0) {
        *id = q.id;
    }
    return e;
}

void Gpu::closeQueue(uint32_t id) {
    if (id != 0) {
        uint32_t q = id;
        t_->call(kSubmitQueueClose, &q, sizeof(q));
    }
}

int Gpu::submit(uint32_t queue, const Bo& commands, uint32_t offsetBytes, uint32_t words, const std::vector<BoUse>& uses,
                uint32_t* fence) {
    return submit(queue, commands, offsetBytes, {{0u, words}}, uses, fence);
}

int Gpu::submit(uint32_t queue, const Bo& commands, uint32_t offsetBytes, const std::vector<std::pair<uint32_t, uint32_t>>& pieces,
                const std::vector<BoUse>& uses, uint32_t* fence) {
    if (pieces.empty() || offsetBytes % 4 != 0) {
        return EINVAL;
    }
    for (const auto& [first, words] : pieces) {
        if (words == 0 || offsetBytes + 4ull * (uint64_t(first) + words) > commands.size()) return EINVAL;
    }
    auto mark = hm_perf_begin();
    // the command buffer is the first of the buffers; the others follow it once each, read or written
    std::vector<MsmSubmitBo> bos;
    bos.push_back(MsmSubmitBo{kSubmitBoRead, commands.handle(), commands.gpuAddress()});
    for (const BoUse& u : uses) {
        if (u.bo == &commands) {
            continue;
        }
        bool seen = false;
        for (MsmSubmitBo& b : bos) {
            if (b.handle == u.bo->handle()) {
                b.flags |= u.write ? kSubmitBoWrite : kSubmitBoRead;
                seen = true;
            }
        }
        if (!seen) {
            bos.push_back(MsmSubmitBo{u.write ? kSubmitBoWrite : kSubmitBoRead, u.bo->handle(), u.bo->gpuAddress()});
        }
    }
    std::vector<MsmSubmitCmd> cmds(pieces.size());
    for (size_t i = 0; i < pieces.size(); i++) {
        cmds[i].type = kSubmitCmdBuf;
        cmds[i].submit_idx = 0;
        cmds[i].submit_offset = offsetBytes + 4 * pieces[i].first;
        cmds[i].size = pieces[i].second * 4;
    }
    MsmGemSubmit s{};
    s.flags = kPipe3D;
    s.nr_bos = uint32_t(bos.size());
    s.nr_cmds = uint32_t(cmds.size());
    s.bos = uint64_t(uintptr_t(bos.data()));
    s.cmds = uint64_t(uintptr_t(cmds.data()));
    s.fence_fd = -1;
    s.queueid = queue;
    hm_perf_end(HM_PERF_BO_LIST, mark, 0);
    mark = hm_perf_begin();
    int e = t_->call(kGemSubmit, &s, sizeof(s));
    hm_perf_end(HM_PERF_SUBMIT_IOCTL, mark, 0);
    if (e == 0) {
        *fence = s.fence;
    }
    return e;
}

int Gpu::wait(uint32_t queue, uint32_t fence, int64_t timeoutNs) {
    MsmWaitFence w{};
    w.fence = fence;
    w.timeout = deadline(*t_, timeoutNs);
    w.queueid = queue;
    return t_->call(kWaitFence, &w, sizeof(w));
}

int Gpu::cpuPrep(const Bo& bo, uint32_t op, int64_t timeoutNs) {
    MsmGemCpuPrep p{bo.handle(), op, deadline(*t_, timeoutNs)};
    return t_->call(kGemCpuPrep, &p, sizeof(p));
}

void Gpu::cpuFini(const Bo& bo) {
    MsmGemCpuFini f{bo.handle()};
    t_->call(kGemCpuFini, &f, sizeof(f));
}

}  // namespace hakios::metal
