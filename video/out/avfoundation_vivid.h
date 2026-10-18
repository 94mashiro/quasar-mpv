/* HDR Vivid (T/UWA 005.1-2022 chapter 9) PQ tone mapping for the native output.
 * Plain C so the host test compiles it without FFmpeg. The Metal kernel source
 * lives here too, next to the C reference it must match.
 * Copyright (c) 2026 Quasar authors
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef MP_AVFOUNDATION_VIVID_H
#define MP_AVFOUNDATION_VIVID_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Raw bitstream codes of dynamic_metadata() (T/UWA 005.1 table 10). FFmpeg's
// AVDynamicHDRVivid keeps them in AVRational.num, but its denominators disagree
// with 7.4 for m_p, m_b, Delta, TH_MB, Delta1/2, Strength and gain[1], so the
// curve scales the raw codes itself.
struct avf_vivid_raw_tm {
    int target;                          // u(12); 2080 marks the SDR-only set
    int base_flag, m_p, m_m, m_a, m_b, m_n, k1, k2, k3, dmode, delta;
    int spline_flag, spline_num;         // spline_num already +1
    struct avf_vivid_raw_spline { int mode, mb, th, d1, d2, str; } spline[2];
};

struct avf_vivid_raw {
    int min, avg, var, max;              // u(12)
    int tm_flag, tm_num;                 // tm_num already +1
    struct avf_vivid_raw_tm tm[2];
    int sat_flag, sat_num, sat_gain[8];
};

struct avf_vivid_interval {
    int mode;
    double TH1, TH2, TH3, MA0, MB0, MC0, MD0, MA1, MB1, MC1, MD1;
};

struct avf_vivid_curve {
    double MaxD, MinD, ref, max_lum;     // PQ code values
    double m_p, m_m, m_n, m_a, m_b, K1, K2, K3;
    double TH30, MB00, off;
    int n_iv;
    struct avf_vivid_interval iv[2];
};

#define AVF_VIVID_LUT_SIZE 4096
#define AVF_VIVID_SDR_TARGET 2080

// Shared with the Metal kernel; keep the field order and types in sync.
struct avf_vivid_uniforms {
    float y_off, y_scale, c_scale;       // input code -> Y' [0,1], C [-0.5,0.5]
    float y_out, y_out_off, c_out;       // and back
    float tml, rml, c0, c1, b;           // 9.5 color correction
    int32_t sat_mode;                    // 0 off, 1 eq.87 only, 2 with the gain[1] branch
    int32_t m;
};

static inline double avf_vivid_pq_eotf(double e)
{
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128;
    const double c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32;
    double p = pow(fmax(e, 0.0), 1 / m2);
    return pow(fmax(p - c1, 0.0) / (c2 - c3 * p), 1 / m1);
}

static inline double avf_vivid_pq_oetf(double l)
{
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128;
    const double c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32;
    double p = pow(fmax(l, 0.0), m1);
    return pow((c1 + c2 * p) / (1 + c3 * p), m2);
}

static inline double avf_vivid_f(const struct avf_vivid_curve *c, double L)
{
    double Ln = pow(L, c->m_n);
    return pow(c->m_p * Ln / ((c->K1 * c->m_p - c->K2) * Ln + c->K3), c->m_m);
}

// eq.16
static inline double avf_vivid_H(const struct avf_vivid_curve *c, double L, double m_a)
{
    return m_a * avf_vivid_f(c, L) + c->m_b;
}

// eq.47
static inline double avf_vivid_dH(const struct avf_vivid_curve *c, double L)
{
    double Ln = pow(L, c->m_n);
    double dgd = pow(c->m_p * Ln / ((c->K1 * c->m_p - c->K2) * Ln + c->K3), c->m_m + 1) *
                 pow(1 / (Ln * c->m_p), 2);
    return c->m_a * c->m_m * c->m_p * c->K3 * c->m_n * pow(L, c->m_n - 1) * dgd;
}

// 9.2.2
static inline void avf_vivid_process0(struct avf_vivid_curve *c, double avg)
{
    c->m_m = 2.4; c->m_n = 1; c->K1 = c->K2 = c->K3 = 1;
    c->m_b = c->MinD;
    double p = avg > 0.6 ? 3.5 : avg < 0.3 ? 4.0 : 3.5 * ((avg - 0.3) / 0.3) + 4.0 * (1 - (avg - 0.3) / 0.3);
    double ml = c->max_lum;
    p += ml > 0.9 ? 0.6 : ml < 0.75 ? 0.0 : 0.6 * ((ml - 0.75) / 0.15);
    c->m_p = p;
    c->m_a = (c->MaxD - c->MinD) / avf_vivid_f(c, ml);
}

// eq.49: two cubic pieces on [TH1,TH2] and [TH2,TH3], C2 at TH2.
static inline void avf_vivid_solve(struct avf_vivid_interval *iv, double VA1, double VA2,
                                   double VA3, double GD1, double GD3)
{
    double h1 = iv->TH2 - iv->TH1, h2 = iv->TH3 - iv->TH2;
    double MB1 = -(3 * VA1 * h2 * h2 + 3 * VA2 * h1 * h1 - 3 * VA3 * h1 * h1 - 3 * h2 * h2 * VA2 +
                   h1 * h1 * h2 * GD3 + GD1 * h1 * h2 * h2) / (2 * h2 * (h1 * h1 + h2 * h1));
    double MC0 = (3 * VA2 - 2 * GD1 * h1 - 3 * VA1 - MB1 * h1) / (h1 * h1);
    double MD0 = (h1 * GD1 + h1 * MB1 + 2 * VA1 - 2 * VA2) / (h1 * h1 * h1);
    iv->MA0 = VA1; iv->MB0 = GD1; iv->MC0 = MC0; iv->MD0 = MD0;
    iv->MA1 = VA2; iv->MB1 = MB1; iv->MC1 = MC0 + 3 * MD0 * h1;
    iv->MD1 = -(VA3 - VA2 - h2 * GD3 + MC0 * h2 * h2 + 3 * MD0 * h1 * h2 * h2) / (2 * h2 * h2 * h2);
}

static inline double avf_vivid_tm_ap(double p)
{
    static const double x[] = {2.5, 3.5, 4.5, 7.5}, y[] = {0.990, 0.879, 0.777, 0.540};
    if (p <= x[0])
        return y[0];
    for (int i = 1; i < 4; i++)
        if (p <= x[i])
            return y[i - 1] + (y[i] - y[i - 1]) * (p - x[i - 1]) / (x[i] - x[i - 1]);
    return y[3];
}

// Builds the luminance curve of 9.2-9.3 for a display peak of target_nits.
// mastering_nits is the static MDCV peak (0 = missing, 4000 per the 2022 erratum).
// Spec gaps are resolved as noted inline; no reference outputs were available.
// Returns false when the metadata asks for something chapter 9 leaves undefined.
static inline bool avf_vivid_curve_init(struct avf_vivid_curve *c, const struct avf_vivid_raw *r,
                                        double target_nits, double mastering_nits)
{
    memset(c, 0, sizeof(*c));
    c->MaxD = avf_vivid_pq_oetf(target_nits / 10000);
    c->MinD = 0;
    c->ref = avf_vivid_pq_oetf((mastering_nits > 0 ? mastering_nits : 4000) / 10000);
    double avg = r->avg / 4095.0, var = r->var / 4095.0, max = r->max / 4095.0;

    // 7.4.8: the 2080 set is for SDR displays. Of the others take the one
    // aimed closest to this display (the spec does not say).
    const struct avf_vivid_raw_tm *tm = NULL;
    for (int i = 0; r->tm_flag && i < r->tm_num && i < 2; i++) {
        if (r->tm[i].target == AVF_VIVID_SDR_TARGET)
            continue;
        if (!tm || fabs(r->tm[i].target / 4095.0 - c->MaxD) < fabs(tm->target / 4095.0 - c->MaxD))
            tm = &r->tm[i];
    }
    int dmode = tm && tm->base_flag ? tm->dmode : 0;
    double target = tm ? tm->target / 4095.0 : 0;
    double delta = tm ? (dmode == 2 || dmode == 6 ? -1 : 1) * tm->delta / 127.0 : 0;
    double p0 = 0, m0 = 0, a0 = 0, b0 = 0, n0 = 0, k10 = 0, k20 = 0, k30 = 0;
    if (tm && tm->base_flag) {
        p0 = 10.0 * tm->m_p / 16383; m0 = tm->m_m / 10.0; a0 = tm->m_a / 1023.0;
        b0 = tm->m_b * 0.25 / 1023; n0 = tm->m_n / 10.0;
        k10 = tm->k1; k20 = tm->k2; k30 = tm->k3 == 2 ? max : tm->k3;
    }

    // 9.2.3. The spec also defines A through a constant F, contradicting the
    // stated defaults; use the defaults.
    double max_lum = 0.2 * max + 0.4 * 2 * avg + 0.4 * var;
    max_lum = fmin(fmax(max_lum, 0.5081), c->ref);
    c->max_lum = max_lum = fmax(max_lum, c->MaxD);

    // 9.2.1
    if (!tm || !tm->base_flag) {
        avf_vivid_process0(c, avg);
    } else if (fabs(target - c->MaxD) < 0.5 / 4095 || dmode == 3) {
        c->m_p = p0; c->m_m = m0; c->m_n = n0; c->m_a = a0; c->m_b = b0;
        c->K1 = k10; c->K2 = k20; c->K3 = k30;
    } else {
        double dn = 10000 * fabs(avf_vivid_pq_eotf(c->MaxD) - avf_vivid_pq_eotf(target)) / 100;
        if (dmode == 0 || dmode == 2 || dmode == 4 || dmode == 6) {      // 9.2.4
            c->m_m = m0; c->m_n = n0; c->K1 = k10; c->K2 = k20; c->K3 = k30;
            c->m_b = b0 * (c->MaxD - c->MinD) / target;
            c->m_a = a0 * (c->MaxD - c->MinD) / target;
            c->m_p = fmin(fmax(p0 + delta * sqrt(dn), 3.0), 7.5);
        } else if (dmode == 1 || dmode == 5) {                          // 9.2.5
            avf_vivid_process0(c, avg);
            double w = fmin(fmax(delta * sqrt(dn), 0.0), 1.0);
            c->m_p = (1 - w) * p0 + w * c->m_p;
            c->m_m = (1 - w) * m0 + w * c->m_m;
            c->m_n = (1 - w) * n0 + w * c->m_n;
            c->K1 = (1 - w) * k10 + w * c->K1;
            c->K2 = (1 - w) * k20 + w * c->K2;
            c->K3 = (1 - w) * k30 + w * c->K3;
            c->m_b = c->MinD;
            c->m_a = (c->MaxD - c->MinD) / avf_vivid_f(c, max_lum);
        } else {
            return false;                                               // mode 7
        }
    }

    // 9.3.2 linear segment. Interval 1 uses the stream only for a mode-0
    // first entry; the first entry with mode 1-3 becomes interval 2.
    int nsp = tm && tm->spline_flag ? (tm->spline_num < 2 ? tm->spline_num : 2) : 0;
    bool stream = nsp && tm->spline[0].mode == 0;
    double TH30, MB, off = 0, D1 = 0, D2 = 0, S = 0;
    if (stream) {
        TH30 = tm->spline[0].th / 4095.0;
        MB = (tm->spline[0].mb >> 2) / 63.0;
        off = (tm->spline[0].mb & 3) * 0.1 / 3;
        D1 = tm->spline[0].d1 * 0.25 / 1023;
        D2 = tm->spline[0].d2 * 0.25 / 1023;
        S = 2.0 * tm->spline[0].str / 255 - 1;
    } else {
        double w = (avg - 0.3) / 0.3;
        TH30 = avg > 0.6 ? 0.1 : avg < 0.3 ? 0.25 : 0.1 * w + 0.25 * (1 - w);
        MB = avg > 0.6 ? 0.96 : avg < 0.3 ? 1.0 : 0.96 * w + 1.0 * (1 - w);
    }
    // 9.3.2.3
    if (tm && tm->base_flag && dmode < 3) {
        double m_a_T = avf_vivid_tm_ap(c->m_p);
        if (c->m_a > m_a_T) {
            double h = avf_vivid_H(c, max_lum, m_a_T) / max_lum;
            double WA = (c->MaxD / max_lum - h) / (1 - h);
            c->m_b = (1 - WA) * c->m_b;
            MB = fmin(fmax(MB + (1 - MB) * WA, MB), 1);
            TH30 = fmin(fmax(TH30 + (max_lum - TH30) * WA, TH30), 1);
        }
    }
    c->TH30 = TH30; c->MB00 = MB; c->off = off;

    // 9.3.3.1 / 9.3.3.2
    bool clip = dmode != 2 && dmode != 3 && dmode != 6;
    struct avf_vivid_interval *iv = &c->iv[0];
    iv->mode = 0;
    iv->TH1 = TH30;
    iv->TH2 = stream ? TH30 + D1 : TH30 + 0.15;
    iv->TH3 = stream ? TH30 + D1 + D2 : iv->TH2 + 0.5 * iv->TH2 - 0.5 * iv->TH1;
    double VA1 = MB * iv->TH1 + off;
    double VA3 = avf_vivid_H(c, iv->TH3, c->m_a);
    if (stream && VA3 > iv->TH3 && clip) {
        c->m_b -= VA3 - iv->TH3;
        VA3 = iv->TH3;
    }
    double VA2 = VA1 + (iv->TH2 - iv->TH1) * (VA3 - VA1) / (iv->TH3 - iv->TH1);
    if (stream) {
        VA2 += (VA3 - VA1) * S / 2;
        if (VA2 > iv->TH2 && clip)
            VA2 = iv->TH2;
    }
    avf_vivid_solve(iv, VA1, VA2, VA3, MB, avf_vivid_dH(c, iv->TH3));
    c->n_iv = 1;

    // 9.3.3.3
    for (int j = 0; j < nsp; j++) {
        int mode = tm->spline[j].mode;
        if (mode == 0)
            continue;
        double s = 2.0 * tm->spline[j].str / 255 - 1;
        double a1 = tm->spline[j].th / 4095.0;
        double a2 = a1 + tm->spline[j].d1 * 0.25 / 1023;
        double a3 = a2 + tm->spline[j].d2 * 0.25 / 1023;
        if (a3 < iv->TH3)
            break;
        if (a1 < iv->TH3) {
            a1 = iv->TH3;
            a2 = (a1 + a3) / 2;
        }
        double V1 = avf_vivid_H(c, a1, c->m_a), V3 = avf_vivid_H(c, a3, c->m_a);
        if ((mode == 1 || mode == 2) && dmode != 3) {
            V3 = c->MaxD;
            if (V3 > a3 && dmode != 2 && dmode != 6) {
                a3 = V3;
                a2 = a1 + (a3 - a1) / 2;
            }
        } else if (mode == 1 || mode == 2) {
            V3 = target;
        }
        double V2 = V1 + (a2 - a1) * (V3 - V1) / (a3 - a1) + (V3 - V1) * s / 2;
        if ((mode == 1 || mode == 2) && V2 > a2 && clip)
            V2 = a2;
        double G1 = avf_vivid_dH(c, a1), G2 = avf_vivid_dH(c, a3), G3;
        if ((mode == 1 || mode == 2) && V3 == a3 && clip) {
            G3 = 1.0;   // the spec lists this beside the mode rules; let it win
        } else if (mode == 1) {
            double up = fmax((V3 - V1) / (a3 - a2), G1), mid = (V3 - V1) / (a3 - a1);
            double down = fmax((V3 - V1) * 0.1 / (a3 - a1), G1);
            G3 = s < 0 ? down * -s + mid * (1 + s) : up * s + mid * (1 - s);
        } else if (mode == 2) {
            G3 = G2 - tm->spline[j].mb * 1.1 / 255;
        } else {
            G3 = G2;
        }
        struct avf_vivid_interval *iv2 = &c->iv[1];
        iv2->mode = mode; iv2->TH1 = a1; iv2->TH2 = a2; iv2->TH3 = a3;
        avf_vivid_solve(iv2, V1, V2, V3, G1, G3);
        c->n_iv = 2;
        break;
    }
    return true;
}

// 9.4 eq.76-79: PQ code of max(R',G',B') -> mapped PQ code.
static inline double avf_vivid_map(const struct avf_vivid_curve *c, double x)
{
    if (c->n_iv > 1) {
        const struct avf_vivid_interval *v = &c->iv[1];
        if ((v->mode == 1 || v->mode == 2) && x > v->TH3) {
            double H1 = v->TH3 - v->TH2;   // H1 is undefined in the spec
            double MBH = 3 * v->MD1 * H1 * H1 + 2 * v->MC1 * H1 + v->MB1;
            double BASEH = v->MD1 * H1 * H1 * H1 + v->MC1 * H1 * H1 + v->MB1 * H1 + v->MA1;
            return MBH * (x - v->TH3) + BASEH;
        }
    }
    if (x <= c->TH30)
        return c->MB00 * x + c->off;
    for (int i = 0; i < c->n_iv; i++) {
        const struct avf_vivid_interval *v = &c->iv[i];
        if (x > v->TH1 && x <= v->TH2) {
            double d = x - v->TH1;
            return ((v->MD0 * d + v->MC0) * d + v->MB0) * d + v->MA0;
        }
        if (x > v->TH2 && x < v->TH3) {
            double d = x - v->TH2;
            return ((v->MD1 * d + v->MC1) * d + v->MB1) * d + v->MA1;
        }
    }
    return avf_vivid_H(c, x, c->m_a);
}

// Fills the curve LUT and the per-pixel constants. False if the curve is not finite.
static inline bool avf_vivid_prepare(const struct avf_vivid_curve *c, const struct avf_vivid_raw *r,
                                     bool full_range, float lut[AVF_VIVID_LUT_SIZE],
                                     struct avf_vivid_uniforms *u)
{
    for (int i = 0; i < AVF_VIVID_LUT_SIZE; i++) {
        double y = avf_vivid_map(c, i / (double)(AVF_VIVID_LUT_SIZE - 1));
        if (!isfinite(y))
            return false;
        lut[i] = fmin(fmax(y, 0.0), 1.0);
    }
    *u = (struct avf_vivid_uniforms){
        .y_off = full_range ? 0 : 64, .y_scale = full_range ? 1 / 1023.0f : 1 / 876.0f,
        .c_scale = full_range ? 1 / 1023.0f : 1 / 896.0f,
        .y_out = full_range ? 1023 : 876, .y_out_off = full_range ? 0 : 64,
        .c_out = full_range ? 1023 : 896,
        .tml = c->MaxD, .rml = c->ref,
    };
    if (r->sat_flag && r->sat_num > 0) {
        u->c0 = r->sat_gain[0] / 128.0f;
        u->sat_mode = 1;
        if (r->sat_num > 1) {
            u->sat_mode = 2;
            u->c1 = (r->sat_gain[1] & 0xFC) / 128.0f;
            u->m = 1 << (r->sat_gain[1] & 3);
        }
        // 9.5: B must stay within [0.8, 1].
        u->b = fminf(fmaxf(powf(avf_vivid_map(c, c->MaxD) / u->tml, u->c0), 0.8f), 1.0f);
    }
    return true;
}

static inline float avf_vivid_eotf_f(float e)
{
    float p = powf(fmaxf(e, 0.0f), 1 / 78.84375f);
    return powf(fmaxf(p - 0.8359375f, 0.0f) / (18.8515625f - 18.6875f * p), 1 / 0.1593017578125f);
}

static inline float avf_vivid_oetf_f(float l)
{
    float p = powf(fmaxf(l, 0.0f), 0.1593017578125f);
    return powf((0.8359375f + 18.8515625f * p) / (1 + 18.6875f * p), 78.84375f);
}

static inline float avf_vivid_lut(const float *lut, float x)
{
    float f = fminf(fmaxf(x, 0.0f), 1.0f) * (AVF_VIVID_LUT_SIZE - 1);
    int i = (int)f < AVF_VIVID_LUT_SIZE - 2 ? (int)f : AVF_VIVID_LUT_SIZE - 2;
    return lut[i] + (lut[i + 1] - lut[i]) * (f - i);
}

// 9.4-9.5 for one 2x2 block of 10-bit BT.2020 PQ codes. CPU reference of the
// Metal kernel below; the host test holds them to the same output. Instead of
// eq.89-90's round trip through RGB, the corrected Y'CbCr is written directly.
static inline void avf_vivid_block(const float *lut, const struct avf_vivid_uniforms *u,
                                   const int yin[4], int cbin, int crin,
                                   int yout[4], int *cbout, int *crout)
{
    float cb = (cbin - 512) * u->c_scale, cr = (crin - 512) * u->c_scale, scb = 0, scr = 0;
    for (int k = 0; k < 4; k++) {
        float Y = (yin[k] - u->y_off) * u->y_scale;
        float r = fminf(fmaxf(Y + 1.4746f * cr, 0.0f), 1.0f);
        float g = fminf(fmaxf(Y - 0.16455313f * cb - 0.57135313f * cr, 0.0f), 1.0f);
        float b = fminf(fmaxf(Y + 1.8814f * cb, 0.0f), 1.0f);
        float fm = fmaxf(r, fmaxf(g, b)), lm = avf_vivid_eotf_f(fm);
        float pr = 0, pg = 0, pb = 0, sca = 1;
        if (lm > 0) {
            float gain = avf_vivid_eotf_f(avf_vivid_lut(lut, fm)) / lm;
            pr = avf_vivid_oetf_f(avf_vivid_eotf_f(r) * gain);
            pg = avf_vivid_oetf_f(avf_vivid_eotf_f(g) * gain);
            pb = avf_vivid_oetf_f(avf_vivid_eotf_f(b) * gain);
            if (u->sat_mode == 2 && fm > u->tml)
                sca = fm >= u->rml ? u->b - u->c1 * 0.4f
                    : u->b - u->c1 * 0.4f * powf((fm - u->tml) / (u->rml - u->tml), (float)u->m);
            else if (u->sat_mode)
                sca = powf(fmaxf(pr, fmaxf(pg, pb)) / fm, u->c0);
            sca = fminf(fmaxf(sca, 0.8f), 1.0f);
        }
        float y = 0.2627f * pr + 0.678f * pg + 0.0593f * pb;
        scb += (pb - y) / 1.8814f * sca;
        scr += (pr - y) / 1.4746f * sca;
        yout[k] = (int)fminf(fmaxf(roundf(y * u->y_out + u->y_out_off), 0.0f), 1023.0f);
    }
    *cbout = (int)fminf(fmaxf(roundf(scb / 4 * u->c_out + 512), 0.0f), 1023.0f);
    *crout = (int)fminf(fmaxf(roundf(scr / 4 * u->c_out + 512), 0.0f), 1023.0f);
}

#define AVF_VIVID_MSL(...) #__VA_ARGS__

// P010 in, P010 out; one thread per 2x2 block. Planes are mapped as R16Unorm
// and RG16Unorm, so codes are value * 65535 / 64.
static const char avf_vivid_metal_source[] = "#include <metal_stdlib>\nusing namespace metal;\n"
AVF_VIVID_MSL(
struct U { float y_off, y_scale, c_scale, y_out, y_out_off, c_out, tml, rml, c0, c1, b; int sat_mode, m; };
static float eotf(float e) {
    float p = precise::pow(max(e, 0.0f), 1 / 78.84375f);
    return precise::pow(max(p - 0.8359375f, 0.0f) / (18.8515625f - 18.6875f * p), 1 / 0.1593017578125f);
}
static float oetf(float l) {
    float p = precise::pow(max(l, 0.0f), 0.1593017578125f);
    return precise::pow((0.8359375f + 18.8515625f * p) / (1 + 18.6875f * p), 78.84375f);
}
kernel void vivid_map(texture2d<float, access::read> yi [[texture(0)]],
                      texture2d<float, access::read> ci [[texture(1)]],
                      texture2d<float, access::write> yo [[texture(2)]],
                      texture2d<float, access::write> co [[texture(3)]],
                      constant U &u [[buffer(0)]], constant float *lut [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= ci.get_width() || gid.y >= ci.get_height()) return;
    float2 c = (round(ci.read(gid).rg * 65535.0f) / 64.0f - 512.0f) * u.c_scale;
    float scb = 0, scr = 0;
    for (uint k = 0; k < 4; k++) {
        uint2 at = gid * 2 + uint2(k & 1, k >> 1);
        uint2 rd = min(at, uint2(yi.get_width() - 1, yi.get_height() - 1));
        float Y = (round(yi.read(rd).r * 65535.0f) / 64.0f - u.y_off) * u.y_scale;
        float r = clamp(Y + 1.4746f * c.y, 0.0f, 1.0f);
        float g = clamp(Y - 0.16455313f * c.x - 0.57135313f * c.y, 0.0f, 1.0f);
        float b = clamp(Y + 1.8814f * c.x, 0.0f, 1.0f);
        float fm = max(r, max(g, b)), lm = eotf(fm);
        float3 P = 0;
        float sca = 1;
        if (lm > 0) {
            float f = fm * 4095.0f;
            uint i = min(uint(f), 4094u);
            float gain = eotf(lut[i] + (lut[i + 1] - lut[i]) * (f - float(i))) / lm;
            P = float3(oetf(eotf(r) * gain), oetf(eotf(g) * gain), oetf(eotf(b) * gain));
            if (u.sat_mode == 2 && fm > u.tml)
                sca = fm >= u.rml ? u.b - u.c1 * 0.4f
                    : u.b - u.c1 * 0.4f * precise::pow((fm - u.tml) / (u.rml - u.tml), float(u.m));
            else if (u.sat_mode != 0)
                sca = precise::pow(max(P.r, max(P.g, P.b)) / fm, u.c0);
            sca = clamp(sca, 0.8f, 1.0f);
        }
        float y = 0.2627f * P.r + 0.678f * P.g + 0.0593f * P.b;
        scb += (P.b - y) / 1.8814f * sca;
        scr += (P.r - y) / 1.4746f * sca;
        if (at.x < yo.get_width() && at.y < yo.get_height())
            yo.write(float4(clamp(round(y * u.y_out + u.y_out_off), 0.0f, 1023.0f) * 64.0f / 65535.0f), at);
    }
    float2 o = clamp(round(float2(scb, scr) / 4 * u.c_out + 512.0f), 0.0f, 1023.0f);
    co.write(float4(o * 64.0f / 65535.0f, 0, 0), gid);
}
);

#endif
