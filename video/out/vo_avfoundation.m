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

// Video speed of this frame: mpv divides the speed-unadjusted duration by it.
// Exact from the first frame after a speed change, unlike estimating it from
// PTS gaps (dropped frames, VFR) over a window.
static bool avf_frame_rate(struct vo_frame *frame, int64_t frame_duration_ns,
                           double *rate)
{
    if (frame->approx_duration <= 0.0 || frame_duration_ns <= 0)
        return false;
    *rate = MP_TIME_S_TO_NS(frame->approx_duration) / (double)frame_duration_ns;
    return *rate >= AVF_RATE_MIN && *rate <= AVF_RATE_MAX;
}

// Ignore implausible steps: stalls, first sample.
#define AVF_SERVO_MAX_DT_NS    MP_TIME_MS_TO_NS(500)

// Frame-error feedback. error_ns = frame media PTS minus projected timebase
// at presentation; positive means timebase behind. dt_ns = host time since
// last evaluation. Persist *integral; zero on hard anchor. Return target
// rate; *snap requests anchor, *update_rate applies rate.
static double avf_servo_rate(int64_t error_ns, double nominal_rate,
                             double applied_rate, int64_t now_ns,
                             int64_t last_update_ns, int64_t dt_ns,
                             double *integral, bool *snap,
                             bool *update_rate)
{
    *snap = false;
    *update_rate = false;

    if (llabs(error_ns) > AVF_DRIFT_SNAP_NS) {
        *snap = true;
        return nominal_rate;
    }

    double p_term = (double)error_ns / (double)AVF_SERVO_HORIZON_NS;
    p_term = MPCLAMP(p_term, -AVF_SERVO_MAX_OFFSET, AVF_SERVO_MAX_OFFSET);

    if (dt_ns > 0 && dt_ns <= AVF_SERVO_MAX_DT_NS) {
        *integral += p_term * (double)dt_ns / (double)AVF_SERVO_INTEGRAL_NS;
        *integral = MPCLAMP(*integral, -AVF_SERVO_MAX_OFFSET,
                            AVF_SERVO_MAX_OFFSET);
    }

    double offset = MPCLAMP(p_term + *integral, -AVF_SERVO_MAX_OFFSET,
                            AVF_SERVO_MAX_OFFSET);
    double desired = nominal_rate * (1.0 + offset);

    if (fabs(desired - applied_rate) <= AVF_SERVO_MIN_DELTA * nominal_rate)
        return applied_rate;
    if (last_update_ns && now_ns - last_update_ns < AVF_SERVO_UPDATE_NS)
        return applied_rate;

    *update_rate = true;
    return desired;
}
// --- end avf sync servo core ---

static const struct m_sub_options avfoundation_conf;

static id<AVQueuedSampleBufferRendering> active_sample_buffer_renderer(
    AVSampleBufferDisplayLayer *displayLayer)
{
    if (!displayLayer)
        return nil;

    if (@available(iOS 17.0, tvOS 17.0, macOS 14.0, *))
        return displayLayer.sampleBufferRenderer;

    return displayLayer;
}

static AVQueuedSampleBufferRenderingStatus sample_buffer_renderer_status(
    AVSampleBufferDisplayLayer *displayLayer)
{
    if (!displayLayer)
        return AVQueuedSampleBufferRenderingStatusUnknown;

    if (@available(iOS 17.0, tvOS 17.0, macOS 14.0, *))
        return displayLayer.sampleBufferRenderer.status;

    return displayLayer.status;
}

static bool sample_buffer_renderer_requires_flush(
    AVSampleBufferDisplayLayer *displayLayer)
{
    if (!displayLayer)
        return false;

    if (@available(iOS 17.0, tvOS 17.0, macOS 14.0, *))
        return displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding;

    if (@available(iOS 14.0, tvOS 14.0, macOS 11.0, *))
        return displayLayer.requiresFlushToResumeDecoding;

    return false;
}

static bool sample_buffer_renderer_is_ready(AVSampleBufferDisplayLayer *displayLayer)
{
    id<AVQueuedSampleBufferRendering> renderer =
        active_sample_buffer_renderer(displayLayer);
    return renderer && renderer.isReadyForMoreMediaData;
}

// Anchor with immediate CoreMedia source clock. mpv timestamps use
// mp_time_ns() epoch, not CM host time.
static CMTime source_time_for_mp_time(struct priv *p, int64_t target_mp_ns)
{
    CMClockOrTimebaseRef source = CMTimebaseCopySource(p->timebase);
    CMTime source_now = source ? CMSyncGetTime(source) : kCMTimeInvalid;
    if (source)
        CFRelease(source);
    if (!CMTIME_IS_NUMERIC(source_now))
        source_now = CMClockGetTime(CMClockGetHostTimeClock());

    return CMTimeAdd(source_now, cm_time_from_ns(target_mp_ns - mp_time_ns()));
}

static int64_t current_media_time_ns(struct priv *p)
{
    if (p->next_media_pts_valid)
        return p->next_media_pts_ns;
    if (p->last_media_pts_valid)
        return p->last_media_pts_ns;
    if (p->timebase)
        return cm_time_to_ns(CMTimebaseGetTime(p->timebase));
    return 0;
}

// Video/OSD timestamp units: scheduled mpv display time in host mode;
// container PTS in media mode.
static int64_t sample_presentation_pts_ns(struct priv *p)
{
    if (p->presentation_host)
        return p->next_present_host_ns > 0 ? p->next_present_host_ns
                                           : mp_time_ns();
    return current_media_time_ns(p);
}

static void reset_media_timing(struct priv *p)
{
    p->next_present_host_ns = 0;
    p->next_media_pts_ns = 0;
    p->next_media_pts_valid = false;
    p->next_timebase_rate = 0.0;
    p->next_timebase_rate_valid = false;
    p->last_media_pts_ns = 0;
    p->last_media_pts_valid = false;
    p->timebase_anchor_valid = false;
    p->timebase_paused = false;
    p->playback_paused = false;
    // Keep nominal speed across seeks; first new anchor needs persistent
    // player rate.
    p->timebase_rate = p->timebase_rate > 0.0 ? p->timebase_rate : 1.0;
    p->timebase_applied_rate = p->timebase_rate;
    p->last_rate_update_ns = 0;
    p->servo_integral = 0.0;
    p->last_servo_eval_ns = 0;
}

