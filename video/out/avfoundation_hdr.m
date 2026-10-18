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

#include "vo_avfoundation_priv.h"

// Emit stable host signal before incompatible sample enqueue; host reloads
// media through existing Metal/libplacebo output.
void avf_report_unsupported_dovi(struct vo *vo, const char *reason)
{
    struct priv *p = vo->priv;
    if (!p->dovi_unsupported_logged) {
        MP_ERR(vo, "MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED: %s\n", reason);
        p->dovi_unsupported_logged = true;
    }
}

bool avf_validate_native_dovi_frame(struct vo *vo, struct mp_image *mpi,
                                       CVPixelBufferRef pixbuf)
{
    struct priv *p = vo->priv;
    CFTypeRef converted = pixbuf ? CVBufferGetAttachment(pixbuf,
        CFSTR("MPVUI.NativeDolbyVisionProfile7To81"), NULL) : NULL;
    // Converted DV still requires native session identity and decoder RPU,
    // even without container color tags.
    if (converted && (!CFEqual(converted, kCFBooleanTrue) ||
                      !p->opts->native_dovi_profile7)) {
        avf_report_unsupported_dovi(vo, "P7 conversion was not explicitly enabled for this output");
        return false;
    }
    if (mpi->params.repr.sys != PL_COLOR_SYSTEM_DOLBYVISION && !converted)
        return true;
    if (mpi->imgfmt != IMGFMT_VIDEOTOOLBOX) {
        avf_report_unsupported_dovi(vo, "software Dolby Vision needs libplacebo reshaping");
        return false;
    }
    CFTypeRef native = CVBufferGetAttachment(pixbuf,
        CFSTR("MPVUI.NativeDolbyVisionSession"), NULL);
    CFTypeRef rpu = CVBufferGetAttachment(pixbuf, CFSTR("DolbyVisionRPUData"), NULL);
    if (!native || !CFEqual(native, kCFBooleanTrue) || !rpu ||
        CFGetTypeID(rpu) != CFDataGetTypeID() || CFDataGetLength((CFDataRef)rpu) == 0) {
        struct priv *p = vo->priv;
        if (!p->dovi_unsupported_logged) {
            CFTypeRef primaries = CVBufferGetAttachment(pixbuf, kCVImageBufferColorPrimariesKey, NULL);
            CFTypeRef transfer = CVBufferGetAttachment(pixbuf, kCVImageBufferTransferFunctionKey, NULL);
            CFTypeRef matrix = CVBufferGetAttachment(pixbuf, kCVImageBufferYCbCrMatrixKey, NULL);
            bool rpu_data = rpu && CFGetTypeID(rpu) == CFDataGetTypeID();
            MP_VERBOSE(vo, "Native Dolby Vision metadata: marker=%s RPU=%s "
                           "RPUtype=%lu expectedDataType=%lu RPUbytes=%ld "
                           "pixelFormat=%08x primaries=%s transfer=%s matrix=%s\n",
                       native && CFEqual(native, kCFBooleanTrue) ? "yes" : "no",
                       rpu ? "present" : "absent",
                       rpu ? (unsigned long)CFGetTypeID(rpu) : 0,
                       (unsigned long)CFDataGetTypeID(),
                       rpu_data ? (long)CFDataGetLength((CFDataRef)rpu) : -1L,
                       (unsigned int)CVPixelBufferGetPixelFormatType(pixbuf),
                       primaries ? [[(__bridge id)primaries description] UTF8String] : "unset",
                       transfer ? [[(__bridge id)transfer description] UTF8String] : "unset",
                       matrix ? [[(__bridge id)matrix description] UTF8String] : "unset");
        }
        avf_report_unsupported_dovi(vo, "decoder supplied no validated native Dolby Vision sample metadata");
        return false;
    }
    int profile = -1, compatibility = -1;
    CFTypeRef profile_value = CVBufferGetAttachment(pixbuf,
        CFSTR("MPVUI.NativeDolbyVisionSessionProfile"), NULL);
    CFTypeRef compatibility_value = CVBufferGetAttachment(pixbuf,
        CFSTR("MPVUI.NativeDolbyVisionSessionCompatibility"), NULL);
    if (profile_value && CFGetTypeID(profile_value) == CFNumberGetTypeID())
        CFNumberGetValue(profile_value, kCFNumberIntType, &profile);
    if (compatibility_value && CFGetTypeID(compatibility_value) == CFNumberGetTypeID())
        CFNumberGetValue(compatibility_value, kCFNumberIntType, &compatibility);
    int state = (converted ? 20000 : 10000) + (profile + 1) * 100 + compatibility + 1;
    if (p->dovi_validated_state != state) {
        MP_INFO(vo, "MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=%s "
                    "session-profile=%d session-compatibility=%d\n",
                converted ? "yes" : "no", profile, compatibility);
        p->dovi_validated_state = state;
    }
    return true;
}

