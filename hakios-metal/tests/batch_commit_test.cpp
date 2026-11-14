#include <atomic>
#include <cerrno>
#include <cstring>
#include <thread>
#include <vector>

#include "hakios-metal/command.hpp"
#include "hakios-metal/bo_cache.hpp"
#include "hakios-metal/fake_gpu.hpp"
#include "hakios-metal/hakios_metal.h"
#include "hakios-metal/texture.hpp"
#include "test.hpp"
#include "fixtures/fill_id_bc.hpp"

using namespace hakios::metal;

namespace {
class BatchGpu : public FakeGpu {
public:
    BatchGpu() : FakeGpu(true) {}
    std::mutex gate;
    std::condition_variable changed;
    bool hold = false, entered = false, released = false;
    unsigned attempts = 0, rejectAt = 0;
    std::vector<uint32_t> published, waited;
    int call(uint32_t request, void* data, size_t size) override {
        if (request == kGemSubmit) {
            std::unique_lock<std::mutex> g(gate);
            attempts++;
            if (hold) {
                entered = true;
                changed.notify_all();
                changed.wait(g, [&] { return released; });
            }
            if (attempts == rejectAt) return EIO;
            const int e = FakeGpu::call(request, data, size);
            if (e == 0) published.push_back(static_cast<MsmGemSubmit*>(data)->fence);
            return e;
        }
        if (request == kWaitFence) {
            std::lock_guard<std::mutex> g(gate);
            waited.push_back(static_cast<MsmWaitFence*>(data)->fence);
        }
        return FakeGpu::call(request, data, size);
    }
};
}

TEST(serial_batch_shares_real_fences_and_retires_failed_submits_in_order) {
    for (unsigned reject : {0u, 2u}) {
        auto transport = std::make_unique<BatchGpu>();
        auto* f = transport.get();
        f->rejectAt = reject;
        f->pause();
        Gpu gpu(std::move(transport));
        std::string why;
        auto q = CommandQueue::make(gpu, &why);
        auto memory = newBuffer(gpu, 4096, &why);
        std::vector<std::shared_ptr<CommandBuffer>> buffers;
        std::vector<unsigned> callbacks;
        for (unsigned i = 0; i < 19; i++) {
            auto cb = q->commandBuffer();
            CHECK(cb->fill(*memory, i * 4, 4, uint8_t(i + 1)));
            cb->addCompletedHandler([&, i](CommandBuffer& done) {
                CHECK(done.status() == (reject && i >= 8 && i < 16 ? CommandBuffer::kError : CommandBuffer::kCompleted));
                callbacks.push_back(i);
            });
            buffers.push_back(cb);
        }
        q->commitBatch(buffers);
        CHECK_EQ(f->attempts, 3u);
        CHECK_EQ(f->published.size(), reject ? 2u : 3u);
        CHECK(callbacks.empty()); // drain waits for publication, never for GPU completion
        for (unsigned i = 0; i < buffers.size(); i++)
            CHECK(buffers[i]->status() == (reject && i >= 8 && i < 16 ? CommandBuffer::kCommitted : CommandBuffer::kScheduled));
        f->resume();
        for (auto& cb : buffers) cb->waitUntilCompleted();
        CHECK_EQ(callbacks.size(), 19u);
        for (unsigned i = 0; i < 19; i++) CHECK_EQ(callbacks[i], i);
        CHECK_EQ(f->waited.size(), reject ? 11u : 19u);
        for (unsigned i = 0; i < f->waited.size(); i++) {
            const unsigned group = reject ? (i < 8 ? 0 : 1) : i / 8;
            CHECK_EQ(f->waited[i], f->published[group]);
        }
        CHECK_EQ(f->stats().faults, 0u);
    }
}

