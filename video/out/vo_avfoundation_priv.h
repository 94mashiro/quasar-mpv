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

// Shared by the vo_avfoundation*.m / avfoundation_*.m files: state, options, small
// helpers and the functions one file calls in another.

#pragma once

#include <math.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <limits.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/pixfmt.h>
#include "common/common.h"
#include "options/m_config.h"
#include "options/m_option.h"
#include "osdep/timer.h"
#include "vo.h"
#include "video/fmt-conversion.h"
#include "video/mp_image.h"
#include "video/hwdec.h"
#include "sub/osd.h"
#include "avfoundation_color.h"
#include "avfoundation_hdr10plus.h"
#include <libavutil/dovi_meta.h>
#include <libavutil/hdr_dynamic_vivid_metadata.h>

#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#include <pthread.h>
#include "avfoundation_vivid.h"
#include "avfoundation_fel.h"

struct avf_render_geometry {
    int w, h;
    struct mp_rect src, dst;
    struct mp_osd_res osd_res;
};

enum avf_osd_draw_path {
    AVF_OSD_DRAW_NONE = 0,
    AVF_OSD_DRAW_DIRECT_LIBASS,
    AVF_OSD_DRAW_DIRECT_BGRA,
    AVF_OSD_DRAW_COREGRAPHICS,
};

// Sample timing modes.
//
// Host: frame->pts carries mpv's scheduled display time; host timebase runs
// at 1.0. Audio-slaved scheduling absorbs clock skew through microsecond
// frame adjustments; VO accumulates no timing state. Layer cannot pause
// itself: queued frames may continue for queue-lead-ms.
//
// Media: container PTS uses anchored, rate-servoed timebase following mpv.
// Required for PiP's time/rate UI. Clock-domain error needs rate slewing or
// visible re-anchor snap (plezy#1776).
enum avf_presentation_mode {
    AVF_PRESENTATION_MEDIA = 0,
    AVF_PRESENTATION_HOST = 1,
};

struct avfoundation_opts {
    int native_dovi_profile7;
    bool composite_osd;
    bool pip_composite_osd;
    int queue_lead_ms;
    int presentation;
    int osd_max_height;
    double subtitle_luminance;
    double subtitle_edr_gain;
    double vivid_peak;
    bool osd_video_res;
    int osd_layer;
};

// --- avf sync servo core (host-testable; keep freestanding) ---
// mpv normally follows audio clock; CMTimebase follows CoreMedia host clock.
// HDMI PLLs, route changes, and temperature shift their skew. Fixed-rate
// drift accumulates; >=20ms re-anchor snaps repeat, skip, or drop frames
// (#1776).
//
// PI servo retires small errors over AVF_SERVO_HORIZON_NS through invisible
// microsecond deadline shifts. Integral absorbs constant clock/rate mismatch,
// avoiding mismatch * horizon residual. Hard-anchor only timestamp breaks,
// speed changes, or audio-clock steps after route changes.

// Above threshold: hard-anchor. At slew cap, 50ms correction takes >3s
// visibly out of sync; mpv hard-resyncs at this scale.
#define AVF_DRIFT_SNAP_NS      MP_TIME_MS_TO_NS(50)
// Servo time constant: error retirement horizon.
#define AVF_SERVO_HORIZON_NS   MP_TIME_S_TO_NS(2)
// Correction cap: +-1.5% of nominal rate.
#define AVF_SERVO_MAX_OFFSET   0.015
// Skip updates <100ppm: ~0.2ms steady-state error, less CoreMedia churn.
#define AVF_SERVO_MIN_DELTA    0.0001
// Minimum update interval: ~1/10 horizon; throttling stays stable.
#define AVF_SERVO_UPDATE_NS    MP_TIME_MS_TO_NS(200)
// Integral constant = 4x horizon: critical damping, poles (s + 1/(2T))^2.
// Larger absorbs mismatch slower; smaller rings.
#define AVF_SERVO_INTEGRAL_NS  (4 * AVF_SERVO_HORIZON_NS)
// Average timestamp quantization over frame time. Denominator: mpv's
// speed-adjusted frame duration. Host deadlines include audio-clock jitter,
// stalls, and A/V corrections unrelated to playback speed.
#define AVF_RATE_WINDOW_NS        MP_TIME_MS_TO_NS(500)
#define AVF_RATE_MIN              0.05
#define AVF_RATE_MAX              8.0
#define AVF_RATE_CHANGE_FRACTION  0.01
#define AVF_RATE_FAST_FRACTION    0.04
#define AVF_RATE_FAST_SAMPLES     2

