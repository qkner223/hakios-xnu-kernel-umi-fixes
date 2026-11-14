#include "hakios-metal/bo_cache.hpp"
#include "hakios-metal/fake_gpu.hpp"
#include "hakios-metal/perf.h"
#include "hakios-metal/pm4.hpp"
#include "hakios-metal/texture.hpp"
#include "test.hpp"
#include <cerrno>
#include <cstring>
#include <thread>
#include <algorithm>
#include <unordered_map>

using namespace hakios::metal;

namespace {
struct Counts { unsigned news = 0, infos = 0, maps = 0, unmaps = 0, closes = 0, waits = 0; };
class CountingGpu : public FakeGpu {
public:
    explicit CountingGpu(Counts& counts, bool async = false) : FakeGpu(async), counts(counts) {}
    Counts& counts;
    bool failMap = false, failInfo = false, failNew = false, failSubmit = false;
    int call(uint32_t r, void* p, size_t n) override {
        if (r == kGemNew) { ++counts.news; if (failNew) return ENOMEM; }
        if (r == kGemInfo) { ++counts.infos; if (failInfo) return EIO; }
        if (r == kGemClose) ++counts.closes;
        if (r == kWaitFence) ++counts.waits;
        if (r == kGemSubmit && failSubmit) return EIO;
        return FakeGpu::call(r, p, n);
    }
    void* map(uint32_t h, uint64_t n) override { ++counts.maps; return failMap ? nullptr : FakeGpu::map(h, n); }
    void unmap(uint32_t h, void* p) override { ++counts.unmaps; FakeGpu::unmap(h, p); }
};
std::unique_ptr<Bo> resource(Gpu& gpu, uint64_t size = 4096, unsigned format = 80,
                             unsigned usage = 4, unsigned kind = HM_BO_TEXTURE, unsigned flags = kBoWriteCombined) {
    uint64_t previous = hakios_metal_bo_context(hm_bo_key(format, usage, kind));
    int error = 0;
    auto bo = gpu.newBo(size, flags, &error);
    hakios_metal_bo_context(previous);
    CHECK_EQ(error, 0);
    CHECK(bo != nullptr);
    return bo;
}
std::unique_ptr<Bo> commands(Gpu& gpu) {
    int error = 0;
    auto bo = gpu.newBo(4096, 0, &error);
    CHECK_EQ(error, 0);
    static_cast<uint32_t*>(bo->cpu())[0] = pm4::type7(pm4::kNop, 0);
    return bo;
}
}

TEST(bo_cache_retains_handle_mapping_iova_and_zero_contract) {
    Counts c;
    {
        Gpu gpu(std::make_unique<CountingGpu>(c));
        auto a = resource(gpu);
        auto handle = a->handle(); auto address = a->gpuAddress(); auto cpu = a->cpu();
        memset(cpu, 0xa5, a->size());
        a.reset();
        CHECK_EQ(gpu.allocatedBytes(), 0ull); // Metal's live-resource accounting excludes the cache
        CHECK_EQ(c.unmaps, 0u); CHECK_EQ(c.closes, 0u);
        auto b = resource(gpu, 16384); // same rounded size
        CHECK_EQ(b->handle(), handle); CHECK_EQ(b->gpuAddress(), address); CHECK(b->cpu() == cpu);
        auto* p = static_cast<const uint8_t*>(b->cpu());
        bool zero = true;
        for (size_t i = 0; i < b->size(); ++i) zero &= p[i] == 0;
        CHECK(zero);
        CHECK_EQ(c.news, 1u); CHECK_EQ(c.infos, 1u); CHECK_EQ(c.maps, 1u);
    }
    CHECK_EQ(c.unmaps, 1u); CHECK_EQ(c.closes, 1u); // transport teardown drains the cache
}