enum {
    AVF_VIVID_ABSENT = 0,
    AVF_VIVID_ACTIVE,
    AVF_VIVID_SKIPPED_DOVI,
    AVF_VIVID_SKIPPED_FORMAT,
    AVF_VIVID_UNSUPPORTED,
    AVF_VIVID_FAILED,
};

void avf_release_vivid(struct priv *p)
{
    [p->vividPipeline release];
    p->vividPipeline = nil;
    [p->vividQueue release];
    p->vividQueue = nil;
    [p->vividLut release];
    p->vividLut = nil;
    if (p->vividTextureCache) {
        CFRelease(p->vividTextureCache);
        p->vividTextureCache = NULL;
    }
    if (p->vividPool) {
        CVPixelBufferPoolRelease(p->vividPool);
        p->vividPool = NULL;
    }
    if (p->vividReservePool) {
        CVPixelBufferPoolRelease(p->vividReservePool);
        p->vividReservePool = NULL;
    }
    [p->vividDevice release];
    p->vividDevice = nil;
    p->vivid_lut_valid = false;
}

static bool ensure_vivid(struct vo *vo)
{
    struct priv *p = vo->priv;

    if (p->vividPipeline)
        return true;
    if (p->vivid_setup_failed)
        return false;
    p->vivid_setup_failed = true;
    p->vividDevice = MTLCreateSystemDefaultDevice();
    if (!p->vividDevice)
        return false;
    NSError *err = nil;
    id<MTLLibrary> lib = [p->vividDevice newLibraryWithSource:@(avf_vivid_metal_source)
                                                      options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"vivid_map"];
    if (fn)
        p->vividPipeline = [p->vividDevice newComputePipelineStateWithFunction:fn error:&err];
    [fn release];
    [lib release];
    if (!p->vividPipeline) {
        MP_ERR(vo, "HDR Vivid kernel failed: %s\n", err.localizedDescription.UTF8String);
        avf_release_vivid(p);
        return false;
    }
    p->vividQueue = [p->vividDevice newCommandQueue];
    p->vividLut = [p->vividDevice newBufferWithLength:sizeof(float) * AVF_VIVID_LUT_SIZE
                                              options:MTLResourceStorageModeShared];
    if (!p->vividQueue || !p->vividLut ||
        CVMetalTextureCacheCreate(NULL, NULL, p->vividDevice, NULL,
                                  &p->vividTextureCache) != kCVReturnSuccess) {
        avf_release_vivid(p);
        return false;
    }
    p->vivid_setup_failed = false;
    return true;
}

