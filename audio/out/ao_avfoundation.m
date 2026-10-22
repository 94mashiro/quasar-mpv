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

#include "ao_avfoundation_priv.h"

static char avfoundation_queue_key;


static CMTime CMTimeFromNanoseconds(int64_t time)
{
    return CMTimeMake(time, 1000000000);
}

static void feed(struct ao *ao);

// AirPlay's latency needs the renderer's own queue depth.
static bool pcm_route_needs_depth(void)
{
#if TARGET_OS_OSX
    return false;
#else
    for (AVAudioSessionPortDescription *port in
            AVAudioSession.sharedInstance.currentRoute.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortAirPlay])
            return true;
    }
    return false;
#endif
}

static void pcm_request_media_data(struct ao *ao)
{
    struct priv *p = ao->priv;
    [p->renderer requestMediaDataWhenReadyOnQueue:p->queue usingBlock:^{
        feed(ao);
    }];
}

// Idle timer on p->queue, or player thread while stop()/uninit() blocks
// queue; no handler race.
static void pcm_cancel_pending_feed(struct priv *p)
{
    if (p->feed_timer) {
        dispatch_source_set_timer(p->feed_timer, DISPATCH_TIME_FOREVER,
                                  DISPATCH_TIME_FOREVER, 0);
    }
}

// Disarm feed until queue falls below bound; retry by timer. Returning empty
// while renderer stays ready spins: callback runs until not-ready/no-data,
// and rearming needs a new ready edge.
static void pcm_pause_feeding(struct ao *ao)
{
    struct priv *p = ao->priv;

    [p->renderer stopRequestingMediaData];
    if (!p->feed_enabled)
        return;
    if (!p->feed_timer) {
        // No wake timer: keep feeding to avoid stall.
        pcm_request_media_data(ao);
        return;
    }
    dispatch_source_set_timer(
        p->feed_timer,
        dispatch_time(DISPATCH_TIME_NOW, p->pcm_lookahead_ns / 2),
        DISPATCH_TIME_FOREVER, p->pcm_lookahead_ns / 10);
}

// Toggle bounded PCM feed on p->queue. start()/stop() already hold queue;
// reentrancy check avoids deadlock with timer.
static void pcm_set_feeding(struct ao *ao, bool enabled)
{
    struct priv *p = ao->priv;

    void (^block)(void) = ^{
        p->feed_enabled = enabled;
        pcm_cancel_pending_feed(p);
        if (enabled) {
            pcm_request_media_data(ao);
        } else {
            [p->renderer stopRequestingMediaData];
        }
    };
    if (dispatch_get_specific(&avfoundation_queue_key) == p)
        block();
    else
        dispatch_sync(p->queue, block);
}

