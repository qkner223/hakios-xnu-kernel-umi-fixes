// Plane upload regressions from v7; FakeGpu validates dispatch bindings, not shader pixels.
#include <cstring>
#include <vector>
#include "hakios-metal/command.hpp"
#include "hakios-metal/compiler.hpp"
#include "hakios-metal/fake_gpu.hpp"
#include "hakios-metal/texture.hpp"
#include "../../userland/src/HakiosMetalYCbCr.h"
#include "test.hpp"

using namespace hakios::metal;

TEST(ycbcr_plane_upload_accepts_byte_strides_and_offsets) {
    Gpu gpu(std::make_unique<FakeGpu>());
    struct Layout { unsigned w, h, yPitch, cPitch, yOffset, cOffset; };
    for (const Layout& l : {Layout{1125, 2436, 1136, 1136, 0, 2767296},
                            Layout{478, 360, 512, 512, 0, 188416},
                            Layout{478, 360, 788, 512, 0, 360 * 788 + 7},
                            Layout{787, 1705, 800, 800, 0, 1364800},
                            Layout{65, 33, 67, 69, 3, 2301}}) {
        const unsigned cw = (l.w + 1) / 2, ch = (l.h + 1) / 2;
        std::vector<uint8_t> source(l.cOffset + l.cPitch * ch, 0xa5);
        for (unsigned plane = 0; plane < 2; ++plane) {
            const unsigned w = plane ? cw : l.w, h = plane ? ch : l.h;
            const unsigned pitch = plane ? l.cPitch : l.yPitch, offset = plane ? l.cOffset : l.yOffset;
            const unsigned row = w * (plane ? 2 : 1);
            TextureDesc d;
            d.format = plane ? PixelFormat::kRG8Unorm : PixelFormat::kR8Unorm;
            d.width = w; d.height = h; d.usage = kTextureUsageRead;
            std::string why;
            auto texture = Texture::make(gpu, d, &why);
            CHECK(texture != nullptr);
            if (!texture) return;
            // Reuse the same texture through several new frames, including all-zero chroma.
            for (unsigned seed = 0; seed < 3; ++seed) {
                for (unsigned y = 0; y < h; ++y)
                    for (unsigned x = 0; x < row; ++x)
                        source[offset + y * pitch + x] = seed ? uint8_t(x + y + seed * 31) : 0;
                CHECK(texture->replace(0, 0, w, h, source.data() + offset, pitch, &why));
                std::vector<uint8_t> readback(row * h);
                CHECK(texture->read(0, 0, w, h, readback.data(), row, &why));
                for (unsigned y = 0; y < h; ++y)
                    CHECK(std::memcmp(readback.data() + y * row, source.data() + offset + y * pitch, row) == 0);
            }
        }
    }
}

TEST(ycbcr_embedded_kernel_compiles_and_dispatches_three_textures) {
    if (!hasCompiler()) return;
    std::string why;
    auto kernel = compileAir(ycbcr_convert_bc, ycbcr_convert_bc_size, &why);
    CHECK(kernel != nullptr);
    if (!kernel) { std::printf("       %s\n", why.c_str()); return; }
    CHECK_EQ(kernel->kernel.textures[0].kind, uint8_t(kTexSampled));
    CHECK_EQ(kernel->kernel.textures[1].kind, uint8_t(kTexSampled));
    CHECK_EQ(kernel->kernel.textures[2].kind, uint8_t(kTexImage));
    CHECK_EQ(kernel->kernel.textures[2].write, 1u);
    Gpu gpu(std::make_unique<FakeGpu>());
    auto queue = CommandQueue::make(gpu, &why);
    TextureDesc d;
    d.format = PixelFormat::kR8Unorm; d.width = 478; d.height = 360; d.usage = kTextureUsageRead;
    auto luma = Texture::make(gpu, d, &why);
    d.format = PixelFormat::kRG8Unorm; d.width = 239; d.height = 180;
    auto chroma = Texture::make(gpu, d, &why);
    d.format = PixelFormat::kRGBA8Unorm; d.width = 478; d.height = 360; d.usage |= kTextureUsageWrite;
    auto output = Texture::make(gpu, d, &why);
    auto params = newBuffer(gpu, 32, &why);
    CHECK(queue && luma && chroma && output && params);
    if (!queue || !luma || !chroma || !output || !params) return;
    std::memset(params->contents(), 0, 32);
    Bindings bindings;
    bindings.buffers = {{params.get(), 0}};
    bindings.textures = {luma.get(), chroma.get(), output.get()};
    const uint32_t groups[3] = {478, 360, 1}, local[3] = {1, 1, 1};
    auto cb = queue->commandBuffer();
    CHECK(cb->dispatch(kernel->kernel, groups, local, bindings));
    cb->commit();
    cb->waitUntilCompleted();
    CHECK_EQ(cb->status(), CommandBuffer::kCompleted);
    if (!cb->error().empty()) std::printf("       %s\n", cb->error().c_str());
}
