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

#include "vo_avfoundation_priv.h"

int avf_presentation_pool_limit(int queue_lead_ms, int64_t frame_duration_ns,
                                      bool presentation_host)
{
    int regular = 7;
    if (frame_duration_ns > 0) {
        int64_t lead = MP_TIME_MS_TO_NS(queue_lead_ms);
        int64_t queued = lead / frame_duration_ns + (lead % frame_duration_ns != 0);
        regular = MPMAX(regular, MPMIN(queued + 3, AVF_POOL_MAX_BUFFERS - 1));
    }
    return regular + (presentation_host ? 1 : 0);
}

// AVFoundation can retain queued buffers after flush until a new image arrives.
CVReturn avf_pool_get_buffer_with_limit(CVPixelBufferPoolRef pool,
                                               int limit, CVPixelBufferRef *out)
{
    if (limit < 1 || limit > AVF_POOL_MAX_BUFFERS)
        return kCVReturnInvalidArgument;
    static NSDictionary *attributes[AVF_POOL_MAX_BUFFERS];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < AVF_POOL_MAX_BUFFERS; i++)
            attributes[i] = [@{(id)kCVPixelBufferPoolAllocationThresholdKey: @(i + 1)} retain];
    });
    return CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)attributes[limit - 1], out);
}

CVReturn avf_pool_get_buffer(CVPixelBufferPoolRef pool, CVPixelBufferRef *out)
{
    return avf_pool_get_buffer_with_limit(pool, 8, out);
}

static CVReturn avf_pool_get_reserve_buffer(CVPixelBufferPoolRef pool,
                                            CVPixelBufferPoolRef *reserve_pool,
                                            CVPixelBufferRef *out)
{
    CFDictionaryRef attributes = CVPixelBufferPoolGetPixelBufferAttributes(pool);
    if (*reserve_pool && !CFEqual(attributes,
            CVPixelBufferPoolGetPixelBufferAttributes(*reserve_pool))) {
        CVPixelBufferPoolRelease(*reserve_pool);
        *reserve_pool = NULL;
    }
    if (!*reserve_pool) {
        NSDictionary *pool_attributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @1,
            (id)kCVPixelBufferPoolMaximumBufferAgeKey: @1.0,
        };
        CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
            (__bridge CFDictionaryRef)pool_attributes, attributes, reserve_pool);
        if (status != kCVReturnSuccess)
            return status;
    }
    return avf_pool_get_buffer_with_limit(*reserve_pool, 1, out);
}

CVReturn avf_pool_get_buffer_for_frame(struct vo *vo,
                                             CVPixelBufferPoolRef pool,
                                             CVPixelBufferPoolRef *reserve_pool,
                                             CVPixelBufferRef *out)
{
    struct priv *p = vo->priv;
    bool allow_reserve = p->playback_paused && !p->presentation_host;
    int limit = avf_presentation_pool_limit(p->opts->queue_lead_ms,
        p->pool_frame_duration_ns, p->presentation_host);
    CVReturn status = avf_pool_get_buffer_with_limit(pool, limit, out);
    if (status == kCVReturnWouldExceedAllocationThreshold && allow_reserve)
        status = avf_pool_get_reserve_buffer(pool, reserve_pool, out);
    if (status != kCVReturnWouldExceedAllocationThreshold)
        return status;

    int64_t start = mp_time_ns();
    int64_t deadline = p->playback_paused && !p->presentation_host
        ? start + MP_TIME_MS_TO_NS(20)
        : p->next_present_host_ns > 0
            ? p->next_present_host_ns - MP_TIME_MS_TO_NS(4)
            : start + MP_TIME_MS_TO_NS(2);
    // Bound teardown latency even when queue-lead-ms is set to a full second.
    deadline = MPMIN(deadline, start + MP_TIME_MS_TO_NS(128));
    if (deadline <= start)
        return status;

    // Presentation can retain every regular upload buffer briefly. Wait for a
    // recycled buffer instead of growing the pool or discarding a timely frame.
    // The copied observer block retains this semaphore under MRC; it captures no
    // VO state and remains safe if notification delivery overlaps removal.
    dispatch_semaphore_t available = dispatch_semaphore_create(0);
    if (!available)
        return status;
    CVPixelBufferPoolRef reserve = allow_reserve ? *reserve_pool : NULL;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:(__bridge NSString *)kCVPixelBufferPoolFreeBufferNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                    if (notification.object == (__bridge id)pool ||
                        (reserve && notification.object == (__bridge id)reserve))
                        dispatch_semaphore_signal(available);
                }];
    // Close the race between the failed allocation and observer registration.
    while (true) {
        status = avf_pool_get_buffer_with_limit(pool, limit, out);
        if (status == kCVReturnWouldExceedAllocationThreshold && allow_reserve)
            status = avf_pool_get_buffer_with_limit(reserve, 1, out);
        if (status != kCVReturnWouldExceedAllocationThreshold)
            break;
        int64_t remaining = deadline - mp_time_ns();
        if (remaining <= 0 || dispatch_semaphore_wait(available,
                dispatch_time(DISPATCH_TIME_NOW, remaining)) != 0)
            break;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    dispatch_release(available);
    return status;
}

