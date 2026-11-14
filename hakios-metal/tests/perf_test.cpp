#include "hakios-metal/command.hpp"
#include "hakios-metal/fake_gpu.hpp"
#include "hakios-metal/hakios_metal.h"
#include "hakios-metal/perf.h"
#include "hakios-metal/texture.hpp"
#include "../../devices/xiaomi-mi-10/overlays/xnu/files/iokit/Kernel/umi_frame_sample.h"
#include "test.hpp"
#include <algorithm>

using namespace hakios::metal;

TEST(frame_samples_compare_rgb_across_surface_storage_and_stride) {
    constexpr unsigned width = 128, height = 256, stride = 144;
    std::vector<uint32_t> a(width * height, 0xff123456), b(stride * height, 0x00123456);
    uint32_t sa[UMI_SAMPLE_PIXELS], sb[UMI_SAMPLE_PIXELS];
    umi_frame_sample(reinterpret_cast<const volatile uint8_t*>(a.data()), width, height, width * 4, sa);
    umi_frame_sample(reinterpret_cast<const volatile uint8_t*>(b.data()), width, height, stride * 4, sb);
    CHECK_EQ(umi_frame_sample_changes(sa, sb), 0u); // different alpha and row padding
    b[2 * stride + 2] ^= 1; // center of the first sampled cell
    umi_frame_sample(reinterpret_cast<const volatile uint8_t*>(b.data()), width, height, stride * 4, sb);
    CHECK_EQ(umi_frame_sample_changes(sa, sb), 1u);
    b[0] ^= 1; // unsampled changes are deliberately not counted: this is a lower bound
    umi_frame_sample(reinterpret_cast<const volatile uint8_t*>(b.data()), width, height, stride * 4, sb);
    CHECK_EQ(umi_frame_sample_changes(sa, sb), 1u);
    std::fill(b.begin(), b.end(), 0x00654321);
    umi_frame_sample(reinterpret_cast<const volatile uint8_t*>(b.data()), width, height, stride * 4, sb);
    CHECK_EQ(umi_frame_sample_changes(sa, sb), unsigned(UMI_SAMPLE_PIXELS));
}

TEST(perf_distinguishes_direct_allocation_pool_miss_and_reuse) {
    Gpu gpu(std::make_unique<FakeGpu>());
    std::string why;
    auto queue = CommandQueue::make(gpu, &why);
    hm_perf_stat stats[HM_PERF_COUNT];
    hakios_metal_perf_take(stats);
    hakios_metal_perf_enable(0);
    auto uncounted = newBuffer(gpu, 4096, &why);
    hakios_metal_perf_take(stats);
    CHECK_EQ(stats[HM_PERF_BO].count, 0ull);

    hakios_metal_perf_enable(1);
    auto direct = newBuffer(gpu, 4096, &why);
    auto pooled = queue->takeBuffer(4096, &why);
    auto* contents = static_cast<uint8_t*>(pooled->contents());
    contents[0] = 42;
    queue->giveBuffer(std::move(pooled));
    auto reused = queue->takeBuffer(4096, &why);
    CHECK(reused->contents() == contents);
    CHECK_EQ(static_cast<uint8_t*>(reused->contents())[0], 0u);
    hakios_metal_perf_take(stats);
    CHECK_EQ(stats[HM_PERF_BO].count, 2ull);
    CHECK_EQ(stats[HM_PERF_BO].bytes, 8192ull);
    CHECK_EQ(stats[HM_PERF_NEW_IOCTL].count, 2ull);
    CHECK_EQ(stats[HM_PERF_MAP].count, 2ull);
    CHECK_EQ(stats[HM_PERF_POOL_HIT].count, 1ull);
    CHECK_EQ(stats[HM_PERF_POOL_MISS].count, 1ull);
    CHECK(stats[HM_PERF_BO].wall > 0);
    CHECK(stats[HM_PERF_BO].cpu > 0);

    auto cb = queue->commandBuffer();
    CHECK(cb->fill(*direct, 0, 4096, 0x5a));
    cb->commit();
    cb->waitUntilCompleted();
    hakios_metal_perf_enable(0);
    hakios_metal_perf_take(stats);
    CHECK(cb->status() == CommandBuffer::kCompleted);
    CHECK_EQ(static_cast<uint8_t*>(direct->contents())[0], 0x5au);
    CHECK_EQ(stats[HM_PERF_SUBMIT].count, 1ull);
    CHECK_EQ(stats[HM_PERF_SUBMIT_IOCTL].count, 1ull);
    CHECK_EQ(stats[HM_PERF_UPLOAD].count, 1ull);
    CHECK(stats[HM_PERF_UPLOAD].bytes > 0);
    hakios_metal_perf_take(stats);
    for (const auto& stat : stats) CHECK_EQ(stat.count, 0ull);

    unsigned made, taken;
    unsigned long long bytes;
    hakios_metal_buffer_counts(&made, &taken, &bytes);
    CHECK(newBuffer(gpu, 0, &why) == nullptr);
    hakios_metal_buffer_counts(&made, &taken, &bytes);
    CHECK_EQ(made, 0u);
    CHECK_EQ(bytes, 0ull); // failed requests must not look like allocation churn
}

TEST(attachments_made_are_counted_apart_from_other_buffers) {
    Gpu gpu(std::make_unique<FakeGpu>());
    std::string why;
    unsigned made, taken, attachments;
    unsigned long long bytes, attachmentBytes;
    hakios_metal_buffer_counts(&made, &taken, &bytes);
    hakios_metal_attachment_counts(&attachments, &attachmentBytes);
    TextureDesc one;
    one.width = 100;
    one.height = 10;
    one.usage = kTextureUsageRenderTarget;
    TextureDesc four = one;
    four.type = TextureType::k2DMultisample;
    four.samples = 4;
    auto single = Texture::make(gpu, one, &why);
    auto msaa = Texture::make(gpu, four, &why);
    CHECK(single != nullptr && msaa != nullptr);
    hakios_metal_buffer_counts(&made, &taken, &bytes);
    hakios_metal_attachment_counts(&attachments, &attachmentBytes);
    CHECK_EQ(made, 2u);
    CHECK_EQ(attachments, 1u);   // the multisample one; the single-sample render target is not an attachment's buffer
    CHECK(attachmentBytes > 0 && attachmentBytes < bytes);
}
