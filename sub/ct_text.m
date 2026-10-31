/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Quasar (2026).
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "ct_text.h"

// libass sizes a font so that ascent + descent = the style size. Here the
// line box keeps that size for Noto Sans SC (ascent 1.160 + descent 0.288
// em), the bundled default before, and every CJK font is sized so that its
// '中' is as tall as Noto's (0.919 em): a font change keeps the text size.
#define REF_ASCENT 1.160
#define REF_DESCENT 0.288
#define REF_HANZI 0.919
// CJK-Latin gap CoreText adds on its own for the system UI font only.
#define CJK_LATIN_GAP 0.25

// Run attributes beyond the font, as CFNumbers.
static CFStringRef const kPrimary = CFSTR("qct.primary");
static CFStringRef const kOutline = CFSTR("qct.outline");
static CFStringRef const kBack = CFSTR("qct.back");
static CFStringRef const kFlags = CFSTR("qct.flags");
static CFStringRef const kPx = CFSTR("qct.px");

enum { F_UNDERLINE = 1, F_STRIKE = 2, F_FAKE_BOLD = 4 };

struct ct_text {
    uint64_t hash;
    bool valid;
    struct ct_image *images;
    int n_images, cap_images;
    uint8_t **bufs;
    int n_bufs, cap_bufs;
};

struct ct_text *ct_text_create(void)
{
    return calloc(1, sizeof(struct ct_text));
}

static void clear_output(struct ct_text *ct)
{
    for (int i = 0; i < ct->n_bufs; i++)
        free(ct->bufs[i]);
    ct->n_bufs = 0;
    ct->n_images = 0;
}

void ct_text_destroy(struct ct_text *ct)
{
    if (!ct)
        return;
    clear_output(ct);
    free(ct->bufs);
    free(ct->images);
    free(ct);
}

// --- change detection

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++)
        h = (h ^ b[i]) * 0x100000001b3ULL;
    return h;
}

static uint64_t fnv_str(uint64_t h, const char *s)
{
    return fnv(h, s ? s : "", s ? strlen(s) + 1 : 1);
}

// --- fonts

static bool is_system(const char *family)
{
    return !family || !family[0] || !strcmp(family, "sans-serif") ||
           !strcmp(family, "system-ui");
}

static CTFontDescriptorRef family_descriptor(const char *family)
{
    CFStringRef name = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    if (!name)
        return NULL;
    const void *k[] = {kCTFontFamilyNameAttribute};
    const void *v[] = {name};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(attrs);
    CFRelease(attrs);
    CFRelease(name);
    return d;
}

// The family's font at 1 pt, or NULL when it is not installed (CoreText
// would hand back a substitute).
static CTFontRef named_font(const char *family)
{
    CTFontDescriptorRef d = family_descriptor(family);
    if (!d)
        return NULL;
    CTFontRef f = CTFontCreateWithFontDescriptor(d, 1, NULL);
    CFRelease(d);
    if (!f)
        return NULL;
    CFStringRef got = CTFontCopyFamilyName(f);
    CFStringRef want = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    bool same = got && want && CFStringCompare(got, want, kCFCompareCaseInsensitive) == 0;
    if (got)
        CFRelease(got);
    if (want)
        CFRelease(want);
    if (!same) {
        CFRelease(f);
        return NULL;
    }
    return f;
}

// The glyph '中' in font (or what CoreText falls back to for it): its ink
// height, the size CJK text looks.
static double hanzi_height(CTFontRef font)
{
    UniChar c = 0x4E2D;
    CGGlyph g = 0;
    CTFontRef f = NULL;
    if (!CTFontGetGlyphsForCharacters(font, &c, &g, 1)) {
        CFStringRef s = CFStringCreateWithCharacters(NULL, &c, 1);
        f = s ? CTFontCreateForString(font, s, CFRangeMake(0, 1)) : NULL;
        if (s)
            CFRelease(s);
        if (!f || !CTFontGetGlyphsForCharacters(f, &c, &g, 1)) {
            if (f)
                CFRelease(f);
            return 0;
        }
    }
    CGRect r = CTFontGetBoundingRectsForGlyphs(f ? f : font, kCTFontOrientationDefault,
                                               &g, NULL, 1);
    if (f)
        CFRelease(f);
    return r.size.height;
}

static bool has_cjk(CTFontRef font)
{
    UniChar c = 0x4E2D;
    CGGlyph g = 0;
    return CTFontGetGlyphsForCharacters(font, &c, &g, 1);
}

// Latin cap height over CJK ink height of the system pair (SF, PingFang):
// other pairs are sized to it.
static double system_cap_ratio(void)
{
    static double ratio;
    if (!ratio) {
        CTFontRef sys = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 100, NULL);
        double h = sys ? hanzi_height(sys) : 0;
        ratio = h > 0 ? CTFontGetCapHeight(sys) / h : 0.81;
        if (sys)
            CFRelease(sys);
    }
    return ratio;
}

static CTFontRef with_traits(CTFontRef f, double em, bool bold, bool italic, bool *fake_bold)
{
    CTFontRef out = CTFontCreateCopyWithAttributes(f, em, NULL, NULL);
    if (!out)
        return NULL;
    if (bold) {
        CTFontRef b = CTFontCreateCopyWithSymbolicTraits(out, em, NULL, kCTFontBoldTrait,
                                                         kCTFontBoldTrait);
        if (b) {
            CFRelease(out);
            out = b;
        } else {
            *fake_bold = true;
        }
    }
    if (italic) {
        CTFontRef i = CTFontCreateCopyWithSymbolicTraits(out, em, NULL, kCTFontItalicTrait,
                                                         kCTFontItalicTrait);
        if (!i) {
            // Oblique, as libass does for fonts without an italic.
            CGAffineTransform skew = {1, 0, 0.2, 1, 0, 0};
            i = CTFontCreateCopyWithAttributes(out, em, &skew, NULL);
        }
        if (i) {
            CFRelease(out);
            out = i;
        }
    }
    return out;
}