static void feed(struct ao *ao)
{
    struct priv *p = ao->priv;
    int samplerate = ao->samplerate;
    int sstride = ao->sstride;

    if (p->pcm_lookahead_ns) {
        int64_t now = CMTimeGetNanoseconds([p->synchronizer currentTime]);
        if (p->end_time_av - now >= p->pcm_lookahead_ns && !pcm_route_needs_depth()) {
            pcm_pause_feeding(ao);
            return;
        }
    }

    CMBlockBufferRef block_buffer = NULL;
    CMSampleBufferRef sample_buffer = NULL;
    OSStatus err;

    int request_sample_count = samplerate / 10;
    int buffer_size = request_sample_count * sstride;
    void *data[] = {CFAllocatorAllocate(NULL, buffer_size, 0)};

    int64_t cur_time_av = CMTimeGetNanoseconds([p->synchronizer currentTime]);
    int64_t cur_time_mp = mp_time_ns();
    int64_t end_time_av = MPMAX(p->end_time_av, cur_time_av);
    int64_t time_delta = CMTimeGetNanoseconds(CMTimeMake(request_sample_count, samplerate));
    bool eof;
    int real_sample_count = ao_read_data(ao, data, request_sample_count, end_time_av - cur_time_av + cur_time_mp + time_delta, &eof, false, true);
    if (eof) {
        [p->renderer stopRequestingMediaData];
        ao_stop_streaming(ao);
    }
    if (real_sample_count == 0) {
        goto finish;
    }

    if ((err = CMBlockBufferCreateWithMemoryBlock(
        NULL,
        data[0],
        buffer_size,
        NULL,
        NULL,
        0,
        real_sample_count * sstride,
        0,
        &block_buffer
    )) != noErr) {
        MP_FATAL(ao, "failed to create block buffer\n");
        MP_VERBOSE(ao, "CMBlockBufferCreateWithMemoryBlock returned %d\n", err);
        goto error;
    }
    data[0] = NULL;

    CMSampleTimingInfo sample_timing_into[] = {(CMSampleTimingInfo) {
        .duration = CMTimeMake(1, samplerate),
        .presentationTimeStamp = CMTimeFromNanoseconds(end_time_av),
        .decodeTimeStamp = kCMTimeInvalid
    }};
    size_t sample_size_array[] = {sstride};
    if ((err = CMSampleBufferCreateReady(
        NULL,
        block_buffer,
        p->format_description,
        real_sample_count,
        1,
        sample_timing_into,
        1,
        sample_size_array,
        &sample_buffer
    )) != noErr) {
        MP_FATAL(ao, "failed to create sample buffer\n");
        MP_VERBOSE(ao, "CMSampleBufferCreateReady returned %d\n", err);
        goto error;
    }

    [p->renderer enqueueSampleBuffer:sample_buffer];

    time_delta = CMTimeGetNanoseconds(CMTimeMake(real_sample_count, samplerate));
    p->end_time_av = end_time_av + time_delta;

    goto finish;

error:
    ao_request_reload(ao);
finish:
    if (data[0]) CFAllocatorDeallocate(NULL, data[0]);
    if (block_buffer) CFRelease(block_buffer);
    if (sample_buffer) CFRelease(sample_buffer);
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->spdif) {
        void (^start_block)(void) = ^{
            if (p->spdif_reload_requested)
                return;
            ao_avf_avp_apply_volume(ao);
            p->avp_playing = true;
            p->avp_last_progress = mp_time_ns();
            // Published drain/underrun permits restart when data arrives. EOF
            // also needs fresh finite epoch.
            if (p->avp_eof)
                ao_avf_avp_teardown_item(ao);
            if (!p->item)
                ao_avf_avp_create_item(ao);
            else if (p->avp_rate_applied)
                [p->player setRate:1];
            avp_timer_arm(p);
            ao_avf_feed_avp(ao);
        };
        if (dispatch_get_specific(&avfoundation_queue_key) == p)
            start_block();
        else
            dispatch_sync(p->queue, start_block);
        return;
    }

    p->end_time_av = -1;
    [p->synchronizer setRate:1];
    // Unbounded path needs no gate; retain direct initial arm.
    if (p->pcm_lookahead_ns) {
        pcm_set_feeding(ao, true);
        return;
    }
    [p->renderer requestMediaDataWhenReadyOnQueue:p->queue usingBlock:^{
        feed(ao);
    }];
}

static void stop(struct ao *ao)
{
    struct priv *p = ao->priv;

    void (^stop_block)(void) = ^{
        if (p->spdif) {
            p->avp_playing = false;
            avp_timer_idle(p);
            ao_avf_avp_teardown_item(ao);
            ao_update_streaming_clock(ao, 0, 0, false);
            return;
        }
        [p->renderer stopRequestingMediaData];
        [p->renderer flush];
        [p->synchronizer setRate:0];
        // Frozen clock cannot drain; unschedule feed until start().
        p->feed_enabled = false;
        pcm_cancel_pending_feed(p);
    };
    if (dispatch_get_specific(&avfoundation_queue_key) == p)
        stop_block();
    else
        dispatch_sync(p->queue, stop_block);
}

static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;

    if (p->spdif) {
        void (^pause_block)(void) = ^{
            if (p->spdif_reload_requested)
                return;
            ao_avf_avp_apply_volume(ao);
            p->avp_playing = !paused;
            if (paused) {
                avp_timer_idle(p);
                [p->player setRate:0];
                ao_avf_avp_publish_clock(ao);
            } else {
                p->avp_last_progress = mp_time_ns();
                if (p->avp_rate_applied) {
                    [p->player setRate:1];
                    if (p->avp_start_deadline >= 0)
                        p->avp_start_deadline = mp_time_ns() + AVP_START_GRACE_NS;
                } else {
                    // Resume priming/readiness supervision now.
                    p->avp_start_deadline = mp_time_ns() + AVP_READY_GRACE_NS;
                }
                avp_timer_arm(p);
                ao_avf_feed_avp(ao);
            }
        };
        if (dispatch_get_specific(&avfoundation_queue_key) == p)
            pause_block();
        else
            dispatch_sync(p->queue, pause_block);
        return true;
    }

    if (paused) {
        [p->synchronizer setRate:0];
        // Stopped clock cannot lower queue depth; stop requests instead of
        // polling every half-bound.
        if (p->pcm_lookahead_ns)
            pcm_set_feeding(ao, false);
    } else {
        if (p->pcm_lookahead_ns)
            pcm_set_feeding(ao, true);
        [p->synchronizer setRate:1];
    }

    return true;
}

