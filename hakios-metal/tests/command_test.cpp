// The Metal model against the fake GPU, which runs the packets: what a blit leaves in memory, the order of
// completion, the states, and the refusals.
#include <atomic>
#include <cerrno>
#include <cstring>
#include <random>

#include "hakios-metal/command.hpp"
#include "hakios-metal/fake_gpu.hpp"
#include "hakios-metal/render.hpp"
#include "hakios-metal/texture.hpp"
#include "test.hpp"

using namespace hakios::metal;

namespace {
struct Rig {
    explicit Rig(bool async = false, uint32_t delayUs = 0, bool recovers = true) {
        auto f = std::make_unique<FakeGpu>(async, delayUs, recovers);
        fake = f.get();
        gpu = std::make_unique<Gpu>(std::move(f));
        std::string why;
        queue = CommandQueue::make(*gpu, &why);
    }
    ~Rig() {
        queue.reset();
    }
    FakeGpu* fake;
    std::unique_ptr<Gpu> gpu;
    std::unique_ptr<CommandQueue> queue;
};

std::shared_ptr<Buffer> buffer(Rig& r, uint64_t n) {
    std::string why;
    auto b = newBuffer(*r.gpu, n, &why);
    CHECK(b != nullptr);
    return b;
}
}  // namespace

TEST(gpu_params) {
    // what the kernel answers (hakios: bsd/dev/hakios.adreno.c, hakios_gpu_parameter), written here from that source by
    // hand, so that the fake and this test are two readings of it and not one
    Rig r;
    uint64_t v = 0;
    CHECK_EQ(r.gpu->param(kParamGpuId, &v), 0);
    CHECK_EQ(v, 0ull);                                      // "GPU_ID: none, the chip ID says it"
    CHECK_EQ(r.gpu->param(kParamChipId, &v), 0);
    CHECK_EQ(uint32_t(v), 0x06050002u);                     // GPU_CHIP_ID (dt qcom,chipid) ...
    CHECK_EQ(v >> 32, FakeGpu::kSpeedBin);                  // ... "with the speed bin above it"
    CHECK_EQ(r.gpu->chipId(), 0x06050002u);
    CHECK_EQ(r.gpu->param(kParamGmemSize, &v), 0);
    CHECK_EQ(v, 1179648ull);
    CHECK_EQ(r.gpu->param(kParamMaxFreq, &v), 0);
    CHECK_EQ(v, 587000000ull);                              // core_khz * 1000, the UMI stock clock
    CHECK_EQ(r.gpu->param(kParamFaults, &v), 0);
    CHECK_EQ(v, 0ull);
    CHECK_EQ(r.gpu->param(kParamPriorities, &v), 0);
    CHECK_EQ(v, 1ull);
    CHECK_EQ(r.gpu->param(kParamHighestBankBit, &v), 0);
    CHECK_EQ(v, 16ull);
    CHECK_EQ(r.gpu->param(kParamUbwcSwizzle, &v), 0);
    CHECK_EQ(v, 6ull);
    CHECK_EQ(r.gpu->param(kParamMacrotileMode, &v), 0);
    CHECK_EQ(v, 1ull);
    CHECK_EQ(r.gpu->param(0x0e, &v), EINVAL);               // VA_START: "addresses are ours to give"
    CHECK_EQ(r.gpu->param(0x0f, &v), EINVAL);               // VA_SIZE
    CHECK_EQ(r.gpu->param(0x99, &v), EINVAL);
}

TEST(copy_moves_the_bytes) {
    Rig r;
    auto a = buffer(r, 1 << 20), b = buffer(r, 1 << 20);
    std::mt19937 rng(7);
    auto* pa = static_cast<uint32_t*>(a->contents());
    for (size_t i = 0; i < (1 << 18); i++) pa[i] = rng();
    memset(b->contents(), 0, 1 << 20);
    auto cb = r.queue->commandBuffer();
    CHECK(cb->copy(*a, 4096, *b, 8192, 500000));
    cb->commit();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kCompleted);
    CHECK(memcmp(static_cast<uint8_t*>(b->contents()) + 8192, static_cast<uint8_t*>(a->contents()) + 4096, 500000) == 0);
    // nothing before or after the copied range was touched
    auto* pb = static_cast<uint8_t*>(b->contents());
    bool clean = true;
    for (size_t i = 0; i < 8192; i++) clean = clean && pb[i] == 0;
    for (size_t i = 8192 + 500000; i < (1 << 20); i++) clean = clean && pb[i] == 0;
    CHECK(clean);
    CHECK_EQ(r.fake->stats().faults, 0u);
}