static double cap_height(CTFontRef f)
{
    return CTFontGetCapHeight(f);
}

// f at the em size where measure() reads target px. The system font picks
// its optical variant (and CJK fallback) by size, so measure at the size
// used and correct once.
static CTFontRef sized(CTFontRef f, double em, double target, double (*measure)(CTFontRef),
                       bool bold, bool italic, bool *fake_bold)
{
    CTFontRef out = with_traits(f, em, bold, italic, fake_bold);
    double got = out ? measure(out) : 0;
    if (got > 0 && fabs(got - target) > target * 0.005) {
        CTFontRef again = with_traits(f, em * target / got, bold, italic, fake_bold);
        if (again) {
            CFRelease(out);
            out = again;
        }
    }
    return out;
}

struct fonts {
    CTFontRef latin, cjk;   // the same font when the main font has CJK
    bool fake_bold_latin, fake_bold_cjk;
};

static void free_fonts(struct fonts *f)
{
    if (f->latin)
        CFRelease(f->latin);
    if (f->cjk)
        CFRelease(f->cjk);
}

// px is the line box (REF ascent + descent); the CJK font is sized to REF's
// '中'. A main font without CJK is a Latin font: its cap height is set to
// the CJK ink height times the system pair's ratio, so mixed lines look as
// balanced as SF with PingFang.
static struct fonts make_fonts(const char *family, const char *cjk_family,
                               double px, bool bold, bool italic)
{
    struct fonts out = {0};
    CTFontRef sys = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 1, NULL);
    CTFontRef main = is_system(family) ? NULL : named_font(family);
    CTFontRef cjk = NULL;
    if (main && has_cjk(main))
        cjk = (CTFontRef)CFRetain(main);
    else if (cjk_family && cjk_family[0] && !is_system(cjk_family))
        cjk = named_font(cjk_family);
    if (!sys) {
        if (main)
            CFRelease(main);
        if (cjk)
            CFRelease(cjk);
        return out;
    }
    double ratio = hanzi_height(cjk ? cjk : sys);    // at 1 pt
    double ink = px * REF_HANZI / (REF_ASCENT + REF_DESCENT);
    double cjk_em = ink / (ratio > 0 ? ratio : REF_HANZI);
    out.cjk = sized(cjk ? cjk : sys, cjk_em, ink, hanzi_height, bold, italic, &out.fake_bold_cjk);
    if ((main && cjk == main) || (!main && !cjk)) {
        // One font for both: the main font has CJK, or the system pair
        // (one run, so CoreText adds its own CJK-Latin spacing).
        out.latin = out.cjk ? (CTFontRef)CFRetain(out.cjk) : NULL;
        out.fake_bold_latin = out.fake_bold_cjk;
    } else {
        CTFontRef latin = main ? main : sys;
        double hanzi = out.cjk ? hanzi_height(out.cjk) : 0;
        double cap = CTFontGetCapHeight(latin);
        if (hanzi > 0 && cap > 0) {
            double target = system_cap_ratio() * hanzi;
            out.latin = sized(latin, target / cap, target, cap_height, bold, italic,
                              &out.fake_bold_latin);
        } else {
            out.latin = with_traits(latin, cjk_em, bold, italic, &out.fake_bold_latin);
        }
    }
    if (main)
        CFRelease(main);
    if (cjk)
        CFRelease(cjk);
    CFRelease(sys);
    return out;
}

// --- ASS text parsing (the subset mpv's text converters emit)

struct run_state {
    bool b, i, u, s;
    uint32_t primary, outline, back;
    double px;
    char fn[128];
};

struct event_layout {
    int align;
    // Paragraphs separated by \N.
    CFMutableAttributedStringRef *paras;
    int n_paras;
    double max_px;      // largest run size, for the line box
};

static bool parse_hex(const char **pp, uint32_t *out)
{
    const char *p = *pp;
    while (*p == '&' || *p == 'H' || *p == 'h')
        p++;
    char *end;
    unsigned long v = strtoul(p, &end, 16);
    if (end == p)
        return false;
    if (*end == '&')
        end++;
    *out = (uint32_t)v;
    *pp = end;
    return true;
}

// ASS &HBBGGRR& to libass RGBA, keeping the alpha byte of `old`.
static uint32_t ass_color(uint32_t bgr, uint32_t old)
{
    uint32_t r = bgr & 0xFF, g = (bgr >> 8) & 0xFF, b = (bgr >> 16) & 0xFF;
    return (r << 24) | (g << 16) | (b << 8) | (old & 0xFF);
}

static uint32_t with_alpha(uint32_t c, uint32_t a)
{
    return (c & 0xFFFFFF00) | (a & 0xFF);
}

static void reset_state(struct run_state *s, const struct ct_text_style *st)
{
    *s = (struct run_state){
        .b = st->bold, .i = st->italic,
        .primary = st->primary, .outline = st->outline, .back = st->back,
        .px = st->size,
    };
}