TEST(batch_does_not_return_or_schedule_before_submit_publishes_its_fence) {
    auto transport = std::make_unique<BatchGpu>();
    auto* f = transport.get();
    f->hold = true;
    f->pause();
    Gpu gpu(std::move(transport));
    std::string why;
    auto q = CommandQueue::make(gpu, &why);
    auto memory = newBuffer(gpu, 4096, &why);
    std::vector<std::shared_ptr<CommandBuffer>> buffers;
    for (unsigned i = 0; i < 4; i++) {
        auto cb = q->commandBuffer();
        CHECK(cb->fill(*memory, i * 4, 4, 0x42));
        buffers.push_back(cb);
    }
    std::atomic<bool> returned{false};
    std::thread submit([&] { q->commitBatch(buffers); returned = true; });
    {
        std::unique_lock<std::mutex> g(f->gate);
        f->changed.wait(g, [&] { return f->entered; });
        CHECK(!returned.load());
        CHECK(f->published.empty());
        for (auto& cb : buffers) CHECK(cb->status() == CommandBuffer::kCommitted);
        f->released = true;
    }
    f->changed.notify_all();
    submit.join();
    CHECK(returned.load());
    CHECK_EQ(f->published.size(), 1u);
    for (auto& cb : buffers) CHECK(cb->status() == CommandBuffer::kScheduled);
    f->resume();
    for (auto& cb : buffers) cb->waitUntilCompleted();
    CHECK_EQ(f->waited.size(), 4u);
    for (auto fence : f->waited) CHECK_EQ(fence, f->published[0]);
}

TEST(batch_recording_error_is_a_boundary_and_keeps_callback_order) {
    auto transport = std::make_unique<BatchGpu>();
    auto* f = transport.get();
    f->pause();
    Gpu gpu(std::move(transport));
    std::string why;
    auto q = CommandQueue::make(gpu, &why);
    auto memory = newBuffer(gpu, 4096, &why);
    std::vector<unsigned> callbacks;
    std::vector<std::shared_ptr<CommandBuffer>> buffers;
    for (unsigned i = 0; i < 5; i++) {
        auto cb = q->commandBuffer();
        if (i == 2) cb->refuse("bad recording");
        else CHECK(cb->fill(*memory, i * 4, 4, uint8_t(i)));
        cb->addCompletedHandler([&, i](CommandBuffer& done) {
            CHECK(done.status() == (i == 2 ? CommandBuffer::kError : CommandBuffer::kCompleted));
            callbacks.push_back(i);
        });
        buffers.push_back(cb);
    }
    q->commitBatch(buffers);
    CHECK_EQ(f->attempts, 2u);
    CHECK(callbacks.empty());
    f->resume();
    for (auto& cb : buffers) cb->waitUntilCompleted();
    CHECK(callbacks == std::vector<unsigned>({0, 1, 2, 3, 4}));
    CHECK_EQ(f->waited.size(), 4u);
}

TEST(c_api_serial_recordings_enter_one_deferred_batch_and_callbacks_can_free_handles) {
    for (int deferred : {0, 1}) {
        auto* d = hakios_metal_open_fake();
        auto* q = hakios_metal_queue_new(d);
        hakios_metal_queue_set_deferred(q, deferred);
        auto* texture = hakios_metal_texture_new(d, 2, 70, 64, 64, HAKIOS_METAL_TEXTURE_USAGE_RENDER_TARGET);
        hakios_metal_render_pass pass = {};
        pass.color0 = texture;
        pass.load_action = 2;
        pass.store_action = 1;
        pass.clear_color[3] = 1;
        unsigned singleWords, singleCut;
        hakios_metal_stream_counts(&singleWords, &singleCut);
        auto* single = hakios_metal_cb_new(q);
        CHECK_EQ(hakios_metal_cb_clear(single, &pass), 0);
        hakios_metal_cb_commit(single, nullptr, nullptr);
        hakios_metal_cb_wait(single);
        hakios_metal_cb_free(single);
        hakios_metal_stream_counts(&singleWords, &singleCut);
        std::vector<unsigned> callbacks;
        struct Context { unsigned index; std::vector<unsigned>* calls; } contexts[8];
        std::vector<hakios_metal_commit> commits;
        for (unsigned i = 0; i < 8; i++) {
            auto* cb = hakios_metal_cb_new(q);
            CHECK_EQ(hakios_metal_cb_clear(cb, &pass), 0); // queued recording in deferred mode
            contexts[i] = {i, &callbacks};
            commits.push_back({cb, [](hakios_metal_cb* done, void* p) {
                auto& context = *static_cast<Context*>(p);
                CHECK(hakios_metal_cb_status(done) == HAKIOS_METAL_COMPLETED);
                context.calls->push_back(context.index);
                hakios_metal_cb_free(done);
            }, &contexts[i]});
        }
        unsigned longest, cut;
        hakios_metal_stream_counts(&longest, &cut);
        hakios_metal_queue_commit_batch(q, commits.data(), unsigned(commits.size()));
        hakios_metal_stream_counts(&longest, &cut);
        CHECK(longest >= singleWords * 8); // proves the eight serial recordings reached one submission
        auto* tail = hakios_metal_cb_new(q);
        hakios_metal_cb_commit(tail, nullptr, nullptr);
        hakios_metal_cb_wait(tail);
        CHECK(callbacks == std::vector<unsigned>({0, 1, 2, 3, 4, 5, 6, 7}));
        hakios_metal_cb_free(tail);
        hakios_metal_queue_commit_batch(q, nullptr, 0);
        hakios_metal_queue_free(q);
        hakios_metal_texture_free(texture);
        hakios_metal_close(d);
    }
}

