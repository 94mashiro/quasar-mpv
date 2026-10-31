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
 */

// Plain-text subtitles (SRT, WebVTT, mov_text after mpv's ASS conversion)
// laid out and rasterized with CoreText instead of libass: system fonts
// (PingFang, SF) and CoreText's font fallback, CJK-Latin spacing, and the
// same output as libass (A8 masks: shadow, outline, body), so every OSD
// consumer works unchanged. Events with ASS typesetting tags are left to
// libass. No mpv or libass dependencies: quasar-app compiles it for the
// subtitle style preview, and its iosApp/tool/cttext host test on its own.

#pragma once

#include <stdbool.h>
#include <stdint.h>

// One A8 mask in OSD pixels, like libass's ASS_Image.
struct ct_image {
    int w, h, stride;
    const uint8_t *bitmap;
    uint32_t color;         // RGBA, A = transparency
    int dst_x, dst_y;
    int type;               // 0 body, 1 outline, 2 shadow or box
};

struct ct_text_style {
    // Family name. NULL, "", "sans-serif" or "system-ui": the system font.
    const char *font;
    // Family for CJK text; NULL or "": the font's own fallback.
    const char *cjk_font;
    float size;             // px, libass convention: the font's ascent + descent
    bool bold, italic;
    uint32_t primary, outline, back;    // libass RGBA, A = transparency
    float outline_w;        // px
    float shadow_x, shadow_y;           // px
    float blur;             // px, blurs the outline (or body) and its shadow
    float shadow_blur;      // px, extra blur for the shadow only
    int border_style;       // 1 outline and shadow, 3 box per line, 4 one box
    float spacing;          // px between letters
    float line_spacing;     // px between lines
    int align;              // ASS \an 1-9
    bool has_box;           // a box behind each event, in `box`
    uint32_t box;
    float box_padding;      // px
};

struct ct_text_frame {
    int w, h;               // OSD size
    int ml, mt, mr, mb;     // video rect margins inside it
    int margin_l, margin_r, margin_v;   // px
    float line_position;    // 0-100, as ass_set_line_position()
    int justify;            // 0 auto, 1 left, 2 center, 3 right
    float tag_scale;        // px per script unit, for \fs
};

struct ct_text;

struct ct_text *ct_text_create(void);
void ct_text_destroy(struct ct_text *ct);

// Lays out and rasterizes the events, in order (the first sits lowest in
// its alignment group). Returns false when an event uses tags this renderer
// does not handle; the caller renders the frame with libass. *changed as for
// ass_render_frame(). The images stay valid until the next call that
// changes them or ct_text_destroy(); *out is an array of *n_out, painted
// in order.
bool ct_text_render(struct ct_text *ct, const struct ct_text_frame *f,
                    const struct ct_text_style *st, const char *const *events,
                    int n, const struct ct_image **out, int *n_out, int *changed);