// One override block, without braces. False on a tag we do not handle.
static bool parse_tags(const char *p, const char *end, struct run_state *s,
                       const struct ct_text_style *st, const struct ct_text_frame *f,
                       int *align)
{
    while (p < end) {
        if (*p != '\\') {
            p++;    // comment text inside braces
            continue;
        }
        p++;
        if (p + 1 < end && p[0] >= '1' && p[0] <= '4' && (p[1] == 'c' || p[1] == 'a')) {
            int which = p[0] - '0';
            bool alpha = p[1] == 'a';
            p += 2;
            uint32_t v = 0;
            bool have = parse_hex(&p, &v);
            uint32_t *dst = which == 1 ? &s->primary : which == 3 ? &s->outline
                          : which == 4 ? &s->back : NULL;
            const uint32_t def = which == 1 ? st->primary : which == 3 ? st->outline
                               : st->back;
            // No value resets to the style.
            if (dst && alpha)
                *dst = with_alpha(*dst, have ? v : def);
            else if (dst)
                *dst = have ? ass_color(v, *dst) : (def & 0xFFFFFF00) | (*dst & 0xFF);
            continue;
        }
        const char *n = p;
        while (p < end && ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')))
            p++;
        size_t len = p - n;
        if (len >= 2 && !strncmp(n, "fn", 2)) {
            const char *v = n + 2;
            const char *ve = v;
            while (ve < end && *ve != '\\')
                ve++;
            size_t vl = ve - v;
            if (vl >= sizeof(s->fn))
                vl = sizeof(s->fn) - 1;
            memcpy(s->fn, v, vl);
            s->fn[vl] = 0;
            p = ve;
            continue;
        }
        if (len >= 1 && n[0] == 'r') {
            reset_state(s, st);
            while (p < end && *p != '\\')
                p++;
            continue;
        }
        char *ne;
        double num = strtod(p, &ne);
        bool has_num = ne != p;
        if (len == 2 && !strncmp(n, "an", 2)) {
            if (has_num && num >= 1 && num <= 9 && !*align)
                *align = (int)num;
        } else if (len == 2 && !strncmp(n, "fs", 2)) {
            s->px = has_num && num > 0 ? num * f->tag_scale : st->size;
        } else if (len == 1 && n[0] == 'b') {
            s->b = has_num ? (num == 1 || num >= 700) : st->bold;
        } else if (len == 1 && n[0] == 'i') {
            s->i = has_num ? num != 0 : st->italic;
        } else if (len == 1 && n[0] == 'u') {
            s->u = has_num && num != 0;
        } else if (len == 1 && n[0] == 's') {
            s->s = has_num && num != 0;
        } else if ((len == 1 && n[0] == 'c') || (len == 5 && !strncmp(n, "alpha", 5))) {
            bool alpha = len == 5;
            uint32_t v = 0;
            const char *q = p;
            bool have = parse_hex(&q, &v);
            p = q;
            if (alpha) {
                uint32_t a = have ? v : (st->primary & 0xFF);
                s->primary = with_alpha(s->primary, a);
                s->outline = with_alpha(s->outline, have ? v : st->outline);
                s->back = with_alpha(s->back, have ? v : st->back);
            } else {
                s->primary = have ? ass_color(v, s->primary)
                                  : (st->primary & 0xFFFFFF00) | (s->primary & 0xFF);
            }
            continue;
        } else {
            return false;   // positioning, animation, drawing, karaoke, ...
        }
        p = has_num ? ne : p;
    }
    return true;
}

static bool is_cjk(UniChar c)
{
    return (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) ||
           (c >= 0xF900 && c <= 0xFAFF) || (c >= 0x3040 && c <= 0x30FF);
}

static bool is_latin(UniChar c)
{
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7);
}

static CFNumberRef num_u32(uint32_t v)
{
    int64_t x = v;
    return CFNumberCreate(NULL, kCFNumberSInt64Type, &x);
}

static uint32_t get_u32(CFDictionaryRef d, CFStringRef k)
{
    CFNumberRef n = CFDictionaryGetValue(d, k);
    int64_t x = 0;
    if (n)
        CFNumberGetValue(n, kCFNumberSInt64Type, &x);
    return (uint32_t)x;
}

// CJK text (Han, kana, Hangul, CJK and fullwidth punctuation) uses the CJK
// font; neutral characters (spaces, curly quotes, dashes, ellipsis) follow
// the character before them.
static int char_class(UniChar c)
{
    if (is_cjk(c) || (c >= 0x3000 && c <= 0x303F) || (c >= 0xFF00 && c <= 0xFF60) ||
        (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0xAC00 && c <= 0xD7AF) ||
        (c >= 0x1100 && c <= 0x11FF) || (c >= 0xD800 && c <= 0xDFFF))
        return 1;
    if (c == ' ' || c == 0xA0 || (c >= 0x2018 && c <= 0x201F) || c == 0x2026 ||
        c == 0x2014 || c == 0x00B7)
        return -1;
    return 0;
}