TEST(serial_batch_obeys_word_budget_and_isolates_large_command_buffers) {
    for (bool large : {false, true}) {
        auto transport = std::make_unique<BatchGpu>();
        auto* f = transport.get();
        Gpu gpu(std::move(transport));
        std::string why;
        auto q = CommandQueue::make(gpu, &why);
        auto memory = newBuffer(gpu, 4096, &why);
        std::vector<std::shared_ptr<CommandBuffer>> buffers;
        for (unsigned i = 0; i < 7 + unsigned(large); i++) {
            auto cb = q->commandBuffer();
            const size_t words = large && i == 0 ? 9000 : 6000;
            while (cb->streamWords() < words) CHECK(cb->fill(*memory, 0, 4, 0x33));
            buffers.push_back(cb);
        }
        q->commitBatch(buffers);
        for (auto& cb : buffers) cb->waitUntilCompleted();
        CHECK_EQ(f->attempts, large ? 3u : 2u);
        CHECK(f->stats().maxSubmitWords <= 32768);
        CHECK_EQ(f->stats().faults, 0u);
    }
}

TEST(c_api_deferred_batch_reports_recording_error_once_and_continues) {
    auto* d = hakios_metal_open_fake();
    auto* q = hakios_metal_queue_new(d);
    hakios_metal_queue_set_deferred(q, 1);
    std::vector<unsigned> calls;
    struct Context { unsigned index; std::vector<unsigned>* calls; } contexts[3];
    hakios_metal_commit entries[3];
    for (unsigned i = 0; i < 3; i++) {
        auto* cb = hakios_metal_cb_new(q);
        if (i == 1) hakios_metal_cb_fail(cb, "batch recording failed");
        contexts[i] = {i, &calls};
        entries[i] = {cb, [](hakios_metal_cb* done, void* p) {
            auto& context = *static_cast<Context*>(p);
            CHECK(hakios_metal_cb_status(done) == (context.index == 1 ? HAKIOS_METAL_ERROR : HAKIOS_METAL_COMPLETED));
            if (context.index == 1) CHECK(strstr(hakios_metal_cb_error(done), "batch recording failed") != nullptr);
            context.calls->push_back(context.index);
        }, &contexts[i]};
    }
    hakios_metal_queue_commit_batch(q, entries, 3);
    for (auto& entry : entries) hakios_metal_cb_wait(entry.cb);
    CHECK(calls == std::vector<unsigned>({0, 1, 2}));
    for (auto& entry : entries) hakios_metal_cb_free(entry.cb);
    hakios_metal_queue_free(q);
    hakios_metal_close(d);
}