// Create pixel-buffer pool.
bool avf_create_pixel_buffer_pool(struct vo *vo, CVPixelBufferPoolRef *poolRef,
                                     int *cached_w, int *cached_h, OSType *cached_fmt,
                                     int w, int h, OSType format, const char *name)
{
    // Reuse matching dimensions/format.
    if (*poolRef && *cached_w == w && *cached_h == h &&
        (!cached_fmt || *cached_fmt == format))
        return true;

    // Release old pool
    if (*poolRef) {
        CVPixelBufferPoolFlush(*poolRef, kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(*poolRef);
        *poolRef = NULL;
    }

    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        (id)kCVPixelBufferPoolMaximumBufferAgeKey: @1.0
    };

    NSDictionary *bufferAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        (__bridge CFDictionaryRef)bufferAttrs, poolRef);

    if (status != kCVReturnSuccess) {
        MP_ERR(vo, "Failed to create %s pool: %d\n", name, status);
        return false;
    }

    *cached_w = w;
    *cached_h = h;
    if (cached_fmt)
        *cached_fmt = format;

    MP_VERBOSE(vo, "Created %s pool: %dx%d format=%d\n", name, w, h, (int)format);
    return true;
}


bool avf_create_output_pool(struct vo *vo, int w, int h, OSType outputFormat)
{
    struct priv *p = vo->priv;

    return avf_create_pixel_buffer_pool(vo, &p->outputPool, &p->output_pool_w,
        &p->output_pool_h, &p->output_pool_format, w, h, outputFormat,
        "composite output");
}

static void tag_pixel_buffer_color_metadata(CVPixelBufferRef pixbuf,
                                            const struct mp_image_params *params)
{
    avf_tag_color_metadata(pixbuf, &params->color, params->repr.sys, params->chroma_location);
    avf_tag_geometry(pixbuf, params->p_w, params->p_h,
                     params->crop.x0, params->crop.y0, params->crop.x1, params->crop.y1);
    // Rotation/vertical flip are consumed by mpv's autorotate filter before
    // this VO (which deliberately does not advertise VO_CAP_ROTATE90).
}

void avf_restore_dolby_vision_transfer(CVPixelBufferRef pixbuf,
                                          const struct mp_image_params *params)
{
    if (!pixbuf || params->repr.sys != PL_COLOR_SYSTEM_DOLBYVISION)
        return;
    if (!CVBufferGetAttachment(pixbuf, CFSTR("DolbyVisionRPUData"), NULL) ||
        CVBufferGetAttachment(pixbuf, kCVImageBufferTransferFunctionKey, NULL))
        return;

    CFStringRef transfer = get_cv_transfer_function(params->color.transfer);
    if (transfer) {
        CVBufferSetAttachment(pixbuf, kCVImageBufferTransferFunctionKey,
                              transfer, kCVAttachmentMode_ShouldPropagate);
    }
}