static int control(struct ao *ao, enum aocontrol cmd, void *arg)
{
    struct priv *p = ao->priv;

    if (cmd == AOCONTROL_GET_SPATIAL_STATUS) {
        struct mpv_node *node = arg;
        node_init(node, MPV_FORMAT_NODE_MAP, NULL);
        node_map_add_string(node, "path", p->spdif ? "avplayer" : "sample-buffer");
        __block AVAudioSpatializationFormats formats = AVAudioSpatializationFormatNone;
        __block bool available = false;
        void (^read_formats)(void) = ^{
            if (@available(tvOS 15.0, iOS 15.0, macOS 12.0, *)) {
                available = p->spdif ? p->item != nil : p->renderer != nil;
                formats = p->spdif ? p->item.allowedAudioSpatializationFormats
                                  : p->renderer.allowedAudioSpatializationFormats;
            }
        };
        dispatch_sync(p->queue, read_formats);
        if (available) {
            node_map_add_flag(node, "allows-stereo", !!(formats & AVAudioSpatializationFormatMonoAndStereo));
            node_map_add_flag(node, "allows-multichannel", !!(formats & AVAudioSpatializationFormatMultichannel));
        }
#if TARGET_OS_IPHONE
        if (@available(tvOS 15.0, iOS 15.0, *)) {
            NSArray<AVAudioSessionPortDescription *> *outputs = AVAudioSession.sharedInstance.currentRoute.outputs;
            if (outputs.count) {
                bool enabled = false;
                for (AVAudioSessionPortDescription *port in outputs)
                    enabled |= port.isSpatialAudioEnabled;
                node_map_add_flag(node, "route-spatial-enabled", enabled);
            }
        }
#endif
        return CONTROL_OK;
    }

    if (p->spdif) {
        __block int result = CONTROL_OK;
        void (^control_block)(void) = ^{
            switch (cmd) {
            case AOCONTROL_GET_MUTE:
                *(bool*)arg = p->avp_muted;
                break;
            case AOCONTROL_GET_VOLUME:
                *(float*)arg = p->avp_volume * 100;
                break;
            case AOCONTROL_SET_MUTE:
                p->avp_muted = *(bool*)arg;
                ao_avf_avp_apply_volume(ao);
                break;
            case AOCONTROL_SET_VOLUME:
                p->avp_volume = MPCLAMP(*(float*)arg / 100, 0, 1);
                ao_avf_avp_apply_volume(ao);
                break;
            default:
                result = CONTROL_UNKNOWN;
            }
        };
        if (dispatch_get_specific(&avfoundation_queue_key) == p)
            control_block();
        else
            dispatch_sync(p->queue, control_block);
        return result;
    }

    switch (cmd) {
    case AOCONTROL_GET_MUTE:
        *(bool*)arg = [p->renderer isMuted];
        return CONTROL_OK;
    case AOCONTROL_GET_VOLUME:
        *(float*)arg = [p->renderer volume] * 100;
        return CONTROL_OK;
    case AOCONTROL_SET_MUTE:
        [p->renderer setMuted:*(bool*)arg];
        return CONTROL_OK;
    case AOCONTROL_SET_VOLUME:
        [p->renderer setVolume:*(float*)arg / 100];
        return CONTROL_OK;
    default:
        return CONTROL_UNKNOWN;
    }
}

