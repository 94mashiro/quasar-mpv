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
 * Contains code from edde746/MPVKit at b8b922ec, whose repository license at
 * that revision was LGPL-3.0, and changes by Quasar (2026). This file as a
 * whole is distributed under the GNU LGPL version 3; see
 * quasar/AVFOUNDATION_CREDITS.md.
 */

#include <IOSurface/IOSurfaceRef.h>

#include "vo_avfoundation_priv.h"
#include "avfoundation_osd_size.h"

void avf_update_avfoundation_geometry(struct vo *vo)
{
    // Host owns geometry/videoGravity. Never sync-enter main queue from VO:
    // libmpv teardown may wait here. Frame-space OSD needs no UI reads during
    // rotation, detach, or PiP resize; sample dimensions stay fixed.
    vo->dwidth = vo->params ? vo->params->w : 1;
    vo->dheight = vo->params ? vo->params->h : 1;
    vo->monitor_par = 1.0;
}

// --- avf frame-space osd core ---
// PiP sizes its window from samples. Layer-space subtitles can occupy
// --sub-use-margins letterbox space; compositing then grows samples and
// resizes PiP per cue (plezy#2078).
//
// Use coded frame grid: collapse margins, make --sub-pos relative to
// presented frame, preserve composite dimensions, and keep Core Image
// fallback frame-sized. Squeeze non-square-pixel text to cancel layer
// stretch, matching osd_res_from_image_params().
static struct avf_render_geometry avf_frame_space_geometry(int frame_w, int frame_h,
                                                          int p_w, int p_h)
{
    if (frame_w <= 0 || frame_h <= 0)
        return (struct avf_render_geometry){0};

    struct mp_rect frame = {0, 0, frame_w, frame_h};

    return (struct avf_render_geometry){
        .w = frame_w,
        .h = frame_h,
        .src = frame,
        .dst = frame,
        .osd_res = {
            .w = frame_w,
            .h = frame_h,
            .display_par = p_w > 0 && p_h > 0 ? p_h / (double)p_w : 1.0,
        },
    };
}

// Clip cached OSD bounds to video rect; map onto frame grid with one pixel
// slack per side for inverse compositing. Return false outside video:
// layer-space cue lies in letterbox margin.
static bool avf_map_subtitle_rect(struct avf_render_geometry geometry,
                                  struct mp_rect sub, int sub_w, int sub_h,
                                  int frame_w, int frame_h,
                                  struct mp_rect *out)
{
    struct mp_rect src = geometry.src;
    struct mp_rect dst = geometry.dst;
    int srcW = src.x1 - src.x0;
    int srcH = src.y1 - src.y0;
    int dstW = dst.x1 - dst.x0;
    int dstH = dst.y1 - dst.y0;
    if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0)
        return false;

    int frame_x0 = MPCLAMP(src.x0, 0, frame_w);
    int frame_y0 = MPCLAMP(src.y0, 0, frame_h);
    int frame_x1 = MPCLAMP(src.x1, 0, frame_w);
    int frame_y1 = MPCLAMP(src.y1, 0, frame_h);
    if (frame_x1 <= frame_x0 || frame_y1 <= frame_y0)
        return false;

    int osd_x0 = MPMAX(sub.x0, MPMAX(dst.x0, 0));
    int osd_y0 = MPMAX(sub.y0, MPMAX(dst.y0, 0));
    int osd_x1 = MPMIN(sub.x1, MPMIN(dst.x1, sub_w));
    int osd_y1 = MPMIN(sub.y1, MPMIN(dst.y1, sub_h));
    if (osd_x1 <= osd_x0 || osd_y1 <= osd_y0)
        return false;

    int x0 = src.x0 + (int)(((int64_t)(osd_x0 - dst.x0) * srcW) / dstW) - 1;
    int y0 = src.y0 + (int)(((int64_t)(osd_y0 - dst.y0) * srcH) / dstH) - 1;
    int x1 = src.x0 + (int)((((int64_t)(osd_x1 - dst.x0) * srcW) + dstW - 1) / dstW) + 1;
    int y1 = src.y0 + (int)((((int64_t)(osd_y1 - dst.y0) * srcH) + dstH - 1) / dstH) + 1;
    x0 = MPCLAMP(x0, frame_x0, frame_x1);
    y0 = MPCLAMP(y0, frame_y0, frame_y1);
    x1 = MPCLAMP(x1, frame_x0, frame_x1);
    y1 = MPCLAMP(y1, frame_y0, frame_y1);
    if (x1 <= x0 || y1 <= y0)
        return false;

    *out = (struct mp_rect){x0, y0, x1, y1};
    return true;
}
// --- end avf frame-space osd core ---

// Subtitle layer: screen-resolution OSD in the video rect (see
// avf_layer_osd_size). Square pixels, so display_par is 1; libass applies the
// video PAR to ASS itself, as for a window-sized OSD.
static struct avf_render_geometry avf_layer_space_geometry(struct priv *p,
                                                          int frame_w, int frame_h,
                                                          int p_w, int p_h)
{
    int ow, oh;
    if (!avf_layer_osd_size(p->render_layer_w, p->render_layer_h, frame_w, frame_h,
                            p_w, p_h, &ow, &oh))
        return (struct avf_render_geometry){0};
    return (struct avf_render_geometry){
        .w = ow,
        .h = oh,
        .src = {0, 0, frame_w, frame_h},
        .dst = {0, 0, ow, oh},
        .osd_res = {.w = ow, .h = oh, .display_par = 1.0},
    };
}

static struct avf_render_geometry compute_render_geometry(struct vo *vo,
                                                          int frame_w,
                                                          int frame_h)
{
    struct priv *p = vo->priv;
    struct mp_rect src, dst;
    struct mp_osd_res vo_osd;

    if (frame_w <= 0)
        frame_w = vo->params ? vo->params->w : 0;
    if (frame_h <= 0)
        frame_h = vo->params ? vo->params->h : 0;

    if (should_use_inline_osd_layer(p) && p->osdLayer) {
        struct avf_render_geometry g = avf_layer_space_geometry(p, frame_w, frame_h,
            vo->params ? vo->params->p_w : 1, vo->params ? vo->params->p_h : 1);
        // Before the first attach on main the size is unknown; frame space.
        if (g.w > 0)
            return g;
    }

    if (should_use_frame_space_osd(p)) {
        return avf_frame_space_geometry(frame_w, frame_h,
                                        vo->params ? vo->params->p_w : 1,
                                        vo->params ? vo->params->p_h : 1);
    }

    vo_get_src_dst_rects(vo, &src, &dst, &vo_osd);

    if (should_use_inline_osd_layer(p)) {
        return (struct avf_render_geometry){
            .w = vo_osd.w,
            .h = vo_osd.h,
            .src = src,
            .dst = dst,
            .osd_res = vo_osd,
        };
    }

    if (frame_w <= 0 || frame_h <= 0 || vo_osd.w <= 0 || vo_osd.h <= 0) {
        return (struct avf_render_geometry){0};
    }

    int params_w = vo->params ? vo->params->w : frame_w;
    int params_h = vo->params ? vo->params->h : frame_h;
    if (src.x1 <= src.x0 || src.y1 <= src.y0) {
        src = (struct mp_rect){0, 0, params_w, params_h};
    }

    return (struct avf_render_geometry){
        .w = vo_osd.w,
        .h = vo_osd.h,
        .src = src,
        .dst = dst,
        .osd_res = vo_osd,
    };
}

static void invalidate_render_geometry(struct vo *vo)
{
    struct priv *p = vo->priv;
    p->render_geometry_valid = false;
}

static void update_render_geometry(struct vo *vo, int frame_w, int frame_h)
{
    struct priv *p = vo->priv;

    if (frame_w <= 0)
        frame_w = vo->params ? vo->params->w : 0;
    if (frame_h <= 0)
        frame_h = vo->params ? vo->params->h : 0;

    avf_update_avfoundation_geometry(vo);
    p->render_geometry = compute_render_geometry(vo, frame_w, frame_h);
    p->render_geometry_inline = should_use_inline_osd_layer(p) && p->osdLayer;
    p->render_geometry_valid = true;
}

// Adopt the subtitle layer's pixel size: the first one at once, later ones
// after they held for 150 ms while playing (no relayout per frame of a
// rotation or window drag), at once when paused (one redraw per change, see
// avf_check_osd_layer_resize). Returns true when the size in use changed.
static bool adopt_layer_size(struct priv *p)
{
    int lw = 0, lh = 0;
    [p->osdLayer getPixelWidth:&lw height:&lh];
    if (lw == p->render_layer_w && lh == p->render_layer_h) {
        // Back to the size in use: drop a pending one.
        p->pending_layer_w = lw;
        p->pending_layer_h = lh;
        return false;
    }
    int64_t now = mp_time_ns();
    if (lw != p->pending_layer_w || lh != p->pending_layer_h) {
        p->pending_layer_w = lw;
        p->pending_layer_h = lh;
        p->pending_layer_since_ns = now;
    }
    if (p->render_layer_w > 0 && !p->playback_paused &&
        now - p->pending_layer_since_ns < MP_TIME_MS_TO_NS(150))
        return false;
    p->render_layer_w = lw;
    p->render_layer_h = lh;
    return true;
}

static struct avf_render_geometry get_render_geometry(struct vo *vo,
                                                      int frame_w,
                                                      int frame_h)
{
    struct priv *p = vo->priv;

    bool inline_layer = should_use_inline_osd_layer(p) && p->osdLayer;
    bool layer_resized = inline_layer && adopt_layer_size(p);
    if (!p->render_geometry_valid || layer_resized ||
        inline_layer != p->render_geometry_inline || should_apply_video_geometry(vo))
        update_render_geometry(vo, frame_w, frame_h);

    return p->render_geometry;
}

