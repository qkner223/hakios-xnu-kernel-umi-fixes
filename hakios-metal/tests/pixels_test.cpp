// The CA plug-in's processor-side pixels (userland/src/HakiosMetalPixels.h), run here as the plug-in runs them: a
// two-plane YCbCr surface ('420v' / '420f') made into the RGBA8 copy the GPU samples for Metal's private formats 500
// and 540, the test for a frame whose chroma nobody has written (the green flash of a video in Safari), and the census
// of flat pictures (the purple placeholder of the materials).
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "../../userland/src/HakiosMetalPixels.h"
#include "test.hpp"

namespace {

// a W x H '420v'/'420f' surface's planes, 64-byte rows as MiniIOSurface lays them out, each filled with one value
struct Nv12 {
    size_t w, h, lumaRow, chromaRow, cw, ch;
    std::vector<uint8_t> luma, chroma;
    Nv12(size_t w_, size_t h_, uint8_t y, uint8_t cb, uint8_t cr) : w(w_), h(h_) {
        lumaRow = (w + 63) / 64 * 64;
        cw = (w + 1) / 2;
        ch = (h + 1) / 2;
        chromaRow = (2 * cw + 63) / 64 * 64;
        luma.assign(lumaRow * h, y);
        chroma.assign(chromaRow * ch, 0);
        for (size_t j = 0; j < ch; j++) {
            for (size_t i = 0; i < cw; i++) {
                chroma[j * chromaRow + 2 * i] = cb;
                chroma[j * chromaRow + 2 * i + 1] = cr;
            }
        }
    }
    hm_ycc_planes planes() const { return hm_ycc_planes{luma.data(), lumaRow, chroma.data(), chromaRow, cw, ch}; }
};

std::vector<uint8_t> convert(const Nv12& s, int matrix, int full, int raw) {
    std::vector<uint8_t> out(s.w * s.h * 4, 0xee);
    const hm_ycc_planes p = s.planes();
    hm_ycc_convert(&p, s.w, s.h, matrix, full, raw, out.data(), s.w * 4);
    return out;
}

}  // namespace

TEST(ycbcr_video_range_black_white_and_grey_are_neutral) {
    for (int m : {HM_YCC_601, HM_YCC_709, HM_YCC_2020}) {
        auto black = convert(Nv12(66, 34, 16, 128, 128), m, 0, 0);
        auto white = convert(Nv12(66, 34, 235, 128, 128), m, 0, 0);
        CHECK_EQ(black[0], 0);
        CHECK_EQ(black[1], 0);
        CHECK_EQ(black[2], 0);
        CHECK_EQ(black[3], 255);
        CHECK_EQ(white[0], 255);
        CHECK_EQ(white[1], 255);
        CHECK_EQ(white[2], 255);
        // the last pixel of the last row too: the odd sizes' chroma clamp
        const size_t last = (34 * 66 - 1) * 4;
        CHECK_EQ(white[last], 255);
        CHECK_EQ(white[last + 1], 255);
    }
    auto grey = convert(Nv12(8, 8, 128, 128, 128), HM_YCC_709, 1, 0);
    CHECK_EQ(grey[0], 128);
    CHECK_EQ(grey[1], 128);
    CHECK_EQ(grey[2], 128);
}

TEST(ycbcr_bt709_and_bt601_primaries_come_out_where_the_matrices_put_them) {
    // 100% red in BT.709 video range: Y 63, Cb 102, Cr 240 (ITU-R BT.709 table, 8 bits)
    auto red709 = convert(Nv12(16, 16, 63, 102, 240), HM_YCC_709, 0, 0);
    CHECK(red709[0] >= 253);
    CHECK(red709[1] <= 2);
    CHECK(red709[2] <= 2);
    // the same signal read with BT.601 is a duller red (the shift a 709 video had read as 601)
    auto red601 = convert(Nv12(16, 16, 63, 102, 240), HM_YCC_601, 0, 0);
    CHECK(red601[0] < 245);
    // 100% blue in BT.601 full range: Y 29, Cb 255, Cr 107
    auto blue601 = convert(Nv12(16, 16, 29, 255, 107), HM_YCC_601, 1, 0);
    CHECK(blue601[0] <= 2);
    CHECK(blue601[1] <= 2);
    CHECK(blue601[2] >= 253);
}