static void update_media_timebase_for_frame(struct vo *vo)
{
    struct priv *p = vo->priv;
    if (!p->timebase || !p->next_media_pts_valid)
        return;

    int64_t now = mp_time_ns();
    int64_t present_host_ns = p->next_present_host_ns > 0
        ? p->next_present_host_ns
        : now;
    int64_t media_pts_ns = p->next_media_pts_ns;

    double rate = p->timebase_rate > 0.0 ? p->timebase_rate : 1.0;
    bool rate_changed = false;
    if (p->next_timebase_rate_valid && !p->playback_paused &&
        fabs(p->next_timebase_rate - rate) >
            AVF_RATE_CHANGE_FRACTION * rate) {
        MP_VERBOSE(vo, "Playback rate changed from %.6f to %.6f\n",
                   rate, p->next_timebase_rate);
        rate = p->next_timebase_rate;
        rate_changed = true;
    }
    if (p->playback_paused)
        rate = 0.0;

    bool should_anchor = !p->timebase_anchor_valid || p->timebase_paused ||
        p->playback_paused || rate_changed;

    if (!should_anchor) {
        double applied = p->timebase_applied_rate > 0.0
            ? p->timebase_applied_rate
            : rate;
        int64_t timebase_ns = cm_time_to_ns(CMTimebaseGetTime(p->timebase));
        int64_t projected_ns = timebase_ns +
            (int64_t)((double)(present_host_ns - now) * applied);
        int64_t error_ns = media_pts_ns - projected_ns;

        if (llabs(error_ns) > p->diag_drift_peak_ns)
            p->diag_drift_peak_ns = llabs(error_ns);

        int64_t dt_ns = p->last_servo_eval_ns
            ? now - p->last_servo_eval_ns
            : 0;
        p->last_servo_eval_ns = now;

        bool snap = false, update_rate = false;
        double servo = avf_servo_rate(error_ns, rate, applied, now,
                                      p->last_rate_update_ns, dt_ns,
                                      &p->servo_integral,
                                      &snap, &update_rate);
        if (snap) {
            should_anchor = true;
            MP_VERBOSE(vo, "Timebase %.1f ms off schedule; re-anchoring\n",
                       error_ns / 1e6);
            // Keep nominal rate. Scheduling discontinuity says nothing about
            // speed; each frame carries it (avf_frame_rate).
        } else if (update_rate) {
            CMTimebaseSetRate(p->timebase, servo);
            p->timebase_applied_rate = servo;
            p->last_rate_update_ns = now;
            p->diag_rate_update_count++;
        }
    }

    if (should_anchor) {
        CMTime source_time = source_time_for_mp_time(p, present_host_ns);
        OSStatus err = CMTimebaseSetRateAndAnchorTime(
            p->timebase, rate, cm_time_from_ns(media_pts_ns),
            source_time);
        if (err != noErr) {
            MP_WARN(vo, "Failed to anchor AVFoundation media timebase: %d\n", (int)err);
        }
        // Paused effective rate = zero; retain nominal speed for resume/seek
        // anchor.
        if (rate > 0.0)
            p->timebase_rate = rate;
        p->timebase_applied_rate = rate;
        p->last_rate_update_ns = now;
        p->servo_integral = 0.0;
        p->last_servo_eval_ns = 0;
        p->timebase_anchor_valid = true;
        p->timebase_paused = p->playback_paused;
        p->diag_anchor_count++;
    }

    p->last_media_pts_ns = media_pts_ns;
    p->last_media_pts_valid = true;
}

static void set_media_timebase_paused(struct vo *vo, bool paused)
{
    struct priv *p = vo->priv;
    if (!p->timebase)
        return;
    p->playback_paused = paused;

    if (paused) {
        CMTime media_time = CMTimebaseGetTime(p->timebase);
        if (!CMTIME_IS_NUMERIC(media_time)) {
            media_time = cm_time_from_ns(current_media_time_ns(p));
        }
        CMTime source_time = source_time_for_mp_time(p, mp_time_ns());
        OSStatus err = CMTimebaseSetRateAndAnchorTime(
            p->timebase, 0.0, media_time, source_time);
        if (err != noErr)
            MP_WARN(vo, "Failed to pause AVFoundation media timebase: %d\n", (int)err);
        p->timebase_applied_rate = 0.0;
        p->timebase_paused = true;
        return;
    }

    p->timebase_paused = false;
    p->timebase_anchor_valid = false;
}

static void sample_buffer_renderer_flush(AVSampleBufferDisplayLayer *displayLayer,
                                         bool remove_image)
{
    if (!displayLayer)
        return;

    if (@available(iOS 17.0, tvOS 17.0, macOS 14.0, *)) {
        AVSampleBufferVideoRenderer *renderer = displayLayer.sampleBufferRenderer;
        if (remove_image) {
            [renderer flushWithRemovalOfDisplayedImage:YES completionHandler:NULL];
        } else {
            [renderer flush];
        }
        return;
    }

    if (remove_image) {
        [displayLayer flushAndRemoveImage];
    } else {
        [displayLayer flush];
    }
}

static void sample_buffer_renderer_enqueue(AVSampleBufferDisplayLayer *displayLayer,
                                           CMSampleBufferRef buf)
{
    id<AVQueuedSampleBufferRendering> renderer =
        active_sample_buffer_renderer(displayLayer);
    [renderer enqueueSampleBuffer:buf];
}

static bool display_layer_needs_recovery(AVSampleBufferDisplayLayer *displayLayer)
{
    if (!displayLayer)
        return false;

    return sample_buffer_renderer_status(displayLayer) ==
               AVQueuedSampleBufferRenderingStatusFailed ||
           sample_buffer_renderer_requires_flush(displayLayer);
}

static void recover_display_layer(struct vo *vo, const char *reason, bool force)
{
    struct priv *p = vo->priv;
    AVSampleBufferDisplayLayer *displayLayer = [p->displayLayer retain];
    QuasarSubtitleLayer *osdLayer = [p->osdLayer retain];

    if (!displayLayer) {
        [osdLayer release];
        return;
    }

    int64_t now = mp_time_ns();
    if (!force && p->last_display_recovery_ns &&
        now - p->last_display_recovery_ns < MP_TIME_MS_TO_NS(500)) {
        [displayLayer release];
        [osdLayer release];
        return;
    }
    p->last_display_recovery_ns = now;

    AVQueuedSampleBufferRenderingStatus status =
        AVQueuedSampleBufferRenderingStatusUnknown;
    bool requires_flush = false;
    bool ready = false;
    int64_t timebase_ns = 0;
    double timebase_rate = 0.0;

    {
        status = sample_buffer_renderer_status(displayLayer);
        requires_flush = sample_buffer_renderer_requires_flush(displayLayer);
        ready = sample_buffer_renderer_is_ready(displayLayer);
        if (p->timebase) {
            timebase_ns = cm_time_to_ns(CMTimebaseGetTime(p->timebase));
            timebase_rate = CMTimebaseGetRate(p->timebase);
        }

        sample_buffer_renderer_flush(displayLayer, false);
        [osdLayer flushRemovingImage:NO];
    }

    MP_WARN(vo, "Recovered AVFoundation display layer after %s "
                "(status=%ld, requiresFlush=%s, ready=%s, "
                "mediaPts=%.3f, timebase=%.3f, rate=%.3f)\n",
            reason, (long)status, requires_flush ? "yes" : "no",
            ready ? "yes" : "no",
            current_media_time_ns(p) / 1000000000.0,
            timebase_ns / 1000000000.0, timebase_rate);

    p->not_ready_drop_count = 0;
    p->last_not_ready_drop_ns = 0;
    p->last_video_enqueue_ns = 0;
    p->timebase_anchor_valid = false;
    p->timebase_paused = p->playback_paused;
    p->osd_change_id = 0;
    p->osd_needs_enqueue = false;

    [displayLayer release];
    [osdLayer release];
}