void avf_check_osd_layer_resize(struct vo *vo)
{
    struct priv *p = vo->priv;
    if (!p->playback_paused) {
        // Playing: frames adopt the size; a later paused resize asks anew.
        p->redraw_layer_w = p->redraw_layer_h = 0;
        return;
    }
    // Nothing on screen to re-lay out: the next cue renders at the new size.
    if (!p->osdLayer || p->presentation_host || !should_use_inline_osd_layer(p) ||
        !(p->has_subtitle || p->osd_frame_dropped))
        return;
    int lw = 0, lh = 0;
    [p->osdLayer getPixelWidth:&lw height:&lh];
    if (lw <= 0 || lh <= 0 || (lw == p->render_layer_w && lh == p->render_layer_h) ||
        (lw == p->redraw_layer_w && lh == p->redraw_layer_h))
        return;
    // Once per size, so a redraw that renders nothing cannot loop.
    p->redraw_layer_w = lw;
    p->redraw_layer_h = lh;
    vo->want_redraw = true;
}

// Sync OSD and display layer frames.
void avf_sync_osd_layer_frame(struct vo *vo)
{
    struct priv *p = vo->priv;
    avf_update_avfoundation_geometry(vo);
    invalidate_render_geometry(vo);
    [p->osdLayer attachToDisplayLayer:p->displayLayer];
}

static OSType ci_output_format_for_source(CVPixelBufferRef buffer)
{
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    CFTypeRef transfer = CVBufferGetAttachment(buffer, kCVImageBufferTransferFunctionKey, NULL);
    bool hdr = transfer && (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
                            CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if (hdr || format == kCVPixelFormatType_64RGBAHalf ||
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        return kCVPixelFormatType_64RGBAHalf;
    return kCVPixelFormatType_32BGRA;
}

static void get_yuv_coefficients(CVPixelBufferRef pixbuf, double *kr, double *kb)
{
    *kr = 0.2126;
    *kb = 0.0722;

    CFTypeRef matrix = CVBufferGetAttachment(pixbuf, kCVImageBufferYCbCrMatrixKey, NULL);
    if (!matrix)
        return;

    if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        *kr = 0.2627;
        *kb = 0.0593;
    } else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
        *kr = 0.299;
        *kb = 0.114;
    } else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) {
        *kr = 0.212;
        *kb = 0.087;
    }
}