TEST(batch_word_limit_includes_append_stream_nops) {
    auto transport = std::make_unique<BatchGpu>();
    auto* f = transport.get();
    Gpu gpu(std::move(transport));
    std::string why;
    auto q = CommandQueue::make(gpu, &why);
    auto memory = newBuffer(gpu, 4096, &why);
    std::vector<std::shared_ptr<CommandBuffer>> buffers;
    for (unsigned i = 0; i < 4; i++) {
        auto cb = q->commandBuffer();
        while (cb->streamWords() < 8190) CHECK(cb->fill(*memory, 0, 4, 0x33));
        CHECK_EQ(cb->streamWords(), 8190u); // the two commit tail words make exactly 8192 per CB
        buffers.push_back(cb);
    }
    q->commitBatch(buffers);
    for (auto& cb : buffers) cb->waitUntilCompleted();
    CHECK_EQ(f->attempts, 2u); // four raw streams fit; their append NOPs do not
    CHECK(f->stats().maxSubmitWords <= 32768);
    CHECK_EQ(f->stats().faults, 0u);
}

TEST(staged_serial_private_commits_merge_at_idle_and_count_limit) {
    auto transport = std::make_unique<BatchGpu>();
    auto* f = transport.get();
    Gpu gpu(std::move(transport));
    std::string why;
    auto q = CommandQueue::make(gpu, &why);
    auto memory = newBuffer(gpu, 4096, &why);
    std::vector<std::shared_ptr<CommandBuffer>> buffers;
    for (unsigned i = 0; i < 11; i++) {
        auto cb = q->commandBuffer();
        CHECK(cb->fill(*memory, i * 4, 4, uint8_t(i + 1)));
        cb->keep(memory);
        q->stageBatch({cb});
        buffers.push_back(cb);
        if (i < 7) CHECK_EQ(f->attempts, 0u);
    }
    CHECK_EQ(f->attempts, 1u);
    CHECK_EQ(q->drainCounts()[CommandQueue::kLimit], 1u);
    q->drain(CommandQueue::kIdle);
    for (auto& cb : buffers) cb->waitUntilCompleted();
    CHECK_EQ(f->attempts, 2u);
    CHECK_EQ(q->drainCounts()[CommandQueue::kIdle], 1u);
    CHECK_EQ(buffers[0]->counts().merged, 7u);
    CHECK_EQ(buffers[8]->counts().merged, 2u);
    auto* bytes = static_cast<const uint8_t*>(memory->contents());
    for (unsigned i = 0; i < 11; i++) CHECK_EQ(bytes[i * 4], i + 1);
}

TEST(staged_word_limit_counts_closed_pass_tails_and_append_nops) {
    auto transport = std::make_unique<BatchGpu>();
    auto* f = transport.get();
    Gpu gpu(std::move(transport));
    std::string why;
    auto q = CommandQueue::make(gpu, &why);
    auto memory = newBuffer(gpu, 4096, &why);
    std::vector<std::shared_ptr<CommandBuffer>> buffers;
    for (unsigned i = 0; i < 4; i++) {
        auto cb = q->commandBuffer();
        while (cb->streamWords() < 8190) CHECK(cb->fill(*memory, 0, 4, 0x33));
        q->stageBatch({cb});
        buffers.push_back(cb);
    }
    CHECK_EQ(q->drainCounts()[CommandQueue::kLimit], 1u);
    CHECK_EQ(f->attempts, 1u);
    q->drain(CommandQueue::kIdle);
    for (auto& cb : buffers) cb->waitUntilCompleted();
    CHECK_EQ(f->attempts, 2u);
    CHECK(f->stats().maxSubmitWords <= 32768);
}