static void record_not_ready_drop(struct vo *vo)
{
    struct priv *p = vo->priv;
    int64_t now = mp_time_ns();

    if (p->last_not_ready_drop_ns == 0 ||
        now - p->last_not_ready_drop_ns > MP_TIME_MS_TO_NS(500))
        p->not_ready_drop_count = 0;

    p->last_not_ready_drop_ns = now;
    p->not_ready_drop_count++;

    if (p->not_ready_drop_count >= 3 &&
        (!p->last_video_enqueue_ns ||
         now - p->last_video_enqueue_ns >= MP_TIME_MS_TO_NS(500)))
        recover_display_layer(vo, "repeated not-ready drops", false);
}

static void avfoundation_opts_wakeup(void *ctx)
{
    vo_wakeup(ctx);
}

static void update_avfoundation_options(struct vo *vo)
{
    struct priv *p = vo->priv;

    if (!p->opts_cache || !p->opts)
        return;

    bool old_composite_osd = p->opts->composite_osd;
    bool old_pip_composite_osd = p->opts->pip_composite_osd;
    int old_queue_lead_ms = p->opts->queue_lead_ms;
    int old_osd_max_height = p->opts->osd_max_height;
    bool old_osd_video_res = p->opts->osd_video_res;
    double old_subtitle_luminance = p->opts->subtitle_luminance;
    int old_osd_layer = p->opts->osd_layer;

    if (!m_config_cache_update(p->opts_cache))
        return;

    if (old_queue_lead_ms != p->opts->queue_lead_ms)
        vo_set_queue_params(vo, MP_TIME_MS_TO_NS(p->opts->queue_lead_ms), 1);

    bool composite_changed =
        old_composite_osd != p->opts->composite_osd ||
        old_pip_composite_osd != p->opts->pip_composite_osd ||
        old_osd_layer != p->opts->osd_layer;
    bool osd_scale_changed = old_osd_max_height != p->opts->osd_max_height ||
        old_osd_video_res != p->opts->osd_video_res;

    bool luminance_changed = old_subtitle_luminance != p->opts->subtitle_luminance;
    if (!composite_changed && !osd_scale_changed && !luminance_changed)
        return;
    if (luminance_changed) vo->want_redraw = true;

    if (composite_changed) {
        MP_VERBOSE(vo, "OSD compositing updated: composite_osd: %s, "
                   "pip_composite_osd: %s\n",
                   p->opts->composite_osd ? "yes" : "no",
                   p->opts->pip_composite_osd ? "yes" : "no");
    }
    if (osd_scale_changed) {
        MP_VERBOSE(vo, "OSD scaling updated: max_height: %d, video_res: %s\n",
                   p->opts->osd_max_height,
                   p->opts->osd_video_res ? "yes" : "no");
    }

    avf_clear_subtitle_cache(p);
    if (composite_changed && !should_composite_into_video(p))
        avf_release_ci_compositor(p);
    [p->osdLayer flushRemovingImage:YES];
    [p->osdLayer setGain:p->opts->subtitle_edr_gain];
    avf_sync_osd_layer_frame(vo);
}

// Consume MPVLayerGeometryObserver's pending resize.


static void record_deadline_drop(struct vo *vo)
{
    struct priv *p = vo->priv;
    record_not_ready_drop(vo);
    vo_increment_drop_count(vo, 1);
    p->diag_drop_count++;
    // Paused redraw rejection has no next frame. Request retained-frame
    // repaint; VO loop rate-limits retries and handles shutdown between
    // attempts.
    if (p->playback_paused && !p->presentation_host)
        vo->want_redraw = true;
}

static bool wait_until_ready_for_more_media_data(struct vo *vo, int64_t present_host_ns)
{
    struct priv *p = vo->priv;
    if (display_layer_needs_recovery(p->displayLayer))
        recover_display_layer(vo, "layer recovery request", false);

    if (sample_buffer_renderer_is_ready(p->displayLayer)) {
        p->not_ready_drop_count = 0;
        p->last_not_ready_drop_ns = 0;
        return true;
    }

    // Not-ready before deadline means backpressure. queue-lead-ms and high
    // playback rates can fill renderer early. Wait until near deadline to
    // match drain rate (#1484).
    int64_t start = mp_time_ns();
    // Paused equal-PTS replacement displays immediately; ignore old deadline.
    // Flush may briefly block readiness. Bound retries so shutdown never
    // waits on async callbacks.
    int64_t give_up = p->playback_paused && !p->presentation_host
        ? start + MP_TIME_MS_TO_NS(20)
        : present_host_ns > 0
            ? present_host_ns - MP_TIME_MS_TO_NS(4)
            : start + MP_TIME_MS_TO_NS(2);

    if (give_up <= start) {
        MP_VERBOSE(vo, "Display layer not ready %.2f ms before PTS; dropping frame\n",
                   (present_host_ns - start) / 1000000.0);
        record_deadline_drop(vo);
        return false;
    }

    while (!sample_buffer_renderer_is_ready(p->displayLayer)) {
        if (mp_time_ns() >= give_up) {
            MP_VERBOSE(vo, "Display layer not ready at PTS deadline; dropping frame\n");
            record_deadline_drop(vo);
            return false;
        }
        if (display_layer_needs_recovery(p->displayLayer)) {
            recover_display_layer(vo, "not-ready wait", false);
            if (display_layer_needs_recovery(p->displayLayer)) {
                // Recovery throttled; stop polling failed renderer before
                // deadline.
                MP_VERBOSE(vo, "Display layer unrecovered during wait; dropping frame\n");
                record_deadline_drop(vo);
                return false;
            }
            continue;
        }
        mp_sleep_ns(MP_TIME_MS_TO_NS(1));
    }

    p->not_ready_drop_count = 0;
    p->last_not_ready_drop_ns = 0;
    p->diag_wait_count++;
    p->diag_wait_total_ns += mp_time_ns() - start;
    return true;
}