// Compare media deltas with speed-adjusted frame durations; ignore scheduling
// jitter.
struct avf_rate_est {
    int64_t last_media_pts_ns;
    int64_t last_frame_duration_ns;
    bool last_sample_valid;
    // Steady-state drift window.
    int64_t media_span_ns;
    int64_t real_span_ns;
    // Large-change confirmation window.
    int64_t fast_media_span_ns;
    int64_t fast_real_span_ns;
    int fast_sample_count;
};

@class QuasarSubtitleLayer;

struct priv {
    struct mp_hwdec_ctx hwctx;
    struct m_config_cache *opts_cache;
    struct avfoundation_opts *opts;
    // Latch mode at preinit. Ignore runtime changes: switching would reseed
    // timebase under queued samples.
    bool presentation_host;

    struct mp_image *next_image;
    double next_pts;
    CMTimebaseRef timebase;
    int64_t next_present_host_ns;
    int64_t next_media_pts_ns;
    bool next_media_pts_valid;
    double next_timebase_rate;
    bool next_timebase_rate_valid;
    __strong AVSampleBufferDisplayLayer *displayLayer;

    // Timed OSD/subtitles over untouched (Dolby Vision) frames.
    QuasarSubtitleLayer *osdLayer;
    int64_t osd_change_id;
    int osd_w, osd_h;
    struct mp_osd_res osd_res;
    struct avf_render_geometry render_geometry;
    bool render_geometry_valid;
    CVPixelBufferPoolRef osdPool;
    int osd_pool_w, osd_pool_h;
    bool osd_needs_enqueue;

    // Track dirty rect per IOSurface; recycled pool buffers retain pixels,
    // with this code as sole writer. Clear touched rows only. CFRetain pins
    // identity against pointer reuse.
    struct osd_buf_state {
        IOSurfaceRef surf;     // CFRetained
        struct mp_rect dirty;  // last drawn region
        int64_t last_used_ns;
    } osd_buf_states[4];
    int osd_buf_state_count;

    // OSD counters always accumulate; format logs only with -v.
    struct {
        int renders, skipped, empty, frames;
        int64_t total_ns, max_ns;
        int64_t clear_ns, blend_ns, cg_ns, bounds_ns;
        int64_t enqueue_ns, video_sample_ns, wait_ns;
        // OSD lead = sample PTS minus timebase at enqueue. Negative/small
        // lead signals CPU missed deadline.
        int enq_count, enq_drops;
        int64_t lead_sum_ns, lead_min_ns;
        int64_t last_spike_ns;
    } perf;

    // Compositing mode.
    __strong id<MTLDevice> mtlDevice;
    __strong CIContext *ciContext;
    CVPixelBufferPoolRef outputPool;
    CVPixelBufferPoolRef outputReservePool;
    int output_pool_w, output_pool_h;
    OSType output_pool_format;
    CVPixelBufferRef cachedSubtitleBuffer;
    struct avf_subtitle_image_cache subtitleImageCache;
    bool overlay_matrix_valid;
    enum pl_color_primaries overlay_matrix_primaries;
    double overlay_rgb_matrix[3][3];
    int subtitle_x0, subtitle_y0, subtitle_x1, subtitle_y1;
    bool has_subtitle;

    // Software upload.
    CVPixelBufferPoolRef swUploadPool;
    CVPixelBufferPoolRef swUploadReservePool;
    int64_t pool_frame_duration_ns;
    int sw_pool_w, sw_pool_h;
    OSType sw_pool_format;
    CFDictionaryRef sw_upload_attachments;
    struct mp_image_params sw_upload_params;
    OSType sw_upload_metadata_format;