static struct avf_vivid_raw vivid_raw_from_av(const AVDynamicHDRVivid *v)
{
    const AVHDRVividColorTransformParams *w = &v->params[0];
    struct avf_vivid_raw r = {
        .min = w->minimum_maxrgb.num, .avg = w->average_maxrgb.num,
        .var = w->variance_maxrgb.num, .max = w->maximum_maxrgb.num,
        .tm_flag = w->tone_mapping_mode_flag, .tm_num = w->tone_mapping_param_num,
        .sat_flag = w->color_saturation_mapping_flag, .sat_num = w->color_saturation_num,
    };
    for (int i = 0; i < 2; i++) {
        const AVHDRVividColorToneMappingParams *t = &w->tm_params[i];
        r.tm[i] = (struct avf_vivid_raw_tm){
            .target = t->targeted_system_display_maximum_luminance.num,
            .base_flag = t->base_enable_flag,
            .m_p = t->base_param_m_p.num, .m_m = t->base_param_m_m.num,
            .m_a = t->base_param_m_a.num, .m_b = t->base_param_m_b.num,
            .m_n = t->base_param_m_n.num, .k1 = t->base_param_k1, .k2 = t->base_param_k2,
            .k3 = t->base_param_k3, .dmode = t->base_param_Delta_enable_mode,
            .delta = t->base_param_Delta.num,
            .spline_flag = t->three_Spline_enable_flag, .spline_num = t->three_Spline_num,
        };
        for (int j = 0; j < 2; j++) {
            const AVHDRVivid3SplineParams *sp = &t->three_spline[j];
            r.tm[i].spline[j] = (struct avf_vivid_raw_spline){sp->th_mode, sp->th_enable_mb.num,
                sp->th_enable.num, sp->th_delta1.num, sp->th_delta2.num, sp->enable_strength.num};
        }
    }
    for (int i = 0; i < 8; i++)
        r.sat_gain[i] = w->color_saturation_gain[i].num;
    return r;
}

static bool vivid_texture(struct priv *p, CVPixelBufferRef buf, int plane,
                          MTLPixelFormat format, CVMetalTextureRef *out)
{
    return CVMetalTextureCacheCreateTextureFromImage(NULL, p->vividTextureCache, buf, NULL,
        format, CVPixelBufferGetWidthOfPlane(buf, plane),
        CVPixelBufferGetHeightOfPlane(buf, plane), plane, out) == kCVReturnSuccess;
}