TEST(fill_any_length) {
    Rig r;
    auto b = buffer(r, 1 << 20);
    for (uint64_t len : {4ull, 64ull, 256ull, 260ull, 4096ull, 65540ull, 999996ull}) {
        memset(b->contents(), 0x11, 1 << 20);
        auto cb = r.queue->commandBuffer();
        CHECK(cb->fill(*b, 16, len, 0xa5));
        cb->commit();
        cb->waitUntilCompleted();
        auto* p = static_cast<uint8_t*>(b->contents());
        bool ok = p[15] == 0x11 && p[16 + len] == 0x11;
        for (uint64_t i = 16; i < 16 + len; i++) ok = ok && p[i] == 0xa5;
        CHECK(ok);
    }
    CHECK_EQ(r.fake->stats().faults, 0u);
}

TEST(copy_then_fill_in_one_buffer_keeps_order) {
    Rig r;
    auto a = buffer(r, 4096), b = buffer(r, 4096);
    memset(a->contents(), 0x5a, 4096);
    auto cb = r.queue->commandBuffer();
    CHECK(cb->fill(*b, 0, 4096, 0x00));
    CHECK(cb->copy(*a, 0, *b, 1024, 1024));
    CHECK(cb->fill(*b, 1536, 256, 0xff));
    cb->commit();
    cb->waitUntilCompleted();
    auto* p = static_cast<uint8_t*>(b->contents());
    CHECK_EQ(p[1023], 0x00);
    CHECK_EQ(p[1024], 0x5a);
    CHECK_EQ(p[1535], 0x5a);
    CHECK_EQ(p[1536], 0xff);
    CHECK_EQ(p[1791], 0xff);
    CHECK_EQ(p[1792], 0x5a);
    CHECK_EQ(p[2048], 0x00);
}

TEST(unaligned_copies_go_through_the_2d_engine_byte_for_byte) {
    Rig r;
    auto a = buffer(r, 65536), b = buffer(r, 65536);
    auto* pa = static_cast<uint8_t*>(a->contents());
    auto* pb = static_cast<uint8_t*>(b->contents());
    // every byte of the source its own (a period of 251, prime, so no shift of a few bytes lands on the same values)
    for (uint32_t i = 0; i < 65536; i++) pa[i] = uint8_t(i % 251 + 1);
    memset(pb, 0xee, 65536);
    auto cb = r.queue->commandBuffer();
    CHECK(cb->copy(*a, 1, *b, 70, 37));          // across a 64-byte line, source and destination at different offsets in it
    CHECK(cb->copy(*a, 3, *b, 1029, 20000));     // longer than one row of the engine (0x4000 texels)
    cb->commit();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kCompleted);
    CHECK_EQ(r.fake->stats().faults, 0u);
    CHECK(memcmp(pb + 70, pa + 1, 37) == 0);
    CHECK(memcmp(pb + 1029, pa + 3, 20000) == 0);
    // the bytes on either side of each range are what they were
    CHECK_EQ(pb[69], 0xee);
    CHECK_EQ(pb[107], 0xee);
    CHECK_EQ(pb[1028], 0xee);
    CHECK_EQ(pb[21029], 0xee);
}

TEST(copies_outside_a_buffer_and_unaligned_fills_are_refused) {
    Rig r;
    auto a = buffer(r, 4096), b = buffer(r, 4096);
    auto cb = r.queue->commandBuffer();
    CHECK(!cb->copy(*a, 0, *b, 4000, 200));  // past the end
    std::atomic<int> handled{0};
    cb->addCompletedHandler([&](CommandBuffer& c) { handled += c.status() == CommandBuffer::kError ? 1 : 100; });
    cb->commit();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kError);
    CHECK(!cb->error().empty());
    CHECK_EQ(handled.load(), 1);
    CHECK_EQ(r.fake->stats().submits, 0u);    // nothing of it reached the GPU
    auto cb2 = r.queue->commandBuffer();
    CHECK(!cb2->fill(*b, 2, 4, 0));
}