TEST(bo_cache_keys_separate_format_usage_flags_size_and_memoryless) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    auto a = resource(gpu); auto handle = a->handle(); a.reset();
    auto format = resource(gpu, 4096, 81);
    auto usage = resource(gpu, 4096, 80, 1);
    auto flags = resource(gpu, 4096, 80, 4, HM_BO_TEXTURE, kBoWriteCombined | kBoUncleared);
    auto size = resource(gpu, 32768);
    auto memoryless = resource(gpu, 4096, 80, 4, HM_BO_MEMORYLESS);
    CHECK(format->handle() != handle); CHECK(usage->handle() != handle); CHECK(flags->handle() != handle);
    CHECK(size->handle() != handle); CHECK(memoryless->handle() != handle);
    auto again = resource(gpu);
    CHECK_EQ(again->handle(), handle);
    CHECK_EQ(c.news, 6u);
    static_cast<uint8_t*>(memoryless->cpu())[0] = 0x5a;
    auto mlHandle = memoryless->handle(); memoryless.reset();
    auto mlAgain = resource(gpu, 4096, 80, 4, HM_BO_MEMORYLESS);
    CHECK_EQ(mlAgain->handle(), mlHandle);
    CHECK_EQ(static_cast<uint8_t*>(mlAgain->cpu())[0], 0x5a); // backing retained; no redundant clear
}

TEST(bo_cache_fit_reuses_a_bo_one_page_larger_and_reports_the_slack) {
    Counts c;
    {
        Gpu gpu(std::make_unique<CountingGpu>(c));
        uint64_t s[HM_BO_STAT_COUNT]; hakios_metal_bo_cache_take(s);
        auto big = resource(gpu, 72092);   // five pages: 81920
        CHECK_EQ(big->size(), 81920ull);
        auto handle = big->handle();
        static_cast<uint8_t*>(big->cpu())[70000] = 0x5a;
        big.reset();
        auto near = resource(gpu, 65000);   // four pages: 65536, one page shorter than the cached BO
        CHECK_EQ(near->handle(), handle);
        CHECK_EQ(near->size(), 65536ull);
        CHECK_EQ(c.news, 1u); CHECK_EQ(c.maps, 1u);
        bool zero = true;
        for (size_t i = 0; i < near->size(); ++i) zero &= static_cast<const uint8_t*>(near->cpu())[i] == 0;
        CHECK(zero);   // the zero contract covers the bytes the request names, not the whole cached BO
        hakios_metal_bo_cache_take(s);
        CHECK_EQ(s[HM_BO_ALLOCATIONS], 2ull); CHECK_EQ(s[HM_BO_HITS], 1ull);
        CHECK_EQ(s[HM_BO_FIT_HITS], 1ull); CHECK_EQ(s[HM_BO_FIT_WASTE_BYTES], 16384ull);
    }
}

TEST(bo_cache_fit_refuses_a_gap_past_one_page_or_an_eighth_of_the_request) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    auto big = resource(gpu, 114688);   // seven pages
    auto handle = big->handle(); big.reset();
    auto small = resource(gpu, 65536);  // three pages shorter: past the one-page slack
    CHECK(small->handle() != handle);
    CHECK_EQ(c.news, 2u);
    // an eighth of a large request is the other allowance: 9 MiB is within an eighth of 8 MiB
    auto eight = resource(gpu, 8ull << 20, 81);
    auto eightHandle = eight->handle(); eight.reset();
    auto nine = resource(gpu, 9ull << 20, 81);
    CHECK(nine->handle() != eightHandle);   // a larger request never takes a smaller BO
    nine.reset();
    auto againEight = resource(gpu, 8ull << 20, 81);
    CHECK_EQ(againEight->handle(), eightHandle);   // an exact fit still wins over the larger idle BO
}