static void append_text(CFMutableAttributedStringRef as, const char *t, size_t len,
                        const struct run_state *s, const struct ct_text_style *st)
{
    if (!len)
        return;
    CFStringRef str = CFStringCreateWithBytes(NULL, (const UInt8 *)t, len,
                                              kCFStringEncodingUTF8, false);
    if (!str)
        return;
    const char *family = s->fn[0] ? s->fn : st->font;
    struct fonts fo = make_fonts(family, st->cjk_font, s->px, s->b, s->i);
    if (!fo.latin || !fo.cjk) {
        free_fonts(&fo);
        CFRelease(str);
        return;
    }
    CFIndex at = CFAttributedStringGetLength(as);
    CFIndex n = CFStringGetLength(str);
    CFAttributedStringReplaceString(as, CFRangeMake(at, 0), str);
    CFNumberRef primary = num_u32(s->primary), outline = num_u32(s->outline),
                back = num_u32(s->back);
    CFNumberRef px = CFNumberCreate(NULL, kCFNumberDoubleType, &s->px);
    double kern = st->spacing;
    CFNumberRef kn = CFNumberCreate(NULL, kCFNumberDoubleType, &kern);
    int prev = 0;
    for (CFIndex i = 0; i < n;) {
        int cls = char_class(CFStringGetCharacterAtIndex(str, i));
        if (cls < 0) {
            // Leading neutrals take the class of the first real character.
            cls = prev;
            if (i == 0) {
                for (CFIndex j = 0; j < n; j++) {
                    int c = char_class(CFStringGetCharacterAtIndex(str, j));
                    if (c >= 0) {
                        cls = c;
                        break;
                    }
                }
            }
        }
        CFIndex j = i + 1;
        for (; j < n; j++) {
            int c = char_class(CFStringGetCharacterAtIndex(str, j));
            if (c >= 0 && c != cls)
                break;
        }
        prev = cls;
        bool fake = cls ? fo.fake_bold_cjk : fo.fake_bold_latin;
        int flags = (s->u ? F_UNDERLINE : 0) | (s->s ? F_STRIKE : 0) | (fake ? F_FAKE_BOLD : 0);
        CFNumberRef fl = num_u32(flags);
        const void *k[] = {kCTFontAttributeName, kCTForegroundColorFromContextAttributeName,
                           kPrimary, kOutline, kBack, kFlags, kPx, kCTKernAttributeName};
        const void *v[] = {cls ? fo.cjk : fo.latin, kCFBooleanTrue, primary, outline, back,
                           fl, px, kn};
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 8, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringSetAttributes(as, CFRangeMake(at + i, j - i), attrs, true);
        CFRelease(attrs);
        CFRelease(fl);
        i = j;
    }
    CFRelease(primary);
    CFRelease(outline);
    CFRelease(back);
    CFRelease(px);
    CFRelease(kn);
    free_fonts(&fo);
    CFRelease(str);
}

// CoreText spaces CJK from Latin by itself within one run of the system UI
// font; everywhere else the same 0.25 em gap is added here.
static void add_cjk_latin_gaps(CFMutableAttributedStringRef as, const struct ct_text_style *st)
{
    CFStringRef str = CFAttributedStringGetString(as);
    CFIndex n = CFStringGetLength(str);
    for (CFIndex i = 0; i + 1 < n; i++) {
        UniChar a = CFStringGetCharacterAtIndex(str, i);
        UniChar b = CFStringGetCharacterAtIndex(str, i + 1);
        if (!((is_cjk(a) && is_latin(b)) || (is_latin(a) && is_cjk(b))))
            continue;
        CTFontRef fa = CFAttributedStringGetAttribute(as, i, kCTFontAttributeName, NULL);
        CTFontRef fb = CFAttributedStringGetAttribute(as, i + 1, kCTFontAttributeName, NULL);
        CTFontRef cjk = is_cjk(a) ? fa : fb;
        CFStringRef fam = fa ? CTFontCopyFamilyName(fa) : NULL;
        bool sys = fam && CFStringHasPrefix(fam, CFSTR("."));
        if (fam)
            CFRelease(fam);
        if (sys && fa && fb && CFEqual(fa, fb))
            continue;
        double kern = st->spacing + CJK_LATIN_GAP * (cjk ? CTFontGetSize(cjk) : st->size);
        CFNumberRef kn = CFNumberCreate(NULL, kCFNumberDoubleType, &kern);
        CFAttributedStringSetAttribute(as, CFRangeMake(i, 1), kCTKernAttributeName, kn);
        CFRelease(kn);
    }
}

static void free_layout(struct event_layout *e)
{
    for (int i = 0; i < e->n_paras; i++)
        CFRelease(e->paras[i]);
    free(e->paras);
    e->paras = NULL;
    e->n_paras = 0;
}

static bool new_para(struct event_layout *e)
{
    CFMutableAttributedStringRef as = CFAttributedStringCreateMutable(NULL, 0);
    CFMutableAttributedStringRef *np = realloc(e->paras, sizeof(*np) * (e->n_paras + 1));
    if (!as || !np) {
        if (as)
            CFRelease(as);
        if (np)
            e->paras = np;
        return false;
    }
    e->paras = np;
    e->paras[e->n_paras++] = as;
    CFAttributedStringBeginEditing(as);
    return true;
}