@implementation AVObserver
- (instancetype)initWithAO:(struct ao*)_ao {
    self = [super init];
    if (self) {
        ao = _ao;
    }
    return self;
}
- (void)handleRestartNotification:(NSNotification*)notification {
    @synchronized(self) {
        if (!ao)
            return;
        MP_VERBOSE(ao, "audio output changed: %s\n", notification.name.UTF8String);
        // Core performs the flush/reload and restores its paused state. Never
        // start audio from an arbitrary notification thread or after teardown.
        ao_request_reload(ao);
    }
}
- (void)invalidate {
    @synchronized(self) {
        ao = NULL;
    }
}
@end

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;
    AudioChannelLayout *layout = NULL;
    bool spdif = af_fmt_is_spdif(ao->format);

    if (spdif && !p->opt_accept_compressed) {
        MP_VERBOSE(ao, "compressed audio disabled; trying next audio output\n");
        return CONTROL_ERROR;
    }

    // AVPlayer follows system route, ignoring mpv device UID/exclusive mode.
    // Reject before shared-session changes.
    if (spdif && ((ao->device && ao->device[0]) ||
                  (ao->init_flags & AO_INIT_EXCLUSIVE))) {
        MP_VERBOSE(ao, "compressed AVPlayer cannot honor explicit/exclusive routing; using PCM\n");
        return CONTROL_ERROR;
    }

#if TARGET_OS_IPHONE
    // The session is shared by the whole host, including concurrent players.
    // Hosts with their own policy can opt out. Deactivation belongs to the
    // host's lifecycle, never an individual AO reload or player teardown.
    if (p->opt_manage_session) {
        AVAudioSession *session = AVAudioSession.sharedInstance;
        NSError *error = nil;
        if (![session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeMoviePlayback options:0 error:&error] ||
            ![session setSupportsMultichannelContent:YES error:&error] ||
            ![session setActive:YES error:&error]) {
            MP_ERR(ao, "audio session setup failed: %s\n", error.localizedDescription.UTF8String);
            return CONTROL_ERROR;
        }
        // Physical headphone channels are not the decoded content layout.
        // Keep ao->channels intact so Apple can spatialize surround content.
        NSInteger preferred = MIN(session.maximumOutputNumberOfChannels, ao->channels.num);
        if (!spdif && preferred > 0 &&
            ![session setPreferredOutputNumberOfChannels:preferred error:&error])
            MP_VERBOSE(ao, "preferred route channels unavailable: %s\n", error.localizedDescription.UTF8String);
    }