TEST(ycbcr_raw_540_is_the_planes_as_they_are) {
    auto raw = convert(Nv12(10, 6, 77, 33, 200), HM_YCC_601, 1, 1);
    CHECK_EQ(raw[0], 200);   // R: Cr
    CHECK_EQ(raw[1], 77);    // G: Y
    CHECK_EQ(raw[2], 33);    // B: Cb
    CHECK_EQ(raw[3], 255);
}

TEST(ycbcr_chroma_is_sited_per_two_by_two_block) {
    Nv12 s(4, 4, 128, 128, 128);
    // the top-right pair saturated: pixels (2..3, 0..1) take it, the others stay grey
    s.chroma[2] = 255;
    s.chroma[3] = 255;
    auto out = convert(s, HM_YCC_601, 1, 0);
    auto px = [&](size_t x, size_t y) { return &out[(y * 4 + x) * 4]; };
    CHECK(px(0, 0)[0] == 128 && px(1, 1)[0] == 128);
    CHECK(px(2, 0)[0] == 255 && px(3, 1)[0] == 255);
    CHECK(px(2, 2)[0] == 128);
}

// Zero-valued chroma is pixel data, not a producer readiness signal.
TEST(ycbcr_zero_chroma_is_converted) {
    Nv12 zero(64, 36, 0, 0, 0);
    auto rgb = convert(zero, HM_YCC_709, 0, 0);
    CHECK(rgb[0] == 0 && rgb[2] == 0 && rgb[1] > 60 && rgb[3] == 255);
}

// The v8 green: only a (0, 0) CbCr pair turns green; the measurement finds exactly those pairs and their rows.
TEST(ycbcr_unwritten_420v_pairs_are_counted_by_row) {
    Nv12 s(478, 360, 100, 120, 140);
    hm_ycc_unwritten u;
    hm_ycc_planes p = s.planes();
    hm_ycc_measure_unwritten(&p, s.w, s.h, &u);
    CHECK(u.zeroY == 0 && u.zeroC == 0);
    for (size_t j = 170; j < s.ch; j++) std::memset(&s.chroma[j * s.chromaRow], 0, 2 * s.cw);
    s.luma[5] = 0;
    p = s.planes();
    hm_ycc_measure_unwritten(&p, s.w, s.h, &u);
    CHECK_EQ(u.zeroY, size_t(1));
    CHECK_EQ(u.zeroC, size_t(10 * 239));
    CHECK(u.rowFirst == 170 && u.rowLast == 179);
}

TEST(ycbcr_matrix_names_are_coreVideos) {
    CHECK_EQ(hm_ycc_matrix_named("ITU_R_709_2"), HM_YCC_709);
    CHECK_EQ(hm_ycc_matrix_named("ITU_R_601_4"), HM_YCC_601);
    CHECK_EQ(hm_ycc_matrix_named("ITU_R_2020"), HM_YCC_2020);
    CHECK_EQ(hm_ycc_matrix_named("SMPTE_240M_1995"), HM_YCC_240M);
    CHECK_EQ(hm_ycc_matrix_named("P3_D65"), HM_YCC_UNKNOWN);
    CHECK_EQ(hm_ycc_matrix_named(nullptr), HM_YCC_UNKNOWN);
}