TEST(handlers_run_in_commit_order_while_the_gpu_is_behind) {
    Rig r(true, 200);
    auto b = buffer(r, 65536);
    std::vector<int> order;
    std::mutex m;
    std::vector<std::shared_ptr<CommandBuffer>> all;
    r.fake->pause();
    for (int i = 0; i < 40; i++) {
        auto cb = r.queue->commandBuffer();
        cb->fill(*b, 4 * i, 4, uint8_t(i));
        cb->addCompletedHandler([&, i](CommandBuffer&) {
            std::lock_guard<std::mutex> g(m);
            order.push_back(i);
        });
        cb->commit();
        CHECK(cb->status() == CommandBuffer::kScheduled);   // committed and handed over, the GPU not done
        all.push_back(cb);
    }
    r.fake->resume();
    all.back()->waitUntilCompleted();
    // the last one done means every one before it is done, with its handler run
    for (auto& cb : all) cb->waitUntilCompleted();
    CHECK_EQ(order.size(), size_t(40));
    bool inOrder = true;
    for (int i = 0; i < int(order.size()); i++) inOrder = inOrder && order[i] == i;
    CHECK(inOrder);
    auto* p = static_cast<uint8_t*>(b->contents());
    CHECK_EQ(p[4 * 39], 39);
}

TEST(command_memory_is_used_again) {
    Rig r(true);
    auto b = buffer(r, 4096);
    for (int i = 0; i < 100; i++) {
        auto cb = r.queue->commandBuffer();
        cb->fill(*b, 0, 4096, uint8_t(i));
        cb->commit();
        cb->waitUntilCompleted();
    }
    // one command stream's buffer, taken back after every completion: not a hundred of them
    CHECK(r.queue->idleCommandBuffers() <= 2);
    CHECK(r.fake->liveBuffers() <= 4);
}

TEST(buffers_are_given_back) {
    Rig r;
    {
        auto a = buffer(r, 1 << 16);
        auto b = buffer(r, 1 << 16);
        CHECK(r.fake->liveBuffers() >= 2);
    }
    CHECK_EQ(r.fake->liveBuffers(), 0u);
}

TEST(a_bad_stream_is_a_hang_the_kernel_resets_the_gpu_for) {
    // a packet the real GPU hangs on, with the kernel's gpu_recover=1: the hung submission's own wait fails, FAULTS
    // counts the reset, and the GPU takes work again
    Rig r;
    int e = 0;
    auto bo = r.gpu->newBo(4096, 0, &e);
    auto* w = static_cast<uint32_t*>(bo->cpu());
    w[0] = pm4::type7(0x7f, 0) ^ (1u << 15);   // parity broken
    uint32_t fence = 0;
    CHECK_EQ(r.gpu->submit(0, *bo, 0, 1, {}, &fence), 0);
    CHECK_EQ(r.gpu->wait(0, fence, 1000000000), ETIMEDOUT);
    CHECK_EQ(r.fake->stats().faults, 1u);
    CHECK_EQ(r.gpu->faults(), 1ull);
    w[0] = pm4::type7(pm4::kNop, 0);
    CHECK_EQ(r.gpu->submit(0, *bo, 0, 1, {}, &fence), 0);
    CHECK_EQ(r.gpu->wait(0, fence, 1000000000), 0);
    CHECK_EQ(r.gpu->faults(), 1ull);
}

TEST(a_command_buffer_behind_a_hang_is_run_again_not_given_up) {
    // The reset gives up the submission the GPU hung on and runs the ones behind it again (hakios_gpu_recover, as
    // Linux's msm recover_worker): a command buffer behind the hung one runs and completes. Given up, it never ran, and
    // what it wrote was lost for good -- PiliPlus's glyph uploads behind a hung CoreAnimation frame, glyphs missing.
    Rig r(true);
    auto b = buffer(r, 4096);
    memset(b->contents(), 0, 4096);
    r.fake->pause();
    int e = 0;
    auto bad = r.gpu->newBo(4096, 0, &e);
    static_cast<uint32_t*>(bad->cpu())[0] = pm4::type7(0x7f, 0) ^ (1u << 15);
    uint32_t fence = 0;
    CHECK_EQ(r.gpu->submit(0, *bad, 0, 1, {}, &fence), 0);   // first in the ring: hangs
    auto cb = r.queue->commandBuffer();                        // behind it
    CHECK(cb->fill(*b, 0, 4096, 0xee));
    cb->commit();
    r.fake->resume();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kCompleted);
    CHECK_EQ(static_cast<uint8_t*>(b->contents())[0], 0xee);  // and it did run
    CHECK_EQ(r.gpu->faults(), 1ull);
    CHECK(r.gpu->givenUp(fence));                              // the hung one alone was given up
    CHECK(!r.gpu->givenUp(fence + 1));
    // committed after the reset: runs
    auto cb2 = r.queue->commandBuffer();
    CHECK(cb2->fill(*b, 0, 4096, 0xee));
    cb2->commit();
    cb2->waitUntilCompleted();
    CHECK(cb2->status() == CommandBuffer::kCompleted);
    CHECK_EQ(static_cast<uint8_t*>(b->contents())[4095], 0xee);
}