static bool copy_pixel_buffer_planes(CVPixelBufferRef src, CVPixelBufferRef dst)
{
    CVReturn src_status = CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    if (src_status != kCVReturnSuccess)
        return false;

    CVReturn dst_status = CVPixelBufferLockBaseAddress(dst, 0);
    if (dst_status != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    size_t planes = CVPixelBufferGetPlaneCount(src);
    bool ok = planes == CVPixelBufferGetPlaneCount(dst);
    if (ok && planes > 0) {
        for (size_t plane = 0; plane < planes; plane++) {
            uint8_t *src_base = CVPixelBufferGetBaseAddressOfPlane(src, plane);
            uint8_t *dst_base = CVPixelBufferGetBaseAddressOfPlane(dst, plane);
            size_t src_stride = CVPixelBufferGetBytesPerRowOfPlane(src, plane);
            size_t dst_stride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane);
            size_t height = MPMIN(CVPixelBufferGetHeightOfPlane(src, plane),
                                  CVPixelBufferGetHeightOfPlane(dst, plane));
            size_t bytes = MPMIN(src_stride, dst_stride);
            if (!src_base || !dst_base) {
                ok = false;
                break;
            }
            if (src_stride == dst_stride) {
                memcpy(dst_base, src_base, bytes * height);
            } else {
                for (size_t y = 0; y < height; y++)
                    memcpy(dst_base + y * dst_stride, src_base + y * src_stride, bytes);
            }
        }
    } else if (ok) {
        uint8_t *src_base = CVPixelBufferGetBaseAddress(src);
        uint8_t *dst_base = CVPixelBufferGetBaseAddress(dst);
        size_t src_stride = CVPixelBufferGetBytesPerRow(src);
        size_t dst_stride = CVPixelBufferGetBytesPerRow(dst);
        size_t height = MPMIN(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst));
        size_t bytes = MPMIN(src_stride, dst_stride);
        ok = src_base && dst_base;
        if (ok) {
            if (src_stride == dst_stride) {
                memcpy(dst_base, src_base, bytes * height);
            } else {
                for (size_t y = 0; y < height; y++)
                    memcpy(dst_base + y * dst_stride, src_base + y * src_stride, bytes);
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return ok;
}

static int clip_u8(double value)
{
    return MPCLAMP((int)(value + 0.5), 0, 255);
}

static int clip_u10(double value)
{
    return MPCLAMP((int)(value + 0.5), 0, 1023);
}

// Union destination rects, clipped to OSD buffer. Both draw paths stay
// inside; bounds cover nonblank pixels without scanning.
static void update_subtitle_bounds_from_parts(struct priv *p,
                                              struct sub_bitmaps *imgs)
{
    p->subtitle_x0 = p->osd_w;
    p->subtitle_y0 = p->osd_h;
    p->subtitle_x1 = 0;
    p->subtitle_y1 = 0;

    if (!imgs || p->osd_w <= 0 || p->osd_h <= 0)
        return;

    for (int i = 0; i < imgs->num_parts; i++) {
        struct sub_bitmap *sb = &imgs->parts[i];
        if (!sb->bitmap || sb->w <= 0 || sb->h <= 0)
            continue;
        int dw = sb->dw > 0 ? sb->dw : sb->w;
        int dh = sb->dh > 0 ? sb->dh : sb->h;
        p->subtitle_x0 = MPMIN(p->subtitle_x0, MPCLAMP(sb->x, 0, p->osd_w));
        p->subtitle_y0 = MPMIN(p->subtitle_y0, MPCLAMP(sb->y, 0, p->osd_h));
        p->subtitle_x1 = MPMAX(p->subtitle_x1, MPCLAMP(sb->x + dw, 0, p->osd_w));
        p->subtitle_y1 = MPMAX(p->subtitle_y1, MPCLAMP(sb->y + dh, 0, p->osd_h));
    }
}

void avf_reset_osd_buf_states(struct priv *p)
{
    for (int i = 0; i < p->osd_buf_state_count; i++) {
        if (p->osd_buf_states[i].surf)
            CFRelease(p->osd_buf_states[i].surf);
    }
    p->osd_buf_state_count = 0;
}

// Expire IOSurface entries soon after pool lifetime; avoid retaining aged-out
// buffers.
void avf_prune_osd_buf_states(struct priv *p, int64_t now)
{
    for (int i = 0; i < p->osd_buf_state_count;) {
        if (now - p->osd_buf_states[i].last_used_ns > MP_TIME_MS_TO_NS(2000)) {
            CFRelease(p->osd_buf_states[i].surf);
            p->osd_buf_states[i] = p->osd_buf_states[--p->osd_buf_state_count];
        } else {
            i++;
        }
    }
}

static struct osd_buf_state *osd_buf_state_acquire(struct priv *p,
                                                   CVPixelBufferRef buf)
{
    IOSurfaceRef surf = buf ? CVPixelBufferGetIOSurface(buf) : NULL;
    if (!surf)
        return NULL;

    int64_t now = mp_time_ns();
    struct osd_buf_state *oldest = NULL;
    for (int i = 0; i < p->osd_buf_state_count; i++) {
        struct osd_buf_state *st = &p->osd_buf_states[i];
        if (st->surf == surf) {
            st->last_used_ns = now;
            return st;
        }
        if (!oldest || st->last_used_ns < oldest->last_used_ns)
            oldest = st;
    }

    struct osd_buf_state *st;
    if (p->osd_buf_state_count < (int)MP_ARRAY_SIZE(p->osd_buf_states)) {
        st = &p->osd_buf_states[p->osd_buf_state_count++];
    } else {
        st = oldest;
        CFRelease(st->surf);
    }
    *st = (struct osd_buf_state){
        .surf = (IOSurfaceRef)CFRetain(surf),
        // First write: unknown contents, clear fully.
        .dirty = {0, 0, INT_MAX, INT_MAX},
        .last_used_ns = now,
    };
    return st;
}

static void osd_buf_record_dirty(struct priv *p, CVPixelBufferRef buf,
                                 struct mp_rect dirty)
{
    IOSurfaceRef surf = buf ? CVPixelBufferGetIOSurface(buf) : NULL;
    if (!surf)
        return;
    for (int i = 0; i < p->osd_buf_state_count; i++) {
        if (p->osd_buf_states[i].surf == surf) {
            p->osd_buf_states[i].dirty = dirty;
            return;
        }
    }
}

static bool create_osd_pool(struct vo *vo, int w, int h)
{
    struct priv *p = vo->priv;
    // Pool replacement discards buffers and dirty state.
    if (p->osdPool && (p->osd_pool_w != w || p->osd_pool_h != h))
        avf_reset_osd_buf_states(p);
    return avf_create_pixel_buffer_pool(vo, &p->osdPool, &p->osd_pool_w,
        &p->osd_pool_h, NULL, w, h, kCVPixelFormatType_32BGRA, "OSD overlay");
}

// Upload kernels fuse planar interleave and 10/12-bit MSB alignment into
// required biplanar copy. No extra conversion pass.

static void draw_subtitle_bitmaps(CGContextRef context, struct sub_bitmaps *imgs,
                                  int h)
{
    CGColorSpaceRef partColorSpace = (imgs->format == SUBBITMAP_BGRA)
        ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB) : NULL;

    for (int i = 0; i < imgs->num_parts; i++) {
        struct sub_bitmap *sb = &imgs->parts[i];

        if (!sb->bitmap || sb->w <= 0 || sb->h <= 0)
            continue;

        CGDataProviderRef provider = CGDataProviderCreateWithData(
            NULL, sb->bitmap, sb->stride * sb->h, NULL);

        if (!provider)
            continue;

        if (imgs->format == SUBBITMAP_BGRA) {
            CGImageRef partImage = CGImageCreate(
                sb->w, sb->h, 8, 32, sb->stride, partColorSpace,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                provider, NULL, false, kCGRenderingIntentDefault);

            if (partImage) {
                CGRect destRect = CGRectMake(sb->x, h - sb->y - sb->dh, sb->dw, sb->dh);
                CGContextDrawImage(context, destRect, partImage);
                CGImageRelease(partImage);
            }
        } else if (imgs->format == SUBBITMAP_LIBASS) {
            // Invert mask: libass 255=opaque; CGImageMask 0=paint.
            CGFloat decode[] = {1, 0};
            CGImageRef mask = CGImageMaskCreate(
                sb->w, sb->h, 8, 8, sb->stride, provider, decode, false);

            if (mask) {
                CGContextSaveGState(context);
                CGRect destRect = CGRectMake(sb->x, h - sb->y - sb->dh, sb->dw, sb->dh);
                CGContextClipToMask(context, destRect, mask);

                uint32_t c = sb->libass.color;
                float r = ((c >> 24) & 0xFF) / 255.0f;
                float g = ((c >> 16) & 0xFF) / 255.0f;
                float b = ((c >> 8) & 0xFF) / 255.0f;
                float a = 1.0f - ((c >> 0) & 0xFF) / 255.0f;

                CGContextSetRGBFillColor(context, r, g, b, a);
                CGContextFillRect(context, destRect);
                CGContextRestoreGState(context);
                CGImageRelease(mask);
            }
        }

        CGDataProviderRelease(provider);
    }

    if (partColorSpace)
        CGColorSpaceRelease(partColorSpace);
}

static int get_direct_osd_draw_path(struct sub_bitmaps *imgs)
{
    if (!imgs || imgs->num_parts <= 0)
        return AVF_OSD_DRAW_NONE;

    int path = AVF_OSD_DRAW_NONE;
    if (imgs->format == SUBBITMAP_LIBASS) {
        path = AVF_OSD_DRAW_DIRECT_LIBASS;
    } else if (imgs->format == SUBBITMAP_BGRA) {
        path = AVF_OSD_DRAW_DIRECT_BGRA;
    } else {
        return AVF_OSD_DRAW_NONE;
    }

    for (int i = 0; i < imgs->num_parts; i++) {
        struct sub_bitmap *sb = &imgs->parts[i];
        if (!sb->bitmap || sb->w <= 0 || sb->h <= 0)
            continue;

        int dw = sb->dw > 0 ? sb->dw : sb->w;
        int dh = sb->dh > 0 ? sb->dh : sb->h;
        if (dw != sb->w || dh != sb->h)
            return AVF_OSD_DRAW_COREGRAPHICS;
    }

    return path;
}

static void blend_libass_bgra_scalar(uint8_t *dst, size_t dst_stride,
                                     uint8_t *src, int src_stride,
                                     int w, int h, uint32_t color)
{
    const unsigned int r = (color >> 24) & 0xff;
    const unsigned int g = (color >> 16) & 0xff;
    const unsigned int b = (color >>  8) & 0xff;
    const unsigned int a = 0xff - (color & 0xff);

    if (!a)
        return;

    for (int y = 0; y < h; y++) {
        uint32_t *dstrow = (uint32_t *)dst;
        for (int x = 0; x < w; x++) {
            const unsigned int v = src[x];
            if (!v)
                continue;

            unsigned int aa = a * v;
            unsigned int inv = 255 * 255 - aa;
            uint32_t dstpix = dstrow[x];
            unsigned int dstb =  dstpix        & 0xff;
            unsigned int dstg = (dstpix >>  8) & 0xff;
            unsigned int dstr = (dstpix >> 16) & 0xff;
            unsigned int dsta = (dstpix >> 24) & 0xff;

            dstb = (v * b * a + dstb * inv + 32512) / (255 * 255);
            dstg = (v * g * a + dstg * inv + 32512) / (255 * 255);
            dstr = (v * r * a + dstr * inv + 32512) / (255 * 255);
            dsta = (aa * 255 + dsta * inv + 32512) / (255 * 255);
            dstrow[x] = dstb | (dstg << 8) | (dstr << 16) | (dsta << 24);
        }
        dst += dst_stride;
        src += src_stride;
    }
}

static void blend_bgra_over_bgra_scalar(uint8_t *dst, size_t dst_stride,
                                        uint8_t *src, int src_stride,
                                        int w, int h)
{
    for (int y = 0; y < h; y++) {
        uint32_t *srcrow = (uint32_t *)src;
        uint32_t *dstrow = (uint32_t *)dst;
        for (int x = 0; x < w; x++) {
            uint32_t srcpix = srcrow[x];
            unsigned int srca = (srcpix >> 24) & 0xff;
            if (!srca)
                continue;
            if (srca == 0xff || !dstrow[x]) {
                dstrow[x] = srcpix;
                continue;
            }

            uint32_t dstpix = dstrow[x];
            unsigned int inv = 0xff - srca;
            unsigned int srcb =  srcpix        & 0xff;
            unsigned int srcg = (srcpix >>  8) & 0xff;
            unsigned int srcr = (srcpix >> 16) & 0xff;
            unsigned int dstb =  dstpix        & 0xff;
            unsigned int dstg = (dstpix >>  8) & 0xff;
            unsigned int dstr = (dstpix >> 16) & 0xff;
            unsigned int dsta = (dstpix >> 24) & 0xff;

            dstb = MPMIN(0xff, srcb + (dstb * inv + 127) / 255);
            dstg = MPMIN(0xff, srcg + (dstg * inv + 127) / 255);
            dstr = MPMIN(0xff, srcr + (dstr * inv + 127) / 255);
            dsta = MPMIN(0xff, srca + (dsta * inv + 127) / 255);
            dstrow[x] = dstb | (dstg << 8) | (dstr << 16) | (dsta << 24);
        }
        dst += dst_stride;
        src += src_stride;
    }
}

#if defined(__aarch64__)

// Bit-exact NEON blends: fold divisions into floor-by-255 stages.
// floor(x/65025) == floor(floor(x/255)/255).

// Exact u16 floor(x/255).
static inline uint16x8_t div255_u16_neon(uint16x8_t x)
{
    return vshrq_n_u16(
        vaddq_u16(vaddq_u16(x, vdupq_n_u16(1)), vshrq_n_u16(x, 8)), 8);
}

// Exact u32 floor(x/255), magic-multiply, narrowed to u16. Numerators <2^24;
// result fits.
static inline uint16x4_t div255_u32_to_u16_neon(uint32x4_t x)
{
    const uint32x2_t magic = vdup_n_u32(0x80808081u);
    uint64x2_t lo = vmull_u32(vget_low_u32(x), magic);
    uint64x2_t hi = vmull_u32(vget_high_u32(x), magic);
    uint32x2_t l = vmovn_u64(vshrq_n_u64(lo, 39));
    uint32x2_t h = vmovn_u64(vshrq_n_u64(hi, 39));
    return vmovn_u32(vcombine_u32(l, h));
}

// libass channel blend: (aa*c + inv*dst + 32512) / 65025.
static inline uint8x8_t blend_libass_channel_neon(uint16x8_t aa, uint16x8_t inv,
                                                  uint8_t c, uint8x8_t dst)
{
    uint16x8_t d16 = vmovl_u8(dst);
    uint32x4_t lo = vmull_n_u16(vget_low_u16(aa), c);
    uint32x4_t hi = vmull_n_u16(vget_high_u16(aa), c);
    lo = vmlal_u16(lo, vget_low_u16(inv), vget_low_u16(d16));
    hi = vmlal_u16(hi, vget_high_u16(inv), vget_high_u16(d16));
    lo = vaddq_u32(lo, vdupq_n_u32(32512));
    hi = vaddq_u32(hi, vdupq_n_u32(32512));
    uint16x8_t y = vcombine_u16(div255_u32_to_u16_neon(lo),
                                div255_u32_to_u16_neon(hi));
    return vmovn_u16(div255_u16_neon(y));
}

// Require w % 8 == 0; scalar tail. Zero mask yields dst exactly: (dst*65025 +
// 32512)/65025 == dst. No lane select; vmaxv skip only optimizes.
static void blend_libass_bgra_neon(uint8_t *dst, size_t dst_stride,
                                   uint8_t *src, int src_stride,
                                   int w, int h, uint32_t color)
{
    const uint8_t r = (color >> 24) & 0xff;
    const uint8_t g = (color >> 16) & 0xff;
    const uint8_t b = (color >>  8) & 0xff;
    const uint8_t a = 0xff - (color & 0xff);
    const uint8x8_t va = vdup_n_u8(a);
    const uint16x8_t full = vdupq_n_u16(255 * 255);

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x += 8) {
            uint8x8_t m = vld1_u8(src + x);
            if (!vmaxv_u8(m))
                continue;

            uint16x8_t aa = vmull_u8(m, va);
            uint16x8_t inv = vsubq_u16(full, aa);
            uint8x8x4_t d = vld4_u8(dst + (size_t)x * 4);
            d.val[0] = blend_libass_channel_neon(aa, inv, b, d.val[0]);
            d.val[1] = blend_libass_channel_neon(aa, inv, g, d.val[1]);
            d.val[2] = blend_libass_channel_neon(aa, inv, r, d.val[2]);
            d.val[3] = blend_libass_channel_neon(aa, inv, 255, d.val[3]);
            vst4_u8(dst + (size_t)x * 4, d);
        }
        dst += dst_stride;
        src += src_stride;
    }
}

