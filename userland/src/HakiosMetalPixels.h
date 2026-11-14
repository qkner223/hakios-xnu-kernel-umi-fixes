/*
 * Pixels the CA Metal plug-in (HakiosMetalCA.m) looks at on the processor, as plain C so that the host tests
 * (hakios-metal/tests/pixels_test.cpp) run this very code:
 *
 *   - a two-plane YCbCr surface ('420v', '420f', and the 4:2:2 / 4:4:4 ones laid out the same way) made into the RGBA8
 *     copy the GPU samples (-hakiosConvertYCbCr), with the matrix the surface declares and a test for a frame nobody has
 *     written yet: a chroma plane that reads all zeroes, which converted is the green of Cb = Cr = 0;
 *   - a picture that is one flat colour (a census of what clients upload: the purple placeholder of the materials).
 *
 * Everything here is static and inline: the plug-in links with -undefined dynamic_lookup, so nothing in it may be a
 * symbol of its own that something else expects to find (CLAUDE.md, v2's dyld crash).
 */
#ifndef HAKIOS_METAL_PIXELS_H
#define HAKIOS_METAL_PIXELS_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* the matrices a surface may declare: CoreVideo's names (kCVImageBufferYCbCrMatrix_*), which it sets on the surface as
 * the value of "CVImageBufferYCbCrMatrix" when a buffer's attachments propagate */
enum { HM_YCC_UNKNOWN = 0, HM_YCC_601 = 1, HM_YCC_709 = 2, HM_YCC_2020 = 3, HM_YCC_240M = 4 };

static inline int
hm_ycc_matrix_named(const char *name)
{
	if (name == NULL) return HM_YCC_UNKNOWN;
	if (strstr(name, "709") != NULL) return HM_YCC_709;
	if (strstr(name, "2020") != NULL) return HM_YCC_2020;
	if (strstr(name, "601") != NULL) return HM_YCC_601;
	if (strstr(name, "240") != NULL) return HM_YCC_240M;
	return HM_YCC_UNKNOWN;
}

static inline const char *
hm_ycc_matrix_name(int matrix)
{
	return matrix == HM_YCC_709 ? "BT.709" : matrix == HM_YCC_2020 ? "BT.2020" : matrix == HM_YCC_240M ? "SMPTE 240M" : "BT.601";
}

/* The planes as the surface lays them out: luma rows, then interleaved Cb Cr pairs (cw x ch pairs). */
typedef struct {
	const uint8_t *luma;
	size_t lumaRow;
	const uint8_t *chroma;
	size_t chromaRow;
	size_t cw, ch;
} hm_ycc_planes;

/* The conversion is the same affine operation for every pixel of a frame.  Keep
 * the five 8-bit lookup tables once per frame so the hot loop does table loads
 * and adds instead of three multiplies and repeated floating-point setup. */
typedef struct {
	int32_t y[256], rv[256], gu[256], gv[256], bu[256];
} hm_ycc_lut;

static inline void
hm_ycc_make_lut(hm_ycc_lut *lut, int matrix, int full)
{
	double kr = 0.299, kb = 0.114;

	if (matrix == HM_YCC_709) {
		kr = 0.2126;
		kb = 0.0722;
	} else if (matrix == HM_YCC_2020) {
		kr = 0.2627;
		kb = 0.0593;
	} else if (matrix == HM_YCC_240M) {
		kr = 0.212;
		kb = 0.087;
	}
	const double kg = 1.0 - kr - kb, ys = full ? 1.0 : 255.0 / 219.0, cs = full ? 1.0 : 255.0 / 224.0;
	const int32_t yo = full ? 0 : 16, fy = (int32_t)(ys * 65536.0 + 0.5);
	const int32_t frv = (int32_t)(2.0 * (1.0 - kr) * cs * 65536.0 + 0.5);
	const int32_t fbu = (int32_t)(2.0 * (1.0 - kb) * cs * 65536.0 + 0.5);
	const int32_t fgu = (int32_t)(2.0 * kb * (1.0 - kb) / kg * cs * 65536.0 + 0.5);
	const int32_t fgv = (int32_t)(2.0 * kr * (1.0 - kr) / kg * cs * 65536.0 + 0.5);

	for (int i = 0; i < 256; i++) {
		lut->y[i] = (i - yo) * fy + 0x8000;
		lut->rv[i] = frv * (i - 128);
		lut->gu[i] = fgu * (i - 128);
		lut->gv[i] = fgv * (i - 128);
		lut->bu[i] = fbu * (i - 128);
	}
}

/* Bytes a '420v' frame cannot hold: video range keeps Y and Cb/Cr off 0, so a 0 there is memory the producer has not
 * written. A frame's luma 0 bytes, its (0, 0) CbCr pairs, and the first and last chroma row holding one. Measured only
 * (the green of a Safari video is such pairs converted, v8); nothing is decided from it. */