TEST(without_recovery_the_first_hang_ends_every_later_wait) {
    // the kernel without gpu_recover=1: gGPUReported is set by the first wait that times out and never cleared
    Rig r(false, 0, false);
    int e = 0;
    auto bo = r.gpu->newBo(4096, 0, &e);
    auto* w = static_cast<uint32_t*>(bo->cpu());
    w[0] = pm4::type7(0x7f, 0) ^ (1u << 15);
    uint32_t fence = 0;
    CHECK_EQ(r.gpu->submit(0, *bo, 0, 1, {}, &fence), 0);
    CHECK_EQ(r.gpu->wait(0, fence, 1000000000), ETIMEDOUT);
    CHECK_EQ(r.gpu->faults(), 0ull);                           // no reset to count
    w[0] = pm4::type7(pm4::kNop, 0);
    CHECK_EQ(r.gpu->submit(0, *bo, 0, 1, {}, &fence), 0);     // still taken, as the ring takes them ...
    CHECK_EQ(r.gpu->wait(0, fence, 1000000000), ETIMEDOUT);    // ... and never run
    auto b = buffer(r, 4096);
    auto cb = r.queue->commandBuffer();
    CHECK(cb->fill(*b, 0, 4096, 0x11));
    cb->commit();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kError);
    CHECK(cb->error().find("recovery is disabled or failed") != std::string::npos);
}

TEST(a_fence_never_handed_out_is_a_hang) {
    // the kernel does not know such a fence: it waits the whole patience, and that is a hang like any other
    Rig r;
    CHECK_EQ(r.gpu->wait(0, 7, 1000000), ETIMEDOUT);
    CHECK_EQ(r.gpu->faults(), 1ull);
}

TEST(big_copies_are_cut_into_packets_the_gpu_takes) {
    Rig r;
    auto a = buffer(r, 16 << 20), b = buffer(r, 16 << 20);
    auto* pa = static_cast<uint32_t*>(a->contents());
    for (size_t i = 0; i < (4u << 20); i++) pa[i] = uint32_t(i * 2654435761u);
    auto cb = r.queue->commandBuffer();
    CHECK(cb->copy(*a, 0, *b, 0, 16 << 20));
    CHECK(cb->fill(*a, 0, 16 << 20, 0x77));
    cb->commit();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kCompleted);
    CHECK_EQ(static_cast<uint32_t*>(b->contents())[(4u << 20) - 1], uint32_t(((4u << 20) - 1) * 2654435761u));
    CHECK_EQ(static_cast<uint8_t*>(a->contents())[(16 << 20) - 1], 0x77);
    CHECK_EQ(r.fake->stats().faults, 0u);
}

TEST(surface_last_release_races_reimport) {
    Rig r;
    r.fake->addSurface(71, 64, 64, 256, 0x42475241u);
    std::atomic<unsigned> bad{0}, ready{0};
    std::vector<std::thread> threads;
    for (unsigned t = 0; t < 4; ++t) {
        threads.emplace_back([&] {
            ++ready;
            while (ready != 4) std::this_thread::yield();
            for (unsigned i = 0; i < 10000; ++i) {
                SurfaceInfo info{};
                std::string why;
                auto b = surfaceBuffer(*r.gpu, 71, &info, &why);
                if (!b) { ++bad; continue; }
                std::this_thread::yield();
                MsmGemInfo query{};
                query.handle = b->bo().handle();
                query.info = kInfoGetIova;
                if (r.gpu->transport().call(kGemInfo, &query, sizeof(query)) != 0 ||
                    query.value != b->gpuAddress()) ++bad;
            }
        });
    }
    for (auto& t : threads) t.join();
    CHECK_EQ(bad.load(), 0u);  // a live imported Buffer must still own a mapped kernel handle
}