// Src-over channel: min(0xff, src + (dst*inv + 127)/255). Matches scalar
// srca==0xff/dst==0 shortcuts. Caller preserves dst only for srca==0 lanes.
static inline uint8x8_t blend_over_channel_neon(uint8x8_t srcc, uint8x8_t dstc,
                                                uint8x8_t inv)
{
    uint16x8_t t = vaddq_u16(vmull_u8(dstc, inv), vdupq_n_u16(127));
    return vqadd_u8(srcc, vmovn_u16(div255_u16_neon(t)));
}

// Require w % 8 == 0; scalar tail.
static void blend_bgra_over_bgra_neon(uint8_t *dst, size_t dst_stride,
                                      uint8_t *src, int src_stride,
                                      int w, int h)
{
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x += 8) {
            uint8x8x4_t s = vld4_u8(src + (size_t)x * 4);
            if (!vmaxv_u8(s.val[3]))
                continue;

            uint8x8x4_t d = vld4_u8(dst + (size_t)x * 4);
            uint8x8_t inv = vmvn_u8(s.val[3]);
            uint8x8_t keep = vceqz_u8(s.val[3]);
            for (int c = 0; c < 4; c++) {
                d.val[c] = vbsl_u8(keep, d.val[c],
                    blend_over_channel_neon(s.val[c], d.val[c], inv));
            }
            vst4_u8(dst + (size_t)x * 4, d);
        }
        dst += dst_stride;
        src += src_stride;
    }
}

#endif // __aarch64__

static void blend_libass_bgra(uint8_t *dst, size_t dst_stride,
                              uint8_t *src, int src_stride,
                              int w, int h, uint32_t color)
{
    if (!(0xff - (color & 0xff)))
        return;
#if defined(__aarch64__)
    int w8 = w & ~7;
    if (w8 > 0)
        blend_libass_bgra_neon(dst, dst_stride, src, src_stride, w8, h, color);
    if (w > w8)
        blend_libass_bgra_scalar(dst + (size_t)w8 * 4, dst_stride,
                                 src + w8, src_stride, w - w8, h, color);
#else
    blend_libass_bgra_scalar(dst, dst_stride, src, src_stride, w, h, color);
#endif
}

static void blend_bgra_over_bgra(uint8_t *dst, size_t dst_stride,
                                 uint8_t *src, int src_stride,
                                 int w, int h)
{
#if defined(__aarch64__)
    int w8 = w & ~7;
    if (w8 > 0)
        blend_bgra_over_bgra_neon(dst, dst_stride, src, src_stride, w8, h);
    if (w > w8)
        blend_bgra_over_bgra_scalar(dst + (size_t)w8 * 4, dst_stride,
                                    src + (size_t)w8 * 4, src_stride,
                                    w - w8, h);
#else
    blend_bgra_over_bgra_scalar(dst, dst_stride, src, src_stride, w, h);
#endif
}

static void draw_direct_libass_bitmap(uint8_t *base, size_t stride,
                                      int w, int h, struct sub_bitmap *sb)
{
    int x0 = MPCLAMP(sb->x, 0, w);
    int y0 = MPCLAMP(sb->y, 0, h);
    int x1 = MPCLAMP(sb->x + sb->w, 0, w);
    int y1 = MPCLAMP(sb->y + sb->h, 0, h);
    int draw_w = x1 - x0;
    int draw_h = y1 - y0;
    if (draw_w <= 0 || draw_h <= 0)
        return;

    uint8_t *dst = base + (size_t)y0 * stride + (size_t)x0 * 4;
    uint8_t *src = (uint8_t *)sb->bitmap + (y0 - sb->y) * sb->stride + (x0 - sb->x);
    blend_libass_bgra(dst, stride, src, sb->stride, draw_w, draw_h, sb->libass.color);
}

static void draw_direct_bgra_bitmap(uint8_t *base, size_t stride,
                                    int w, int h, struct sub_bitmap *sb)
{
    int dw = sb->dw > 0 ? sb->dw : sb->w;
    int dh = sb->dh > 0 ? sb->dh : sb->h;
    int x0 = MPCLAMP(sb->x, 0, w);
    int y0 = MPCLAMP(sb->y, 0, h);
    int x1 = MPCLAMP(sb->x + dw, 0, w);
    int y1 = MPCLAMP(sb->y + dh, 0, h);
    int draw_w = x1 - x0;
    int draw_h = y1 - y0;
    if (draw_w <= 0 || draw_h <= 0)
        return;

    uint8_t *dst = base + (size_t)y0 * stride + (size_t)x0 * 4;
    uint8_t *src = (uint8_t *)sb->bitmap + (y0 - sb->y) * sb->stride + (size_t)(x0 - sb->x) * 4;
    blend_bgra_over_bgra(dst, stride, src, sb->stride, draw_w, draw_h);
}

static bool draw_subtitle_bitmaps_direct(struct priv *p, uint8_t *base,
                                         size_t stride, int w, int h,
                                         struct sub_bitmaps *imgs)
{
    int path = get_direct_osd_draw_path(imgs);
    if (path != AVF_OSD_DRAW_DIRECT_LIBASS && path != AVF_OSD_DRAW_DIRECT_BGRA)
        return false;

    for (int i = 0; i < imgs->num_parts; i++) {
        struct sub_bitmap *sb = &imgs->parts[i];
        if (!sb->bitmap || sb->w <= 0 || sb->h <= 0)
            continue;
        if (path == AVF_OSD_DRAW_DIRECT_LIBASS)
            draw_direct_libass_bitmap(base, stride, w, h, sb);
        else
            draw_direct_bgra_bitmap(base, stride, w, h, sb);
    }

    return true;
}

// Render subtitle CGImage for compositing.
static CGImageRef render_subtitle_image(struct vo *vo, struct sub_bitmaps *imgs)
{
    struct priv *p = vo->priv;

    if (!imgs || imgs->num_parts == 0)
        return NULL;

    int w = p->osd_w;
    int h = p->osd_h;

    if (w <= 0 || h <= 0)
        return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colorSpace)
        return NULL;

    CGContextRef context = CGBitmapContextCreate(
        NULL, w, h, 8, w * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (!context)
        return NULL;

    CGContextClearRect(context, CGRectMake(0, 0, w, h));
    draw_subtitle_bitmaps(context, imgs, h);

    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    return result;
}

static CVPixelBufferRef create_empty_osd_pixel_buffer(struct vo *vo)
{
    struct priv *p = vo->priv;
    int w = p->osd_w;
    int h = p->osd_h;

    if (w <= 0 || h <= 0)
        return NULL;

    if (!create_osd_pool(vo, w, h))
        return NULL;

    CVPixelBufferRef pixbuf = NULL;
    // With the subtitle layer, animated ASS queues one buffer per video
    // frame ahead, plus the one on screen and one still on the GPU.
    int limit = avf_presentation_pool_limit(p->opts->queue_lead_ms,
        p->pool_frame_duration_ns, p->presentation_host) + 2;
    CVReturn status = avf_pool_get_buffer_with_limit(p->osdPool,
        MPMIN(limit, AVF_POOL_MAX_BUFFERS), &pixbuf);

    if (status != kCVReturnSuccess || !pixbuf) {
        MP_ERR(vo, "Failed to get OSD overlay buffer: %d\n", status);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixbuf, 0);
    void *base = CVPixelBufferGetBaseAddress(pixbuf);
    size_t stride = CVPixelBufferGetBytesPerRow(pixbuf);
    if (!base || !stride) {
        CVPixelBufferUnlockBaseAddress(pixbuf, 0);
        CVPixelBufferRelease(pixbuf);
        return NULL;
    }

    int64_t t = mp_time_ns();
    struct osd_buf_state *st = osd_buf_state_acquire(p, pixbuf);
    struct mp_rect dirty = st ? st->dirty : (struct mp_rect){0, 0, w, h};
    dirty.x0 = MPCLAMP(dirty.x0, 0, w);
    dirty.y0 = MPCLAMP(dirty.y0, 0, h);
    dirty.x1 = MPCLAMP(dirty.x1, 0, w);
    dirty.y1 = MPCLAMP(dirty.y1, 0, h);
    if (dirty.x1 > dirty.x0 && dirty.y1 > dirty.y0) {
        size_t span = (size_t)(dirty.x1 - dirty.x0) * 4;
        uint8_t *row = (uint8_t *)base + (size_t)dirty.y0 * stride +
                       (size_t)dirty.x0 * 4;
        for (int y = dirty.y0; y < dirty.y1; y++) {
            memset(row, 0, span);
            row += stride;
        }
    }
    if (st)
        st->dirty = (struct mp_rect){0, 0, 0, 0};
    p->perf.clear_ns += mp_time_ns() - t;

    CVPixelBufferUnlockBaseAddress(pixbuf, 0);
    return pixbuf;
}