typedef struct {
	size_t zeroY, zeroC, rowFirst, rowLast;
} hm_ycc_unwritten;

static inline void
hm_ycc_measure_unwritten(const hm_ycc_planes *p, size_t w, size_t h, hm_ycc_unwritten *u)
{
	u->zeroY = u->zeroC = 0;
	u->rowFirst = u->rowLast = 0;
	for (size_t j = 0; j < h; j++)
		for (size_t i = 0; i < w; i++) u->zeroY += p->luma[j * p->lumaRow + i] == 0;
	for (size_t j = 0; j < p->ch; j++) {
		const uint8_t *row = p->chroma + j * p->chromaRow;
		size_t zero = 0;

		for (size_t i = 0; i < p->cw; i++) zero += row[2 * i] == 0 && row[2 * i + 1] == 0;
		if (zero != 0) {
			if (u->zeroC == 0) u->rowFirst = j;
			u->rowLast = j;
			u->zeroC += zero;
		}
	}
}

/*
 * W x H pixels of RGBA8 (rows RGBA_ROW bytes apart) from the planes.
 *
 * RAW: Metal's private RGB8_420_2P (540), the planes as they are at each pixel -- R Cr, G Y, B Cb -- which
 * VideoToolbox's own converter samples and applies its matrix to. Otherwise (500, YCBCR8_420_2P) the RGB an Apple
 * texture unit returns: MATRIX's Kr and Kb, FULL range ('420f') or video range ('420v': Y 16-235, C 16-240).
 * Each luma sample takes the chroma pair at its own place in the smaller plane (4:2:0 and 4:2:2: one pair for two
 * columns; 4:2:0: and for two rows). Fixed point, 16 fractional bits.
 */
static inline void hm_ycc_convert_rows(const hm_ycc_planes *p, size_t w, size_t h, size_t j0, size_t j1, int matrix, int full, int raw,
				       uint8_t *rgba, size_t rgbaRow);