static bool parse_event(const char *text, const struct ct_text_style *st,
                        const struct ct_text_frame *f, struct event_layout *e)
{
    struct run_state s;
    reset_state(&s, st);
    int align = 0;
    e->max_px = st->size;
    if (!new_para(e))
        return false;
    // Pending plain text, flushed with the state it was written under.
    char *buf = malloc(strlen(text) + 1);
    if (!buf)
        return false;
    size_t bl = 0;
#define FLUSH() do { append_text(e->paras[e->n_paras - 1], buf, bl, &s, st); bl = 0; } while (0)
    for (const char *p = text; *p;) {
        if (*p == '{') {
            const char *close = strchr(p, '}');
            if (!close)
                break;
            FLUSH();
            if (!parse_tags(p + 1, close, &s, st, f, &align)) {
                free(buf);
                return false;
            }
            if (s.px > e->max_px)
                e->max_px = s.px;
            p = close + 1;
        } else if (p[0] == '\\' && p[1] == 'N') {
            FLUSH();
            if (!new_para(e)) {
                free(buf);
                return false;
            }
            p += 2;
        } else if (p[0] == '\\' && p[1] == 'n') {
            buf[bl++] = ' ';
            p += 2;
        } else if (p[0] == '\\' && p[1] == 'h') {
            buf[bl++] = (char)0xC2;     // U+00A0
            buf[bl++] = (char)0xA0;
            p += 2;
        } else {
            buf[bl++] = *p++;
        }
    }
    FLUSH();
#undef FLUSH
    free(buf);
    for (int i = 0; i < e->n_paras; i++) {
        add_cjk_latin_gaps(e->paras[i], st);
        CFAttributedStringEndEditing(e->paras[i]);
    }
    e->align = align ? align : st->align;
    return true;
}

// --- layout

struct line {
    CTLineRef line;
    double x, baseline;     // in event block coordinates (y down)
    double width;
    double ascent, descent;
};

struct block {
    struct line *lines;
    int n_lines;
    double w, h;
    double x, y;            // top left in OSD pixels
    int align;
};

static int count_lines(CTTypesetterRef ts, CFIndex len, double width)
{
    int n = 0;
    for (CFIndex i = 0; i < len;) {
        CFIndex b = CTTypesetterSuggestLineBreak(ts, i, width);
        i += b > 0 ? b : 1;
        n++;
    }
    return n;
}

static double line_width(CTLineRef l)
{
    double w = CTLineGetTypographicBounds(l, NULL, NULL, NULL) -
               CTLineGetTrailingWhitespaceWidth(l);
    return w > 0 ? w : 0;
}

static bool add_line(struct block *b, CTLineRef l, const struct ct_text_style *st,
                     double px)
{
    struct line *nl = realloc(b->lines, sizeof(*nl) * (b->n_lines + 1));
    if (!nl) {
        CFRelease(l);
        return false;
    }
    b->lines = nl;
    double ca = 0, cd = 0;
    CTLineGetTypographicBounds(l, &ca, &cd, NULL);
    double ra = px * REF_ASCENT / (REF_ASCENT + REF_DESCENT);
    b->lines[b->n_lines++] = (struct line){
        .line = l,
        .width = line_width(l),
        .ascent = fmax(ra, ca),
        .descent = fmax(px - ra, cd),
    };
    return true;
}

// Greedy breaking finds the line count; the narrowest width that keeps it
// evens the lines out (libass smart wrapping).
static bool layout_para(struct block *b, CFAttributedStringRef as, double avail,
                        const struct ct_text_style *st, double px)
{
    CFIndex len = CFAttributedStringGetLength(as);
    if (!len) {
        CTLineRef empty = CTLineCreateWithAttributedString(as);
        return empty && add_line(b, empty, st, px);
    }
    CTTypesetterRef ts = CTTypesetterCreateWithAttributedString(as);
    if (!ts)
        return false;
    double width = avail;
    int n = count_lines(ts, len, avail);
    if (n > 1) {
        CTLineRef whole = CTTypesetterCreateLine(ts, CFRangeMake(0, len));
        double lo = whole ? line_width(whole) / n : avail / n, hi = avail;
        if (whole)
            CFRelease(whole);
        for (int it = 0; it < 12 && hi - lo > 1; it++) {
            double mid = (lo + hi) / 2;
            if (count_lines(ts, len, mid) > n)
                lo = mid;
            else
                hi = mid;
        }
        width = hi;
    }
    bool ok = true;
    for (CFIndex i = 0; ok && i < len;) {
        CFIndex br = CTTypesetterSuggestLineBreak(ts, i, width);
        if (br <= 0)
            br = 1;
        CTLineRef l = CTTypesetterCreateLine(ts, CFRangeMake(i, br));
        ok = l && add_line(b, l, st, px);
        i += br;
    }
    CFRelease(ts);
    return ok;
}

static void free_block(struct block *b)
{
    for (int i = 0; i < b->n_lines; i++)
        CFRelease(b->lines[i].line);
    free(b->lines);
    b->lines = NULL;
    b->n_lines = 0;
}

static bool layout_event(struct block *b, struct event_layout *e,
                         const struct ct_text_style *st, const struct ct_text_frame *f)
{
    double avail = f->w - f->ml - f->mr - f->margin_l - f->margin_r;
    if (avail < 1)
        avail = 1;
    for (int i = 0; i < e->n_paras; i++) {
        if (!layout_para(b, e->paras[i], avail, st, e->max_px))
            return false;
    }
    int col = (e->align - 1) % 3;   // 0 left, 1 center, 2 right
    int justify = f->justify ? f->justify - 1 : col;
    double y = 0;
    b->w = 0;
    for (int i = 0; i < b->n_lines; i++)
        b->w = fmax(b->w, b->lines[i].width);
    for (int i = 0; i < b->n_lines; i++) {
        struct line *l = &b->lines[i];
        if (i)
            y += st->line_spacing;
        l->baseline = y + l->ascent;
        y += l->ascent + l->descent;
        l->x = justify == 0 ? 0 : justify == 1 ? (b->w - l->width) / 2 : b->w - l->width;
    }
    b->h = y;
    b->align = e->align;
    double left = f->ml + f->margin_l, right = f->w - f->mr - f->margin_r;
    b->x = col == 0 ? left : col == 1 ? left + (right - left - b->w) / 2 : right - b->w;
    return true;
}