static void report_presentation_diagnostics(struct vo *vo)
{
    struct priv *p = vo->priv;
    int64_t now = mp_time_ns();

    if (!p->diag_window_start_ns) {
        p->diag_window_start_ns = now;
        return;
    }
    if (now - p->diag_window_start_ns < MP_TIME_MS_TO_NS(5000))
        return;

    if (p->diag_wait_count || p->diag_drop_count || p->diag_anchor_count ||
        p->diag_rate_update_count || p->diag_drift_peak_ns) {
        double rate = p->timebase_rate > 0.0 ? p->timebase_rate : 1.0;
        double offset_ppm =
            (p->timebase_applied_rate / rate - 1.0) * 1e6;
        MP_VERBOSE(vo, "Presentation pacing over %.1fs: %d ready-waits "
                   "(avg %.2f ms), %d deadline drops, %d timebase anchors, "
                   "%d rate updates (now %+.0f ppm), drift peak %.2f ms\n",
                   (now - p->diag_window_start_ns) / 1e9,
                   p->diag_wait_count,
                   p->diag_wait_count
                       ? p->diag_wait_total_ns / 1e6 / p->diag_wait_count
                       : 0.0,
                   p->diag_drop_count, p->diag_anchor_count,
                   p->diag_rate_update_count, offset_ppm,
                   p->diag_drift_peak_ns / 1e6);
    }

    p->diag_window_start_ns = now;
    p->diag_wait_count = 0;
    p->diag_wait_total_ns = 0;
    p->diag_drop_count = 0;
    p->diag_anchor_count = 0;
    p->diag_rate_update_count = 0;
    p->diag_drift_peak_ns = 0;
}



static AVBufferRef *create_videotoolbox_device_ref(struct vo *vo)
{
    AVBufferRef *device_ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
    if (!device_ref) {
        MP_ERR(vo, "Failed to allocate VideoToolbox device\n");
        return NULL;
    }

    AVHWDeviceContext *device = (AVHWDeviceContext *)device_ref->data;
    AVVTDeviceContext *native = device->hwctx;
    native->enable_native_dolby_vision = 1;
    struct priv *p = vo->priv;
    native->convert_native_dolby_vision_profile7 = p->opts->native_dovi_profile7;
    if (av_hwdevice_ctx_init(device_ref) < 0) {
        MP_ERR(vo, "Failed to init VideoToolbox device\n");
        av_buffer_unref(&device_ref);
        return NULL;
    }

    return device_ref;
}

static int preinit(struct vo *vo)
{
    struct priv *p = vo->priv;
    p->opts_cache = m_config_cache_alloc(p, vo->global, &avfoundation_conf);
    p->opts = p->opts_cache->opts;
    m_config_cache_set_wakeup_cb(p->opts_cache, avfoundation_opts_wakeup, vo);
    if (vo->opts->WinID == -1 || vo->opts->WinID == 0) {
        MP_ERR(vo, "No AVSampleBufferDisplayLayer provided via --wid\n");
        return -1;
    }
    id layer = (__bridge id)(void *)(intptr_t)vo->opts->WinID;
    if (![layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
        MP_ERR(vo, "--wid must identify an AVSampleBufferDisplayLayer\n");
        return -1;
    }
    p->displayLayer = [layer retain];
    if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault,
            CMClockGetHostTimeClock(), &p->timebase) != noErr || !p->timebase) {
        [p->displayLayer release];
        p->displayLayer = nil;
        return -1;
    }
    p->presentation_host = p->opts->presentation == AVF_PRESENTATION_HOST;
    reset_media_timing(p);
    CMTimebaseSetTime(p->timebase, cm_time_from_ns(p->presentation_host ? mp_time_ns() : 0));
    CMTimebaseSetRate(p->timebase, p->presentation_host ? 1.0 : 0.0);
    // Renderer owns controlTimebase; host must not replace it. PiP playback
    // delegate may read it on main queue.
    p->displayLayer.controlTimebase = p->timebase;
    vo_set_queue_params(vo, MP_TIME_MS_TO_NS(p->opts->queue_lead_ms), 1);
    avf_update_avfoundation_geometry(vo);
    vo->hwdec_devs = hwdec_devices_create();
    p->hwctx = (struct mp_hwdec_ctx){
        .driver_name = "avfoundation",
        .av_device_ref = create_videotoolbox_device_ref(vo),
        .hw_imgfmt = IMGFMT_VIDEOTOOLBOX,
    };
    hwdec_devices_add(vo->hwdec_devs, &p->hwctx);
    return 0;
}