TEST(staged_iosurface_write_and_present_publish_real_fence_before_return) {
    for (bool present : {false, true}) {
        auto transport = std::make_unique<BatchGpu>();
        auto* f = transport.get();
        f->addSurface(91, 16, 16, 64, 0x42475241);
        f->pause();
        Gpu gpu(std::move(transport));
        std::string why;
        auto q = CommandQueue::make(gpu, &why);
        auto privateMemory = newBuffer(gpu, 4096, &why);
        SurfaceInfo info;
        auto surface = surfaceBuffer(gpu, 91, &info, &why);
        auto a = q->commandBuffer(), b = q->commandBuffer();
        CHECK(a->fill(*privateMemory, 0, 4, 7)); a->keep(privateMemory);
        CHECK(b->fill(*(present ? privateMemory : surface), 4, 4, 9));
        b->keep(present ? privateMemory : surface);
        q->stageBatch({a});
        CHECK_EQ(f->attempts, 0u);
        q->stageBatch({b}, present ? CommandQueue::kSurface : CommandQueue::kIdle);
        CHECK_EQ(f->attempts, 1u);
        CHECK_EQ(f->published.size(), 1u);
        CHECK_EQ(q->drainCounts()[CommandQueue::kSurface], 1u);
        CHECK_EQ(a->status(), CommandBuffer::kScheduled);
        CHECK_EQ(b->status(), CommandBuffer::kScheduled);
        f->resume();
        b->waitUntilCompleted();
    }
}

TEST(staged_cross_queue_read_drains_producer_at_encoding_and_preserves_bytes) {
    for (bool preRecorded : {false, true}) {
        auto transport = std::make_unique<BatchGpu>();
        auto* f = transport.get();
        Gpu gpu(std::move(transport));
        std::string why;
        auto producer = CommandQueue::make(gpu, &why), consumer = CommandQueue::make(gpu, &why);
        auto source = newBuffer(gpu, 4096, &why), target = newBuffer(gpu, 4096, &why);
        auto a = producer->commandBuffer(), b = consumer->commandBuffer();
        CHECK(a->fill(*source, 0, 4, 0x6a)); a->keep(source);
        if (preRecorded) CHECK(b->copy(*source, 0, *target, 0, 4));
        producer->stageBatch({a});
        CHECK_EQ(f->attempts, 0u);
        if (!preRecorded) CHECK(b->copy(*source, 0, *target, 0, 4));
        b->keep(source); b->keep(target);
        CHECK_EQ(f->attempts, preRecorded ? 0u : 1u);
        consumer->stageBatch({b});
        CHECK_EQ(f->attempts, 1u);
        CHECK_EQ(producer->drainCounts()[CommandQueue::kCrossQueue], 1u);
        b->waitUntilCompleted();
        CHECK_EQ(f->attempts, 2u);
        CHECK_EQ(static_cast<const uint8_t*>(target->contents())[0], 0x6au);
    }
}

TEST(staged_cpu_resource_sync_and_wait_drain_without_virtual_scheduling) {
    for (bool resourceSync : {false, true}) {
        auto transport = std::make_unique<BatchGpu>();
        auto* f = transport.get();
        f->pause();
        Gpu gpu(std::move(transport));
        std::string why;
        auto q = CommandQueue::make(gpu, &why);
        auto memory = newBuffer(gpu, 4096, &why);
        auto cb = q->commandBuffer();
        CHECK(cb->fill(*memory, 0, 4, 0x31)); cb->keep(memory);
        std::atomic<bool> scheduled{false}, completed{false};
        cb->setScheduledHandler([&] { CHECK_EQ(f->published.size(), 1u); scheduled = true; });
        cb->addCompletedHandler([&](CommandBuffer&) { CHECK(scheduled.load()); completed = true; });
        q->stageBatch({cb});
        CHECK_EQ(cb->status(), CommandBuffer::kCommitted);
        CHECK(!scheduled.load() && !completed.load());
        std::thread cpu([&] {
            if (resourceSync) CHECK_EQ(CommandQueue::synchronize(memory->bo()), 0);
            else cb->waitUntilCompleted();
        });
        while (!scheduled.load()) std::this_thread::yield();
        CHECK(!completed.load());
        f->resume(); cpu.join(); cb->waitUntilCompleted();
        CHECK(completed.load());
        CHECK_EQ(q->drainCounts()[CommandQueue::kCpuSync], 1u);
    }
}

