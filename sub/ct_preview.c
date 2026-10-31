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

#include <stdlib.h>
#include <string.h>

#include "mpv/quasar_subtitle.h"
#include "common/msg.h"
#include "mpv_talloc.h"
#include "options/m_option.h"
#include "ct_mp.h"

// sub_style_conf's entry for a style option name, aliases resolved.
static const m_option_t *style_option(const char *name)
{
    for (int depth = 0; depth < 4; depth++) {
        const m_option_t *found = NULL;
        for (const m_option_t *o = sub_style_conf.opts; o->name; o++) {
            if (!strcmp(o->name, name))
                found = o;
        }
        if (!found || found->type != &m_option_type_alias)
            return found;
        name = found->priv;
    }
    return NULL;
}

int mpv_quasar_subtitle_preview(const char *const *options, const char *text,
                                int w, int h, unsigned char *bgra, int stride)
{
    if (!text || w <= 0 || h <= 0 || !bgra || stride < w * 4)
        return -1;
    // A private copy of the defaults, parsed over like the player does.
    struct osd_style_opts o = {0};
    const struct osd_style_opts *def = sub_style_conf.defaults;
    for (const m_option_t *opt = sub_style_conf.opts; opt->name; opt++) {
        if (opt->offset >= 0 && opt->type != &m_option_type_alias)
            m_option_copy(opt, (char *)&o + opt->offset, (const char *)def + opt->offset);
    }
    double font_scale = 1, line_spacing = 0, sub_pos = 100;
    for (int i = 0; options && options[i] && options[i + 1]; i += 2) {
        const char *name = options[i], *value = options[i + 1];
        if (!strcmp(name, "sub-scale"))
            font_scale = strtod(value, NULL);
        else if (!strcmp(name, "sub-line-spacing"))
            line_spacing = strtod(value, NULL);
        else if (!strcmp(name, "sub-pos"))
            sub_pos = strtod(value, NULL);
        if (strncmp(name, "sub-", 4))
            continue;
        const m_option_t *opt = style_option(name + 4);
        if (opt)
            m_option_parse(mp_null_log, opt, bstr0(name), bstr0(value), (char *)&o + opt->offset);
    }
    struct ct_text_style st;
    struct ct_text_frame f;
    ct_mp_params(&o, (struct mp_osd_res){.w = w, .h = h, .display_par = 1}, font_scale,
                 line_spacing, sub_pos, o.color, 0, &st, &f);
    struct ct_text *ct = ct_text_create();
    const struct ct_image *img = NULL;
    int n = 0, changed;
    bool ok = ct && ct_text_render(ct, &f, &st, &text, 1, &img, &n, &changed);
    // Premultiplied source-over, in sRGB like the subtitle layer.
    for (int i = 0; ok && i < n; i++) {
        uint32_t c = img[i].color;
        unsigned a = 255 - (c & 0xFF);
        unsigned r = c >> 24, g = (c >> 16) & 0xFF, b = (c >> 8) & 0xFF;
        for (int y = 0; y < img[i].h; y++) {
            const uint8_t *src = img[i].bitmap + (size_t)y * img[i].stride;
            uint8_t *dst = bgra + (size_t)(img[i].dst_y + y) * stride + img[i].dst_x * 4;
            for (int x = 0; x < img[i].w; x++, dst += 4) {
                unsigned k = src[x] * a / 255;
                if (!k)
                    continue;
                unsigned inv = 255 - k;
                dst[0] = (b * k + dst[0] * inv) / 255;
                dst[1] = (g * k + dst[1] * inv) / 255;
                dst[2] = (r * k + dst[2] * inv) / 255;
                dst[3] = k + dst[3] * inv / 255;
            }
        }
    }
    ct_text_destroy(ct);
    for (const m_option_t *opt = sub_style_conf.opts; opt->name; opt++) {
        if (opt->offset >= 0 && opt->type != &m_option_type_alias)
            m_option_free(opt, (char *)&o + opt->offset);
    }
    return ok ? 0 : -2;
}