// One CP_INDIRECT_BUFFER runs at most 0xfffff words (its size word's 20 bits): v22c's two hangs were each the one
// command buffer longer than that. A longer stream goes to the kernel as several, cut between packets, and runs whole;
// the fake refuses one IB past the limit as the GPU hangs on it.
TEST(a_stream_longer_than_one_ib_runs_is_submitted_in_pieces) {
    {
        std::vector<uint32_t> w;
        for (int i = 0; i < 70; i++) {   // 70 NOPs of 0x3fff words: 0x117ff2 words, past one IB
            w.push_back(pm4::type7(pm4::kNop, pm4::kMaxType7Count));
            w.insert(w.end(), pm4::kMaxType7Count, 0u);
        }
        const auto p = pm4::pieces(w);
        CHECK_EQ(p.size(), 2u);
        CHECK(p[0].first == 0 && p[0].second <= pm4::kMaxIbWords && p[0].second % 0x4000 == 0);   // (whole packets)
        CHECK_EQ(p[1].first, p[0].second);
        CHECK_EQ(uint64_t(p[0].second) + p[1].second, uint64_t(w.size()));
        CHECK_EQ(pm4::pieces(std::vector<uint32_t>(w.begin(), w.begin() + 0x4000)).size(), 1u);
        Rig r;
        int e = 0;
        auto bo = r.gpu->newBo(4 * w.size(), 0, &e);
        memcpy(bo->cpu(), w.data(), 4 * w.size());
        uint32_t fence = 0;
        CHECK_EQ(r.gpu->submit(0, *bo, 0, p, {}, &fence), 0);
        CHECK_EQ(r.gpu->wait(0, fence, 1000000000), 0);
        CHECK_EQ(r.fake->stats().faults, 0u);
        CHECK_EQ(r.gpu->submit(0, *bo, 0, uint32_t(w.size()), {}, &fence), 0);   // as one IB: what hung
        CHECK_EQ(r.gpu->wait(0, fence, 1000000000), ETIMEDOUT);
        CHECK(r.fake->stats().lastFault.find("0xfffff at most") != std::string::npos);
    }
    // a command buffer of 150000 copies (1.2 M words) the queue cuts and runs
    Rig r;
    auto a = buffer(r, 4 * 150000), b = buffer(r, 4 * 150000);
    for (uint32_t i = 0; i < 150000; i++) static_cast<uint32_t*>(a->contents())[i] = i * 2654435761u;
    memset(b->contents(), 0, 4 * 150000);
    auto cb = r.queue->commandBuffer();
    for (uint32_t i = 0; i < 150000; i++) CHECK(cb->copy(*a, 4 * i, *b, 4 * i, 4));
    cb->commit();
    cb->waitUntilCompleted();
    CHECK(cb->status() == CommandBuffer::kCompleted);
    if (cb->status() != CommandBuffer::kCompleted) std::printf("       %s | %s\n", cb->error().c_str(), r.fake->stats().lastFault.c_str());
    CHECK(r.fake->stats().maxSubmitWords <= pm4::kMaxIbWords);
    CHECK(memcmp(a->contents(), b->contents(), 4 * 150000) == 0);
}

namespace {
std::shared_ptr<Texture> glyphAtlas(Rig& r, PixelFormat f, uint32_t w, uint32_t h) {
    TextureDesc d;
    d.format = f;
    d.width = w;
    d.height = h;
    d.usage = kTextureUsageRead | kTextureUsageWrite | kTextureUsageRenderTarget;
    std::string why;
    auto t = Texture::make(*r.gpu, d, &why);
    CHECK(t != nullptr);
    return t;
}

// -copyFromBuffer:...toTexture: as HakiosMetalCA.m encodes a glyph Impeller uploads (BlitCopyBufferToTextureCommandMTL:
// rows of the glyph's width, from where the host buffer put them): rows the 2D engine cannot take as they lie are
// copied, one GPU copy a row, into a staging buffer at a 64-byte pitch, and that is blitted into the atlas
void uploadGlyph(Rig& r, CommandBuffer& cb, const std::shared_ptr<Buffer>& host, uint64_t offset, uint32_t bpr, Texture& atlas, uint32_t x,
                 uint32_t y, uint32_t w, uint32_t h) {
    const uint64_t pitch = (bpr + 63) & ~uint64_t(63);
    auto staging = buffer(r, pitch * h);
    for (uint32_t row = 0; row < h; row++) CHECK(cb.copy(*host, offset + uint64_t(row) * bpr, *staging, row * pitch, bpr));
    TextureDesc d;
    d.format = atlas.format();
    d.width = w;
    d.height = h;
    d.usage = kTextureUsageRead | kTextureUsageWrite | kTextureUsageRenderTarget;
    std::string why;
    auto rows = Texture::overBuffer(staging, 0, pitch, d, &why);
    CHECK(rows != nullptr);
    if (rows == nullptr) return;
    CHECK(cb.blit(*rows, 0, render::BlitRect{0, 0, w, h}, atlas, 0, render::BlitRect{x, y, w, h}, false));
}
}  // namespace