#endif

    if ((p->queue = dispatch_queue_create(
        "avfoundation event",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
    )) == NULL) {
        MP_FATAL(ao, "failed to create dispatch queue\n");
        MP_VERBOSE(ao, "dispatch_queue_create failed\n");
        goto error;
    }
    dispatch_queue_set_specific(p->queue, &avfoundation_queue_key, p, NULL);

    if (spdif) {
        // Only explicit audio-spdif codecs enter here; PCM keeps existing
        // renderer.
        switch (ao->format) {
        case AF_FORMAT_S_AC3:
            p->spdif_data_type = IEC61937_AC3;
            // ad_spdif AC3: 1x-rate IEC 61937.
            p->spdif_rate = ao->samplerate;
            p->spdif_burst_size = 6144;
            p->spdif_uti = "public.ac3-audio";
            p->spdif_ext = "ac3";
            break;
        case AF_FORMAT_S_EAC3:
            p->spdif_data_type = IEC61937_EAC3;
            // ad_spdif EAC3: 4x-rate IEC 61937.
            p->spdif_rate = ao->samplerate / 4;
            p->spdif_burst_size = 24576;
            p->spdif_uti = "public.enhanced-ac3-audio";
            p->spdif_ext = "eac3";
            break;
        default:
            MP_FATAL(ao, "avfoundation only supports AC3 and EAC3 passthrough\n");
#if HAVE_COREAUDIO
            MP_FATAL(ao, "please use coreaudio_exclusive instead\n");
#endif
            goto error;
        }
        p->spdif = true;
        ao->device_clock = true;
        ao->drain_before_gapless = true;
        if (ao->samplerate <= 0 || ao->samplerate > 192000 ||
            p->spdif_rate <= 0 || ao->channels.num != 2) {
            MP_ERR(ao, "invalid compressed audio format\n");
            goto error;
        }

        if ((p->player = [[AVPlayer alloc] init]) == nil) {
            MP_FATAL(ao, "failed to create AVPlayer\n");
            goto error;
        }
        p->avp_volume = 1;
        ao_avf_avp_apply_volume(ao);
        // Own priming/start recovery here; disable player guesses against
        // synthetic endless resource.
        p->player.automaticallyWaitsToMinimizeStalling = NO;
#if !TARGET_OS_VISION
        p->player.allowsExternalPlayback = NO;
#endif
        p->loader = [[AVPLoader alloc] initWithAO:ao];
        if (!p->loader)
            goto error;
        if ((p->avp_timer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, p->queue)) == NULL) {
            MP_FATAL(ao, "failed to create feed timer\n");
            goto error;
        }
        dispatch_source_set_event_handler(p->avp_timer, ^{
            ao_avf_feed_avp(ao);
        });
        avp_timer_idle(p);
        // Keep resumed for lifetime; releasing suspended source traps. Idle
        // timer costs nothing.
        dispatch_resume(p->avp_timer);

        p->avp_lead_ns = (int64_t)(p->opt_compressed_lead * 1e9);

        // 100ms IEC per pull plus partial bursts
        p->stash_size = (ao->samplerate / 10) * af_fmt_to_bytes(ao->format) *
                        ao->channels.num + p->spdif_burst_size * 4;
        p->stash = talloc_size(ao, p->stash_size);
        // history + bounded startup lead at max EAC3 rate + slack
        p->es_size = AVP_ES_HISTORY_BYTES + 1024 * 1024 +
                     (int)(2 * p->opt_compressed_lead * AVP_ES_LEAD_BYTES_PER_S);
        p->es_buf = talloc_size(ao, p->es_size);
        // Lead bound paces stream.
        ao->device_buffer = ao->samplerate * 2;

        return CONTROL_OK;
    }

    if ((p->renderer = [[AVSampleBufferAudioRenderer alloc] init]) == nil) {
        MP_FATAL(ao, "failed to create audio renderer\n");
        MP_VERBOSE(ao, "AVSampleBufferAudioRenderer failed to initialize\n");
        goto error;
    }
    if (@available(tvOS 15.0, iOS 15.0, macOS 12.0, *))
        p->renderer.allowedAudioSpatializationFormats = spatial_formats(p);

    if ((p->synchronizer = [[AVSampleBufferRenderSynchronizer alloc] init]) == nil) {
        MP_FATAL(ao, "failed to create rendering synchronizer\n");
        MP_VERBOSE(ao, "AVSampleBufferRenderSynchronizer failed to initialize\n");
        goto error;
    }

    // --audio-buffer is minimum, not maximum. Use only to keep bound above
    // core's promised buffering.
    if (p->opt_max_lookahead > 0) {
        p->pcm_lookahead_ns =
            (int64_t)(MPMAX(p->opt_max_lookahead, ao->def_buffer) * 1e9);
        p->feed_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               p->queue);
        if (p->feed_timer) {
            dispatch_source_set_event_handler(p->feed_timer, ^{
                pcm_cancel_pending_feed(p);  // one-shot: idle before refeeding
                // Stop/pause may have arrived since timer fired.
                if (p->feed_enabled)
                    pcm_request_media_data(ao);
            });
            dispatch_source_set_timer(p->feed_timer, DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
            // Keep resumed for lifetime; releasing suspended source traps.
            // Idle timer costs nothing.
            dispatch_resume(p->feed_timer);
        } else {
            MP_WARN(ao, "no timer available; leaving the renderer's own "
                        "buffer depth alone\n");
            p->pcm_lookahead_ns = 0;
        }
    }

    if (ao->device && ao->device[0]) {
#if TARGET_OS_OSX
        [p->renderer setAudioOutputDeviceUniqueID:[NSString stringWithUTF8String:ao->device]];
#endif
    }

    [p->synchronizer addRenderer:p->renderer];
#if HAVE_MACOS_11_3_FEATURES
    if (@available(tvOS 14.5, iOS 14.5, macOS 11.3, *)) {
        [p->synchronizer setDelaysRateChangeUntilHasSufficientMediaData:NO];
    }