TEST(bo_cache_fit_still_separates_key_and_flags) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    auto ordinary = resource(gpu, 72092);
    auto handle = ordinary->handle(); ordinary.reset();
    auto otherFormat = resource(gpu, 65000, 81);
    auto otherFlags = resource(gpu, 65000, 80, 4, HM_BO_TEXTURE, kBoWriteCombined | kBoUncleared);
    CHECK(otherFormat->handle() != handle); CHECK(otherFlags->handle() != handle);
    CHECK_EQ(c.news, 3u);
}

TEST(bo_cache_fit_switch_turns_the_near_size_reuse_off) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    uint64_t s[HM_BO_STAT_COUNT]; hakios_metal_bo_cache_take(s);
    hakios_metal_bo_cache_fit_set(0);
    CHECK_EQ(hakios_metal_bo_cache_fit_enabled(), 0);
    auto big = resource(gpu, 72092);
    auto handle = big->handle(); big.reset();
    auto exact = resource(gpu, 81920);   // same page-rounded size is still an exact hit
    CHECK_EQ(exact->handle(), handle); exact.reset();
    auto near = resource(gpu, 65000);
    CHECK(near->handle() != handle);
    CHECK_EQ(c.news, 2u);
    hakios_metal_bo_cache_take(s);
    CHECK_EQ(s[HM_BO_FIT_HITS], 0ull);
    hakios_metal_bo_cache_fit_set(1);
    CHECK_EQ(hakios_metal_bo_cache_fit_enabled(), 1);
}


TEST(bo_cache_waits_for_last_use_on_every_queue_without_waiting_in_allocation) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    auto cmd = commands(gpu);
    uint32_t q1, q2, first, last, other;
    CHECK_EQ(gpu.newQueue(0, &q1), 0); CHECK_EQ(gpu.newQueue(0, &q2), 0);
    auto a = resource(gpu); auto handle = a->handle();
    CHECK_EQ(gpu.submit(q1, *cmd, 0, 1, {{a.get(), false}}, &first), 0);
    CHECK_EQ(gpu.submit(q1, *cmd, 0, 1, {{a.get(), true}}, &last), 0);
    CHECK_EQ(gpu.submit(q2, *cmd, 0, 1, {{a.get(), false}}, &other), 0);
    a.reset();
    auto before = resource(gpu); CHECK(before->handle() != handle);
    CHECK_EQ(c.waits, 0u); // no fence query/wait in the hot path
    CHECK_EQ(gpu.wait(q1, first, 1000000000), 0);
    auto prefix = resource(gpu); CHECK(prefix->handle() != handle);
    CHECK_EQ(gpu.wait(q1, last, 1000000000), 0);
    auto oneQueue = resource(gpu); CHECK(oneQueue->handle() != handle);
    CHECK_EQ(gpu.wait(q2, other, 1000000000), 0);
    auto done = resource(gpu); CHECK_EQ(done->handle(), handle);
    CHECK_EQ(c.waits, 3u);
    gpu.closeQueue(q1); gpu.closeQueue(q2);
}

TEST(bo_cache_keeps_inflight_bytes_and_reuses_after_asynchronous_completion) {
    Counts c;
    auto fake = std::make_unique<CountingGpu>(c, true);
    auto* f = fake.get();
    Gpu gpu(std::move(fake));
    auto cmd = commands(gpu);
    auto a = resource(gpu); auto handle = a->handle();
    uint32_t fence;
    f->pause();
    CHECK_EQ(gpu.submit(0, *cmd, 0, 1, {{a.get(), true}}, &fence), 0);
    a.reset();
    auto b = resource(gpu); CHECK(b->handle() != handle);
    CHECK_EQ(f->liveBuffers(), 3u);
    CHECK_EQ(c.waits, 0u);
    f->resume();
    CHECK_EQ(gpu.wait(0, fence, 1000000000), 0);
    auto done = resource(gpu); CHECK_EQ(done->handle(), handle);
}