static CMSampleBufferRef create_video_sample_buffer(struct vo *vo, mp_image_t *mpi)
{
    @autoreleasepool {
        struct priv *p = vo->priv;

        CVPixelBufferRef pixbuf = NULL;
        bool pixbufNeedsRelease = false;

        // Handle input formats.
        if (mpi->imgfmt == IMGFMT_VIDEOTOOLBOX) {
            // Hardware decoded: zero-copy passthrough
            pixbuf = (CVPixelBufferRef)mpi->planes[3];
            if (!pixbuf || !avf_validate_native_dovi_frame(vo, mpi, pixbuf))
                return NULL;
        } else {
            if (!avf_validate_native_dovi_frame(vo, mpi, NULL))
                return NULL;
            // Software decoded: upload to CVPixelBuffer
            pixbuf = avf_upload_software_frame(vo, mpi);
            if (!pixbuf) {
                MP_ERR(vo, "Failed to upload software frame\n");
                return NULL;
            }
            pixbufNeedsRelease = true;
            p->video_statistics.pixel_buffer_copies++;
        }

        // Profile 7 FEL, then HDR Vivid: both before subtitles and geometry
        // draw on the frame.
        CVPixelBufferRef fel = avf_compose_fel_frame(vo, mpi, pixbuf);
        if (fel) {
            if (pixbufNeedsRelease)
                CVPixelBufferRelease(pixbuf);
            pixbuf = fel;
            pixbufNeedsRelease = true;
            p->video_statistics.pixel_buffer_copies++;
        }
        CVPixelBufferRef vivid = avf_map_vivid_frame(vo, mpi, pixbuf);
        if (vivid) {
            if (pixbufNeedsRelease)
                CVPixelBufferRelease(pixbuf);
            pixbuf = vivid;
            pixbufNeedsRelease = true;
            p->video_statistics.pixel_buffer_copies++;
        }

        CVPixelBufferRef finalBuffer = pixbuf;
        bool needsRelease = false;
        bool pixels_transformed = vivid != NULL;

        bool applyGeometry = should_apply_video_geometry(vo);
        // Native dvh1 RPU describes untouched frames. Core Image redraw
        // invalidates metadata and makes DV output near-black. Preserve
        // unzoomed, correct passthrough.
        if (applyGeometry && pixbuf &&
            CVBufferGetAttachment(pixbuf, CFSTR("DolbyVisionRPUData"), NULL)) {
            if (!p->dovi_geometry_skip_logged) {
                MP_WARN(vo, "Dolby Vision passthrough frame; ignoring video "
                            "zoom/pan instead of destroying DV output\n");
                p->dovi_geometry_skip_logged = true;
            }
            applyGeometry = false;
        }
        if (applyGeometry) {
            CVPixelBufferRef overlay = NULL;
            if (p->has_subtitle && is_biplanar_yuv_format(CVPixelBufferGetPixelFormatType(pixbuf)))
                overlay = avf_composite_yuv_frame(vo, pixbuf, CVPixelBufferGetPixelFormatType(pixbuf), pixbufNeedsRelease);
            CVPixelBufferRef rendered = avf_render_video_geometry_frame(vo, overlay ?: pixbuf,
                                                                    !overlay && p->has_subtitle);
            if (overlay) {
                if (overlay != pixbuf)
                    p->video_statistics.pixel_buffer_copies++;
                else
                    pixels_transformed = true;
                CVPixelBufferRelease(overlay);
            }
            if (rendered) {
                p->video_statistics.pixel_buffer_copies++;
                if (!p->applied_geometry_last_frame) {
                    struct mp_vo_opts *opts = vo->opts;
                    MP_INFO(vo, "AVFoundation geometry rendering enabled "
                                "(zoom=%.3f pan=%.3f,%.3f scale=%.3f,%.3f)\n",
                            opts ? opts->zoom : 0.0f,
                            opts ? opts->pan_x : 0.0f,
                            opts ? opts->pan_y : 0.0f,
                            opts ? opts->scale_x : 1.0f,
                            opts ? opts->scale_y : 1.0f);
                }
                finalBuffer = rendered;
                needsRelease = true;
                pixels_transformed = true;
                p->applied_geometry_last_frame = true;
                p->geometry_render_failure_logged = false;
            } else if (!p->geometry_render_failure_logged) {
                MP_WARN(vo, "AVFoundation geometry rendering failed; "
                            "falling back to original sample-buffer frame\n");
                p->geometry_render_failure_logged = true;
            }
        } else {
            if (p->applied_geometry_last_frame || p->geometry_render_failure_logged) {
                if (p->applied_geometry_last_frame)
                    MP_INFO(vo, "AVFoundation geometry rendering disabled; "
                                "returning to sample-buffer passthrough\n");
                if (p->outputPool)
                    CVPixelBufferPoolFlush(p->outputPool, kCVPixelBufferPoolFlushExcessBuffers);
                p->applied_geometry_last_frame = false;
                p->geometry_render_failure_logged = false;
            }
        }

        if (!needsRelease && !applyGeometry && should_composite_into_video(p)) {
            // Composite this flip's subtitle.
            CVPixelBufferRef composited = avf_composite_frame(vo, pixbuf, pixbufNeedsRelease);
            if (composited && composited != pixbuf)
                p->video_statistics.pixel_buffer_copies++;
            if (composited && should_use_frame_space_osd(p) &&
                (CVPixelBufferGetWidth(composited) != CVPixelBufferGetWidth(pixbuf) ||
                 CVPixelBufferGetHeight(composited) != CVPixelBufferGetHeight(pixbuf))) {
                // PiP window follows sample dimensions. Reject resized
                // composite and present bare frame to avoid per-cue resizing.
                if (!p->composite_size_mismatch_logged) {
                    MP_WARN(vo, "Composited frame is %zux%zu instead of the frame's "
                                "%zux%zu; dropping the overlay to keep the sample "
                                "size steady\n",
                            CVPixelBufferGetWidth(composited),
                            CVPixelBufferGetHeight(composited),
                            CVPixelBufferGetWidth(pixbuf),
                            CVPixelBufferGetHeight(pixbuf));
                    p->composite_size_mismatch_logged = true;
                }
                CVPixelBufferRelease(composited);
                composited = NULL;
            }
            if (composited) {
                finalBuffer = composited;
                needsRelease = true;
                pixels_transformed = true;
            }
        }

        CMSampleTimingInfo info = {
            .presentationTimeStamp = cm_time_from_ns(sample_presentation_pts_ns(p)),
            .duration = kCMTimeInvalid,
            .decodeTimeStamp = kCMTimeInvalid
        };

        // DVD/anamorphic aspect requires sample-aspect buffer attachment;
        // AVSampleBufferDisplayLayer ignores other forms.
        avf_tag_pixel_buffer_pixel_aspect(vo, finalBuffer);

        // P5 may keep RPU but lose VideoToolbox PQ tag. Leave
        // primaries/matrix unspecified.
        if (mpi->imgfmt == IMGFMT_VIDEOTOOLBOX && finalBuffer == pixbuf)
            avf_restore_dolby_vision_transfer(finalBuffer, &mpi->params);

        // Cache format description while
        // CMVideoFormatDescriptionMatchesImageBuffer matches dimensions,
        // format, and attachments. Reconfig, geometry/compositing, or color
        // changes invalidate it.
        CMVideoFormatDescriptionRef format = p->video_format_desc;
        CFDictionaryRef attachments = CVBufferGetAttachments(finalBuffer, kCVAttachmentMode_ShouldPropagate);
        bool metadata_equal = attachments == p->video_format_attachments ||
            (attachments && p->video_format_attachments && CFEqual(attachments, p->video_format_attachments));
        if (!format || !metadata_equal || !CMVideoFormatDescriptionMatchesImageBuffer(format, finalBuffer)) {
            CMVideoFormatDescriptionRef new_format = NULL;
            OSStatus desc_err = CMVideoFormatDescriptionCreateForImageBuffer(
                NULL, finalBuffer, &new_format);
            if (desc_err != noErr || !new_format) {
                MP_ERR(vo, "Failed to create format description: %d\n", (int)desc_err);
                if (needsRelease)
                    CVPixelBufferRelease(finalBuffer);
                if (pixbufNeedsRelease)
                    CVPixelBufferRelease(pixbuf);
                return NULL;
            }
            if (p->video_format_desc)
                CFRelease(p->video_format_desc);
            p->video_format_desc = new_format;
            if (p->video_format_attachments) CFRelease(p->video_format_attachments);
            p->video_format_attachments = attachments ? CFDictionaryCreateCopy(NULL, attachments) : NULL;
            format = new_format;
        }

        CMSampleBufferRef buf = NULL;
        OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(NULL, finalBuffer, format, &info, &buf);

        if (err != noErr || !buf) {
            MP_ERR(vo, "Failed to create sample buffer: %d\n", (int)err);
            if (needsRelease)
                CVPixelBufferRelease(finalBuffer);
            if (pixbufNeedsRelease)
                CVPixelBufferRelease(pixbuf);
            return NULL;
        }

        const void *hdr10plus = NULL;
        size_t hdr10plus_size = 0;
        for (int i = 0; i < mpi->num_ff_side_data; i++) {
            if (mpi->ff_side_data[i].type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS) {
                hdr10plus = mpi->ff_side_data[i].buf->data;
                hdr10plus_size = mpi->ff_side_data[i].buf->size;
                break;
            }
        }
        // Static source mastering metadata remains meaningful after an overlay,
        // but dynamic scene mapping describes the untouched original pixels.
        int hdr_state = avf_attach_hdr10plus(buf, hdr10plus, hdr10plus_size,
                                           pixels_transformed);
        if (hdr_state != p->hdr10plus_state) {
            const char *states[] = {"absent", "attached", "invalid",
                                    "pixels-transformed", "os-unavailable"};
            MP_INFO(vo, "MPVUI_NATIVE_HDR10PLUS: %s\n", states[hdr_state]);
            p->hdr10plus_state = hdr_state;
        }

        // Stopped timebase cannot pass equal-PTS replacement; paused
        // subtitles/seek previews may retain old image. Display these paused
        // media frames immediately; schedule playing frames normally.
        if (p->playback_paused && !p->presentation_host) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buf, true);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFMutableDictionaryRef sample = (CFMutableDictionaryRef)
                    CFArrayGetValueAtIndex(attachments, 0);
                CFDictionarySetValue(sample, kCMSampleAttachmentKey_DisplayImmediately,
                                     kCFBooleanTrue);
            }
        }

        // Release owned composite buffer.
        if (needsRelease)
            CVPixelBufferRelease(finalBuffer);

        // Release uploaded buffer; owned here, not by mpi.
        if (pixbufNeedsRelease)
            CVPixelBufferRelease(pixbuf);

        return buf;
    }
}

