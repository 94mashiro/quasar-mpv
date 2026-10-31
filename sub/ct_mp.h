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

#pragma once

#include <math.h>

#include "ass_mp.h"
#include "ct_text.h"
#include "osd.h"

// --sub-* style options to CoreText renderer parameters, with libass's sizes
// for converted text (mp_ass_set_style(), configure_ass()): style values are
// in 720-line pixels of the video rect, times libass's font scale. Shared by
// playback (sd_ass.c) and the style preview (ct_preview.c).
static inline void ct_mp_params(const struct osd_style_opts *o, struct mp_osd_res dim,
                                double font_scale, double line_spacing, double sub_pos,
                                struct m_color color, double playres_y,
                                struct ct_text_style *st, struct ct_text_frame *f)
{
    double vid_w = dim.w - dim.ml - dim.mr, vid_h = dim.h - dim.mt - dim.mb;
    double u = vid_h / 720.0 * font_scale;
    bool xy = o->shadow_offset_x || o->shadow_offset_y;
    *st = (struct ct_text_style){
        .font = o->font,
        .cjk_font = o->cjk_font,
        .size = o->font_size * u,
        .bold = o->bold,
        .italic = o->italic,
        .primary = MP_ASS_COLOR(color),
        .outline = MP_ASS_COLOR(o->outline_color),
        .back = MP_ASS_COLOR(o->back_color),
        .outline_w = o->outline_size * u,
        .shadow_x = (xy ? o->shadow_offset_x : o->shadow_offset) * u,
        .shadow_y = (xy ? o->shadow_offset_y : o->shadow_offset) * u,
        .blur = o->blur * u,
        .shadow_blur = o->shadow_blur * u,
        .border_style = o->border_style,
        .spacing = o->spacing * u,
        .line_spacing = line_spacing,
        .align = o->align_x + 2 + (1 - o->align_y) * 3,    // \an numpad
        .has_box = o->box_color.a > 0,
        .box = MP_ASS_COLOR(o->box_color),
        .box_padding = o->font_size * u * 0.2,
    };
    *f = (struct ct_text_frame){
        .w = dim.w, .h = dim.h,
        .ml = dim.ml, .mt = dim.mt, .mr = dim.mr, .mb = dim.mb,
        .margin_l = lrint(o->margin_x * vid_w / 960.0),
        .margin_r = lrint(o->margin_x * vid_w / 960.0),
        .margin_v = lrint(o->margin_y * u),   // font-scaled, as sd_ass.c's override_playres
        .line_position = 100.0f - sub_pos,
        .justify = o->justify,
        .tag_scale = vid_h / (playres_y > 0 ? playres_y : MP_ASS_FONT_PLAYRESY) * font_scale,
    };
}