TEST(bo_cache_failures_do_not_retain_incomplete_allocations_or_failed_submits) {
    Counts c;
    auto fake = std::make_unique<CountingGpu>(c); auto* f = fake.get();
    Gpu gpu(std::move(fake));
    int error;
    auto previous = hakios_metal_bo_context(hm_bo_key(80, 4, HM_BO_TEXTURE));
    f->failNew = true;
    CHECK(gpu.newBo(4096, kBoWriteCombined, &error) == nullptr); CHECK_EQ(error, ENOMEM);
    f->failNew = false; f->failInfo = true;
    CHECK(gpu.newBo(4096, kBoWriteCombined, &error) == nullptr); CHECK_EQ(error, EIO);
    f->failInfo = false; f->failMap = true;
    CHECK(gpu.newBo(4096, kBoWriteCombined, &error) == nullptr); CHECK_EQ(error, ENOMEM);
    f->failMap = false;
    hakios_metal_bo_context(previous);
    CHECK_EQ(f->liveBuffers(), 0u); CHECK_EQ(c.closes, 2u);
    auto cmd = commands(gpu); auto a = resource(gpu); auto handle = a->handle();
    uint32_t fence = 0;
    f->failSubmit = true;
    CHECK_EQ(gpu.submit(0, *cmd, 0, 1, {{a.get(), true}}, &fence), EIO);
    a.reset();
    auto reused = resource(gpu); CHECK_EQ(reused->handle(), handle);
}

// No packet execution: virtual large allocations let the budget tests inspect
// handle/map lifetimes without committing hundreds of MiB of host RAM.
namespace {
class BudgetGpu : public Transport {
public:
    std::unordered_map<uint32_t, std::unique_ptr<uint8_t[]>> buffers;
    std::vector<uint32_t> closed;
    uint32_t next = 1;
    unsigned maps = 0, unmaps = 0;
    int call(uint32_t r, void* p, size_t) override {
        if (r == kGemNew) {
            auto& n = *static_cast<MsmGemNew*>(p);
            n.handle = next++;
            buffers.emplace(n.handle, std::make_unique<uint8_t[]>(16384));
        } else if (r == kGemInfo) {
            auto& i = *static_cast<MsmGemInfo*>(p); i.value = uint64_t(i.handle) << 32;
        } else if (r == kGemClose) {
            auto h = static_cast<DrmGemClose*>(p)->handle; closed.push_back(h); buffers.erase(h);
        } else return EINVAL;
        return 0;
    }
    void* map(uint32_t h, uint64_t) override { ++maps; return buffers.at(h).get(); }
    void unmap(uint32_t, void*) override { ++unmaps; }
    int64_t nowNs() override { return 1; }
};
}

TEST(bo_cache_lru_byte_budget_includes_memoryless) {
    auto fake = std::make_unique<BudgetGpu>(); auto* f = fake.get();
    Gpu gpu(std::move(fake));
    const auto uncleared = kBoWriteCombined | kBoUncleared;
    auto a = resource(gpu, 96ull << 20, 80, 4, HM_BO_TEXTURE, uncleared); auto ah = a->handle(); a.reset();
    auto b = resource(gpu, 96ull << 20, 81, 4, HM_BO_TEXTURE, uncleared); auto bh = b->handle(); b.reset();
    a = resource(gpu, 96ull << 20, 80, 4, HM_BO_TEXTURE, uncleared); CHECK_EQ(a->handle(), ah); a.reset();
    auto c = resource(gpu, 96ull << 20, 82, 4, HM_BO_TEXTURE, uncleared); c.reset();
    CHECK_EQ(f->closed.size(), size_t(1)); CHECK_EQ(f->closed[0], bh); // recently reused a survives
    auto ml1 = resource(gpu, 64ull << 20, 90, 4, HM_BO_MEMORYLESS); auto m1 = ml1->handle(); ml1.reset();
    auto ml2 = resource(gpu, 64ull << 20, 91, 4, HM_BO_MEMORYLESS); ml2.reset();
    auto ml3 = resource(gpu, 64ull << 20, 92, 4, HM_BO_MEMORYLESS); ml3.reset();
    auto ml4 = resource(gpu, 64ull << 20, 93, 4, HM_BO_MEMORYLESS); ml4.reset();
    auto ml5 = resource(gpu, 64ull << 20, 94, 4, HM_BO_MEMORYLESS); ml5.reset();
    CHECK(std::find(f->closed.begin(), f->closed.end(), m1) != f->closed.end());
    uint64_t s[HM_BO_STAT_COUNT]; hakios_metal_bo_cache_take(s);
    CHECK_EQ(s[HM_BO_CACHED_BYTES], 256ull << 20); CHECK_EQ(s[HM_BO_MEMORYLESS_BYTES], 256ull << 20);
    CHECK_EQ(f->unmaps, f->closed.size());
}