TEST(c_api_staged_callbacks_keep_order_across_deferred_recording_and_error) {
    for (bool deferred : {false, true}) {
        auto* d = hakios_metal_open_fake(); auto* q = hakios_metal_queue_new(d);
        hakios_metal_queue_set_deferred(q, deferred);
        auto* b = hakios_metal_buffer_new(d, 4096);
        std::vector<unsigned> scheduled, completed;
        struct Context { unsigned index; std::vector<unsigned>* scheduled; std::vector<unsigned>* completed; } contexts[4];
        hakios_metal_cb* buffers[4];
        for (unsigned i = 0; i < 4; i++) {
            buffers[i] = hakios_metal_cb_new(q);
            CHECK_EQ(hakios_metal_cb_fill(buffers[i], b, i * 4, 4, i + 1), 0);
            if (i == 1) hakios_metal_cb_fail(buffers[i], "staged error");
            contexts[i] = {i, &scheduled, &completed};
            hakios_metal_commit entry{buffers[i], [](hakios_metal_cb*, void* p) {
                auto& c = *static_cast<Context*>(p); c.completed->push_back(c.index);
            }, &contexts[i]};
            unsigned reason = HAKIOS_METAL_DRAIN_IDLE;
            hakios_metal_queue_stage_batch(q, &entry, 1, [](hakios_metal_cb* cb, void* p) {
                auto& c = *static_cast<Context*>(p);
                CHECK(hakios_metal_cb_status(cb) >= HAKIOS_METAL_SCHEDULED);
                c.scheduled->push_back(c.index);
            }, &reason);
        }
        CHECK(scheduled.empty() && completed.empty());
        hakios_metal_cb_wait(buffers[3]);
        CHECK(scheduled == std::vector<unsigned>({0, 2, 3}));
        CHECK(completed == std::vector<unsigned>({0, 1, 2, 3}));
        CHECK_EQ(static_cast<uint8_t*>(hakios_metal_buffer_contents(b))[12], 4u);
        for (auto* cb : buffers) hakios_metal_cb_free(cb);
        hakios_metal_buffer_free(b); hakios_metal_queue_free(q); hakios_metal_close(d);
    }
}

TEST(c_api_staged_cpu_contents_modify_and_texture_readback_drain) {
    for (unsigned sync = 0; sync < 5; sync++) {
        auto* d = hakios_metal_open_fake(); auto* q = hakios_metal_queue_new(d);
        auto* b = hakios_metal_buffer_new(d, 4096);
        auto* t = hakios_metal_texture_new(d, 2, 70, 16, 16, 1 | 2 | 4);
        auto* cb = hakios_metal_cb_new(q);
        CHECK_EQ(hakios_metal_cb_fill(cb, b, 0, 4, 0x2a), 0);
        hakios_metal_render_pass pass{};
        pass.color0 = t; pass.load_action = 2; pass.store_action = 1; pass.clear_color[0] = 1; pass.clear_color[3] = 1;
        CHECK_EQ(hakios_metal_cb_clear(cb, &pass), 0);
        CHECK(hakios_metal_texture_is_complete(t)); // recorded work is not a committed GPU use
        unsigned reason = HAKIOS_METAL_DRAIN_IDLE;
        hakios_metal_commit entry{cb, nullptr, nullptr};
        hakios_metal_queue_stage_batch(q, &entry, 1, nullptr, &reason);
        CHECK_EQ(hakios_metal_cb_status(cb), HAKIOS_METAL_COMMITTED);
        CHECK(!hakios_metal_texture_is_complete(t));
        uint8_t pixel[4]{};
        if (sync == 0) CHECK_EQ(static_cast<uint8_t*>(hakios_metal_buffer_contents(b))[0], 0x2au);
        if (sync == 1) CHECK_EQ(hakios_metal_buffer_sync(b), 0);
        if (sync == 2) {
            CHECK_EQ(hakios_metal_texture_read(t, 0, 0, 1, 1, pixel, 4), 0); CHECK_EQ(pixel[0], 255u);
        }
        if (sync == 3) CHECK_EQ(static_cast<uint8_t*>(hakios_metal_texture_contents(t))[0], 255u);
        if (sync == 4) CHECK_EQ(hakios_metal_texture_sync(t), 0);
        CHECK(hakios_metal_cb_status(cb) >= HAKIOS_METAL_SCHEDULED);
        hakios_metal_cb_free(cb); hakios_metal_texture_free(t); hakios_metal_buffer_free(b);
        hakios_metal_queue_free(q); hakios_metal_close(d);
    }
}