void avf_tag_pixel_buffer_pixel_aspect(struct vo *vo, CVPixelBufferRef pixbuf)
{
    if (!pixbuf || !vo->params)
        return;

    int p_w = vo->params->p_w;
    int p_h = vo->params->p_h;
    size_t bw = CVPixelBufferGetWidth(pixbuf);
    size_t bh = CVPixelBufferGetHeight(pixbuf);

    // Only coded-size passthrough, upload, and frame-space composites carry
    // source sample aspect. Display-shaped, vo_get_src_dst_rects-letterboxed
    // buffers already have square pixels; avoid double correction.
    bool coded_size = bw == (size_t)vo->params->w && bh == (size_t)vo->params->h &&
                      is_biplanar_yuv_format(CVPixelBufferGetPixelFormatType(pixbuf));

    if (coded_size && p_w > 0 && p_h > 0 && p_w != p_h) {
        NSDictionary *par = @{
            (id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey: @(p_w),
            (id)kCVImageBufferPixelAspectRatioVerticalSpacingKey: @(p_h)
        };
        CVBufferSetAttachment(pixbuf, kCVImageBufferPixelAspectRatioKey,
                              (__bridge CFDictionaryRef)par,
                              kCVAttachmentMode_ShouldPropagate);
    } else {
        // Square pixels or recycled buffer: remove stale attachment.
        CVBufferRemoveAttachment(pixbuf, kCVImageBufferPixelAspectRatioKey);
    }
}

// Upload to NV12/P010-family biplanar buffers. Display pipeline reliably
// supports these; tri-planar y420 lacks shipping AVSampleBufferDisplayLayer
// users and fast subtitle blending. Interleave planar sources during upload
// copy.
static OSType get_cv_pixel_format(int imgfmt)
{
    if (imgfmt == IMGFMT_NV12 || imgfmt == IMGFMT_420P)
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (imgfmt == IMGFMT_P010 || imgfmt == imgfmt_420p10() ||
        imgfmt == imgfmt_420p12())
        return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    return 0;
}

// Create upload pool.
static bool create_sw_upload_pool(struct vo *vo, int w, int h, OSType format)
{
    struct priv *p = vo->priv;
    return avf_create_pixel_buffer_pool(vo, &p->swUploadPool, &p->sw_pool_w,
        &p->sw_pool_h, &p->sw_pool_format, w, h, format, "software upload");
}

void avf_clear_sw_upload_metadata(struct priv *p)
{
    if (p->sw_upload_attachments)
        CFRelease(p->sw_upload_attachments);
    p->sw_upload_attachments = NULL;
}

static void tag_sw_upload_metadata(struct vo *vo, CVPixelBufferRef pixbuf,
                                    const struct mp_image_params *params)
{
    struct priv *p = vo->priv;
    struct mp_image_params stable = *params;
    // Software Dolby Vision is rejected before upload. Never keep decoder-owned
    // metadata pointers in a cache that can outlive the input image.
    stable.repr.dovi = NULL;
    stable.imgfmt_name = NULL;
    OSType format = CVPixelBufferGetPixelFormatType(pixbuf);
    if (p->sw_upload_attachments && p->sw_upload_metadata_format == format &&
        mp_image_params_equal(&p->sw_upload_params, &stable)) {
        CVBufferSetAttachments(pixbuf, p->sw_upload_attachments,
                               kCVAttachmentMode_ShouldPropagate);
        return;
    }

    tag_pixel_buffer_color_metadata(pixbuf, params);
    CFDictionaryRef attachments = CVBufferGetAttachments(pixbuf, kCVAttachmentMode_ShouldPropagate);
    // The composite can remove per-frame HDR tags from this buffer in place.
    // Keep an immutable snapshot so the next upload restores the original tags.
    CFDictionaryRef snapshot = attachments ? CFDictionaryCreateCopy(NULL, attachments) : NULL;
    avf_clear_sw_upload_metadata(p);
    p->sw_upload_attachments = snapshot;
    p->sw_upload_params = stable;
    p->sw_upload_metadata_format = format;
}

// 16-bit copy, LSB->MSB shift: yuv420p10/12 -> P010.
static void copy_shift_u16_row(uint16_t *dst, const uint16_t *src, size_t n,
                               int shift)
{
    size_t x = 0;
#if defined(__aarch64__)
    int16x8_t vshift = vdupq_n_s16(shift);
    for (; x + 8 <= n; x += 8)
        vst1q_u16(dst + x, vshlq_u16(vld1q_u16(src + x), vshift));
#endif
    for (; x < n; x++)
        dst[x] = src[x] << shift;
}

// Interleave 16-bit U/V and shift; libyuv I010ToP010 semantics.
static void interleave_shift_uv_row_u16(uint16_t *dst, const uint16_t *u,
                                        const uint16_t *v, size_t n, int shift)
{
    size_t x = 0;
#if defined(__aarch64__)
    int16x8_t vshift = vdupq_n_s16(shift);
    for (; x + 8 <= n; x += 8) {
        uint16x8x2_t uv = {{
            vshlq_u16(vld1q_u16(u + x), vshift),
            vshlq_u16(vld1q_u16(v + x), vshift),
        }};
        vst2q_u16(dst + 2 * x, uv);
    }
#endif
    for (; x < n; x++) {
        dst[2 * x + 0] = u[x] << shift;
        dst[2 * x + 1] = v[x] << shift;
    }
}

// Interleave 8-bit U/V: yuv420p -> NV12.
static void interleave_uv_row_u8(uint8_t *dst, const uint8_t *u,
                                 const uint8_t *v, size_t n)
{
    size_t x = 0;
#if defined(__aarch64__)
    for (; x + 16 <= n; x += 16) {
        uint8x16x2_t uv = {{ vld1q_u8(u + x), vld1q_u8(v + x) }};
        vst2q_u8(dst + 2 * x, uv);
    }
#endif
    for (; x < n; x++) {
        dst[2 * x + 0] = u[x];
        dst[2 * x + 1] = v[x];
    }
}

// yuv420p10/12 (LSB-aligned planar) -> locked P010-layout ('x420') buffer.
void avf_upload_420p1x_to_p010(struct mp_image *mpi, CVPixelBufferRef pixbuf,
                                  int shift)
{
    int w = mpi->w, h = mpi->h;
    int cw = (w + 1) / 2, ch = (h + 1) / 2;

    uint8_t *dst_y = CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
    size_t dst_y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
    for (int y = 0; y < h; y++) {
        copy_shift_u16_row((uint16_t *)(dst_y + y * dst_y_stride),
                           (const uint16_t *)(mpi->planes[0] + y * mpi->stride[0]),
                           w, shift);
    }

    uint8_t *dst_uv = CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
    size_t dst_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);
    for (int y = 0; y < ch; y++) {
        interleave_shift_uv_row_u16(
            (uint16_t *)(dst_uv + y * dst_uv_stride),
            (const uint16_t *)(mpi->planes[1] + y * mpi->stride[1]),
            (const uint16_t *)(mpi->planes[2] + y * mpi->stride[2]),
            cw, shift);
    }
}