static int run_vivid(struct vo *vo, mp_image_t *mpi, CVPixelBufferRef src,
                     const AVDynamicHDRVivid *v, CVPixelBufferRef *out)
{
    struct priv *p = vo->priv;

    if (!ensure_vivid(vo))
        return AVF_VIVID_FAILED;
    struct avf_vivid_raw raw = vivid_raw_from_av(v);
    double peak = p->opts->vivid_peak, mastering = mpi->params.color.hdr.max_luma;
    OSType format = CVPixelBufferGetPixelFormatType(src);
    bool full = is_full_range_yuv_format(format);
    if (memcmp(&raw, &p->vivid_raw, sizeof(raw)) || peak != p->vivid_lut_peak ||
        mastering != p->vivid_lut_mastering || full != p->vivid_lut_full) {
        struct avf_vivid_curve c;
        p->vivid_lut_valid = avf_vivid_curve_init(&c, &raw, peak, mastering) &&
            avf_vivid_prepare(&c, &raw, full, p->vividLut.contents, &p->vivid_uniforms);
        p->vivid_raw = raw;
        p->vivid_lut_peak = peak;
        p->vivid_lut_mastering = mastering;
        p->vivid_lut_full = full;
        if (p->vivid_lut_valid)
            MP_DBG(vo, "HDR Vivid curve: peak=%.0f mastering=%.0f m_p=%.4f m_m=%.3f "
                     "m_a=%.4f m_b=%.4f TH3=%.4f splines=%d map(1)=%.4f\n", peak, mastering,
                     c.m_p, c.m_m, c.m_a, c.m_b, c.TH30, c.n_iv, avf_vivid_map(&c, 1.0));
    }
    if (!p->vivid_lut_valid)
        return AVF_VIVID_UNSUPPORTED;

    int w = (int)CVPixelBufferGetWidth(src), h = (int)CVPixelBufferGetHeight(src);
    CVPixelBufferRef dst = NULL;
    if (!avf_create_pixel_buffer_pool(vo, &p->vividPool, &p->vivid_pool_w, &p->vivid_pool_h,
                                  &p->vivid_pool_format, w, h, format, "HDR Vivid"))
        return AVF_VIVID_FAILED;
    CVReturn status = avf_pool_get_buffer_for_frame(vo, p->vividPool, &p->vividReservePool, &dst);
    // Mapping runs on the VO thread close to the frame's deadline, so at 4K60
    // there is no time left to wait for the layer to recycle a buffer; a few
    // extra buffers keep the frame mapped instead of showing it unmapped.
    if (status == kCVReturnWouldExceedAllocationThreshold) {
        int limit = avf_presentation_pool_limit(p->opts->queue_lead_ms,
            p->pool_frame_duration_ns, p->presentation_host) + 4;
        status = avf_pool_get_buffer_with_limit(p->vividPool,
            MPMIN(limit, AVF_POOL_MAX_BUFFERS), &dst);
    }
    // Failure reasons are logged once per run of failures, like the state.
    bool log_failure = p->vivid_state != AVF_VIVID_FAILED;
    if (status != kCVReturnSuccess) {
        if (log_failure)
            MP_WARN(vo, "HDR Vivid: no output buffer: %d\n", status);
        return AVF_VIVID_FAILED;
    }

    CVMetalTextureRef tex[4] = {0};
    bool ok = vivid_texture(p, src, 0, MTLPixelFormatR16Unorm, &tex[0]) &&
              vivid_texture(p, src, 1, MTLPixelFormatRG16Unorm, &tex[1]) &&
              vivid_texture(p, dst, 0, MTLPixelFormatR16Unorm, &tex[2]) &&
              vivid_texture(p, dst, 1, MTLPixelFormatRG16Unorm, &tex[3]);
    if (ok) {
        // ponytail: waits for the GPU on the VO thread; a ring of in-flight
        // frames if 4K60 misses its deadline.
        id<MTLCommandBuffer> cmd = [p->vividQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p->vividPipeline];
        for (int i = 0; i < 4; i++)
            [enc setTexture:CVMetalTextureGetTexture(tex[i]) atIndex:i];
        [enc setBytes:&p->vivid_uniforms length:sizeof(p->vivid_uniforms) atIndex:0];
        [enc setBuffer:p->vividLut offset:0 atIndex:1];
        NSUInteger tw = p->vividPipeline.threadExecutionWidth;
        NSUInteger th = MPMAX(p->vividPipeline.maxTotalThreadsPerThreadgroup / tw, 1);
        [enc dispatchThreads:MTLSizeMake(CVPixelBufferGetWidthOfPlane(src, 1),
                                         CVPixelBufferGetHeightOfPlane(src, 1), 1)
            threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [enc endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        ok = cmd.status == MTLCommandBufferStatusCompleted;
        if (!ok && log_failure)
            MP_WARN(vo, "HDR Vivid: GPU command failed: %s\n", cmd.error.localizedDescription.UTF8String);
    } else if (log_failure) {
        MP_WARN(vo, "HDR Vivid: Metal texture failed\n");
    }
    for (int i = 0; i < 4; i++) {
        if (tex[i])
            CFRelease(tex[i]);
    }
    if (!ok) {
        CVPixelBufferRelease(dst);
        return AVF_VIVID_FAILED;
    }

    // The output is HDR10 mastered for this display, so the system should not
    // tone map it again. Pooled buffers keep the last frame's attachments.
    CVBufferRemoveAllAttachments(dst);
    CVBufferPropagateAttachments(src, dst);
    struct pl_color_space color = mpi->params.color;
    if (color.hdr.prim.red.x <= 0)
        color.hdr.prim = *pl_raw_primaries_get(PL_COLOR_PRIM_BT_2020);
    if (color.hdr.prim.white.x <= 0)
        color.hdr.prim.white = pl_raw_primaries_get(PL_COLOR_PRIM_BT_2020)->white;
    color.hdr.max_luma = peak;
    color.hdr.min_luma = MPMIN(color.hdr.min_luma, peak / 2);
    color.hdr.max_cll = peak;
    color.hdr.max_fall = 0;
    avf_set_static_hdr_metadata(dst, &color);
    *out = dst;
    return AVF_VIVID_ACTIVE;
}

// Returns an owned P010 frame mapped for the display, or NULL to keep src.
CVPixelBufferRef avf_map_vivid_frame(struct vo *vo, mp_image_t *mpi, CVPixelBufferRef src)
{
    struct priv *p = vo->priv;

    const AVDynamicHDRVivid *v = NULL;
    for (int i = 0; i < mpi->num_ff_side_data && p->opts->vivid_peak > 0; i++) {
        if (mpi->ff_side_data[i].type == AV_FRAME_DATA_DYNAMIC_HDR_VIVID &&
            mpi->ff_side_data[i].buf->size >= sizeof(*v))
            v = (const AVDynamicHDRVivid *)mpi->ff_side_data[i].buf->data;
    }
    CVPixelBufferRef out = NULL;
    int state = !v ? AVF_VIVID_ABSENT
        : CVBufferGetAttachment(src, CFSTR("DolbyVisionRPUData"), NULL) ? AVF_VIVID_SKIPPED_DOVI
        : !is_p010_format(CVPixelBufferGetPixelFormatType(src)) ||
          mpi->params.color.transfer != PL_COLOR_TRC_PQ ? AVF_VIVID_SKIPPED_FORMAT
        : run_vivid(vo, mpi, src, v, &out);
    if (state != p->vivid_state) {
        const char *states[] = {"absent", "active", "skipped-dolby-vision", "skipped-not-pq-p010",
                                "unsupported-metadata", "failed"};
        MP_INFO(vo, "MPVUI_NATIVE_VIVID: %s (peak %.0f nits)\n", states[state], p->opts->vivid_peak);
        p->vivid_state = state;
    }
    return out;
}

enum {
    AVF_FEL_NONE = 0,
    AVF_FEL_COMPOSED,
    AVF_FEL_MEL,
    AVF_FEL_UNSUPPORTED,
    AVF_FEL_FAILED,
};

void avf_release_fel(struct priv *p)
{
    [p->felPipeline release];
    p->felPipeline = nil;
    [p->felQueue release];
    p->felQueue = nil;
    if (p->felTextureCache) {
        CFRelease(p->felTextureCache);
        p->felTextureCache = NULL;
    }
    CVPixelBufferPoolRef *pools[] = {&p->felPool, &p->felReservePool, &p->felElPool};
    for (int i = 0; i < 3; i++) {
        if (*pools[i]) {
            CVPixelBufferPoolRelease(*pools[i]);
            *pools[i] = NULL;
        }
    }
    [p->felDevice release];
    p->felDevice = nil;
}

static bool ensure_fel(struct vo *vo)
{
    struct priv *p = vo->priv;

    if (p->felPipeline)
        return true;
    if (p->fel_setup_failed)
        return false;
    p->fel_setup_failed = true;
    p->felDevice = MTLCreateSystemDefaultDevice();
    if (!p->felDevice)
        return false;
    NSError *err = nil;
    id<MTLLibrary> lib = [p->felDevice newLibraryWithSource:@(avf_fel_metal_source)
                                                    options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"fel_compose"];
    if (fn)
        p->felPipeline = [p->felDevice newComputePipelineStateWithFunction:fn error:&err];
    [fn release];
    [lib release];
    if (!p->felPipeline) {
        MP_ERR(vo, "Dolby Vision FEL kernel failed: %s\n", err.localizedDescription.UTF8String);
        avf_release_fel(p);
        return false;
    }
    p->felQueue = [p->felDevice newCommandQueue];
    if (!p->felQueue || CVMetalTextureCacheCreate(NULL, NULL, p->felDevice, NULL,
                                                  &p->felTextureCache) != kCVReturnSuccess) {
        avf_release_fel(p);
        return false;
    }
    p->fel_setup_failed = false;
    return true;
}

static bool fel_params_from_av(const AVDOVIMetadata *m, struct avf_fel_params *out)
{
    const AVDOVIRpuDataHeader *h = av_dovi_get_header(m);
    const AVDOVIDataMapping *map = av_dovi_get_mapping(m);
    if (map->nlq_method_idc != AV_DOVI_NLQ_LINEAR_DZ)
        return false;
    *out = (struct avf_fel_params){
        .bl_bits = h->bl_bit_depth, .el_bits = h->el_bit_depth,
        .denom = h->coef_log2_denom, .disable_residual = h->disable_residual_flag,
    };
    for (int c = 0; c < 3; c++) {
        const AVDOVIReshapingCurve *k = &map->curves[c];
        struct avf_fel_comp *o = &out->comp[c];
        o->num_pivots = k->num_pivots;
        memcpy(o->pivots, k->pivots, sizeof(o->pivots));
        for (int i = 0; i < 8; i++) {
            o->mapping_idc[i] = k->mapping_idc[i];
            o->poly_order[i] = k->poly_order[i];
            o->mmr_order[i] = k->mmr_order[i];
            o->mmr_constant[i] = k->mmr_constant[i];
        }
        memcpy(o->poly_coef, k->poly_coef, sizeof(o->poly_coef));
        memcpy(o->mmr_coef, k->mmr_coef, sizeof(o->mmr_coef));
        o->nlq_offset = map->nlq[c].nlq_offset;
        o->vdr_in_max = map->nlq[c].vdr_in_max;
        o->slope = map->nlq[c].linear_deadzone_slope;
        o->threshold = map->nlq[c].linear_deadzone_threshold;
    }
    return true;
}

static bool fel_texture(struct priv *p, CVPixelBufferRef buf, int plane, CVMetalTextureRef *out)
{
    return CVMetalTextureCacheCreateTextureFromImage(NULL, p->felTextureCache, buf, NULL,
        plane ? MTLPixelFormatRG16Unorm : MTLPixelFormatR16Unorm,
        CVPixelBufferGetWidthOfPlane(buf, plane), CVPixelBufferGetHeightOfPlane(buf, plane),
        plane, out) == kCVReturnSuccess;
}

// The EL as a P010 buffer: the VideoToolbox frame itself, or a software
// frame uploaded into its own pool (BL and EL sizes differ).
static CVPixelBufferRef fel_el_buffer(struct vo *vo, struct mp_image *el)
{
    struct priv *p = vo->priv;

    if (el->imgfmt == IMGFMT_VIDEOTOOLBOX) {
        CVPixelBufferRef buf = (CVPixelBufferRef)el->planes[3];
        return buf ? CVPixelBufferRetain(buf) : NULL;
    }
    CVPixelBufferRef buf = NULL;
    if (el->imgfmt != imgfmt_420p10() ||
        !avf_create_pixel_buffer_pool(vo, &p->felElPool, &p->fel_el_pool_w, &p->fel_el_pool_h,
                                  &p->fel_el_pool_format, el->w, el->h,
                                  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "FEL EL upload") ||
        avf_pool_get_buffer(p->felElPool, &buf) != kCVReturnSuccess)
        return NULL;
    if (CVPixelBufferLockBaseAddress(buf, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buf);
        return NULL;
    }
    avf_upload_420p1x_to_p010(el, buf, 6);
    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

static int run_fel(struct vo *vo, mp_image_t *mpi, CVPixelBufferRef bl, CVPixelBufferRef *out)
{
    struct priv *p = vo->priv;

    const AVDOVIMetadata *meta = NULL;
    for (int i = 0; i < mpi->num_ff_side_data; i++) {
        if (mpi->ff_side_data[i].type == AV_FRAME_DATA_DOVI_METADATA)
            meta = (const AVDOVIMetadata *)mpi->ff_side_data[i].buf->data;
    }
    struct avf_fel_params params;
    if (!meta || !fel_params_from_av(meta, &params))
        return AVF_FEL_UNSUPPORTED;
    if (!avf_fel_has_residual(&params))
        return AVF_FEL_MEL;
    struct mp_image *el = mpi->enhancement_layer;
    int w = (int)CVPixelBufferGetWidth(bl), h = (int)CVPixelBufferGetHeight(bl);
    bool half = el->w * 2 == w && el->h * 2 == h;
    struct avf_fel_uniforms u;
    if (!is_p010_format(CVPixelBufferGetPixelFormatType(bl)) || is_full_range_yuv_format(
            CVPixelBufferGetPixelFormatType(bl)) || (!half && (el->w != w || el->h != h)) ||
        !avf_fel_prepare(&params, half, &u))
        return AVF_FEL_UNSUPPORTED;
    if (!ensure_fel(vo))
        return AVF_FEL_FAILED;

    CVPixelBufferRef elbuf = fel_el_buffer(vo, el), dst = NULL;
    if (!elbuf || !is_p010_format(CVPixelBufferGetPixelFormatType(elbuf)) ||
        !avf_create_pixel_buffer_pool(vo, &p->felPool, &p->fel_pool_w, &p->fel_pool_h,
                                  &p->fel_pool_format, w, h,
                                  CVPixelBufferGetPixelFormatType(bl), "FEL output") ||
        avf_pool_get_buffer_for_frame(vo, p->felPool, &p->felReservePool, &dst) != kCVReturnSuccess) {
        CVPixelBufferRelease(elbuf);
        return AVF_FEL_FAILED;
    }

    CVMetalTextureRef tex[6] = {0};
    CVPixelBufferRef bufs[3] = {bl, elbuf, dst};
    bool ok = true;
    for (int i = 0; i < 6 && ok; i++)
        ok = fel_texture(p, bufs[i / 2], i % 2, &tex[i]);
    if (ok) {
        // ponytail: waits for the GPU on the VO thread like the Vivid kernel;
        // pipeline frames if 4K60 misses its deadline.
        id<MTLCommandBuffer> cmd = [p->felQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p->felPipeline];
        for (int i = 0; i < 6; i++)
            [enc setTexture:CVMetalTextureGetTexture(tex[i]) atIndex:i];
        [enc setBytes:&u length:sizeof(u) atIndex:0];
        NSUInteger tw = p->felPipeline.threadExecutionWidth;
        NSUInteger th = MPMAX(p->felPipeline.maxTotalThreadsPerThreadgroup / tw, 1);
        [enc dispatchThreads:MTLSizeMake(CVPixelBufferGetWidthOfPlane(bl, 1),
                                         CVPixelBufferGetHeightOfPlane(bl, 1), 1)
            threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [enc endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        ok = cmd.status == MTLCommandBufferStatusCompleted;
    }
    for (int i = 0; i < 6; i++) {
        if (tex[i])
            CFRelease(tex[i]);
    }
    CVPixelBufferRelease(elbuf);
    if (!ok) {
        CVPixelBufferRelease(dst);
        return AVF_FEL_FAILED;
    }
    // The BL's attachments describe the composed frame too: the decoder's
    // Profile 7 conversion left a P8.1 RPU with identity reshaping, which is
    // what a composed frame needs (a no-op RPU). Pooled buffers
    // keep the last frame's attachments.
    CVBufferRemoveAllAttachments(dst);
    CVBufferPropagateAttachments(bl, dst);
    *out = dst;
    return AVF_FEL_COMPOSED;
}

// Returns an owned composed frame, or NULL to keep the base layer.
CVPixelBufferRef avf_compose_fel_frame(struct vo *vo, mp_image_t *mpi, CVPixelBufferRef bl)
{
    struct priv *p = vo->priv;

    CVPixelBufferRef out = NULL;
    int state = mpi->enhancement_layer ? run_fel(vo, mpi, bl, &out) : AVF_FEL_NONE;
    if (state != p->fel_state && (state != AVF_FEL_NONE || p->fel_state == AVF_FEL_COMPOSED)) {
        const char *states[] = {"no-enhancement-layer", "composed", "mel", "unsupported", "failed"};
        MP_INFO(vo, "MPVUI_NATIVE_DOLBY_VISION_FEL: %s\n", states[state]);
    }
    p->fel_state = state;
    return out;
}
