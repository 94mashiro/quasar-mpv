/* Dolby Vision Profile 7 FEL composition (ETSI GS CCM 001 5.4) for the native
 * output. Plain C so the host test compiles it without FFmpeg; the Metal
 * kernel source lives here next to the C reference it must match.
 * LGPL-2.1-or-later, like the native video output. */
#ifndef MP_AVFOUNDATION_FEL_H
#define MP_AVFOUNDATION_FEL_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Composer metadata as FFmpeg's AVDOVIDataMapping keeps it: absolute pivots,
// coefficients in fixed point with `denom` fractional bits.
struct avf_fel_comp {
    int num_pivots;
    uint16_t pivots[9];
    uint8_t mapping_idc[8];          // 0 polynomial, 1 MMR
    uint8_t poly_order[8];
    int64_t poly_coef[8][3];
    uint8_t mmr_order[8];
    int64_t mmr_constant[8];
    int64_t mmr_coef[8][3][7];
    uint16_t nlq_offset;
    uint64_t vdr_in_max, slope, threshold;
};

struct avf_fel_params {
    int bl_bits, el_bits, denom;
    bool disable_residual;
    struct avf_fel_comp comp[3];
};

// Shared with the Metal kernel; keep the field order and types in sync.
struct avf_fel_uniforms {
    float pivots[3][9];              // BL codes
    int32_t num_pivots[3];
    int32_t mmr[3][8];               // 1 = MMR piece
    int32_t order[3][8];
    float poly[3][8][3];             // per x = code / 1024
    float mmr_coef[3][8][22];        // constant, then 7 terms per order
    float nlq_offset[3], slope[3], threshold[3], in_max[3];
    int32_t residual;
    int32_t el_half;                 // EL is half the BL size (4K BL)
};

// The residual of MEL streams is zero: nothing to compose.
static inline bool avf_fel_has_residual(const struct avf_fel_params *p)
{
    if (p->disable_residual)
        return false;
    for (int c = 0; c < 3; c++) {
        if (p->comp[c].slope || p->comp[c].threshold)
            return true;
    }
    return false;
}

// False for metadata this composer does not handle (bit depths other than
// 10, too many pivots).
static inline bool avf_fel_prepare(const struct avf_fel_params *p, bool el_half,
                                   struct avf_fel_uniforms *u)
{
    if (p->bl_bits != 10 || p->el_bits != 10 || p->denom < 16 || p->denom > 32)
        return false;
    memset(u, 0, sizeof(*u));
    double scale = 1.0 / ((uint64_t)1 << p->denom);
    for (int c = 0; c < 3; c++) {
        const struct avf_fel_comp *k = &p->comp[c];
        if (k->num_pivots < 2 || k->num_pivots > 9)
            return false;
        u->num_pivots[c] = k->num_pivots;
        for (int i = 0; i < k->num_pivots; i++)
            u->pivots[c][i] = k->pivots[i];
        for (int i = 0; i < k->num_pivots - 1; i++) {
            u->mmr[c][i] = k->mapping_idc[i] == 1;
            if (u->mmr[c][i] && (c == 0 || k->mmr_order[i] < 1 || k->mmr_order[i] > 3))
                return false;
            if (!u->mmr[c][i] && k->poly_order[i] > 2)
                return false;
            u->order[c][i] = u->mmr[c][i] ? k->mmr_order[i] : k->poly_order[i];
            for (int j = 0; j <= 2; j++)
                u->poly[c][i][j] = j <= k->poly_order[i] ? k->poly_coef[i][j] * scale : 0;
            u->mmr_coef[c][i][0] = k->mmr_constant[i] * scale;
            for (int o = 0; o < 3; o++) {
                for (int j = 0; j < 7; j++)
                    u->mmr_coef[c][i][1 + o * 7 + j] = k->mmr_coef[i][o][j] * scale;
            }
        }
        u->nlq_offset[c] = k->nlq_offset;
        u->slope[c] = k->slope * scale;
        u->threshold[c] = k->threshold * scale;
        u->in_max[c] = k->vdr_in_max * scale;
    }
    u->residual = avf_fel_has_residual(p);
    u->el_half = el_half;
    return true;
}