static CVPixelBufferRef render_subtitle_pixel_buffer(struct vo *vo,
                                                     struct sub_bitmaps *imgs)
{
    struct priv *p = vo->priv;
    int w = p->osd_w;
    int h = p->osd_h;

    if (!imgs || imgs->num_parts == 0)
        return NULL;

    CVPixelBufferRef pixbuf = create_empty_osd_pixel_buffer(vo);
    if (!pixbuf)
        return NULL;

    CVPixelBufferLockBaseAddress(pixbuf, 0);
    void *base = CVPixelBufferGetBaseAddress(pixbuf);
    size_t stride = CVPixelBufferGetBytesPerRow(pixbuf);
    if (!base || !stride) {
        CVPixelBufferUnlockBaseAddress(pixbuf, 0);
        CVPixelBufferRelease(pixbuf);
        return NULL;
    }

    int64_t t = mp_time_ns();
    if (draw_subtitle_bitmaps_direct(p, base, stride, w, h, imgs)) {
        p->perf.blend_ns += mp_time_ns() - t;
        CVPixelBufferUnlockBaseAddress(pixbuf, 0);
        return pixbuf;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = colorSpace ? CGBitmapContextCreate(
        base, w, h, 8, stride, colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    ) : NULL;

    if (colorSpace)
        CGColorSpaceRelease(colorSpace);

    if (!context) {
        CVPixelBufferUnlockBaseAddress(pixbuf, 0);
        CVPixelBufferRelease(pixbuf);
        return NULL;
    }

    draw_subtitle_bitmaps(context, imgs, h);
    CGContextRelease(context);
    p->perf.cg_ns += mp_time_ns() - t;

    CVPixelBufferUnlockBaseAddress(pixbuf, 0);
    return pixbuf;
}

QuasarSubtitleFrame *avf_create_osd_frame(struct vo *vo, bool *needed)
{
    struct priv *p = vo->priv;

    *needed = should_use_inline_osd_layer(p) && p->osd_needs_enqueue;
    if (!*needed)
        return nil;
    if (p->has_subtitle && p->cachedSubtitleFrame)
        return [p->cachedSubtitleFrame retain];
    return [[QuasarSubtitleFrame alloc] init];
}

bool avf_enqueue_osd_frame(struct vo *vo, QuasarSubtitleFrame *frame,
                           int64_t media_pts_ns)
{
    struct priv *p = vo->priv;

    if (!frame)
        return true;
    if (!p->osdLayer)
        return false;
    // Same rule as video: a stopped timebase cannot pass an equal-PTS
    // replacement, so paused cue changes display immediately.
    [p->osdLayer enqueueFrame:frame pts:media_pts_ns
                    immediate:p->playback_paused && !p->presentation_host];
    return true;
}

static bool render_osd_buffer(struct vo *vo, struct sub_bitmap_list *list);

// Composite all OSD groups in order into one cache. Combined change_id tracks
// group removal; per-callback caching loses subtitles beside independent
// OSD/messages.
static bool render_osd_with_geometry(struct vo *vo, double pts,
                                     struct avf_render_geometry geometry,
                                     int frame_h)
{
    struct priv *p = vo->priv;
    if (!vo->osd || geometry.w <= 0 || geometry.h <= 0)
        return false;
    if (!osd_res_equals(p->osd_res, geometry.osd_res)) {
        p->osd_res = geometry.osd_res;
        p->osd_change_id = 0;
    }
    p->osd_w = geometry.w;
    p->osd_h = geometry.h;
    static const bool formats[SUBBITMAP_COUNT] = {
        [SUBBITMAP_BGRA] = true,
        [SUBBITMAP_LIBASS] = true,
    };
    struct sub_bitmap_list *list = osd_render(vo->osd, p->osd_res, pts, 0, formats);
    bool inline_layer = should_use_inline_osd_layer(p);
    bool changed = list->change_id != p->osd_change_id ||
        !(inline_layer ? p->cachedSubtitleFrame || p->osd_frame_dropped
                       : p->cachedSubtitleBuffer);
    if (!changed) {
        p->perf.skipped++;
        talloc_free(list);
        return true;
    }
    // A cue that just ended (or a clear that failed to enqueue) still needs
    // an empty sample on osdLayer.
    bool clear_pending = p->osd_needs_enqueue || p->has_subtitle;
    avf_clear_subtitle_cache(p);
    if (!list->num_items) {
        p->osd_needs_enqueue = clear_pending;
        talloc_free(list);
        return true;
    }
    int64_t start = mp_time_ns();
    // Subtitle layer: keep only the parts' pixels; the layer composites them.
    if (inline_layer) {
        QuasarSubtitleFrame *frame = [[QuasarSubtitleFrame alloc] initWithList:list];
        if (!frame || frame->_count < 0) {
            MP_WARN(vo, "Subtitle frame dropped: %s\n", frame && frame->_bytes == 0 &&
                    frame->_pixelsOffset == 0 ? "over the size limit" : "out of memory");
            [frame release];
            // Not retried until the subtitle changes.
            p->osd_change_id = list->change_id;
            p->osd_frame_dropped = true;
            p->osd_needs_enqueue = clear_pending;
            talloc_free(list);
            return false;
        }
        p->cachedSubtitleFrame = frame;
    } else if (!render_osd_buffer(vo, list)) {
        talloc_free(list);
        return false;
    }
    p->osd_change_id = list->change_id;
    p->has_subtitle = true;
    p->osd_needs_enqueue = true;
    p->perf.renders++;
    int64_t elapsed = mp_time_ns() - start;
    p->perf.total_ns += elapsed;
    p->perf.max_ns = MPMAX(p->perf.max_ns, elapsed);
    talloc_free(list);
    return true;
}

// Frame-space OSD for compositing into video frames.
static bool render_osd_buffer(struct vo *vo, struct sub_bitmap_list *list)
{
    struct priv *p = vo->priv;
    CVPixelBufferRef buf = create_empty_osd_pixel_buffer(vo);
    if (!buf || CVPixelBufferLockBaseAddress(buf, 0) != kCVReturnSuccess) {
        if (buf)
            CVPixelBufferRelease(buf);
        return false;
    }
    void *base = CVPixelBufferGetBaseAddress(buf);
    size_t stride = CVPixelBufferGetBytesPerRow(buf);
    if (!base || !stride) {
        CVPixelBufferUnlockBaseAddress(buf, 0);
        CVPixelBufferRelease(buf);
        return false;
    }
    CGContextRef cg = NULL;
    struct mp_rect bounds = {p->osd_w, p->osd_h, 0, 0};
    for (int i = 0; i < list->num_items; i++) {
        struct sub_bitmaps *group = list->items[i];
        if (!draw_subtitle_bitmaps_direct(p, base, stride, p->osd_w, p->osd_h, group)) {
            if (!cg) {
                CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                cg = color ? CGBitmapContextCreate(
                    base, p->osd_w, p->osd_h, 8, stride, color,
                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
                if (color)
                    CGColorSpaceRelease(color);
                if (!cg) {
                    // Earlier direct groups may already have written pixels.
                    osd_buf_record_dirty(p, buf, (struct mp_rect){0, 0, p->osd_w, p->osd_h});
                    CVPixelBufferUnlockBaseAddress(buf, 0);
                    CVPixelBufferRelease(buf);
                    return false;
                }
            }
            draw_subtitle_bitmaps(cg, group, p->osd_h);
        }
        update_subtitle_bounds_from_parts(p, group);
        bounds.x0 = MPMIN(bounds.x0, p->subtitle_x0);
        bounds.y0 = MPMIN(bounds.y0, p->subtitle_y0);
        bounds.x1 = MPMAX(bounds.x1, p->subtitle_x1);
        bounds.y1 = MPMAX(bounds.y1, p->subtitle_y1);
    }
    if (cg)
        CGContextRelease(cg);
    CVPixelBufferUnlockBaseAddress(buf, 0);
    p->cachedSubtitleBuffer = buf;
    p->subtitle_x0 = bounds.x0;
    p->subtitle_y0 = bounds.y0;
    p->subtitle_x1 = bounds.x1;
    p->subtitle_y1 = bounds.y1;
    osd_buf_record_dirty(p, buf, bounds);
    return true;
}

// Render OSD synchronously; preserve timed clear samples.
void avf_render_osd(struct vo *vo, double pts)
{
    struct priv *p = vo->priv;
    int frame_w = p->next_image ? p->next_image->w : 0;
    int frame_h = p->next_image ? p->next_image->h : 0;
    struct avf_render_geometry geometry = get_render_geometry(vo, frame_w, frame_h);

    render_osd_with_geometry(vo, pts, geometry, frame_h);
}

static bool ensure_ci_compositor(struct vo *vo)
{
    struct priv *p = vo->priv;

    if (p->ciContext)
        return true;

    p->mtlDevice = MTLCreateSystemDefaultDevice();
    if (!p->mtlDevice) {
        MP_ERR(vo, "Failed to create Metal device\n");
        return false;
    }

    CGColorSpaceRef workingSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    NSDictionary *ciOptions = @{
        kCIContextHighQualityDownsample: @NO,
        kCIContextUseSoftwareRenderer: @NO,
        kCIContextWorkingColorSpace: (__bridge id)workingSpace
    };
    p->ciContext = [[CIContext contextWithMTLDevice:p->mtlDevice options:ciOptions] retain];
    CGColorSpaceRelease(workingSpace);
    if (!p->ciContext) {
        MP_ERR(vo, "Failed to create CIContext\n");
        [p->mtlDevice release];
        p->mtlDevice = nil;
        return false;
    }

    return true;
}

void avf_release_ci_compositor(struct priv *p)
{
    avf_subtitle_image_cache_clear(&p->subtitleImageCache);
    [p->ciContext release];
    p->ciContext = nil;
    if (p->transferSession) {
        VTPixelTransferSessionInvalidate(p->transferSession);
        CFRelease(p->transferSession);
        p->transferSession = NULL;
    }
    [p->mtlDevice release];
    p->mtlDevice = nil;
}

static struct avf_overlay_color get_overlay_color(struct vo *vo, CVPixelBufferRef videoBuffer)
{
    struct priv *p = vo->priv;
    struct avf_overlay_color color = {
        .white_nits = p->opts->subtitle_luminance,
        .transfer = AVF_BT1886,
    };
    get_yuv_coefficients(videoBuffer, &color.kr, &color.kb);
    CFTypeRef trc = CVBufferGetAttachment(videoBuffer, kCVImageBufferTransferFunctionKey, NULL);
    if (trc) {
        if (CFEqual(trc, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) color.transfer = AVF_PQ;
        else if (CFEqual(trc, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) color.transfer = AVF_HLG;
        else if (CFEqual(trc, kCVImageBufferTransferFunction_sRGB)) color.transfer = AVF_SRGB;
        else if (CFEqual(trc, kCVImageBufferTransferFunction_Linear)) color.transfer = AVF_LINEAR;
    }
    enum pl_color_primaries prim = vo->params->color.primaries;
    CFTypeRef cvprim = CVBufferGetAttachment(videoBuffer, kCVImageBufferColorPrimariesKey, NULL);
    const enum pl_color_primaries candidates[] = {
        PL_COLOR_PRIM_BT_601_525, PL_COLOR_PRIM_BT_601_625, PL_COLOR_PRIM_BT_709,
        PL_COLOR_PRIM_BT_2020, PL_COLOR_PRIM_DCI_P3, PL_COLOR_PRIM_DISPLAY_P3,
    };
    for (int i = 0; cvprim && i < MP_ARRAY_SIZE(candidates); i++)
        if (CFEqual(cvprim, get_cv_color_primaries(candidates[i]))) prim = candidates[i];
    if (prim == PL_COLOR_PRIM_UNKNOWN) prim = PL_COLOR_PRIM_BT_709;
    if (!p->overlay_matrix_valid || p->overlay_matrix_primaries != prim) {
        pl_matrix3x3 matrix = pl_get_color_mapping_matrix(
            pl_raw_primaries_get(PL_COLOR_PRIM_BT_709), pl_raw_primaries_get(prim),
            PL_INTENT_RELATIVE_COLORIMETRIC);
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++) p->overlay_rgb_matrix[i][j] = matrix.m[i][j];
        p->overlay_matrix_primaries = prim;
        p->overlay_matrix_valid = true;
    }
    memcpy(color.rgb_matrix, p->overlay_rgb_matrix, sizeof(color.rgb_matrix));

    return color;
}

// An explicit output-transfer float texture makes PQ/HLG subtitle reference
// white unambiguous. CI decodes it into the context's linear working space
// before alpha composition; artwork alpha remains premultiplied at its input.
static CIImage *subtitle_ci_image(struct vo *vo, CVPixelBufferRef videoBuffer)
{
    struct priv *p = vo->priv;
    CVPixelBufferRef sub = p->cachedSubtitleBuffer;
    if (!sub) return nil;
    CGColorSpaceRef cs = CVImageBufferGetColorSpace(videoBuffer);
    if (!cs) {
        MP_ERR(vo, "MPVUI_NATIVE_VIDEO_UNSUPPORTED: no color space for native CI overlay\n");
        return nil;
    }
    struct avf_overlay_color color = get_overlay_color(vo, videoBuffer);
    return avf_cached_subtitle_image(&p->subtitleImageCache, sub, cs, &color);
}

// VideoToolbox also tags the decoded surface itself (for example
// SidebandVideoPropertiesLookupID); attachments alone do not carry those
// values. Copy them so a composited frame is presented like the decoded one.
static void avf_copy_iosurface_values(struct vo *vo, CVPixelBufferRef src, CVPixelBufferRef dst)
{
    struct priv *p = vo->priv;
    IOSurfaceRef from = CVPixelBufferGetIOSurface(src), to = CVPixelBufferGetIOSurface(dst);
    if (!from || !to)
        return;
    IOSurfaceRemoveAllValues(to);
    CFDictionaryRef values = IOSurfaceCopyAllValues(from);
    if (!values)
        return;
    IOSurfaceSetValues(to, values);
    if (!p->iosurface_values_logged) {
        p->iosurface_values_logged = true;
        CFStringRef d = CFCopyDescription(values);
        char text[600] = "";
        if (d) {
            CFStringGetCString(d, text, sizeof(text), kCFStringEncodingUTF8);
            CFRelease(d);
        }
        for (char *c = text; *c; c++) if (*c == '\n') *c = ' ';
        MP_INFO(vo, "MPVUI_NATIVE_IOSURFACE: copied %ld values %s\n",
                (long)CFDictionaryGetCount(values), text);
    }
    CFRelease(values);
}

static CVPixelBufferRef copy_frame_to_pool(struct vo *vo, CVPixelBufferRef videoBuffer)
{
    struct priv *p = vo->priv;
    OSType format = CVPixelBufferGetPixelFormatType(videoBuffer);
    int w = (int)CVPixelBufferGetWidth(videoBuffer), h = (int)CVPixelBufferGetHeight(videoBuffer);
    int out_w, out_h;
    avf_pool_frame_size(w, h, &out_w, &out_h);
    if (!avf_create_output_pool(vo, out_w, out_h, format))
        return NULL;
    CVPixelBufferRef outputBuffer = NULL;
    CVReturn status = avf_pool_get_buffer_for_frame(vo, p->outputPool,
                                                  &p->outputReservePool, &outputBuffer);
    if (status != kCVReturnSuccess || !outputBuffer) {
        MP_ERR(vo, "Failed to get YUV composite buffer: %d\n", status);
        return NULL;
    }
    copy_pixel_buffer_metadata(videoBuffer, outputBuffer, format);
    avf_copy_iosurface_values(vo, videoBuffer, outputBuffer);
    // Picture in picture copies every frame; a CPU memcpy of a 4K P010 frame
    // costs the vo thread 6-16 ms. The transfer session copies on the GPU.
    // Both buffers carry the same color attachments, so it converts nothing.
    // Scaling stretches the source's clean aperture and pixel aspect onto the
    // destination (kVTScalingMode_Normal).
    if (!p->transferSession &&
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &p->transferSession) != noErr)
        p->transferSession = NULL;
    if (p->transferSession &&
        VTPixelTransferSessionTransferImage(p->transferSession, videoBuffer, outputBuffer) == noErr)
        return outputBuffer;
    p->pool_stats.memcpy++;
    if (out_w != w || out_h != h || !copy_pixel_buffer_planes(videoBuffer, outputBuffer)) {
        CVPixelBufferRelease(outputBuffer);
        return NULL;
    }
    return outputBuffer;
}

// Diagnostics: where picture in picture spends the vo thread, every 120 frames.
CVPixelBufferRef avf_copy_frame_to_pool(struct vo *vo, CVPixelBufferRef videoBuffer)
{
    struct priv *p = vo->priv;
    int64_t t = mp_time_ns();
    CVPixelBufferRef out = copy_frame_to_pool(vo, videoBuffer);
    p->pool_stats.copy_ns += mp_time_ns() - t;
    if (++p->pool_stats.frames % 120 == 0) {
        int64_t n = p->pool_stats.frames, s = p->pool_stats.subtitled;
        MP_INFO(vo, "MPVUI_NATIVE_POOL: %dx%d->%dx%d frames=%" PRId64 " memcpy=%" PRId64 " subtitled=%" PRId64
                " copy=%" PRId64 "us blend=%" PRId64 "us\n",
                (int)CVPixelBufferGetWidth(videoBuffer), (int)CVPixelBufferGetHeight(videoBuffer),
                out ? (int)CVPixelBufferGetWidth(out) : 0, out ? (int)CVPixelBufferGetHeight(out) : 0,
                n, p->pool_stats.memcpy, s,
                p->pool_stats.copy_ns / n / 1000, s ? p->pool_stats.blend_ns / s / 1000 : 0);
        memset(&p->pool_stats, 0, sizeof(p->pool_stats));
    }
    return out;
}

static CVPixelBufferRef composite_yuv_frame(struct vo *vo, CVPixelBufferRef videoBuffer,
                                            OSType sourceFormat, bool in_place);

CVPixelBufferRef avf_composite_yuv_frame(struct vo *vo, CVPixelBufferRef videoBuffer,
                                           OSType sourceFormat, bool in_place)
{
    struct priv *p = vo->priv;
    int64_t copy = p->pool_stats.copy_ns, t = mp_time_ns();
    CVPixelBufferRef out = composite_yuv_frame(vo, videoBuffer, sourceFormat, in_place);
    if (out) {
        p->pool_stats.subtitled++;
        // copy_ns may have been reset by the report inside; then count it all as blend
        int64_t copied = p->pool_stats.copy_ns >= copy ? p->pool_stats.copy_ns - copy : 0;
        p->pool_stats.blend_ns += mp_time_ns() - t - copied;
    }
    return out;
}

static CVPixelBufferRef composite_yuv_frame(struct vo *vo, CVPixelBufferRef videoBuffer,
                                            OSType sourceFormat, bool in_place)
{
    struct priv *p = vo->priv;

    if (!p->cachedSubtitleBuffer || p->subtitle_x1 <= p->subtitle_x0 ||
        p->subtitle_y1 <= p->subtitle_y0)
        return NULL;

    int videoW = (int)CVPixelBufferGetWidth(videoBuffer);
    int videoH = (int)CVPixelBufferGetHeight(videoBuffer);
    if (videoW <= 0 || videoH <= 0)
        return NULL;

    int subW = (int)CVPixelBufferGetWidth(p->cachedSubtitleBuffer);
    int subH = (int)CVPixelBufferGetHeight(p->cachedSubtitleBuffer);
    if (subW <= 0 || subH <= 0)
        return NULL;

    struct avf_render_geometry geometry = get_render_geometry(vo, videoW, videoH);
    if (!in_place) {
        // The pool copy may be smaller; subtitles stay on the frame's grid
        // and are sampled down onto it.
        int poolW, poolH;
        avf_pool_frame_size(videoW, videoH, &poolW, &poolH);
        if (poolW != videoW || poolH != videoH) {
            struct mp_rect *r = &geometry.src;
            *r = (struct mp_rect){r->x0 * poolW / videoW, r->y0 * poolH / videoH,
                                  r->x1 * poolW / videoW, r->y1 * poolH / videoH};
            videoW = poolW;
            videoH = poolH;
        }
    }
    struct mp_rect src = geometry.src;
    struct mp_rect dst = geometry.dst;
    int srcW = src.x1 - src.x0;
    int srcH = src.y1 - src.y0;
    int dstW = dst.x1 - dst.x0;
    int dstH = dst.y1 - dst.y0;

    struct mp_rect sub = {p->subtitle_x0, p->subtitle_y0,
                          p->subtitle_x1, p->subtitle_y1};
    struct mp_rect target;
    if (!avf_map_subtitle_rect(geometry, sub, subW, subH, videoW, videoH, &target))
        return NULL;

    int vx0 = target.x0;
    int vy0 = target.y0;
    int vx1 = target.x1;
    int vy1 = target.y1;

    CVPixelBufferRef outputBuffer = NULL;
    if (in_place) {
        outputBuffer = CVPixelBufferRetain(videoBuffer);
    } else {
        outputBuffer = avf_copy_frame_to_pool(vo, videoBuffer);
        if (!outputBuffer)
            return NULL;
    }

    if (CVPixelBufferLockBaseAddress(outputBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(outputBuffer);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(p->cachedSubtitleBuffer,
                                     kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(outputBuffer, 0);
        CVPixelBufferRelease(outputBuffer);
        return NULL;
    }

    uint8_t *subBase = CVPixelBufferGetBaseAddress(p->cachedSubtitleBuffer);
    size_t subStride = CVPixelBufferGetBytesPerRow(p->cachedSubtitleBuffer);
    uint8_t *yBase = CVPixelBufferGetBaseAddressOfPlane(outputBuffer, 0);
    uint8_t *uvBase = CVPixelBufferGetBaseAddressOfPlane(outputBuffer, 1);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(outputBuffer, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(outputBuffer, 1);

    if (!subBase || !subStride || subW <= 0 || subH <= 0 || !yBase || !uvBase) {
        CVPixelBufferUnlockBaseAddress(p->cachedSubtitleBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(outputBuffer, 0);
        CVPixelBufferRelease(outputBuffer);
        return NULL;
    }

    struct avf_overlay_color color = get_overlay_color(vo, videoBuffer);

    bool fullRange = is_full_range_yuv_format(sourceFormat);
    bool p010 = is_p010_format(sourceFormat);
    double yOffset = fullRange ? 0.0 : (p010 ? 64.0 : 16.0);
    double yRange = fullRange ? (p010 ? 1023.0 : 255.0) : (p010 ? 876.0 : 219.0);
    double cCenter = p010 ? 512.0 : 128.0;
    double cRange = fullRange ? (p010 ? 1023.0 : 255.0) : (p010 ? 896.0 : 224.0);

    bool identity_mapping = src.x0 == dst.x0 && src.y0 == dst.y0 &&
                            srcW == dstW && srcH == dstH;
    for (int cy = vy0 / 2; cy < (vy1 + 1) / 2; cy++) {
        const uint8_t *subRows[2] = {NULL, NULL};
        int rows = MPMIN(2, videoH - cy * 2);
        for (int dy = 0; dy < rows; dy++) {
            int y = cy * 2 + dy;
            if (y < vy0 || y >= vy1)
                continue;
            int sy = identity_mapping ? y :
                dst.y0 + (int)(((int64_t)(y - src.y0) * dstH) / srcH);
            sy = MPCLAMP(sy, 0, subH - 1);
            subRows[dy] = subBase + (size_t)sy * subStride;
        }
        uint8_t *uvRow = uvBase + (size_t)cy * uvStride;
        for (int cx = vx0 / 2; cx < (vx1 + 1) / 2; cx++) {
            int columns = MPMIN(2, videoW - cx * 2);
            int count = rows * columns;
            uint8_t bgra[4][4] = {{0}};
            int xs[4], ys[4];
            bool covered = false;
            for (int dx = 0; dx < columns; dx++) {
                int x = cx * 2 + dx;
                if (x < vx0 || x >= vx1)
                    continue;
                int sx = identity_mapping ? x :
                    dst.x0 + (int)(((int64_t)(x - src.x0) * dstW) / srcW);
                sx = MPCLAMP(sx, 0, subW - 1);
                for (int dy = 0; dy < rows; dy++) {
                    if (!subRows[dy])
                        continue;
                    int i = dy * columns + dx;
                    memcpy(bgra[i], subRows[dy] + (size_t)sx * 4, 4);
                    xs[i] = x;
                    ys[i] = cy * 2 + dy;
                    covered |= bgra[i][3] != 0;
                }
            }
            // Sparse subtitle bounds often contain mostly transparent cells.
            // Do not read or normalize video samples until artwork covers one.
            if (!covered)
                continue;

            double uv[2];
            for (int k = 0; k < 2; k++) {
                double code = p010 ? ((uint16_t *)uvRow)[2 * cx + k] >> 6 : uvRow[2 * cx + k];
                uv[k] = (code - cCenter) / cRange;
            }
            double luma[4] = {0};
            for (int i = 0; i < count; i++) {
                if (!bgra[i][3])
                    continue;
                int x = xs[i];
                int y = ys[i];
                uint8_t *yRow = yBase + (size_t)y * yStride;
                double code = p010 ? ((uint16_t *)yRow)[x] >> 6 : yRow[x];
                luma[i] = (code - yOffset) / yRange;
            }
            if (!avf_blend_chroma_cell(&color, bgra, luma, uv, count)) continue;
            for (int i = 0; i < count; i++) {
                if (!bgra[i][3]) continue; // bit-exact untouched luma, including P010 low bits
                int x = xs[i];
                int y = ys[i];
                uint8_t *yRow = yBase + (size_t)y * yStride;
                double code = yOffset + yRange * luma[i];
                if (p010) ((uint16_t *)yRow)[x] = clip_u10(code) << 6;
                else yRow[x] = clip_u8(code);
            }
            for (int k = 0; k < 2; k++) {
                double code = cCenter + cRange * uv[k];
                if (p010) ((uint16_t *)uvRow)[2 * cx + k] = clip_u10(code) << 6;
                else uvRow[2 * cx + k] = clip_u8(code);
            }
        }
    }
    // Keep the source's content light level and HDR10+ metadata. Subtitles sit
    // near SDR white, below the content's peak; dropping the keys changes the
    // system's tone mapping only on frames that carry a cue, so the picture
    // brightness jumps whenever a subtitle appears or disappears.

    CVPixelBufferUnlockBaseAddress(p->cachedSubtitleBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(outputBuffer, 0);
    return outputBuffer;
}

CVPixelBufferRef avf_render_video_geometry_frame(struct vo *vo,
                                                    CVPixelBufferRef videoBuffer,
                                                    bool include_subtitle)
{
    struct priv *p = vo->priv;

    if (!ensure_ci_compositor(vo))
        return NULL;

    size_t videoW = CVPixelBufferGetWidth(videoBuffer);
    size_t videoH = CVPixelBufferGetHeight(videoBuffer);

    struct avf_render_geometry geometry = get_render_geometry(vo, (int)videoW, (int)videoH);
    size_t outW = geometry.w > 0 ? (size_t)geometry.w : videoW;
    size_t outH = geometry.h > 0 ? (size_t)geometry.h : videoH;
    if (!outW || !outH)
        return NULL;

    struct mp_rect src = geometry.src;
    struct mp_rect dst = geometry.dst;
    if (src.x1 <= src.x0 || src.y1 <= src.y0 || dst.x1 <= dst.x0 || dst.y1 <= dst.y0)
        return NULL;

    OSType outputFormat = ci_output_format_for_source(videoBuffer);
    if (!avf_create_output_pool(vo, (int)outW, (int)outH, outputFormat))
        return NULL;

    CVPixelBufferRef outputBuffer = NULL;
    CVReturn status = avf_pool_get_buffer_for_frame(vo, p->outputPool,
                                                  &p->outputReservePool, &outputBuffer);

    if (status != kCVReturnSuccess || !outputBuffer) {
        MP_ERR(vo, "Failed to get geometry output buffer: %d\n", status);
        return NULL;
    }

    copy_pixel_buffer_metadata(videoBuffer, outputBuffer, outputFormat);

    @autoreleasepool {
        CGColorSpaceRef srcColorSpace = CVImageBufferGetColorSpace(videoBuffer);
        CGColorSpaceRef fallbackColorSpace = NULL;
        if (!srcColorSpace) {
            fallbackColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            srcColorSpace = fallbackColorSpace;
        }

        CIImage *videoImage;
        if (srcColorSpace) {
            NSDictionary *videoOptions = @{
                kCIImageColorSpace: (__bridge id)srcColorSpace
            };
            videoImage = [CIImage imageWithCVPixelBuffer:videoBuffer options:videoOptions];
        } else {
            videoImage = [CIImage imageWithCVPixelBuffer:videoBuffer];
        }

        if (fallbackColorSpace)
            CGColorSpaceRelease(fallbackColorSpace);

        if (!videoImage) {
            CVPixelBufferRelease(outputBuffer);
            return NULL;
        }

        CGRect srcRect = CGRectMake(src.x0, videoH - src.y1,
                                   src.x1 - src.x0, src.y1 - src.y0);
        CGFloat dstW = dst.x1 - dst.x0;
        CGFloat dstH = dst.y1 - dst.y0;
        CGFloat dstY = outH - dst.y1;

        videoImage = [videoImage imageByCroppingToRect:srcRect];
        videoImage = [videoImage imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-srcRect.origin.x, -srcRect.origin.y)];
        videoImage = [videoImage imageByApplyingTransform:
            CGAffineTransformMakeScale(dstW / srcRect.size.width, dstH / srcRect.size.height)];
        videoImage = [videoImage imageByApplyingTransform:
            CGAffineTransformMakeTranslation(dst.x0, dstY)];

        CIImage *background = [[CIImage imageWithColor:
            [CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:CGRectMake(0, 0, outW, outH)];
        CIImage *outputImage = [videoImage imageByCompositingOverImage:background];

        if (include_subtitle && p->cachedSubtitleBuffer) {
            CIImage *subtitleImage = subtitle_ci_image(vo, videoBuffer);
            if (subtitleImage) {
                CGSize subSize = subtitleImage.extent.size;
                if (subSize.width != (CGFloat)outW || subSize.height != (CGFloat)outH) {
                    CGFloat scaleX = (CGFloat)outW / subSize.width;
                    CGFloat scaleY = (CGFloat)outH / subSize.height;
                    subtitleImage = [subtitleImage imageByApplyingTransform:
                        CGAffineTransformMakeScale(scaleX, scaleY)];
                }
                outputImage = [subtitleImage imageByCompositingOverImage:outputImage];
            }
        }

        CGColorSpaceRef outputColorSpace = CVImageBufferGetColorSpace(videoBuffer);
        if (outputColorSpace) {
            [p->ciContext render:outputImage
                 toCVPixelBuffer:outputBuffer
                          bounds:CGRectMake(0, 0, outW, outH)
                      colorSpace:outputColorSpace];
        } else {
            [p->ciContext render:outputImage
                 toCVPixelBuffer:outputBuffer
                          bounds:CGRectMake(0, 0, outW, outH)
                      colorSpace:nil];
        }
    }

    return outputBuffer;
}

// GPU Core Image subtitle composite; HDR-compatible.
CVPixelBufferRef avf_composite_frame(struct vo *vo, CVPixelBufferRef videoBuffer,
                                       bool in_place)
{
    struct priv *p = vo->priv;

    if (!p->has_subtitle || should_use_inline_osd_layer(p))
        return NULL;
    if (CVBufferGetAttachment(videoBuffer, CFSTR("DolbyVisionRPUData"), NULL)) {
        if (!p->dovi_geometry_skip_logged) {
            MP_WARN(vo, "Dolby Vision RPU frame: native OSD composition skipped\n");
            p->dovi_geometry_skip_logged = true;
        }
        return NULL;
    }

    OSType sourceFormat = CVPixelBufferGetPixelFormatType(videoBuffer);
    if (is_biplanar_yuv_format(sourceFormat)) {
        CVPixelBufferRef composited = avf_composite_yuv_frame(vo, videoBuffer, sourceFormat, in_place);
        if (composited)
            return composited;
    }

    if (!p->cachedSubtitleBuffer || !ensure_ci_compositor(vo))
        return NULL;

    size_t videoW = CVPixelBufferGetWidth(videoBuffer);
    size_t videoH = CVPixelBufferGetHeight(videoBuffer);

    struct avf_render_geometry geometry = get_render_geometry(vo, (int)videoW, (int)videoH);
    size_t outW = geometry.w > 0 ? (size_t)geometry.w : videoW;
    size_t outH = geometry.h > 0 ? (size_t)geometry.h : videoH;
    if (!outW || !outH)
        return NULL;

    struct mp_rect src = geometry.src;
    struct mp_rect dst = geometry.dst;
    if (src.x1 <= src.x0 || src.y1 <= src.y0 || dst.x1 <= dst.x0 || dst.y1 <= dst.y0)
        return NULL;

    CGRect outputRect = CGRectMake(0, 0, outW, outH);

    OSType outputFormat = ci_output_format_for_source(videoBuffer);

    // Match output pool dimensions/format.
    if (!avf_create_output_pool(vo, (int)outW, (int)outH, outputFormat))
        return NULL;

    // Acquire output buffer.
    CVPixelBufferRef outputBuffer = NULL;
    CVReturn status = avf_pool_get_buffer_for_frame(vo, p->outputPool,
                                                  &p->outputReservePool, &outputBuffer);

    if (status != kCVReturnSuccess || !outputBuffer) {
        MP_ERR(vo, "Failed to get output buffer from pool: %d\n", status);
        return NULL;
    }

    copy_pixel_buffer_metadata(videoBuffer, outputBuffer, outputFormat);

    // Autorelease CIImages promptly.
    @autoreleasepool {
        // Create CIImages; preserve HDR source color space.
        CGColorSpaceRef srcColorSpace = CVImageBufferGetColorSpace(videoBuffer);
        CGColorSpaceRef fallbackColorSpace = NULL;
        if (!srcColorSpace) {
            fallbackColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            srcColorSpace = fallbackColorSpace;
        }

        CIImage *videoImage;
        if (srcColorSpace) {
            NSDictionary *videoOptions = @{
                kCIImageColorSpace: (__bridge id)srcColorSpace
            };
            videoImage = [CIImage imageWithCVPixelBuffer:videoBuffer options:videoOptions];
        } else {
            videoImage = [CIImage imageWithCVPixelBuffer:videoBuffer];
        }

        if (fallbackColorSpace)
            CGColorSpaceRelease(fallbackColorSpace);

        if (!videoImage) {
            CVPixelBufferRelease(outputBuffer);
            return NULL;
        }

        CGRect srcRect = CGRectMake(src.x0, videoH - src.y1,
                                   src.x1 - src.x0, src.y1 - src.y0);
        CGFloat dstW = dst.x1 - dst.x0;
        CGFloat dstH = dst.y1 - dst.y0;
        CGFloat dstY = outH - dst.y1;

        videoImage = [videoImage imageByCroppingToRect:srcRect];
        videoImage = [videoImage imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-srcRect.origin.x, -srcRect.origin.y)];
        videoImage = [videoImage imageByApplyingTransform:
            CGAffineTransformMakeScale(dstW / srcRect.size.width, dstH / srcRect.size.height)];
        videoImage = [videoImage imageByApplyingTransform:
            CGAffineTransformMakeTranslation(dst.x0, dstY)];

        CIImage *background = [[CIImage imageWithColor:
            [CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:outputRect];
        videoImage = [videoImage imageByCompositingOverImage:background];

        CIImage *subtitleImage = subtitle_ci_image(vo, videoBuffer);

        if (!subtitleImage) {
            CVPixelBufferRelease(outputBuffer);
            return NULL;
        }

        // Scale subtitle to output size.
        CGSize subSize = subtitleImage.extent.size;

        if (subSize.width != (CGFloat)outW || subSize.height != (CGFloat)outH) {
            CGFloat scaleX = (CGFloat)outW / subSize.width;
            CGFloat scaleY = (CGFloat)outH / subSize.height;
            subtitleImage = [subtitleImage imageByApplyingTransform:
                CGAffineTransformMakeScale(scaleX, scaleY)];
        }

        // Composite subtitle over video
        CIImage *composited = [subtitleImage imageByCompositingOverImage:videoImage];

        // Render output; preserve color space.
        CGColorSpaceRef outputColorSpace = CVImageBufferGetColorSpace(videoBuffer);
        if (outputColorSpace) {
            [p->ciContext render:composited
                 toCVPixelBuffer:outputBuffer
                          bounds:outputRect
                      colorSpace:outputColorSpace];
        } else {
            [p->ciContext render:composited toCVPixelBuffer:outputBuffer bounds:outputRect colorSpace:nil];
        }
    }

    return outputBuffer;
}

void avf_clear_subtitle_cache(struct priv *p)
{
    avf_subtitle_image_cache_clear(&p->subtitleImageCache);
    [p->cachedSubtitleFrame release];
    p->cachedSubtitleFrame = nil;
    p->osd_frame_dropped = false;
    if (p->cachedSubtitleBuffer) {
        CVPixelBufferRelease(p->cachedSubtitleBuffer);
        p->cachedSubtitleBuffer = NULL;
    }
    p->has_subtitle = false;
    p->osd_change_id = 0;
    p->osd_needs_enqueue = false;
    p->osd_callback_invoked = false;
    p->subtitle_x0 = p->subtitle_y0 = p->subtitle_x1 = p->subtitle_y1 = 0;
}

// Clear subtitle state on video change/stop.
void avf_clear_subtitle_state(struct vo *vo)
{
    avf_clear_subtitle_cache(vo->priv);
}