TEST(glyph_uploads_at_odd_offsets_land_after_the_buffer_that_read_the_atlas_and_leave_their_neighbours) {
    // Impeller's glyph atlas (A8, Metal's MTLPixelFormatA8Unorm; R8 the same bytes): new glyphs blitted in at odd places
    // from odd host-buffer offsets, while a command buffer committed before them still reads the atlas. The reader sees
    // the atlas as it was (the queue runs in order: Metal's tracked hazard between the two); the glyphs land whole, a
    // 13-byte row (a copy of bytes through the 2D engine) beside a 12-byte one (the command processor's word copy)
    // in the same 64-byte lines, and not one byte around them moves.
    for (PixelFormat f : {PixelFormat::kA8Unorm, PixelFormat::kR8Unorm}) {
        Rig r(true);
        const uint32_t W = 256, H = 32;
        auto atlas = glyphAtlas(r, f, W, H);
        auto before = glyphAtlas(r, f, W, H);
        if (atlas == nullptr || before == nullptr) return;
        std::vector<uint8_t> was(W * H), now(W * H);
        for (uint32_t i = 0; i < W * H; i++) was[i] = uint8_t(0x40 + i % 7);
        std::string why;
        CHECK(atlas->replace(0, 0, 0, W, H, was.data(), W, &why));
        auto host = buffer(r, 4096);
        auto* bytes = static_cast<uint8_t*>(host->contents());
        for (uint32_t i = 0; i < 4096; i++) bytes[i] = uint8_t(0x80 | (i * 37) % 127);
        r.fake->pause();
        auto reader = r.queue->commandBuffer();
        CHECK(reader->blit(*atlas, 0, render::BlitRect{0, 0, W, H}, *before, 0, render::BlitRect{0, 0, W, H}, false));
        reader->commit();
        auto upload = r.queue->commandBuffer();
        uploadGlyph(r, *upload, host, 16, 13, *atlas, 37, 5, 13, 7);      // rows of 13: bytes
        uploadGlyph(r, *upload, host, 272, 12, *atlas, 50, 5, 12, 9);     // rows of 12 beside it: words
        uploadGlyph(r, *upload, host, 528, 45, *atlas, 199, 21, 45, 11);  // and one that crosses into the last line
        upload->commit();
        r.fake->resume();
        upload->waitUntilCompleted();
        CHECK(reader->status() == CommandBuffer::kCompleted);
        CHECK(upload->status() == CommandBuffer::kCompleted);
        if (upload->status() != CommandBuffer::kCompleted) std::printf("       %s | %s\n", upload->error().c_str(), r.fake->stats().lastFault.c_str());
        CHECK(before->read(0, 0, 0, W, H, now.data(), W, &why));
        CHECK(now == was);
        std::vector<uint8_t> want = was;
        auto put = [&](uint64_t from, uint32_t bpr, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
            for (uint32_t row = 0; row < h; row++)
                for (uint32_t col = 0; col < w; col++) want[(y + row) * W + x + col] = bytes[from + row * bpr + col];
        };
        put(16, 13, 37, 5, 13, 7);
        put(272, 12, 50, 5, 12, 9);
        put(528, 45, 199, 21, 45, 11);
        CHECK(atlas->read(0, 0, 0, W, H, now.data(), W, &why));
        uint32_t wrong = 0;
        for (uint32_t i = 0; i < W * H; i++) wrong += now[i] != want[i];
        CHECK_EQ(wrong, 0u);
    }
}