TEST(pencil_tile_completion_waits_for_render_target_backing_through_aliases) {
    for (bool surface : {false, true}) {
        auto transport = std::make_unique<BatchGpu>();
        auto* f = transport.get();
        f->addSurface(92, 16, 16, 64, 0x42475241);
        f->pause();
        Gpu gpu(std::move(transport));
        std::string why;
        auto q = CommandQueue::make(gpu, &why);
        TextureDesc desc;
        desc.width = desc.height = 16;
        desc.format = PixelFormat::kBGRA8Unorm;
        desc.usage = kTextureUsageRenderTarget | kTextureUsageRead;
        auto tile = surface ? Texture::wrapSurface(gpu, 92, desc, &why) : Texture::make(gpu, desc, &why);
        auto alias = surface ? Texture::wrapSurface(gpu, 92, desc, &why) :
            Texture::view(tile, desc.format, desc.type, 0, 1, 0, 1, &why);
        CHECK(tile != nullptr && alias != nullptr);
        CHECK(tile->buffer() == alias->buffer());
        RenderPass pass;
        pass.color0 = tile.get(); pass.load = LoadAction::kClear; pass.clearColor[0] = pass.clearColor[3] = 1;
        auto cb = q->commandBuffer();
        CHECK(cb->clear(pass)); // persistent tile write, with no sampled texture binding
        CHECK(CommandQueue::isComplete(alias->buffer()->bo()));
        q->stageBatch({cb});
        CHECK(!CommandQueue::isComplete(alias->buffer()->bo()));
        q->drain(CommandQueue::kIdle);
        CHECK(!CommandQueue::isComplete(alias->buffer()->bo()));
        std::atomic<bool> returned{false};
        std::thread finishImage([&] {
            CHECK_EQ(CommandQueue::synchronize(alias->buffer()->bo()), 0);
            returned = true;
        });
        for (;;) {
            std::lock_guard<std::mutex> lock(f->gate);
            if (f->waited.size() >= 2) break; // queue waiter and the resource waiter both reached a real fence
        }
        CHECK(!returned.load());
        f->resume(); finishImage.join(); cb->waitUntilCompleted();
        CHECK(returned.load());
        CHECK(CommandQueue::isComplete(alias->buffer()->bo()));
        if (!surface) {
            // Finger-up copies the new stroke into the persistent tile; the next stroke must keep its previous pixel.
            auto trail = Texture::make(gpu, desc, &why);
            TextureDesc maskDesc = desc;
            maskDesc.format = PixelFormat::kR8Unorm;
            auto mask = Texture::make(gpu, maskDesc, &why);
            RenderPass paint;
            paint.color0 = trail.get(); paint.load = LoadAction::kClear;
            paint.clearColor[2] = paint.clearColor[3] = 1;
            paint.more[0].texture = mask.get(); paint.more[0].load = LoadAction::kClear;
            paint.more[0].store = StoreAction::kDontCare;
            auto next = q->commandBuffer();
            CHECK(next->clear(paint));
            CHECK(next->blit(*trail, 0, {0, 0, 1, 1}, *tile, 0, {1, 0, 1, 1}, false));
            q->stageBatch({next});
            CHECK(!CommandQueue::isComplete(alias->buffer()->bo()));
            CHECK_EQ(CommandQueue::synchronize(alias->buffer()->bo()), 0);
            uint8_t pixels[8]{};
            CHECK(alias->read(0, 0, 2, 1, pixels, sizeof pixels, &why));
            const uint8_t expected[] = {0, 0, 255, 255, 255, 0, 0, 255}; // BGRA: previous red, new blue
            CHECK_EQ(std::memcmp(pixels, expected, sizeof pixels), 0);
            next->waitUntilCompleted();
        }
        CHECK_EQ(f->stats().faults, 0u);
    }
}