TEST(bo_cache_maps_msaa_pairs_reuse_two_retired_generations) {
    auto fake = std::make_unique<BudgetGpu>(); auto* f = fake.get();
    Gpu gpu(std::move(fake));
    // 1125x2436, 4x BGRA8 and Depth32Float_Stencil8, including layout padding.
    auto attachment = [&](PixelFormat format) {
        TextureDesc desc;
        desc.type = TextureType::k2DMultisample; desc.samples = 4;
        desc.width = 1125; desc.height = 2436;
        desc.format = format; desc.usage = kTextureUsageRenderTarget;
        const auto previous = hakios_metal_bo_context(hm_bo_key(unsigned(format), 4 | (4 << 8) | (4 << 16), HM_BO_MEMORYLESS));
        std::string why;
        auto texture = Texture::make(gpu, desc, &why);
        hakios_metal_bo_context(previous);
        CHECK(texture != nullptr);
        CHECK_EQ(texture->buffer()->length(), (format == PixelFormat::kBGRA8UnormSrgb ? 43240ull : 55080ull) << 10);
        return texture;
    };
    std::vector<std::shared_ptr<Texture>> attachments;
    std::vector<uint32_t> handles;
    for (unsigned i = 0; i < 2; ++i) {
        attachments.push_back(attachment(PixelFormat::kBGRA8UnormSrgb));
        attachments.push_back(attachment(PixelFormat::kDepth32FloatStencil8));
    }
    for (const auto& texture : attachments) handles.push_back(texture->buffer()->bo().handle());
    attachments.clear();
    uint64_t stats[HM_BO_STAT_COUNT]; hakios_metal_bo_cache_take(stats);
    for (unsigned frame = 0; frame < 30; ++frame) {
        for (unsigned i = 0; i < 2; ++i) {
            attachments.push_back(attachment(PixelFormat::kBGRA8UnormSrgb));
            attachments.push_back(attachment(PixelFormat::kDepth32FloatStencil8));
        }
        std::vector<uint32_t> reused;
        for (const auto& texture : attachments) reused.push_back(texture->buffer()->bo().handle());
        std::sort(reused.begin(), reused.end());
        CHECK(reused == handles);
        attachments.clear();
    }
    hakios_metal_bo_cache_take(stats);
    CHECK_EQ(stats[HM_BO_NEW], 0ull); CHECK_EQ(stats[HM_BO_HITS], 120ull);
    CHECK_EQ(stats[HM_BO_MEMORYLESS_BYTES], 196672ull << 10);
    CHECK_EQ(f->maps, 4u); CHECK_EQ(f->unmaps, 0u);
}