TEST(a_partial_replace_of_an_a8_atlas_at_odd_offsets_writes_its_rectangle_alone) {
    // -replaceRegion: of a glyph into an A8 or R8 atlas while a command buffer that reads the atlas is still queued:
    // Metal's replaceRegion is the processor's write, now, unsynchronised with the GPU (the caller's to order), and the
    // atlas is shared write-combined memory, so the queued reader sees the new bytes. What must hold: the rectangle is
    // written at its odd place from the caller's odd stride, nothing around it moves, and a later reader sees it.
    for (PixelFormat f : {PixelFormat::kA8Unorm, PixelFormat::kR8Unorm}) {
        Rig r(true);
        const uint32_t W = 128, H = 16;
        auto atlas = glyphAtlas(r, f, W, H);
        auto seen = glyphAtlas(r, f, W, H);
        auto later = glyphAtlas(r, f, W, H);
        if (atlas == nullptr || seen == nullptr || later == nullptr) return;
        std::vector<uint8_t> was(W * H, 0x11), glyph(19 * 5), now(W * H);
        for (uint32_t i = 0; i < glyph.size(); i++) glyph[i] = uint8_t(0xa0 + i);
        std::string why;
        CHECK(atlas->replace(0, 0, 0, W, H, was.data(), W, &why));
        r.fake->pause();
        auto reader = r.queue->commandBuffer();
        CHECK(reader->blit(*atlas, 0, render::BlitRect{0, 0, W, H}, *seen, 0, render::BlitRect{0, 0, W, H}, false));
        reader->commit();
        CHECK(atlas->replace(0, 63, 7, 17, 5, glyph.data(), 19, &why));   // 17 of each 19-byte row, at (63, 7)
        r.fake->resume();
        reader->waitUntilCompleted();
        auto after = r.queue->commandBuffer();
        CHECK(after->blit(*atlas, 0, render::BlitRect{0, 0, W, H}, *later, 0, render::BlitRect{0, 0, W, H}, false));
        after->commit();
        after->waitUntilCompleted();
        std::vector<uint8_t> want = was;
        for (uint32_t row = 0; row < 5; row++)
            for (uint32_t col = 0; col < 17; col++) want[(7 + row) * W + 63 + col] = glyph[row * 19 + col];
        CHECK(atlas->read(0, 0, 0, W, H, now.data(), W, &why));
        CHECK(now == want);
        CHECK(later->read(0, 0, 0, W, H, now.data(), W, &why));
        CHECK(now == want);
        CHECK(seen->read(0, 0, 0, W, H, now.data(), W, &why));
        CHECK(now == want);   // (unsynchronised, as Metal's: the queued reader ran after the processor wrote)
    }
}

TEST(glyph_uploads_behind_a_hang_are_run_after_the_reset) {
    // What lost PiliPlus's glyphs: the GPU hung on another program's work (CoreAnimation's) with Impeller's glyph-atlas
    // upload queued behind it, the reset gave everything in the ring up "as done", and the atlas kept its old bytes
    // while Impeller had the glyphs as uploaded for good -- missing at rest, other subpixel variants of the same glyph
    // showing as the text moved. The reset gives up the hung submission alone now; the upload runs.
    Rig r(true);
    auto atlas = glyphAtlas(r, PixelFormat::kA8Unorm, 128, 16);
    if (atlas == nullptr) return;
    std::vector<uint8_t> zero(128 * 16, 0), now(128 * 16);
    std::string why;
    CHECK(atlas->replace(0, 0, 0, 128, 16, zero.data(), 128, &why));
    auto host = buffer(r, 4096);
    auto* bytes = static_cast<uint8_t*>(host->contents());
    for (uint32_t i = 0; i < 4096; i++) bytes[i] = uint8_t(0x80 | i % 101);
    r.fake->pause();
    int e = 0;
    auto bad = r.gpu->newBo(4096, 0, &e);
    static_cast<uint32_t*>(bad->cpu())[0] = pm4::type7(0x7f, 0) ^ (1u << 15);
    uint32_t fence = 0;
    CHECK_EQ(r.gpu->submit(0, *bad, 0, 1, {}, &fence), 0);    // another program's frame: hangs
    auto upload = r.queue->commandBuffer();
    uploadGlyph(r, *upload, host, 48, 23, *atlas, 41, 3, 23, 9);
    upload->commit();
    r.fake->resume();
    upload->waitUntilCompleted();
    CHECK(upload->status() == CommandBuffer::kCompleted);
    CHECK_EQ(r.gpu->faults(), 1ull);
    CHECK(atlas->read(0, 0, 0, 128, 16, now.data(), 128, &why));
    uint32_t wrong = 0;
    for (uint32_t y = 0; y < 16; y++)
        for (uint32_t x = 0; x < 128; x++) {
            const bool in = x >= 41 && x < 64 && y >= 3 && y < 12;
            wrong += now[y * 128 + x] != (in ? bytes[48 + (y - 3) * 23 + (x - 41)] : 0);
        }
    CHECK_EQ(wrong, 0u);
}