// Bottom-aligned blocks stack upwards in order, top-aligned ones downwards;
// middle ones are centered as a group.
static void place_blocks(struct block *bl, int n, const struct ct_text_frame *f)
{
    double vid_h = f->h - f->mt - f->mb;
    double bottom = f->h - f->mb - f->margin_v;
    double top = f->mt + f->margin_v;
    double mid_h = 0;
    for (int i = 0; i < n; i++) {
        if ((bl[i].align - 1) / 3 == 1)
            mid_h += bl[i].h;
    }
    double mid = f->mt + (vid_h - mid_h) / 2;
    for (int i = 0; i < n; i++) {
        struct block *b = &bl[i];
        int row = (b->align - 1) / 3;   // 0 bottom, 1 middle, 2 top
        if (row == 0) {
            double lift = f->line_position / 100.0 * (vid_h - 2 * f->margin_v - b->h);
            b->y = bottom - b->h - fmax(0, lift);
            bottom = b->y;
        } else if (row == 2) {
            b->y = top;
            top += b->h;
        } else {
            b->y = mid;
            mid += b->h;
        }
    }
}

// --- rasterization

static uint8_t *alloc_buf(struct ct_text *ct, size_t size)
{
    if (ct->n_bufs == ct->cap_bufs) {
        int cap = ct->cap_bufs ? ct->cap_bufs * 2 : 16;
        uint8_t **nb = realloc(ct->bufs, sizeof(*nb) * cap);
        if (!nb)
            return NULL;
        ct->bufs = nb;
        ct->cap_bufs = cap;
    }
    uint8_t *b = calloc(1, size);
    if (b)
        ct->bufs[ct->n_bufs++] = b;
    return b;
}

static struct ct_image *add_image(struct ct_text *ct)
{
    if (ct->n_images == ct->cap_images) {
        int cap = ct->cap_images ? ct->cap_images * 2 : 16;
        struct ct_image *ni = realloc(ct->images, sizeof(*ni) * cap);
        if (!ni)
            return NULL;
        ct->images = ni;
        ct->cap_images = cap;
    }
    struct ct_image *img = &ct->images[ct->n_images++];
    *img = (struct ct_image){0};
    return img;
}

// Three passes of a box blur, about a Gaussian with sigma r.
static void box_blur(uint8_t *buf, int w, int h, int stride, int r)
{
    if (r <= 0)
        return;
    int n = w > h ? w : h;
    uint8_t *tmp = malloc(n);
    if (!tmp)
        return;
    int div = 2 * r + 1;
    for (int pass = 0; pass < 3; pass++) {
        for (int y = 0; y < h; y++) {
            uint8_t *row = buf + (size_t)y * stride;
            int sum = 0;
            for (int i = -r; i <= r; i++)
                sum += row[i < 0 ? 0 : i >= w ? w - 1 : i];
            for (int x = 0; x < w; x++) {
                tmp[x] = sum / div;
                int add = x + r + 1, sub = x - r;
                sum += row[add >= w ? w - 1 : add] - row[sub < 0 ? 0 : sub];
            }
            memcpy(row, tmp, w);
        }
        for (int x = 0; x < w; x++) {
            int sum = 0;
            for (int i = -r; i <= r; i++)
                sum += buf[(size_t)(i < 0 ? 0 : i >= h ? h - 1 : i) * stride + x];
            for (int y = 0; y < h; y++) {
                tmp[y] = sum / div;
                int add = y + r + 1, sub = y - r;
                sum += buf[(size_t)(add >= h ? h - 1 : add) * stride + x] -
                       buf[(size_t)(sub < 0 ? 0 : sub) * stride + x];
            }
            for (int y = 0; y < h; y++)
                buf[(size_t)y * stride + x] = tmp[y];
        }
    }
    free(tmp);
}

enum layer { L_BODY, L_OUTLINE };

struct canvas {
    int x, y, w, h, stride;     // OSD pixels
    double ox, oy;              // block origin inside the canvas (y down)
};