// 5.4.2.2. The spec's index for s at the last pivot is one past the last
// piece; use the last piece.
static inline int avf_fel_piece(const struct avf_fel_uniforms *u, int c, float s)
{
    for (int i = 0; i < u->num_pivots[c] - 2; i++) {
        if (s < u->pivots[c][i + 1])
            return i;
    }
    return u->num_pivots[c] - 2;
}

static inline float avf_fel_clamp_s(const struct avf_fel_uniforms *u, int c, float s)
{
    return fminf(fmaxf(s, u->pivots[c][0]), u->pivots[c][u->num_pivots[c] - 1]);
}

// 5.4.2.3: BL code -> mapped value, 1.0 = 2^16.
static inline float avf_fel_map(const struct avf_fel_uniforms *u, int c, float s0, float s1, float s2)
{
    float s = c == 0 ? s0 : c == 1 ? s1 : s2;
    int i = avf_fel_piece(u, c, s);
    float v;
    if (u->mmr[c][i]) {
        float x0 = avf_fel_clamp_s(u, 0, s0) / 1024, x1 = avf_fel_clamp_s(u, 1, s1) / 1024;
        float x2 = avf_fel_clamp_s(u, 2, s2) / 1024;
        float t[7] = {x0, x1, x2, x0 * x1, x0 * x2, x1 * x2, x0 * x1 * x2};
        const float *m = u->mmr_coef[c][i];
        v = m[0];
        for (int j = 0; j < 7; j++) {
            float t1 = t[j], t2 = t1 * t1;
            v += m[1 + j] * t1;
            if (u->order[c][i] >= 2)
                v += m[8 + j] * t2;
            if (u->order[c][i] >= 3)
                v += m[15 + j] * t2 * t1;
        }
    } else {
        float x = avf_fel_clamp_s(u, c, s) / 1024;
        v = (u->poly[c][i][2] * x + u->poly[c][i][1]) * x + u->poly[c][i][0];
    }
    return fminf(fmaxf(v, 0.0f), 65535.0f / 65536);
}

// 5.4.3.2 NLQ_LINEAR_DZ on an (interpolated) EL code, 1.0 = 2^16.
static inline float avf_fel_nlq(const struct avf_fel_uniforms *u, int c, float e)
{
    float d = e - u->nlq_offset[c];
    if (d == 0)
        return 0;
    float r = fminf((fabsf(d) - 0.5f) * u->slope[c] + u->threshold[c], u->in_max[c]);
    return d < 0 ? -r : r;
}

static inline int avf_fel_code(float h)
{
    return (int)fminf(fmaxf(roundf(h * 1024), 0.0f), 1023.0f);
}

static inline int avf_fel_clampi(int v, int hi)
{
    return v < 0 ? 0 : v > hi ? hi : v;
}

// Bilinear EL sample at plane position (fx, fy), clamped to the edges.
static inline float avf_fel_bilinear(const uint16_t *p, int stride, int step, int w, int h,
                                     float fx, float fy)
{
    float x0 = floorf(fx), y0 = floorf(fy), tx = fx - x0, ty = fy - y0;
    int xa = avf_fel_clampi((int)x0, w - 1), xb = avf_fel_clampi((int)x0 + 1, w - 1);
    int ya = avf_fel_clampi((int)y0, h - 1), yb = avf_fel_clampi((int)y0 + 1, h - 1);
    float a = p[ya * stride + xa * step], b = p[ya * stride + xb * step];
    float c = p[yb * stride + xa * step], d = p[yb * stride + xb * step];
    float top = a + (b - a) * tx;
    return top + ((c + (d - c) * tx) - top) * ty;
}