#endif

    // AVSampleBufferAudioRenderer only supports interleaved formats
    ao->format = af_fmt_from_planar(ao->format);
    if (af_fmt_is_planar(ao->format)) {
        MP_FATAL(ao, "planar audio formats are unsupported\n");
        goto error;
    }

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);
    size_t layout_size;
    layout = ca_get_acl(ao, &layout_size);

    OSStatus err;
    if ((err = CMAudioFormatDescriptionCreate(
        NULL,
        &asbd,
        layout_size,
        layout,
        0,
        NULL,
        NULL,
        &p->format_description
    )) != noErr) {
        MP_FATAL(ao, "failed to create audio format description\n");
        MP_VERBOSE(ao, "CMAudioFormatDescriptionCreate returned %d\n", err);
        goto error;
    }
    talloc_free(layout);
    layout = NULL;

    // AVSampleBufferAudioRenderer read ahead aggressively. With the queue
    // bounded, a soft buffer of the same depth suffices; a 2 s one would
    // hold another 2 s stretched at the old speed after a speed change.
    ao->device_buffer = p->pcm_lookahead_ns
        ? (int)(ao->samplerate * (p->pcm_lookahead_ns / 1e9))
        : ao->samplerate * 2;

    p->observer = [[AVObserver alloc] initWithAO:ao];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if HAVE_MACOS_12_FEATURES
    if (@available(tvOS 15.0, iOS 15.0, macOS 12.0, *)) {
        [center addObserver:p->observer selector:@selector(handleRestartNotification:) name:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification object:p->renderer];
    }
#endif
    [center addObserver:p->observer selector:@selector(handleRestartNotification:) name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:p->renderer];

    return CONTROL_OK;

error:
    p->spdif = spdif;
    talloc_free(layout);
    if (p->avp_timer) {
        dispatch_source_cancel(p->avp_timer);
        dispatch_release(p->avp_timer);
        p->avp_timer = NULL;
    }
    if (p->feed_timer) {
        dispatch_source_cancel(p->feed_timer);
        dispatch_release(p->feed_timer);
        p->feed_timer = NULL;
    }
    if (p->loader) {
        [p->loader invalidate];
        [p->loader release];
    }
    if (p->player) [p->player release];
    if (p->renderer) [p->renderer release];
    if (p->synchronizer) [p->synchronizer release];
    if (p->queue) dispatch_release(p->queue);
    if (p->format_description) CFRelease(p->format_description);


    return CONTROL_ERROR;
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->observer) {
        [p->observer invalidate];
        [[NSNotificationCenter defaultCenter] removeObserver:p->observer];
    }
    stop(ao);

    if (p->spdif) {
        // Cancel on p->queue before ao_uninit() frees handler's AO; no active
        // or future handler remains.
        dispatch_sync(p->queue, ^{
            dispatch_source_cancel(p->avp_timer);
            [p->loader invalidate];
        });
        dispatch_release(p->avp_timer);
        [p->loader release];
        [p->player release];
        dispatch_release(p->queue);
    } else {
        // stop() idled timer. Cancel on p->queue before ao_uninit() frees
        // handler's AO; no active or future handler remains.
        if (p->feed_timer) {
            dispatch_sync(p->queue, ^{
                dispatch_source_cancel(p->feed_timer);
            });
            dispatch_release(p->feed_timer);
            p->feed_timer = NULL;
        }
        [p->renderer release];
        [p->synchronizer release];
        dispatch_release(p->queue);
        CFRelease(p->format_description);

        [p->observer release];
    }

}

#define OPT_BASE_STRUCT struct priv

const struct ao_driver audio_out_avfoundation = {
    .description    = "AVFoundation AVSampleBufferAudioRenderer / AVPlayer",
    .name           = "avfoundation",
    .uninit         = uninit,
    .init           = init,
    .control        = control,
    .reset          = stop,
    .start          = start,
    .set_pause      = set_pause,
    .list_devs      = ca_get_device_list,
    .priv_size      = sizeof(struct priv),
    .priv_defaults  = &(const struct priv){
        .opt_accept_compressed = true,
        .opt_spatial_audio = 2,
        .opt_manage_session = true,
        .opt_compressed_lead = 8,
        // Preserve PCM latency unless bound enabled.
        .opt_max_lookahead = 0,
    },
    .options = (const struct m_option[]) {
        {"max-lookahead", OPT_DOUBLE(opt_max_lookahead), M_RANGE(0, 10)},
        {"spatial-audio", OPT_CHOICE(opt_spatial_audio,
            {"no", 0}, {"multichannel", 1}, {"all", 2})},
        {"manage-audio-session", OPT_BOOL(opt_manage_session)},
        {"accept-compressed", OPT_BOOL(opt_accept_compressed)},
        {"compressed-lead", OPT_DOUBLE(opt_compressed_lead), M_RANGE(1, 30)},
        {0}
    },
    .options_prefix = "ao-avfoundation",
};