// yuv420p (planar) -> locked NV12 ('420v') buffer.
static void upload_420p_to_nv12(struct mp_image *mpi, CVPixelBufferRef pixbuf)
{
    int w = mpi->w, h = mpi->h;
    int cw = (w + 1) / 2, ch = (h + 1) / 2;

    uint8_t *dst_y = CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
    size_t dst_y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
    if (dst_y_stride == (size_t)mpi->stride[0]) {
        memcpy(dst_y, mpi->planes[0], dst_y_stride * h);
    } else {
        for (int y = 0; y < h; y++) {
            memcpy(dst_y + y * dst_y_stride,
                   mpi->planes[0] + y * mpi->stride[0], w);
        }
    }

    uint8_t *dst_uv = CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
    size_t dst_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);
    for (int y = 0; y < ch; y++) {
        interleave_uv_row_u8(dst_uv + y * dst_uv_stride,
                             mpi->planes[1] + y * mpi->stride[1],
                             mpi->planes[2] + y * mpi->stride[2],
                             cw);
    }
}

// Upload software frame to CVPixelBuffer.
CVPixelBufferRef avf_upload_software_frame(struct vo *vo, struct mp_image *mpi)
{
    struct priv *p = vo->priv;

    // CoreVideo has no equivalent tag for BT.2020 CL or ICtCp. Refuse an
    // upload that would silently mislabel their samples as ordinary YCbCr.
    if (!get_cv_ycbcr_matrix(mpi->params.repr.sys) ||
        !get_cv_color_primaries(mpi->params.color.primaries) ||
        !get_cv_transfer_function(mpi->params.color.transfer)) {
        MP_ERR(vo, "MPVUI_NATIVE_VIDEO_UNSUPPORTED: software color signal cannot be represented by CoreVideo metadata\n");
        return NULL;
    }
    OSType cvFormat = get_cv_pixel_format(mpi->imgfmt);
    if (mpi->params.repr.levels == PL_COLOR_LEVELS_FULL) {
        if (is_nv12_format(cvFormat))
            cvFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        else if (is_p010_format(cvFormat))
            cvFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    }
    if (!cvFormat) {
        MP_ERR(vo, "Unsupported software format: %d\n", mpi->imgfmt);
        return NULL;
    }

    int w = mpi->w;
    int h = mpi->h;

    if (!create_sw_upload_pool(vo, w, h, cvFormat))
        return NULL;

    CVPixelBufferRef pixbuf = NULL;
    CVReturn status = avf_pool_get_buffer_for_frame(vo, p->swUploadPool,
                                                  &p->swUploadReservePool, &pixbuf);

    if (status != kCVReturnSuccess || !pixbuf) {
        MP_ERR(vo, "Failed to get upload buffer: %d\n", status);
        return NULL;
    }

    CVBufferRemoveAllAttachments(pixbuf);
    if (CVPixelBufferLockBaseAddress(pixbuf, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixbuf);
        return NULL;
    }

    size_t planeCount = CVPixelBufferGetPlaneCount(pixbuf);

    if (mpi->imgfmt == IMGFMT_420P) {
        upload_420p_to_nv12(mpi, pixbuf);
    } else if (mpi->imgfmt == imgfmt_420p10()) {
        avf_upload_420p1x_to_p010(mpi, pixbuf, 6);
    } else if (mpi->imgfmt == imgfmt_420p12()) {
        // P010 keeps two extra low bits below 10-bit display precision;
        // harmless, matching libyuv.
        avf_upload_420p1x_to_p010(mpi, pixbuf, 4);
    } else if (planeCount == 0) {
        // Non-planar format
        void *dst = CVPixelBufferGetBaseAddress(pixbuf);
        size_t dstStride = CVPixelBufferGetBytesPerRow(pixbuf);
        size_t srcStride = mpi->stride[0];

        // Matching strides: one memcpy.
        if (dstStride == srcStride) {
            memcpy(dst, mpi->planes[0], dstStride * h);
        } else {
            size_t copyBytes = MPMIN(dstStride, srcStride);
            for (int y = 0; y < h; y++) {
                memcpy((uint8_t *)dst + y * dstStride,
                       mpi->planes[0] + y * srcStride,
                       copyBytes);
            }
        }
    } else {
        // Source/destination plane layouts match: NV12/P010.
        for (size_t plane = 0; plane < planeCount && plane < MP_MAX_PLANES; plane++) {
            void *dst = CVPixelBufferGetBaseAddressOfPlane(pixbuf, plane);
            size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, plane);
            size_t dstHeight = CVPixelBufferGetHeightOfPlane(pixbuf, plane);

            uint8_t *src = mpi->planes[plane];
            size_t srcStride = mpi->stride[plane];

            if (!src)
                continue;

            // Matching strides: one memcpy.
            if (dstStride == srcStride) {
                memcpy(dst, src, dstStride * dstHeight);
            } else {
                size_t copyBytes = MPMIN(dstStride, srcStride);
                for (size_t y = 0; y < dstHeight; y++) {
                    memcpy((uint8_t *)dst + y * dstStride,
                           src + y * srcStride,
                           copyBytes);
                }
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(pixbuf, 0);
    tag_sw_upload_metadata(vo, pixbuf, &mpi->params);

    return pixbuf;
}