// One chroma sample and its 2x2 luma block of 10-bit codes. Planes are
// unshifted codes; chroma is interleaved CbCr. The C reference of the kernel.
// The EL is upsampled at Annex B's phase (luma and chroma horizontally
// co-sited, vertically centred), bilinear like libplacebo.
static inline void avf_fel_block(const struct avf_fel_uniforms *u,
                                 const uint16_t *bly, int bly_stride, const uint16_t *blc, int blc_stride,
                                 int w, int h,
                                 const uint16_t *ely, int ely_stride, const uint16_t *elc, int elc_stride,
                                 int ew, int eh, int cx, int cy, int yout[4], int *cbout, int *crout)
{
    for (int k = 0; k < 4; k++) {
        int x = cx * 2 + (k & 1), y = cy * 2 + (k >> 1);
        float s = bly[avf_fel_clampi(y, h - 1) * bly_stride + avf_fel_clampi(x, w - 1)];
        float e = u->el_half ? avf_fel_bilinear(ely, ely_stride, 1, ew, eh, x * 0.5f, y * 0.5f - 0.25f)
                             : avf_fel_bilinear(ely, ely_stride, 1, ew, eh, x, y);
        float v = avf_fel_map(u, 0, s, 0, 0) + (u->residual ? avf_fel_nlq(u, 0, e) : 0);
        yout[k] = avf_fel_code(v);
    }
    // 5.4.2.3.3: luma at the chroma site, (1,2,1) across, two rows averaged.
    int s0 = 0;
    for (int r = 0; r < 2; r++) {
        const uint16_t *row = bly + avf_fel_clampi(cy * 2 + r, h - 1) * bly_stride;
        s0 += (row[avf_fel_clampi(cx * 2 - 1, w - 1)] + 2 * row[avf_fel_clampi(cx * 2, w - 1)] +
               row[avf_fel_clampi(cx * 2 + 1, w - 1)] + 2) >> 2;
    }
    s0 = (s0 + 1) >> 1;
    float s1 = blc[cy * blc_stride + cx * 2], s2 = blc[cy * blc_stride + cx * 2 + 1];
    int ecw = (ew + 1) / 2, ech = (eh + 1) / 2;
    float fx = u->el_half ? cx * 0.5f : cx, fy = u->el_half ? cy * 0.5f - 0.25f : cy;
    float e1 = avf_fel_bilinear(elc, elc_stride, 2, ecw, ech, fx, fy);
    float e2 = avf_fel_bilinear(elc + 1, elc_stride, 2, ecw, ech, fx, fy);
    float v1 = avf_fel_map(u, 1, s0, s1, s2) + (u->residual ? avf_fel_nlq(u, 1, e1) : 0);
    float v2 = avf_fel_map(u, 2, s0, s1, s2) + (u->residual ? avf_fel_nlq(u, 2, e2) : 0);
    *cbout = avf_fel_code(v1);
    *crout = avf_fel_code(v2);
}

#define AVF_FEL_MSL(...) #__VA_ARGS__