    // Cache format description; rebuild when dimensions, format, or
    // attachments change.
    CMVideoFormatDescriptionRef video_format_desc;
    CFDictionaryRef video_format_attachments;

    // Maintenance frame counter.
    int frame_count;
    int not_ready_drop_count;
    int64_t last_not_ready_drop_ns;
    int64_t last_display_recovery_ns;
    int64_t last_video_enqueue_ns;
    int64_t last_media_pts_ns;
    bool last_media_pts_valid;
    bool timebase_anchor_valid;
    bool timebase_paused;
    bool playback_paused;
    double timebase_rate;
    // Applied CMTimebase rate = timebase_rate + avf_servo_rate() drift
    // correction.
    double timebase_applied_rate;
    int64_t last_rate_update_ns;
    // PI state; zero on hard anchor.
    double servo_integral;
    int64_t last_servo_eval_ns;
    struct avf_rate_est rate_est;

    // Pacing diagnostics, ~5s intervals.
    int64_t diag_window_start_ns;
    int diag_wait_count;
    int64_t diag_wait_total_ns;
    int diag_drop_count;
    int diag_anchor_count;
    int diag_rate_update_count;
    // Peak absolute scheduling error per window.
    int64_t diag_drift_peak_ns;

    // OSD callback ran this frame.
    bool osd_callback_invoked;

    // Current frame carries a Dolby Vision RPU; its pixels must stay
    // untouched, so subtitles go to osdLayer instead.
    bool frame_dovi;
    bool osd_layer_active;
    bool osd_layer_failed; // Metal setup failed; don't retry every frame

    // Previous frame used Core Image geometry; restore layer when zoom
    // resets.
    bool applied_geometry_last_frame;

    // Suppress repeated geometry-failure logs.
    bool geometry_render_failure_logged;

    // Log Dolby Vision geometry refusal once.
    bool dovi_geometry_skip_logged;
    bool dovi_unsupported_logged;
    int dovi_validated_state;
    int hdr10plus_state;
    struct voctrl_native_video_statistics video_statistics;

    // HDR Vivid mapping (avfoundation_vivid.h). The LUT is rebuilt only when
    // the frame's metadata or the target changes.
    id<MTLDevice> vividDevice;
    id<MTLCommandQueue> vividQueue;
    id<MTLComputePipelineState> vividPipeline;
    id<MTLBuffer> vividLut;
    CVMetalTextureCacheRef vividTextureCache;
    CVPixelBufferPoolRef vividPool;
    CVPixelBufferPoolRef vividReservePool;
    int vivid_pool_w, vivid_pool_h;
    OSType vivid_pool_format;
    bool vivid_setup_failed;
    bool vivid_lut_valid;
    struct avf_vivid_raw vivid_raw;
    double vivid_lut_peak, vivid_lut_mastering;
    bool vivid_lut_full;
    struct avf_vivid_uniforms vivid_uniforms;
    int vivid_state;

    // Dolby Vision Profile 7 FEL composition (avfoundation_fel.h).
    id<MTLDevice> felDevice;
    id<MTLCommandQueue> felQueue;
    id<MTLComputePipelineState> felPipeline;
    CVMetalTextureCacheRef felTextureCache;
    CVPixelBufferPoolRef felPool, felReservePool, felElPool;
    int fel_pool_w, fel_pool_h, fel_el_pool_w, fel_el_pool_h;
    OSType fel_pool_format, fel_el_pool_format;
    bool fel_setup_failed;
    int fel_state;

    // Log resized-composite rejection once.
    bool composite_size_mismatch_logged;

};

static inline bool should_composite_into_video(struct priv *p)
{
    return true;
}

static inline bool should_use_inline_osd_layer(struct priv *p)
{
    return p->frame_dovi || p->opts->osd_layer == 1;
}