// Draws the runs of `color` (by the layer's color key) into an A8 mask.
static bool draw_mask(uint8_t *buf, const struct canvas *c, const struct block *b,
                      enum layer layer, uint32_t color, const struct ct_text_style *st)
{
    CGContextRef cg = CGBitmapContextCreate(buf, c->w, c->h, 8, c->stride, NULL,
                                            (CGBitmapInfo)kCGImageAlphaOnly);
    if (!cg)
        return false;
    CGContextSetRGBFillColor(cg, 0, 0, 0, 1);
    CGContextSetRGBStrokeColor(cg, 0, 0, 0, 1);
    CGContextSetShouldAntialias(cg, true);
    CGContextSetShouldSmoothFonts(cg, false);
    CGContextSetShouldSubpixelPositionFonts(cg, true);
    CGContextSetShouldSubpixelQuantizeFonts(cg, false);
    CGContextSetLineJoin(cg, kCGLineJoinRound);
    CGContextSetLineCap(cg, kCGLineCapRound);
    CGContextSetTextMatrix(cg, CGAffineTransformIdentity);
    bool box = st->border_style == 3 || st->border_style == 4;
    bool any = false;
    for (int i = 0; i < b->n_lines; i++) {
        const struct line *l = &b->lines[i];
        double lx = c->ox + l->x;
        double by = c->h - (c->oy + l->baseline);     // CG y up
        if (layer == L_OUTLINE && box) {
            if (st->border_style == 3 && (st->outline & 0xFFFFFF00) == (color & 0xFFFFFF00)) {
                double t = c->h - (c->oy + l->baseline - l->ascent);
                CGContextFillRect(cg, CGRectMake(lx - st->outline_w, by - l->descent - st->outline_w,
                                                 l->width + 2 * st->outline_w,
                                                 t - (by - l->descent) + 2 * st->outline_w));
                any = true;
            }
            continue;
        }
        CFArrayRef runs = CTLineGetGlyphRuns(l->line);
        for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
            CTRunRef run = CFArrayGetValueAtIndex(runs, r);
            CFDictionaryRef a = CTRunGetAttributes(run);
            uint32_t rc = get_u32(a, layer == L_BODY ? kPrimary : kOutline);
            if (rc != color)
                continue;
            CTFontRef font = CFDictionaryGetValue(a, kCTFontAttributeName);
            CFIndex n = CTRunGetGlyphCount(run);
            if (!font || n <= 0)
                continue;
            CGGlyph *glyphs = malloc(sizeof(CGGlyph) * n);
            CGPoint *pos = malloc(sizeof(CGPoint) * n);
            if (!glyphs || !pos) {
                free(glyphs);
                free(pos);
                continue;
            }
            CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
            CTRunGetPositions(run, CFRangeMake(0, 0), pos);
            int flags = (int)get_u32(a, kFlags);
            double em = CTFontGetSize(font);
            double width = (flags & F_FAKE_BOLD) ? em * 0.04 : 0;
            if (layer == L_OUTLINE)
                width += 2 * st->outline_w;
            CGContextSaveGState(cg);
            CGContextTranslateCTM(cg, lx, by);
            CGContextSetLineWidth(cg, width);
            CGContextSetTextDrawingMode(cg, width > 0 ? kCGTextFillStroke : kCGTextFill);
            CTFontDrawGlyphs(font, glyphs, pos, n, cg);
            if (flags & (F_UNDERLINE | F_STRIKE)) {
                double rw = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
                double th = fmax(CTFontGetUnderlineThickness(font), em * 0.05) + width;
                double x0 = pos[0].x - width / 2;
                if (flags & F_UNDERLINE)
                    CGContextFillRect(cg, CGRectMake(x0, CTFontGetUnderlinePosition(font) - th / 2,
                                                     rw + width, th));
                if (flags & F_STRIKE)
                    CGContextFillRect(cg, CGRectMake(x0, CTFontGetXHeight(font) / 2 - th / 2,
                                                     rw + width, th));
            }
            CGContextRestoreGState(cg);
            free(glyphs);
            free(pos);
            any = true;
        }
    }
    CGContextRelease(cg);
    return any;
}

// Adds an image for buf, clipped to the OSD.
static void emit(struct ct_text *ct, const struct ct_text_frame *f, uint8_t *buf,
                 const struct canvas *c, int dx, int dy, uint32_t color, int type)
{
    int x0 = c->x + dx, y0 = c->y + dy;
    int sx = x0 < 0 ? -x0 : 0, sy = y0 < 0 ? -y0 : 0;
    int w = c->w - sx, h = c->h - sy;
    if (x0 + sx + w > f->w)
        w = f->w - x0 - sx;
    if (y0 + sy + h > f->h)
        h = f->h - y0 - sy;
    if (w <= 0 || h <= 0 || (color & 0xFF) == 0xFF)
        return;
    struct ct_image *img = add_image(ct);
    if (!img)
        return;
    *img = (struct ct_image){
        .w = w, .h = h, .stride = c->stride,
        .bitmap = buf + (size_t)sy * c->stride + sx,
        .color = color, .dst_x = x0 + sx, .dst_y = y0 + sy, .type = type,
    };
}

struct mask {
    uint8_t *buf;
    uint32_t color;
};

// Distinct values of a run attribute over the block, at most `max`.
static int run_colors(const struct block *b, CFStringRef key, uint32_t *out, int max)
{
    int n = 0;
    for (int i = 0; i < b->n_lines; i++) {
        CFArrayRef runs = CTLineGetGlyphRuns(b->lines[i].line);
        for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
            uint32_t c = get_u32(CTRunGetAttributes(CFArrayGetValueAtIndex(runs, r)), key);
            bool seen = false;
            for (int k = 0; k < n; k++)
                seen |= out[k] == c;
            if (!seen && n < max)
                out[n++] = c;
        }
    }
    return n;
}

#define MAX_COLORS 8