static inline void
hm_ycc_convert_rows_lut(const hm_ycc_planes *p, size_t w, size_t h, size_t j0, size_t j1, const hm_ycc_lut *lut, int raw,
				uint8_t *rgba, size_t rgbaRow)
{
	const int halfX = p->cw < w, halfY = p->ch < h;

	for (size_t j = j0; j < j1 && j < h; j++) {
		size_t cy = halfY ? j / 2 : j;

		if (cy >= p->ch) cy = p->ch - 1;
		const uint8_t *yl = p->luma + j * p->lumaRow, *cl = p->chroma + cy * p->chromaRow;
		uint8_t *out = rgba + j * rgbaRow;

		for (size_t i = 0; i < w; i++) {
			size_t cx = halfX ? i / 2 : i;

			if (cx >= p->cw) cx = p->cw - 1;
			const int cb = cl[2 * cx], cr = cl[2 * cx + 1];

			if (raw) {
				out[4 * i] = (uint8_t)cr;
				out[4 * i + 1] = yl[i];
				out[4 * i + 2] = (uint8_t)cb;
				out[4 * i + 3] = 255;
				continue;
			}
			int32_t r = (lut->y[yl[i]] + lut->rv[cr]) >> 16;
			int32_t g = (lut->y[yl[i]] - lut->gu[cb] - lut->gv[cr]) >> 16;
			int32_t b = (lut->y[yl[i]] + lut->bu[cb]) >> 16;

			out[4 * i] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
			out[4 * i + 1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
			out[4 * i + 2] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
			out[4 * i + 3] = 255;
		}
	}
}

static inline void
hm_ycc_convert(const hm_ycc_planes *p, size_t w, size_t h, int matrix, int full, int raw, uint8_t *rgba, size_t rgbaRow)
{
	hm_ycc_convert_rows(p, w, h, 0, h, matrix, full, raw, rgba, rgbaRow);
}

/* ... rows J0 to J1 (of H) alone, into RGBA's rows J0 to J1: bands of one picture, converted on several cores at once */
static inline void
hm_ycc_convert_rows(const hm_ycc_planes *p, size_t w, size_t h, size_t j0, size_t j1, int matrix, int full, int raw,
		    uint8_t *rgba, size_t rgbaRow)
{
	hm_ycc_lut lut;
	hm_ycc_make_lut(&lut, matrix, full);
	hm_ycc_convert_rows_lut(p, w, h, j0, j1, &lut, raw, rgba, rgbaRow);
}

/*
 * Whether a picture is one flat colour: a grid of up to 16 x 16 samples over it all the same. FORMAT is Metal's
 * pixel format: RGBA8 (70, 71), BGRA8 (80, 81) and RGBA16Float (115, 'RGhA') by their pixels, ASTC (186-236) by its blocks -- a flat ASTC
 * picture is every block a void-extent block of one colour (the first 9 bits 0x1FC; bit 9 says HDR; bytes 8-15 the
 * colour as four 16-bit values, R G B A). *RGBA the colour as 8 bits a channel (R G B A whatever the format's order),
 * *HDR 1 for an HDR void extent. 0: not flat, or a format this does not read, or too small to say (under 64 x 64).
 */
static inline int
hm_astc_block(unsigned format, unsigned *bw, unsigned *bh)
{
	static const uint8_t dims[15][2] = { {4, 4}, {5, 4}, {5, 5}, {6, 5}, {6, 6}, {0, 0}, {8, 5}, {8, 6}, {8, 8},
					     {10, 5}, {10, 6}, {10, 8}, {10, 10}, {12, 10}, {12, 12} };
	const unsigned bases[3] = { 186, 204, 222 };

	for (unsigned k = 0; k < 3; k++) {
		if (format >= bases[k] && format < bases[k] + 15 && dims[format - bases[k]][0] != 0) {
			*bw = dims[format - bases[k]][0];
			*bh = dims[format - bases[k]][1];
			return 1;
		}
	}
	return 0;
}

/* a half (IEEE binary16) as 8 bits of 0..1 */
static inline uint8_t
hm_half_to_8(uint16_t h)
{
	const unsigned e = (h >> 10) & 31, m = h & 1023;
	float v;

	if (h & 0x8000) return 0;
	if (e == 31) return 255;
	v = e == 0 ? (float)m / 1024.0f / 16384.0f : (1.0f + (float)m / 1024.0f) * (float)(1u << e) / 32768.0f;
	return v >= 1.0f ? 255 : (uint8_t)(v * 255.0f + 0.5f);
}

static inline int
hm_picture_flat(unsigned format, size_t w, size_t h, const uint8_t *bytes, size_t bytesPerRow, uint8_t rgba[4], int *hdr)
{
	unsigned bw = 1, bh = 1;
	const int astc = hm_astc_block(format, &bw, &bh);
	const int bgra = format == 80 || format == 81, rgba8 = format == 70 || format == 71, rgba16f = format == 115;

	if (hdr != NULL) *hdr = 0;
	if (bytes == NULL || w < 64 || h < 64 || (!astc && !bgra && !rgba8 && !rgba16f)) return 0;
	const size_t across = (w + bw - 1) / bw, down = (h + bh - 1) / bh;      /* pixels, or blocks */
	const size_t unit = astc ? 16 : rgba16f ? 8 : 4;
	if (bytesPerRow < across * unit) return 0;
	const size_t nx = across < 16 ? across : 16, ny = down < 16 ? down : 16;
	uint8_t first[16];

	for (size_t sy = 0; sy < ny; sy++) {
		const uint8_t *row = bytes + (sy * (down - 1) / (ny > 1 ? ny - 1 : 1)) * bytesPerRow;

		for (size_t sx = 0; sx < nx; sx++) {
			const uint8_t *at = row + (sx * (across - 1) / (nx > 1 ? nx - 1 : 1)) * unit;

			if (astc && !(at[0] == 0xfc && (at[1] & 0x01) != 0)) return 0;   /* not a void-extent block */
			if (sx == 0 && sy == 0) {
				memcpy(first, at, unit);
			} else if (astc ? memcmp(first + 8, at + 8, 8) != 0 : memcmp(first, at, unit) != 0) {
				return 0;
			}
		}
	}
	if (astc) {
		/* the colour: 16-bit values, little-endian; their top bytes */
		rgba[0] = first[9];
		rgba[1] = first[11];
		rgba[2] = first[13];
		rgba[3] = first[15];
		if (hdr != NULL) *hdr = (first[1] & 0x02) != 0;
	} else if (rgba16f) {
		for (int c = 0; c < 4; c++) rgba[c] = hm_half_to_8((uint16_t)(first[2 * c] | first[2 * c + 1] << 8));
	} else if (bgra) {
		rgba[0] = first[2];
		rgba[1] = first[1];
		rgba[2] = first[0];
		rgba[3] = first[3];
	} else {
		memcpy(rgba, first, 4);
	}
	return 1;
}

/* the purple of the materials: red and blue the same (to a step or two) and well above green */
static inline int
hm_rgba_magenta(const uint8_t rgba[4])
{
	const int d = (int)rgba[0] - (int)rgba[2];

	return d >= -3 && d <= 3 && rgba[0] >= 24 && (int)rgba[1] + 16 <= (int)rgba[0];
}

#endif /* HAKIOS_METAL_PIXELS_H */
