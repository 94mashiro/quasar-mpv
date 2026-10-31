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

// Subtitle layer OSD size. No mpv dependencies: quasar-app's
// iosApp/tool/osdsize host test compiles it on its own.

#pragma once

#include <math.h>
#include <stdbool.h>

// libass layout cost grows with the OSD area; past this short edge (an
// external 4K screen) Core Animation scales the drawable up instead.
#define AVF_LAYER_OSD_MAX_SHORT 1620.0

// The video rect inside a layer_w x layer_h pixel layer (aspect fit, square
// pixels), so libass rasterizes at screen resolution. The size keeps the
// video's display aspect, so contentsGravity maps it onto the video rect like
// the frame-sized buffer before. The short edge is capped at
// AVF_LAYER_OSD_MAX_SHORT. Returns false when a size is unknown.
static inline bool avf_layer_osd_size(int layer_w, int layer_h, int frame_w,
                                      int frame_h, int p_w, int p_h,
                                      int *out_w, int *out_h)
{
    if (layer_w <= 0 || layer_h <= 0 || frame_w <= 0 || frame_h <= 0)
        return false;
    double vw = frame_w * (p_w > 0 && p_h > 0 ? p_w / (double)p_h : 1.0);
    double vh = frame_h;
    double aspect = vw / vh;
    double w = layer_w, h = layer_h;
    if (w / h > aspect)
        w = h * aspect;
    else
        h = w / aspect;
    double s = fmin(1.0, AVF_LAYER_OSD_MAX_SHORT / fmin(w, h));
    *out_w = (int)fmax(2, lround(w * s));
    *out_h = (int)fmax(2, lround(h * s));
    return true;
}