// Frame-space OSD: PiP presents samples directly and sizes its window from
// them. Subtitles have no surrounding window margin.
static inline bool should_use_frame_space_osd(struct priv *p)
{
    return true;
}

static inline bool should_apply_video_geometry(struct vo *vo)
{
    struct priv *p = vo->priv;
    struct mp_vo_opts *opts = vo->opts;
    // Frame space has no window for zoom/pan; geometry rendering would resize
    // PiP's source samples.
    if (should_use_frame_space_osd(p))
        return false;
    // Core Image handles per-frame geometry only. Panscan/aspect overrides
    // use sample-buffer/videoGravity path.
    return opts && (fabsf(opts->zoom) > 0.0001f ||
                    fabsf(opts->pan_x) > 0.0001f ||
                    fabsf(opts->pan_y) > 0.0001f ||
                    fabsf(opts->scale_x - 1.0f) > 0.0001f ||
                    fabsf(opts->scale_y - 1.0f) > 0.0001f);
}

static inline bool is_p010_format(OSType format)
{
    return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

static inline bool is_nv12_format(OSType format)
{
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

static inline bool is_biplanar_yuv_format(OSType format)
{
    return is_nv12_format(format) || is_p010_format(format);
}

static inline bool is_full_range_yuv_format(OSType format)
{
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
           format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

// Planar 10/12-bit 4:2:0 from dav1d/FFmpeg AV1/HEVC lacks named IMGFMT_*. Use
// generic FFmpeg mapping, as vo_drm.c does.
static inline int imgfmt_420p10(void)
{
    return pixfmt2imgfmt(AV_PIX_FMT_YUV420P10);
}

static inline int imgfmt_420p12(void)
{
    return pixfmt2imgfmt(AV_PIX_FMT_YUV420P12);
}

static inline bool media_pts_is_valid(double pts)
{
    return pts != MP_NOPTS_VALUE && isfinite(pts);
}

static inline int64_t media_pts_to_ns(double pts)
{
    return (int64_t)(pts * (double)NSEC_PER_SEC + (pts >= 0 ? 0.5 : -0.5));
}

static inline CMTime cm_time_from_ns(int64_t ns)
{
    return CMTimeMake(ns, NSEC_PER_SEC);
}

static inline int64_t cm_time_to_ns(CMTime time)
{
    if (!CMTIME_IS_NUMERIC(time))
        return 0;

    CMTime converted = CMTimeConvertScale(time, NSEC_PER_SEC,
                                          kCMTimeRoundingMethod_Default);
    return converted.value;
}

// Subtitles over frames whose pixels must stay untouched (Dolby Vision RPU),
// drawn on a transparent CAMetalLayer above the
// display layer. Cues arrive as the timed BGRA samples the display layer
// would get; a display link shows the newest one whose PTS the shared
// timebase has reached. gain > 1 lifts opaque subtitle pixels into EDR
// (1.0 = SDR white, capped at 2.0). Thread use: enqueue/flush/setGain from
// the VO thread, everything touching the layer or Metal on main.
// The OSD pool's cap (AVF_POOL_MAX_BUFFERS); the display link drains due
// entries, so the queue only holds what the VO has queued ahead.
#define QSUB_QUEUE_MAX 32

@interface QuasarSubtitleLayer : NSObject {
@public
    CAMetalLayer *_layer;
@private
    CMTimebaseRef _timebase;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    CVMetalTextureCacheRef _textureCache;
    CADisplayLink *_link;
    pthread_mutex_t _lock;
    struct { int64_t pts_ns; CVPixelBufferRef buf; bool immediate; } _entries[QSUB_QUEUE_MAX];
    int _count;
    bool _clearPending;
    float _gain;
    float _appliedGain;
    CVPixelBufferRef _current;
    struct mp_log *_log;
    bool _loggedFirst;
}
- (instancetype)initWithTimebase:(CMTimebaseRef)timebase gain:(double)gain
                             log:(struct mp_log *)log;
- (void)enqueueSampleBuffer:(CMSampleBufferRef)buf;
- (void)flushRemovingImage:(BOOL)remove;
- (void)setGain:(double)gain;
- (void)attachToDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer;
- (void)invalidate;
@end

// Presentation pool capacity follows the scheduled queue, with three buffers for
// renderer retention/upload and a separate paused replacement reserve. A fixed
// seven-buffer pool can exhaust before queued 120 fps samples are retired.
// Keep allocation lazy and bounded even with extreme frame rates or queue leads.
enum { AVF_POOL_MAX_BUFFERS = 32 };

void avf_update_avfoundation_geometry(struct vo *vo);

void avf_sync_osd_layer_frame(struct vo *vo);

void avf_reset_osd_buf_states(struct priv *p);

void avf_prune_osd_buf_states(struct priv *p, int64_t now);

CMSampleBufferRef avf_create_osd_sample_buffer(struct vo *vo,
                                                  int64_t media_pts_ns,
                                                  bool *needed);

bool avf_enqueue_osd_sample(struct vo *vo, CMSampleBufferRef buf);

void avf_render_osd(struct vo *vo, double pts);

void avf_release_ci_compositor(struct priv *p);

CVPixelBufferRef avf_composite_yuv_frame(struct vo *vo, CVPixelBufferRef videoBuffer,
                                           OSType sourceFormat, bool in_place);

CVPixelBufferRef avf_render_video_geometry_frame(struct vo *vo,
                                                    CVPixelBufferRef videoBuffer,
                                                    bool include_subtitle);

CVPixelBufferRef avf_composite_frame(struct vo *vo, CVPixelBufferRef videoBuffer,
                                       bool in_place);

void avf_clear_subtitle_cache(struct priv *p);

void avf_clear_subtitle_state(struct vo *vo);

int avf_presentation_pool_limit(int queue_lead_ms, int64_t frame_duration_ns,
                                      bool presentation_host);

CVReturn avf_pool_get_buffer_with_limit(CVPixelBufferPoolRef pool,
                                               int limit, CVPixelBufferRef *out);

CVReturn avf_pool_get_buffer(CVPixelBufferPoolRef pool, CVPixelBufferRef *out);

CVReturn avf_pool_get_buffer_for_frame(struct vo *vo,
                                             CVPixelBufferPoolRef pool,
                                             CVPixelBufferPoolRef *reserve_pool,
                                             CVPixelBufferRef *out);

bool avf_create_pixel_buffer_pool(struct vo *vo, CVPixelBufferPoolRef *poolRef,
                                     int *cached_w, int *cached_h, OSType *cached_fmt,
                                     int w, int h, OSType format, const char *name);

bool avf_create_output_pool(struct vo *vo, int w, int h, OSType outputFormat);

void avf_restore_dolby_vision_transfer(CVPixelBufferRef pixbuf,
                                          const struct mp_image_params *params);

void avf_tag_pixel_buffer_pixel_aspect(struct vo *vo, CVPixelBufferRef pixbuf);

void avf_get_yuv_coefficients(CVPixelBufferRef pixbuf, double *kr, double *kb);

bool avf_copy_pixel_buffer_planes(CVPixelBufferRef src, CVPixelBufferRef dst);

void avf_clear_sw_upload_metadata(struct priv *p);

void avf_upload_420p1x_to_p010(struct mp_image *mpi, CVPixelBufferRef pixbuf,
                                  int shift);

CVPixelBufferRef avf_upload_software_frame(struct vo *vo, struct mp_image *mpi);

void avf_report_unsupported_dovi(struct vo *vo, const char *reason);

bool avf_validate_native_dovi_frame(struct vo *vo, struct mp_image *mpi,
                                       CVPixelBufferRef pixbuf);

void avf_release_vivid(struct priv *p);

CVPixelBufferRef avf_map_vivid_frame(struct vo *vo, mp_image_t *mpi, CVPixelBufferRef src);

void avf_release_fel(struct priv *p);

CVPixelBufferRef avf_compose_fel_frame(struct vo *vo, mp_image_t *mpi, CVPixelBufferRef bl);