// Hold one ioctl while adjacent commits become ready. The next submit must batch them
// without returning any commit before its fence is published, and preserve callback order.
TEST(ready_small_command_buffers_share_a_submit_and_keep_completion_order) {
    for (bool reject : {false, true}) {
    class GatedGpu : public FakeGpu {
    public:
        std::mutex gate;
        std::condition_variable changed;
        bool entered = false, released = false, rejectSecond = false, readWrite = false;
        unsigned submits = 0;
        int call(uint32_t request, void* data, size_t size) override {
            if (request == kGemSubmit) {
                std::unique_lock<std::mutex> g(gate);
                const auto& submit = *static_cast<const MsmGemSubmit*>(data);
                const auto* bos = reinterpret_cast<const MsmSubmitBo*>(submit.bos);
                for (uint32_t i = 0; i < submit.nr_bos; i++) readWrite |= bos[i].flags == (kSubmitBoRead | kSubmitBoWrite);
                if (++submits == 2 && rejectSecond) return EIO;
                if (!entered) {
                    entered = true; changed.notify_all();
                    changed.wait(g, [&] { return released; });
                }
            }
            return FakeGpu::call(request, data, size);
        }
    };
    auto fake = std::make_unique<GatedGpu>();
    auto* f = fake.get();
    f->rejectSecond = reject;
    Gpu gpu(std::move(fake));
    std::string why;
    auto queue = CommandQueue::make(gpu, &why);
    auto buf = newBuffer(gpu, 4096, &why);
    std::vector<std::shared_ptr<CommandBuffer>> buffers;
    std::vector<std::thread> threads;
    std::vector<int> completed;
    std::mutex completionLock;
    std::atomic<unsigned> returned{0};
    for (int i = 0; i < 5; i++) {
        auto cb = queue->commandBuffer();
        CHECK(cb->fill(*buf, i * 64, 64, uint8_t(i + 1)));
        if (i == 0) CHECK(cb->copy(*buf, 0, *buf, 64, 4));
        cb->addCompletedHandler([&, i](CommandBuffer& done) {
            CHECK(done.status() == (reject && i > 0 ? CommandBuffer::kError : CommandBuffer::kCompleted));
            std::lock_guard<std::mutex> g(completionLock);
            completed.push_back(i);
        });
        buffers.push_back(cb);
        threads.emplace_back([&, cb] { cb->commit(); returned++; });
        if (i == 0) {
            std::unique_lock<std::mutex> g(f->gate);
            f->changed.wait(g, [&] { return f->entered; });
        } else {
            while (cb->status() != CommandBuffer::kCommitted) std::this_thread::yield();
        }
    }
    CHECK_EQ(returned.load(), 0u);
    {
        std::lock_guard<std::mutex> g(f->gate);
        f->released = true;
    }
    f->changed.notify_all();
    for (auto& thread : threads) thread.join();
    for (auto& cb : buffers) cb->waitUntilCompleted();
    CHECK_EQ(f->stats().submits, reject ? 1u : 2u);
    CHECK(f->readWrite);
    CHECK_EQ(f->stats().faults, 0u);
    unsigned merged = 0;
    for (auto& cb : buffers) merged += cb->counts().merged;
    CHECK_EQ(merged, reject ? 0u : 3u);
    CHECK(completed == std::vector<int>({0, 1, 2, 3, 4}));
    const auto* bytes = static_cast<const uint8_t*>(buf->contents());
    if (!reject) for (unsigned i = 0; i < 5; i++) CHECK_EQ(bytes[i * 64], i + 1);
    auto next = queue->commandBuffer();
    CHECK(next->fill(*buf, 0, 64, 0x42));
    next->commit(); next->waitUntilCompleted();
    CHECK(next->status() == CommandBuffer::kCompleted);
    CHECK_EQ(bytes[0], 0x42u);
    }
}