static bool enqueue_video_sample(struct vo *vo, CMSampleBufferRef buf)
{
    struct priv *p = vo->priv;

    if (!buf)
        return false;

    sample_buffer_renderer_enqueue(p->displayLayer, buf);
    p->last_video_enqueue_ns = mp_time_ns();
    return true;
}

// OSD counters always accumulate; format logs only with -v.
static void report_osd_perf(struct vo *vo)
{
    struct priv *p = vo->priv;

    if (p->perf.renders <= 0)
        return;

    if (mp_msg_test(vo->log, MSGL_V)) {
        double n = p->perf.renders;
        double nf = MPMAX(p->perf.frames, 1);
        double ne = MPMAX(p->perf.enq_count, 1);
        MP_VERBOSE(vo,
            "osd-perf: n=%d avg=%.2fms max=%.2fms "
            "[clear %.2f blend %.2f cg %.2f bounds %.2f] enq %.2f | "
            "vid %.3f wait %.3f (/frame) | "
            "margin avg=%.1f min=%.1fms drops=%d | "
            "skip=%d empty=%d osd=%dx%d\n",
            p->perf.renders,
            p->perf.total_ns / n / 1e6,
            p->perf.max_ns / 1e6,
            p->perf.clear_ns / n / 1e6,
            p->perf.blend_ns / n / 1e6,
            p->perf.cg_ns / n / 1e6,
            p->perf.bounds_ns / n / 1e6,
            p->perf.enqueue_ns / n / 1e6,
            p->perf.video_sample_ns / nf / 1e6,
            p->perf.wait_ns / nf / 1e6,
            p->perf.lead_sum_ns / ne / 1e6,
            p->perf.enq_count ? p->perf.lead_min_ns / 1e6 : 0.0,
            p->perf.enq_drops,
            p->perf.skipped, p->perf.empty, p->osd_w, p->osd_h);
    }
    memset(&p->perf, 0, sizeof(p->perf));
}

static void flip_page(struct vo *vo)
{
    struct priv *p = vo->priv;


    report_presentation_diagnostics(vo);

    if (p->next_image) {
        if (p->playback_paused && !p->presentation_host) {
            // Retire future samples before readiness check: rate-zero queue
            // cannot drain. Replace equal-PTS image without blanking.
            sample_buffer_renderer_flush(p->displayLayer, false);
        }
        CMSampleBufferRef osd_buf = NULL;
        bool osd_needed = false;

        bool osd_layer = should_use_inline_osd_layer(p);
        if (osd_layer && !p->osdLayer && !p->osd_layer_failed) {
            // Off-main alloc and controlTimebase match preinit's displayLayer
            // setup; CALayer tree changes happen on main.
            p->osdLayer = [[QuasarSubtitleLayer alloc]
                initWithTimebase:p->timebase gain:p->opts->subtitle_edr_gain
                             log:vo->log];
            if (!p->osdLayer) {
                MP_ERR(vo, "Failed to create the subtitle Metal layer\n");
                p->osd_layer_failed = true;
            }
        }
        if (osd_layer != p->osd_layer_active) {
            MP_INFO(vo, "Subtitles %s\n", osd_layer ? "on separate OSD layer"
                                                      : "composited into video");
            p->osd_layer_active = osd_layer;
            // Entering: push the current cue (or an empty sample). Leaving:
            // drop the layer's overlay; composition takes over.
            if (osd_layer)
                p->osd_needs_enqueue = true;
            else
                [p->osdLayer flushRemovingImage:YES];
        }
        if (osd_layer) {
            [p->osdLayer attachToDisplayLayer:p->displayLayer];
            if (p->playback_paused && !p->presentation_host) {
                // Same as the video flush above; re-send this frame's cue.
                [p->osdLayer flushRemovingImage:NO];
                p->osd_change_id = 0;
            }
        }

        // Enqueue OSD immediately before matching video. Slow subtitle
        // rendering delays both, preserving frame alignment.
        avf_render_osd(vo, p->next_pts);

        int64_t osd_pts_ns = sample_presentation_pts_ns(p);
        osd_buf = avf_create_osd_sample_buffer(vo, osd_pts_ns, &osd_needed);

        int64_t t = mp_time_ns();
        CMSampleBufferRef video_buf = create_video_sample_buffer(vo, p->next_image);
        int64_t sample_ns = mp_time_ns() - t;
        p->perf.video_sample_ns += sample_ns;
        p->video_statistics.sample_build_count++;
        p->video_statistics.last_sample_build_ns = sample_ns;
        p->video_statistics.total_sample_build_ns += sample_ns;
        if (!video_buf)
            record_deadline_drop(vo);

        bool osd_enqueued = !osd_needed;

        t = mp_time_ns();
        bool video_ready = video_buf &&
            wait_until_ready_for_more_media_data(vo, p->next_present_host_ns);
        p->perf.wait_ns += mp_time_ns() - t;

        if (video_ready) {
            if (!p->presentation_host)
                update_media_timebase_for_frame(vo);

            if (osd_buf) {
                t = mp_time_ns();
                osd_enqueued = avf_enqueue_osd_sample(vo, osd_buf);
                p->perf.enqueue_ns += mp_time_ns() - t;
                if (osd_enqueued) {
                    p->osd_needs_enqueue = false;
                    // Lead from OSD/video enqueue to intended presentation,
                    // same clock.
                    int64_t lead = p->next_present_host_ns - mp_time_ns();
                    if (!p->perf.enq_count || lead < p->perf.lead_min_ns)
                        p->perf.lead_min_ns = lead;
                    p->perf.lead_sum_ns += lead;
                    p->perf.enq_count++;
                } else {
                    p->perf.enq_drops++;
                }
            }

            enqueue_video_sample(vo, video_buf);
        }

        if (osd_needed && !osd_enqueued)
            p->osd_change_id = 0;

        if (osd_buf)
            CFRelease(osd_buf);
        if (video_buf)
            CFRelease(video_buf);

        p->perf.frames++;
    }

    // Flush excess buffers every ~60 frames; bound memory without per-frame
    // churn.
    if (++p->frame_count >= 60) {
        p->frame_count = 0;
        if (p->outputPool)
            CVPixelBufferPoolFlush(p->outputPool, kCVPixelBufferPoolFlushExcessBuffers);
        if (p->osdPool)
            CVPixelBufferPoolFlush(p->osdPool, kCVPixelBufferPoolFlushExcessBuffers);
        if (p->swUploadPool)
            CVPixelBufferPoolFlush(p->swUploadPool, kCVPixelBufferPoolFlushExcessBuffers);
        avf_prune_osd_buf_states(p, mp_time_ns());
    }

    // Log often enough for short captures.
    if (p->perf.renders >= 32 ||
        (p->perf.renders > 0 && p->perf.frames >= 300))
        report_osd_perf(vo);

    mp_image_unrefp(&p->next_image);
}