static bool render_block(struct ct_text *ct, const struct ct_text_frame *f,
                         const struct ct_text_style *st, const struct block *b)
{
    if (!b->n_lines || b->w <= 0)
        return true;
    double pad = st->outline_w + st->box_padding + 3 * (st->blur + st->shadow_blur) +
                 st->size * 0.25 + 2;
    struct canvas c;
    c.x = (int)floor(b->x - pad);
    c.y = (int)floor(b->y - pad);
    c.w = (int)ceil(b->x + b->w + pad) - c.x;
    c.h = (int)ceil(b->y + b->h + pad) - c.y;
    c.stride = (c.w + 15) & ~15;
    c.ox = b->x - c.x;
    c.oy = b->y - c.y;
    size_t size = (size_t)c.stride * c.h;
    bool box = st->border_style == 3 || st->border_style == 4;

    struct mask body[MAX_COLORS], outline[MAX_COLORS + 1];
    int n_body = 0, n_outline = 0;

    bool own_box = st->has_box;
    if (st->border_style == 4 || own_box) {
        // One box around the event, under everything: the back color with
        // the outline size as padding (libass background-box), or `box`.
        double padb = own_box ? st->box_padding : st->outline_w;
        uint8_t *buf = alloc_buf(ct, size);
        if (!buf)
            return false;
        CGContextRef cg = CGBitmapContextCreate(buf, c.w, c.h, 8, c.stride, NULL,
                                                (CGBitmapInfo)kCGImageAlphaOnly);
        if (cg) {
            CGContextSetRGBFillColor(cg, 0, 0, 0, 1);
            CGContextFillRect(cg, CGRectMake(c.ox - padb, c.h - c.oy - b->h - padb,
                                             b->w + 2 * padb, b->h + 2 * padb));
            CGContextRelease(cg);
        }
        emit(ct, f, buf, &c, 0, 0, own_box ? st->box : st->back, 2);
    }

    uint32_t colors[MAX_COLORS];
    if (st->outline_w > 0 && st->border_style != 4) {
        int nc = box ? 1 : run_colors(b, kOutline, colors, MAX_COLORS);
        if (box)
            colors[0] = st->outline;
        for (int i = 0; i < nc; i++) {
            uint8_t *buf = alloc_buf(ct, size);
            if (!buf)
                return false;
            if (draw_mask(buf, &c, b, L_OUTLINE, colors[i], st))
                outline[n_outline++] = (struct mask){buf, colors[i]};
        }
    }
    int nc = run_colors(b, kPrimary, colors, MAX_COLORS);
    for (int i = 0; i < nc; i++) {
        uint8_t *buf = alloc_buf(ct, size);
        if (!buf)
            return false;
        if (draw_mask(buf, &c, b, L_BODY, colors[i], st))
            body[n_body++] = (struct mask){buf, colors[i]};
    }

    // libass blurs the outline, or the body when there is none.
    int r = (int)lround(st->blur);
    struct mask *blurred = n_outline ? outline : body;
    int n_blurred = n_outline ? n_outline : n_body;
    for (int i = 0; r > 0 && i < n_blurred; i++)
        box_blur(blurred[i].buf, c.w, c.h, c.stride, r);

    // Shadow: the outline (or body) shape, offset, in the back color.
    int dx = (int)lround(st->shadow_x), dy = (int)lround(st->shadow_y);
    if ((dx || dy) && st->border_style != 4) {
        uint32_t back = box ? st->back : 0;
        for (int i = 0; i < n_blurred; i++) {
            uint8_t *src = blurred[i].buf;
            int sr = (int)lround(st->shadow_blur);
            if (sr > 0) {
                uint8_t *copy = alloc_buf(ct, size);
                if (!copy)
                    return false;
                memcpy(copy, src, size);
                box_blur(copy, c.w, c.h, c.stride, sr);
                src = copy;
            }
            if (!box) {
                // The back color of the first run with this outline color.
                back = st->back;
                for (int l = 0; l < b->n_lines && back == st->back; l++) {
                    CFArrayRef runs = CTLineGetGlyphRuns(b->lines[l].line);
                    for (CFIndex k = 0; k < CFArrayGetCount(runs); k++) {
                        CFDictionaryRef a = CTRunGetAttributes(CFArrayGetValueAtIndex(runs, k));
                        if (get_u32(a, n_outline ? kOutline : kPrimary) == blurred[i].color) {
                            back = get_u32(a, kBack);
                            break;
                        }
                    }
                }
            }
            emit(ct, f, src, &c, dx, dy, back, 2);
        }
    }
    for (int i = 0; i < n_outline; i++)
        emit(ct, f, outline[i].buf, &c, 0, 0, outline[i].color, 1);
    for (int i = 0; i < n_body; i++)
        emit(ct, f, body[i].buf, &c, 0, 0, body[i].color, 0);
    return true;
}

bool ct_text_render(struct ct_text *ct, const struct ct_text_frame *f,
                    const struct ct_text_style *st, const char *const *events,
                    int n, const struct ct_image **out, int *n_out, int *changed)
{
    uint64_t h = 0xcbf29ce484222325ULL;
    h = fnv(h, f, sizeof(*f));
    struct ct_text_style key = *st;
    key.font = key.cjk_font = NULL;
    h = fnv(h, &key, sizeof(key));
    h = fnv_str(h, st->font);
    h = fnv_str(h, st->cjk_font);
    for (int i = 0; i < n; i++)
        h = fnv_str(h, events[i]);
    if (ct->valid && h == ct->hash) {
        *out = ct->images;
        *n_out = ct->n_images;
        *changed = 0;
        return true;
    }

    struct block *blocks = n ? calloc(n, sizeof(*blocks)) : NULL;
    if (n && !blocks)
        return false;
    bool ok = true;
    for (int i = 0; ok && i < n; i++) {
        struct event_layout e = {0};
        ok = parse_event(events[i], st, f, &e) && layout_event(&blocks[i], &e, st, f);
        free_layout(&e);
    }
    if (ok) {
        clear_output(ct);
        place_blocks(blocks, n, f);
        for (int i = 0; ok && i < n; i++)
            ok = render_block(ct, f, st, &blocks[i]);
        if (!ok)
            clear_output(ct);
    }
    for (int i = 0; i < n; i++)
        free_block(&blocks[i]);
    free(blocks);
    if (!ok) {
        ct->valid = false;
        return false;
    }
    ct->hash = h;
    ct->valid = true;
    *out = ct->images;
    *n_out = ct->n_images;
    *changed = 2;
    return true;
}
