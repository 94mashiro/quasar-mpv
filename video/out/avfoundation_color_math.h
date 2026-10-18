/* Native overlay math. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef MP_AVFOUNDATION_COLOR_MATH_H
#define MP_AVFOUNDATION_COLOR_MATH_H
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

enum avf_transfer { AVF_SRGB, AVF_BT1886, AVF_PQ, AVF_HLG, AVF_LINEAR };
struct avf_overlay_color {
    enum avf_transfer transfer;
    double rgb_matrix[3][3]; // linear sRGB -> output primaries (D65 adapted)
    double kr, kb;
    double white_nits;
};

static inline double avf_clamp(double x, double lo, double hi)
{
    return fmin(hi, fmax(lo, x));
}

static inline double avf_srgb_decode(double x)
{
    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

// ST 2084 represents absolute cd/m². HLG uses BT.2100's nominal 1000 cd/m²,
// gamma 1.2 reference display. Its OOTF is applied to luminance, not channels.
// AVFoundation remains responsible for adaptation to the physical display.
static inline void avf_to_nits(enum avf_transfer trc, double rgb[3], double kr, double kb)
{
    for (int c = 0; c < 3; c++) {
        double v = avf_clamp(rgb[c], 0, 1);
        switch (trc) {
        case AVF_PQ: {
            double p = pow(v, 1.0 / 78.84375);
            rgb[c] = 10000 * pow(fmax(p - 0.8359375, 0) /
                                  (18.8515625 - 18.6875 * p), 1.0 / 0.1593017578125);
            break;
        }
        case AVF_HLG:
            rgb[c] = v <= 0.5 ? v * v / 3 :
                (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12;
            break;
        case AVF_SRGB: rgb[c] = 100 * avf_srgb_decode(v); break;
        case AVF_BT1886: rgb[c] = 100 * pow(v, 2.4); break;
        case AVF_LINEAR: rgb[c] = 100 * v; break;
        }
    }
    if (trc == AVF_HLG) {
        double y = kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2];
        double gain = 1000 * pow(fmax(y, 0), 0.2);
        for (int c = 0; c < 3; c++) rgb[c] *= gain;
    }
}

static inline void avf_from_nits(enum avf_transfer trc, double rgb[3], double kr, double kb)
{
    if (trc == AVF_HLG) {
        double y = (kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2]) / 1000;
        double gain = y > 0 ? pow(y, (1.0 - 1.2) / 1.2) / 1000 : 0;
        for (int c = 0; c < 3; c++) rgb[c] *= gain;
    }
    for (int c = 0; c < 3; c++) {
        double v = fmax(rgb[c], 0);
        switch (trc) {
        case AVF_PQ: {
            double p = pow(fmin(v / 10000, 1), 0.1593017578125);
            rgb[c] = pow((0.8359375 + 18.8515625 * p) / (1 + 18.6875 * p), 78.84375);
            break;
        }
        case AVF_HLG:
            rgb[c] = v <= 1.0 / 12 ? sqrt(3 * v) :
                0.17883277 * log(12 * v - 0.28466892) + 0.55991073;
            break;
        case AVF_SRGB:
            v /= 100;
            rgb[c] = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
            break;
        case AVF_BT1886: rgb[c] = pow(v / 100, 1.0 / 2.4); break;
        case AVF_LINEAR: rgb[c] = v / 100; break;
        }
        rgb[c] = avf_clamp(rgb[c], 0, 1);
    }
}

// Convert the straight color of premultiplied sRGB artwork to output-display
// linear cd/m². Shared by the YUV compositor and float Core Image overlays.
static inline void avf_subtitle_nits(const struct avf_overlay_color *color,
                                     const uint8_t bgra[4], double rgb[3])
{
    double a = bgra[3] / 255.0;
    double sub[3] = {0};
    if (a > 0) {
        for (int c = 0; c < 3; c++)
            sub[c] = avf_srgb_decode(avf_clamp(bgra[2 - c] / (255.0 * a), 0, 1));
    }
    double white = color->transfer == AVF_PQ || color->transfer == AVF_HLG ? color->white_nits : 100;
    for (int c = 0; c < 3; c++) {
        rgb[c] = 0;
        for (int k = 0; k < 3; k++) rgb[c] += color->rgb_matrix[c][k] * sub[k];
        rgb[c] = fmax(rgb[c], 0) * white;
    }
}

// Values are normalized Y (0..1), Cb/Cr (-.5...5), before range quantization.
// Premultiplied BGRA is unpremultiplied BEFORE decoding the sRGB transfer.
static inline void avf_blend_pixel(const struct avf_overlay_color *color,
                                  const uint8_t bgra[4], double yuv[3])
{
    double a = bgra[3] / 255.0;
    if (a == 0) return; // preserve even out-of-range original values exactly
    double kr = color->kr, kb = color->kb, kg = 1 - kr - kb;
    double rgb[3] = {
        yuv[0] + 2 * (1 - kr) * yuv[2],
        yuv[0] - 2 * kb * (1 - kb) / kg * yuv[1] - 2 * kr * (1 - kr) / kg * yuv[2],
        yuv[0] + 2 * (1 - kb) * yuv[1]
    };
    avf_to_nits(color->transfer, rgb, kr, kb);
    double sub[3];
    avf_subtitle_nits(color, bgra, sub);
    for (int c = 0; c < 3; c++) rgb[c] = rgb[c] * (1 - a) + sub[c] * a;
    avf_from_nits(color->transfer, rgb, kr, kb);
    yuv[0] = kr * rgb[0] + kg * rgb[1] + kb * rgb[2];
    yuv[1] = (rgb[2] - yuv[0]) / (2 * (1 - kb));
    yuv[2] = (rgb[0] - yuv[0]) / (2 * (1 - kr));
}

// A 4:2:0 sample covers every extant luma pixel in its 2x2 cell, including
// transparent pixels. Average chroma *deltas*, retaining original chroma for
// uncovered pixels. One odd-position antialiased pixel must affect chroma too.
// This deliberately bounds the chroma footprint to one cell; shared chroma
// inevitably affects uncovered luma pixels in that cell, never adjacent cells.
static inline bool avf_blend_chroma_cell(const struct avf_overlay_color *color,
                                       const uint8_t bgra[4][4], double y[4],
                                       double uv[2], int count)
{
    bool changed = false;
    double delta[2] = {0};
    for (int i = 0; i < count; i++) {
        if (!bgra[i][3]) continue;
        double pixel[3] = {y[i], uv[0], uv[1]};
        avf_blend_pixel(color, bgra[i], pixel);
        y[i] = pixel[0];
        delta[0] += pixel[1] - uv[0];
        delta[1] += pixel[2] - uv[1];
        changed = true;
    }
    if (changed) {
        uv[0] += delta[0] / count;
        uv[1] += delta[1] / count;
    }
    return changed;
}
#endif