TEST(bo_cache_object_budget_and_window_counters) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    uint64_t s[HM_BO_STAT_COUNT]; hakios_metal_bo_cache_take(s);
    hakios_metal_perf_enable(1);
    for (unsigned i = 1; i <= 513; ++i) resource(gpu, 4096, i);
    CHECK_EQ(c.closes, 1u); CHECK_EQ(c.unmaps, 1u);
    auto a = resource(gpu, 4096, 513);
    hakios_metal_bo_cache_take(s);
    CHECK_EQ(s[HM_BO_ALLOCATIONS], 514ull); CHECK_EQ(s[HM_BO_NEW], 513ull);
    CHECK_EQ(s[HM_BO_HITS], 1ull); CHECK_EQ(s[HM_BO_MAPS], 513ull);
    CHECK_EQ(s[HM_BO_EVICTIONS], 1ull); CHECK_EQ(s[HM_BO_CACHED_COUNT], 511ull);
    CHECK(s[HM_BO_ALLOC_NS] > 0); CHECK(s[HM_BO_MAP_NS] > 0);
    hakios_metal_bo_cache_take(s);
    for (unsigned i = 0; i < HM_BO_COUNTER_COUNT; ++i) CHECK_EQ(s[i], 0ull);
    CHECK_EQ(s[HM_BO_CACHED_COUNT], 511ull);
    hakios_metal_perf_enable(0);
}

TEST(bo_cache_allocation_context_is_scoped_to_the_calling_thread) {
    Counts c;
    Gpu gpu(std::make_unique<CountingGpu>(c));
    auto previous = hakios_metal_bo_context(hm_bo_key(80, 4, HM_BO_TEXTURE));
    std::thread direct([&] { int error; auto a = gpu.newBo(4096, kBoWriteCombined, &error); CHECK_EQ(error, 0); });
    direct.join();
    CHECK_EQ(c.closes, 1u); // another thread must not inherit the texture context
    int error; auto a = gpu.newBo(4096, kBoWriteCombined, &error); auto handle = a->handle(); a.reset();
    auto b = gpu.newBo(4096, kBoWriteCombined, &error); CHECK_EQ(b->handle(), handle);
    hakios_metal_bo_context(previous);
}

TEST(bo_cache_does_not_cache_iosurface_handles_or_break_duplicate_import_disown) {
    Counts c;
    auto fake = std::make_unique<CountingGpu>(c); auto* f = fake.get();
    Gpu gpu(std::move(fake));
    f->addSurface(1, 64, 64, 256, 0x42475241u);
    auto previous = hakios_metal_bo_context(hm_bo_key(80, 4, HM_BO_TEXTURE));
    SurfaceInfo info; int error;
    auto a = gpu.surfaceBo(1, &info, &error); CHECK_EQ(error, 0);
    auto b = gpu.surfaceBo(1, &info, &error); CHECK_EQ(error, 0);
    CHECK_EQ(a->handle(), b->handle());
    gpu.disown(std::move(b));
    CHECK_EQ(c.closes, 0u); CHECK_EQ(c.unmaps, 1u);
    a.reset();
    CHECK_EQ(c.closes, 1u); CHECK_EQ(c.unmaps, 2u); CHECK_EQ(f->liveBuffers(), 0u);
    hakios_metal_bo_context(previous);
}

TEST(bo_cache_closed_queue_preserves_observed_completion_and_failed_wait_is_not_completion) {
    Counts c;
    auto fake = std::make_unique<CountingGpu>(c, true); auto* f = fake.get();
    Gpu gpu(std::move(fake)); auto cmd = commands(gpu);
    uint32_t queue, fence;
    CHECK_EQ(gpu.newQueue(0, &queue), 0);
    auto a = resource(gpu); auto handle = a->handle();
    f->pause();
    CHECK_EQ(gpu.submit(queue, *cmd, 0, 1, {{a.get(), false}}, &fence), 0);
    a.reset();
    CHECK_EQ(gpu.wait(queue, fence, 0), ETIMEDOUT);
    auto pending = resource(gpu); CHECK(pending->handle() != handle);
    f->resume();
    CHECK_EQ(gpu.wait(queue, fence, 1000000000), 0);
    gpu.closeQueue(queue);
    auto done = resource(gpu); CHECK_EQ(done->handle(), handle);
}