static bool draw_frame(struct vo *vo, struct vo_frame *frame)
{
    struct priv *p = vo->priv;

    mp_image_unrefp(&p->next_image);

    if (!frame->current || (frame->repeat && !frame->redraw)) {
        p->next_pts = MP_NOPTS_VALUE;
        p->next_present_host_ns = mp_time_ns();
        p->next_media_pts_valid = false;
        p->next_timebase_rate_valid = false;
        return true;
    }

    p->next_image = mp_image_new_ref(frame->current);
    if (!p->next_image)
        return false;
    p->frame_dovi = p->next_image->imgfmt == IMGFMT_VIDEOTOOLBOX &&
        p->next_image->planes[3] &&
        CVBufferGetAttachment((CVPixelBufferRef)p->next_image->planes[3],
                              CFSTR("DolbyVisionRPUData"), NULL);

    double pts = p->next_image->pts;
    if (pts == MP_NOPTS_VALUE)
        pts = frame->current->pts;

    p->next_pts = pts;
    p->next_present_host_ns = frame->pts > 0 ? frame->pts : mp_time_ns();
    p->next_media_pts_valid = media_pts_is_valid(pts);
    p->next_media_pts_ns = p->next_media_pts_valid
        ? media_pts_to_ns(pts)
        : current_media_time_ns(p);
    p->next_timebase_rate_valid = false;
    if (p->next_media_pts_valid) {
        int64_t frame_duration_ns = frame->display_synced &&
                                    frame->ideal_frame_duration > 0.0
            ? MP_TIME_S_TO_NS(frame->ideal_frame_duration)
            : frame->duration > 0.0 ? (int64_t)llrint(frame->duration) : 0;
        // Preserve the last scheduled interval for paused redraws and seeks.
        if (frame_duration_ns > 0)
            p->pool_frame_duration_ns = frame_duration_ns;
        p->next_timebase_rate_valid = avf_frame_rate(
            frame, frame_duration_ns, &p->next_timebase_rate);
    }
    return true;
}

static int query_format(struct vo *vo, int format)
{
    // Accept planar 10/12-bit input directly; avoid decode-thread scalar
    // libswscale autoconvert. Fuse biplanar conversion into required upload
    // copy.
    if (format == IMGFMT_VIDEOTOOLBOX ||   // Hardware decoded (zero-copy)
        format == IMGFMT_NV12 ||           // Software decoded (common)
        format == IMGFMT_420P ||           // YUV420P (very common)
        format == IMGFMT_P010 ||           // 10-bit biplanar
        format == imgfmt_420p10())         // 10-bit planar (AV1/HEVC SW decode)
        return 1;
    return 0;
}

static int reconfig(struct vo *vo, struct mp_image_params *params)
{
    MP_VERBOSE(vo, "reconfig: %dx%d\n", params->w, params->h);
    struct priv *p = vo->priv;
    p->dovi_validated_state = p->hdr10plus_state = p->vivid_state = p->fel_state = 0;
    p->video_statistics = (struct voctrl_native_video_statistics){0};
    p->dovi_unsupported_logged = false;
    avf_clear_sw_upload_metadata(p);

    if (params->repr.sys == PL_COLOR_SYSTEM_DOLBYVISION &&
        params->imgfmt != IMGFMT_VIDEOTOOLBOX) {
        avf_report_unsupported_dovi(vo, "software Dolby Vision needs libplacebo reshaping");
        return -1;
    }

    // Clear subtitles on video reconfig.
    avf_clear_subtitle_state(vo);
    avf_sync_osd_layer_frame(vo);

    return 0;
}

static void uninit(struct vo *vo)
{
    struct priv *p = vo->priv;

    report_osd_perf(vo);

    mp_image_unrefp(&p->next_image);
    sample_buffer_renderer_flush(p->displayLayer, true);
    if (p->osdLayer) {
        [p->osdLayer invalidate];
        [p->osdLayer release];
        p->osdLayer = nil;
    }

    if (p->timebase) {
        p->displayLayer.controlTimebase = NULL;
        CFRelease(p->timebase);
        p->timebase = NULL;
    }

    avf_clear_subtitle_cache(p);

    avf_clear_sw_upload_metadata(p);

    if (p->outputReservePool)
        CVPixelBufferPoolRelease(p->outputReservePool);
    if (p->swUploadReservePool)
        CVPixelBufferPoolRelease(p->swUploadReservePool);

    if (p->outputPool) {
        CVPixelBufferPoolRelease(p->outputPool);
        p->outputPool = NULL;
    }

    if (p->osdPool) {
        CVPixelBufferPoolRelease(p->osdPool);
        p->osdPool = NULL;
    }
    avf_reset_osd_buf_states(p);

    if (p->swUploadPool) {
        CVPixelBufferPoolRelease(p->swUploadPool);
        p->swUploadPool = NULL;
    }

    if (p->video_format_desc) {
        CFRelease(p->video_format_desc);
        p->video_format_desc = NULL;
    }

    if (p->video_format_attachments) CFRelease(p->video_format_attachments);
    p->video_format_attachments = NULL;
    avf_release_ci_compositor(p);
    avf_release_vivid(p);
    avf_release_fel(p);

    [p->displayLayer release];
    p->displayLayer = nil;

    talloc_free(p->opts_cache);
    p->opts_cache = NULL;
    p->opts = NULL;

    hwdec_devices_remove(vo->hwdec_devs, &p->hwctx);
    av_buffer_unref(&p->hwctx.av_device_ref);
    hwdec_devices_destroy(vo->hwdec_devs);
    vo->hwdec_devs = NULL;
}