// BL and EL P010 in (R16Unorm / RG16Unorm planes), P010 out; one thread per
// chroma sample.
static const char avf_fel_metal_source[] = "#include <metal_stdlib>\nusing namespace metal;\n"
AVF_FEL_MSL(
struct U {
    float pivots[3][9];
    int num_pivots[3];
    int mmr[3][8];
    int order[3][8];
    float poly[3][8][3];
    float mmr_coef[3][8][22];
    float nlq_offset[3], slope[3], threshold[3], in_max[3];
    int residual;
    int el_half;
};
static int piece(constant U &u, int c, float s) {
    for (int i = 0; i < u.num_pivots[c] - 2; i++)
        if (s < u.pivots[c][i + 1]) return i;
    return u.num_pivots[c] - 2;
}
static float clamp_s(constant U &u, int c, float s) {
    return clamp(s, u.pivots[c][0], u.pivots[c][u.num_pivots[c] - 1]);
}
static float remap(constant U &u, int c, float s0, float s1, float s2) {
    float s = c == 0 ? s0 : c == 1 ? s1 : s2;
    int i = piece(u, c, s);
    float v;
    if (u.mmr[c][i] != 0) {
        float x0 = clamp_s(u, 0, s0) / 1024, x1 = clamp_s(u, 1, s1) / 1024, x2 = clamp_s(u, 2, s2) / 1024;
        float t[7] = {x0, x1, x2, x0 * x1, x0 * x2, x1 * x2, x0 * x1 * x2};
        v = u.mmr_coef[c][i][0];
        for (int j = 0; j < 7; j++) {
            float t1 = t[j], t2 = t1 * t1;
            v += u.mmr_coef[c][i][1 + j] * t1;
            if (u.order[c][i] >= 2) v += u.mmr_coef[c][i][8 + j] * t2;
            if (u.order[c][i] >= 3) v += u.mmr_coef[c][i][15 + j] * t2 * t1;
        }
    } else {
        float x = clamp_s(u, c, s) / 1024;
        v = (u.poly[c][i][2] * x + u.poly[c][i][1]) * x + u.poly[c][i][0];
    }
    return clamp(v, 0.0f, 65535.0f / 65536);
}
static float nlq(constant U &u, int c, float e) {
    float d = e - u.nlq_offset[c];
    if (d == 0) return 0;
    float r = min((abs(d) - 0.5f) * u.slope[c] + u.threshold[c], u.in_max[c]);
    return d < 0 ? -r : r;
}
static float code(float h) { return clamp(round(h * 1024), 0.0f, 1023.0f); }
static float rd(texture2d<float, access::read> t, int x, int y, int ch) {
    uint2 at = uint2(clamp(x, 0, int(t.get_width()) - 1), clamp(y, 0, int(t.get_height()) - 1));
    return round(t.read(at)[ch] * 65535.0f) / 64.0f;
}
static float bilinear(texture2d<float, access::read> t, int ch, float fx, float fy) {
    float x0 = floor(fx), y0 = floor(fy), tx = fx - x0, ty = fy - y0;
    int xa = int(x0), ya = int(y0);
    float a = rd(t, xa, ya, ch), b = rd(t, xa + 1, ya, ch), c = rd(t, xa, ya + 1, ch), d = rd(t, xa + 1, ya + 1, ch);
    float top = a + (b - a) * tx;
    return top + ((c + (d - c) * tx) - top) * ty;
}
kernel void fel_compose(texture2d<float, access::read> bly [[texture(0)]],
                        texture2d<float, access::read> blc [[texture(1)]],
                        texture2d<float, access::read> ely [[texture(2)]],
                        texture2d<float, access::read> elc [[texture(3)]],
                        texture2d<float, access::write> oy [[texture(4)]],
                        texture2d<float, access::write> oc [[texture(5)]],
                        constant U &u [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= blc.get_width() || gid.y >= blc.get_height()) return;
    int cx = int(gid.x), cy = int(gid.y);
    for (int k = 0; k < 4; k++) {
        int x = cx * 2 + (k & 1), y = cy * 2 + (k >> 1);
        float s = rd(bly, x, y, 0);
        float e = u.el_half != 0 ? bilinear(ely, 0, x * 0.5f, y * 0.5f - 0.25f) : bilinear(ely, 0, x, y);
        float v = remap(u, 0, s, 0, 0) + (u.residual != 0 ? nlq(u, 0, e) : 0);
        if (uint(x) < oy.get_width() && uint(y) < oy.get_height())
            oy.write(float4(code(v) * 64.0f / 65535.0f), uint2(x, y));
    }
    int s0 = 0;
    for (int r = 0; r < 2; r++) {
        int y = cy * 2 + r;
        s0 += (int(rd(bly, cx * 2 - 1, y, 0)) + 2 * int(rd(bly, cx * 2, y, 0)) + int(rd(bly, cx * 2 + 1, y, 0)) + 2) >> 2;
    }
    s0 = (s0 + 1) >> 1;
    float s1 = rd(blc, cx, cy, 0), s2 = rd(blc, cx, cy, 1);
    float fx = u.el_half != 0 ? cx * 0.5f : float(cx), fy = u.el_half != 0 ? cy * 0.5f - 0.25f : float(cy);
    float e1 = bilinear(elc, 0, fx, fy), e2 = bilinear(elc, 1, fx, fy);
    float v1 = remap(u, 1, float(s0), s1, s2) + (u.residual != 0 ? nlq(u, 1, e1) : 0);
    float v2 = remap(u, 2, float(s0), s1, s2) + (u.residual != 0 ? nlq(u, 2, e2) : 0);
    oc.write(float4(code(v1) * 64.0f / 65535.0f, code(v2) * 64.0f / 65535.0f, 0, 0), gid);
}
);

#endif