TEST(staged_bo_cache_cannot_reuse_retained_unsubmitted_resource) {
    auto* d = hakios_metal_open_fake(); auto* q = hakios_metal_queue_new(d);
    auto context = hakios_metal_bo_context(hm_bo_key(0, 0, HM_BO_BUFFER));
    auto* b = hakios_metal_buffer_new(d, 4096);
    auto address = hakios_metal_buffer_gpu_address(b);
    auto* cb = hakios_metal_cb_new(q);
    CHECK_EQ(hakios_metal_cb_fill(cb, b, 0, 4, 0x42), 0);
    unsigned reason = HAKIOS_METAL_DRAIN_IDLE;
    hakios_metal_commit entry{cb, nullptr, nullptr};
    hakios_metal_queue_stage_batch(q, &entry, 1, nullptr, &reason);
    hakios_metal_buffer_free(b);
    auto* other = hakios_metal_buffer_new(d, 4096);
    CHECK(hakios_metal_buffer_gpu_address(other) != address);
    CHECK_EQ(hakios_metal_cb_status(cb), HAKIOS_METAL_COMMITTED);
    hakios_metal_cb_wait(cb);
    auto* reused = hakios_metal_buffer_new(d, 4096);
    CHECK_EQ(hakios_metal_buffer_gpu_address(reused), address);
    hakios_metal_bo_context(context);
    hakios_metal_cb_free(cb); hakios_metal_buffer_free(other); hakios_metal_buffer_free(reused);
    hakios_metal_queue_free(q); hakios_metal_close(d);
}

TEST(c_api_staged_gpu_written_constants_copied_at_encode_are_synchronized) {
    if (!hakios_metal_has_compiler()) return;
    auto* kernel = hakios_metal_kernel_compile_bitcode(kernels::fill_id_bc, sizeof kernels::fill_id_bc);
    CHECK(kernel != nullptr);
    for (bool deferred : {false, true}) {
        auto* d = hakios_metal_open_fake(); auto* q = hakios_metal_queue_new(d);
        hakios_metal_queue_set_deferred(q, deferred);
        auto* constants = hakios_metal_buffer_new(d, 128); auto* output = hakios_metal_buffer_new(d, 4096);
        auto* cpuConstants = static_cast<const uint32_t*>(hakios_metal_buffer_contents(constants));
        auto* producer = hakios_metal_cb_new(q);
        CHECK_EQ(hakios_metal_cb_fill(producer, constants, 4, 64, 0x21), 0);
        unsigned reason = HAKIOS_METAL_DRAIN_IDLE;
        hakios_metal_commit entry{producer, nullptr, nullptr};
        hakios_metal_queue_stage_batch(q, &entry, 1, nullptr, &reason);
        auto* consumer = hakios_metal_cb_new(q);
        hakios_metal_buffer* buffers[] = {output, constants}; uint64_t offsets[] = {0, 4};
        const unsigned groups[] = {1, 1, 1}, threads[] = {64, 1, 1};
        CHECK_EQ(hakios_metal_cb_dispatch(consumer, kernel, groups, threads, buffers, offsets, 2), 0);
        CHECK(hakios_metal_cb_status(producer) >= HAKIOS_METAL_SCHEDULED);
        CHECK_EQ(cpuConstants[1], 0x21212121u); // visible before dispatch returns, without another CPU sync
        hakios_metal_cb_commit(consumer, nullptr, nullptr); hakios_metal_cb_wait(consumer);
        hakios_metal_cb_free(producer); hakios_metal_cb_free(consumer);
        hakios_metal_buffer_free(constants); hakios_metal_buffer_free(output);
        hakios_metal_queue_free(q); hakios_metal_close(d);
    }
    hakios_metal_kernel_free(kernel);
}