TEST(flat_pictures_are_found_by_pixel_and_by_astc_void_extent) {
    // 846 x 1827 ASTC 4x4 of void-extent blocks RGBA16 (5959, 1414, 5959, ffff): the purple of logs/212646
    const size_t bw = (846 + 3) / 4, bh = (1827 + 3) / 4, row = bw * 16;
    std::vector<uint8_t> astc(row * bh);
    const uint8_t block[16] = {0xfc, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x59, 0x59, 0x14, 0x14, 0x59, 0x59, 0xff, 0xff};
    for (size_t i = 0; i < bw * bh; i++) std::memcpy(&astc[i * 16], block, 16);
    uint8_t c[4];
    int hdr = -1;
    CHECK(hm_picture_flat(204, 846, 1827, astc.data(), row, c, &hdr));
    CHECK(c[0] == 0x59 && c[1] == 0x14 && c[2] == 0x59 && c[3] == 0xff);
    CHECK_EQ(hdr, 0);
    CHECK(hm_rgba_magenta(c));
    // one block of another colour where the grid samples it: not flat
    astc[(bh - 1) * row + (bw - 1) * 16 + 10] = 0x80;
    CHECK(!hm_picture_flat(204, 846, 1827, astc.data(), row, c, &hdr));
    // a block that is not a void extent: not flat
    astc[(bh - 1) * row + (bw - 1) * 16 + 10] = 0x14;
    astc[0] = 0x42;
    CHECK(!hm_picture_flat(204, 846, 1827, astc.data(), row, c, &hdr));

    // BGRA8 (179, 77, 179) as SpringBoard's switcher wash: flat, magenta; RGBA8 grey: flat, not magenta
    std::vector<uint8_t> bgra(256 * 4 * 128);
    for (size_t i = 0; i < 256 * 128; i++) {
        bgra[4 * i] = 179;
        bgra[4 * i + 1] = 77;
        bgra[4 * i + 2] = 179;
        bgra[4 * i + 3] = 255;
    }
    CHECK(hm_picture_flat(80, 256, 128, bgra.data(), 256 * 4, c, nullptr));
    CHECK(c[0] == 179 && c[1] == 77 && c[2] == 179);
    CHECK(hm_rgba_magenta(c));
    const uint8_t grey[4] = {90, 90, 90, 255};
    CHECK(!hm_rgba_magenta(grey));
    // too small to say, or a format it does not read
    CHECK(!hm_picture_flat(80, 32, 32, bgra.data(), 32 * 4, c, nullptr));
    CHECK(!hm_picture_flat(115, 256, 128, bgra.data(), 256 * 4, c, nullptr));
    // ASTC block sizes by Metal's numbers
    unsigned w = 0, h = 0;
    CHECK(hm_astc_block(186, &w, &h) && w == 4 && h == 4);
    CHECK(hm_astc_block(210, &w, &h) && w == 8 && h == 5);
    CHECK(hm_astc_block(236, &w, &h) && w == 12 && h == 12);
    CHECK(!hm_astc_block(191, &w, &h));
}

TEST(ycbcr_bands_converted_apart_are_the_picture_converted_whole) {
    Nv12 s(70, 37, 0, 0, 0);
    for (size_t i = 0; i < s.luma.size(); i++) s.luma[i] = uint8_t(i * 7);
    for (size_t i = 0; i < s.chroma.size(); i++) s.chroma[i] = uint8_t(i * 13 + 5);
    auto whole = convert(s, HM_YCC_709, 0, 0);
    std::vector<uint8_t> bands(whole.size(), 0);
    const hm_ycc_planes p = s.planes();
    const size_t cuts[] = {0, 10, 20, 30, 37};
    for (int b = 0; b < 4; b++) hm_ycc_convert_rows(&p, s.w, s.h, cuts[b], cuts[b + 1], HM_YCC_709, 0, 0, bands.data(), s.w * 4);
    CHECK(bands == whole);
}

TEST(flat_half_float_pictures_read_as_8_bits) {
    // RGBA16Float (an 'RGhA' surface, what SBRendererService draws a wide-colour treatment into): 0.702, 0.302, 0.702, 1
    std::vector<uint8_t> px(128 * 8 * 96);
    const uint16_t half[4] = {0x399e, 0x34d5, 0x399e, 0x3c00};
    for (size_t i = 0; i < 128 * 96; i++) std::memcpy(&px[i * 8], half, 8);
    uint8_t c[4];
    CHECK(hm_picture_flat(115, 128, 96, px.data(), 128 * 8, c, nullptr));
    CHECK(c[0] >= 178 && c[0] <= 180 && c[1] >= 76 && c[1] <= 78 && c[3] == 255);
    CHECK(hm_rgba_magenta(c));
    CHECK_EQ(hm_half_to_8(0x0000), 0);
    CHECK_EQ(hm_half_to_8(0x3c00), 255);
    CHECK_EQ(hm_half_to_8(0x3800), 128);   // 0.5
    CHECK_EQ(hm_half_to_8(0xbc00), 0);     // negative
}