static int control(struct vo *vo, uint32_t request, void *data)
{
    struct priv *p = vo->priv;

    switch (request) {
    case VOCTRL_GET_NATIVE_VIDEO_STATISTICS:
        *(struct voctrl_native_video_statistics *)data = p->video_statistics;
        return VO_TRUE;
    case VOCTRL_CHECK_EVENTS:
        update_avfoundation_options(vo);
        return VO_TRUE;
    case VOCTRL_VO_OPTS_CHANGED:
        update_avfoundation_options(vo);
        avf_clear_subtitle_cache(p);
        avf_sync_osd_layer_frame(vo);
        return VO_TRUE;
    case VOCTRL_SET_PANSCAN:
        avf_clear_subtitle_cache(p);
        avf_sync_osd_layer_frame(vo);
        return VO_TRUE;
    case VOCTRL_RESET:
        p->dovi_validated_state = p->hdr10plus_state = 0;
        p->video_statistics = (struct voctrl_native_video_statistics){0};
        p->dovi_unsupported_logged = false;
        // vo_seek_reset() runs on seek/stop/track change. Flush queued
        // samples, retain displayed frame through demux/decode to avoid black
        // flashes, matching gpu/gpu-next. Drop OSD layer so stale cues
        // disappear.
        avf_clear_subtitle_state(vo);
        p->not_ready_drop_count = 0;
        p->last_not_ready_drop_ns = 0;
        p->last_display_recovery_ns = 0;
        p->last_video_enqueue_ns = 0;
        p->applied_geometry_last_frame = false;
        p->geometry_render_failure_logged = false;
        bool was_paused = p->playback_paused;
        reset_media_timing(p);
        p->playback_paused = was_paused;
        p->timebase_paused = was_paused;
        sample_buffer_renderer_flush(p->displayLayer, false);
        [p->osdLayer flushRemovingImage:YES];
        if (p->presentation_host && p->timebase) {
            // Fresh host samples have future timestamps. Free-running clock
            // needs only reseed if CoreMedia clamped it between videos.
            CMTimebaseSetTime(p->timebase, cm_time_from_ns(mp_time_ns()));
            CMTimebaseSetRate(p->timebase, 1.0);
        } else if (p->timebase) {
            // Keep clock aligned to held image until next frame anchors it.
            // RESET can follow first post-seek draw; zeroing would strand
            // paused clock away from displayed sample.
            CMTimebaseSetRate(p->timebase, 0.0);
        }
        // RESET can follow first post-seek draw. Repaint retained frame after
        // flush; paused playback may submit nothing else.
        vo->want_redraw = true;
        return VO_TRUE;
    case VOCTRL_PAUSE:
        if (!p->presentation_host)
            set_media_timebase_paused(vo, true);
        return VO_TRUE;
    case VOCTRL_RESUME:
        if (!p->presentation_host)
            set_media_timebase_paused(vo, false);
        return VO_TRUE;
    case VOCTRL_REDRAW:
        p->osd_change_id = 0;
        return VO_TRUE;
    case VOCTRL_UPDATE_WINDOW_TITLE:
        return VO_TRUE;
    }
    return VO_NOTIMPL;
}


#define OPT_BASE_STRUCT struct priv
static const struct m_option priv_options[] = {
    {0},
};

#undef OPT_BASE_STRUCT
#define OPT_BASE_STRUCT struct avfoundation_opts
static const struct m_option avfoundation_options[] = {
    // Lossy mode 2 drops enhancement layer and resets luma/chroma mapping.
    // Latched at decoder creation; changes require media reload.
    {"native-dovi-profile7", OPT_CHOICE(native_dovi_profile7,
        {"no", 0}, {"p8.1", 1})},
    {"composite-osd", OPT_BOOL(composite_osd)},
    // auto: separate OSD layer only for Dolby Vision RPU frames (pixels
    // must stay untouched). always: for every frame (simulator testing).
    {"osd-layer", OPT_CHOICE(osd_layer, {"auto", 0}, {"always", 1})},
    {"pip-composite-osd", OPT_BOOL(pip_composite_osd)},
    {"queue-lead-ms", OPT_INT(queue_lead_ms), M_RANGE(0, 1000)},
    {"presentation", OPT_CHOICE(presentation,
        {"media", AVF_PRESENTATION_MEDIA},
        {"host", AVF_PRESENTATION_HOST})},
    // Inline OSD raster height cap; 0 = display resolution. Layer upscales
    // result.
    {"osd-max-height", OPT_INT(osd_max_height), M_RANGE(0, 4320)},
    {"subtitle-luminance", OPT_DOUBLE(subtitle_luminance), M_RANGE(1, 1000)},
    // Subtitle layer brightness relative to SDR white (HDR subtitle
    // exposure); > 1 turns on EDR for that layer.
    {"subtitle-edr-gain", OPT_DOUBLE(subtitle_edr_gain), M_RANGE(0, 2)},
    // HDR Vivid: map frames with T/UWA 005.1 metadata to this display peak
    // in nits; 0 leaves them to the system as HDR10.
    {"vivid-peak", OPT_DOUBLE(vivid_peak), M_RANGE(0, 10000)},
    // Rasterize at video pixel density: 1:1 over displayed video rect.
    {"osd-video-res", OPT_BOOL(osd_video_res)},
    {0},
};

static const struct m_sub_options avfoundation_conf = {
    .prefix = "avfoundation",
    .opts = avfoundation_options,
    .size = sizeof(struct avfoundation_opts),
    .defaults = &(const struct avfoundation_opts){
        .native_dovi_profile7 = 0,
        .composite_osd = true,
        .pip_composite_osd = true,
        .queue_lead_ms = 128,
        .subtitle_luminance = 203,
        .subtitle_edr_gain = 1.0,
        // tvOS has no PiP. Use host timebase to avoid accumulated drift
        // against mpv's audio-slaved schedule (plezy#1776).
        .presentation = TARGET_OS_TV ? AVF_PRESENTATION_HOST
                                     : AVF_PRESENTATION_MEDIA,
    },
};

const struct vo_driver video_out_avfoundation = {
    .description = "AVFoundation AVSampleBufferDisplayLayer (macOS/iOS)",
    .name = "avfoundation",
    .caps = 0,
    .preinit = preinit,
    .query_format = query_format,
    .control = control,
    .draw_frame = draw_frame,
    .flip_page = flip_page,
    .reconfig = reconfig,
    .uninit = uninit,
    .priv_size = sizeof(struct priv),
    .options = priv_options,
    .global_opts = &avfoundation_conf,
};
