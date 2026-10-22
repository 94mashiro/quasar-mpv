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

// Shared by ao_avfoundation.m and ao_avfoundation_avplayer.m: state, constants, small
// helpers and the functions one file calls in another.

#pragma once

#include "ao.h"
#include "audio/format.h"
#include "audio/out/ao_avfoundation_iec.h"
#include "audio/out/ao_coreaudio_chmap.h"
#include "audio/out/ao_coreaudio_utils.h"
#include "common/common.h"
#include "common/msg.h"
#include "internal.h"
#include "options/m_option.h"
#include "misc/node.h"
#include "mpv/client.h"
#include "osdep/timer.h"
#include "ta/ta_talloc.h"

#include <errno.h>
#include <math.h>
#include <stdatomic.h>

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface AVObserver : NSObject {
    struct ao *ao;
}
- (void)handleRestartNotification:(NSNotification*)notification;
- (void)invalidate;
@end

@interface AVPLoader : NSObject <AVAssetResourceLoaderDelegate> {
    struct ao *ao;
@public
    NSMutableArray<AVAssetResourceLoadingRequest *> *requests;
}
- (instancetype)initWithAO:(struct ao*)_ao;
- (void)invalidate;
@end

struct priv {
    // PCM sink
    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    dispatch_queue_t queue;
    CMAudioFormatDescriptionRef format_description;
    AVObserver *observer;
    int64_t end_time_av;

    // Opt-in AC3/EAC3 elementary stream via in-process AVAssetResourceLoader.
    // Apple handles route-specific Dolby/Atmos; hardware validation required.
    bool spdif;
    int spdif_rate;              // elementary-stream audio rate
    int spdif_burst_size;        // IEC 61937 burst repetition period, bytes
    int spdif_data_type;         // IEC 61937 Pc data type for this format
    const char *spdif_uti;       // UTI declared to AVPlayer
    const char *spdif_ext;       // synthetic stream extension
    bool spdif_reload_requested;
    uint8_t *stash;              // partial IEC bursts between pulls
    int stash_len;
    int stash_size;

    AVPlayer *player;
    float avp_volume;           // ao-volume, independently combined with gain
    bool avp_gain_warned;
    bool avp_muted;             // ao-mute, independent of software mute
    AVPlayerItem *item;
    AVURLAsset *asset;
    AVPLoader *loader;
    // Compressed driver pulls mpv, serves loader, applies transport. Create
    // once; idle at DISPATCH_TIME_FOREVER. Keep resumed: releasing suspended
    // source traps.
    dispatch_source_t avp_timer;
    // AVPlayer ES window indexed by byte offset. Retain bounded read history
    // for offset-zero restarts.
    uint8_t *es_buf;
    int es_size;
    int es_len;
    int64_t es_head;             // stream offset of es_buf[0]
    int64_t es_pts;              // appended audio ns since item epoch
    int64_t pulled_samples;      // IEC samples handed over by ao_read_data
    int64_t es_dropped_ns;       // AU periods pulled but never appended
    bool avp_playing;            // desired transport state
    bool avp_rate_applied;       // AVPlayer received rate 1
    bool avp_start_seeked;       // seek-to-start retry used
    bool avp_eof;
    int64_t avp_info_deadline;   // bounded initial metadata prefill grace
    bool avp_bounded_length;    // metadata advertised ceiling, not EOF
    bool avp_eof_response;      // loader received actual end
    int64_t es_served_until;    // contiguous bytes from offset zero
    int64_t avp_eof_parked_since;
    int64_t avp_eof_parked_position;
    int64_t avp_eof_parked_end;
    int64_t avp_start_deadline;  // mp_time_ns() deadline; -1 = healthy
    int64_t avp_primed_pts;      // es_pts at last priming progress
    int avp_last_item_status;    // last logged AVPlayerItemStatus
    int avp_last_tcs;            // last logged AVPlayerTimeControlStatus
    int64_t avp_last_position;
    int64_t avp_last_progress;
    int avp_heartbeat;           // verbose position log divider
    int64_t avp_lead_ns;         // steady-state ES lead option
    // AC3/EAC3 opt-in routes through AVPlayer. Disable to let next configured
    // AO handle bitstream.
    bool opt_accept_compressed;
    int opt_spatial_audio; // 0=off, 1=multichannel, 2=all
    bool opt_manage_session;
    // ES lead ahead of observed playhead, seconds. Loader reads through write
    // head regardless of lead; Apple consumes ~1.8s quanta. At 2s lead,
    // refills overran write head, skipping ~100-220ms every 1.79s on tvOS
    // regardless of bitrate/route (plezy#1300, plezy#1776). At 8s, ~4x
    // quantum, ~4min measurement dropped from 21/min (Plezy 2.15) or 10.6/min
    // (2s AO) to zero.
    double opt_compressed_lead;
    // PCM lookahead bound. macOS: slider/keyboard --volume is software gain
    // baked into queued samples. All platforms: speed changes (scaletempo)
    // are baked in too, so video runs at the new speed while queued audio
    // still plays the old one and A/V sync holds frames until it drains.
    // Not applied while routed to AirPlay, whose latency needs the depth.
    //
    // Limit PCM enqueue lead. Local AVSampleBufferAudioRenderer backpressure
    // measured ~1.7s; software gain is baked into queued samples, delaying
    // volume changes until drain. Bound reduces delay; 0 preserves renderer
    // depth.
    int64_t pcm_lookahead_ns;
    // Owned one-shot timer, idle at DISPATCH_TIME_FOREVER. Unlike
    // dispatch_after, teardown can cancel before ao_uninit() frees AO
    // referenced by handler.
    dispatch_source_t feed_timer;
    // PCM feeding flag; mutate only on p->queue. Frozen clock cannot drain,
    // so stop timer from repeatedly checking exceeded bound.
    bool feed_enabled;
    double opt_max_lookahead;
};

// Eligibility only: Apple still honors the user's Off/Fixed/Head Tracked choice.
static inline AVAudioSpatializationFormats spatial_formats(struct priv *p)
{
    switch (p->opt_spatial_audio) {
    case 0: return AVAudioSpatializationFormatNone;
    case 1: return AVAudioSpatializationFormatMultichannel;
    default: return AVAudioSpatializationFormatMonoStereoAndMultichannel;
    }
}

#define IEC61937_HEADER_SIZE 8
#define IEC61937_AC3  0x01
#define IEC61937_EAC3 0x15

// IEC 61937 burst: 1536 samples at base rate.
#define SPDIF_FRAMES_PER_BURST 1536

#define AVP_TICK_NS         MP_TIME_MS_TO_NS(50)
// Startup lead allows seconds of preroll before playhead moves. Steady-state
// cap would deadlock against frozen clock.
#define AVP_START_LEAD_NS(p) (2 * (p)->avp_lead_ns)
// Minimum transport priming.
#define AVP_START_MIN_NS    MP_TIME_S_TO_NS(1)
// Readiness deadline after priming.
#define AVP_READY_GRACE_NS  MP_TIME_S_TO_NS(5)
// Playhead-movement deadline after rate applied.
#define AVP_START_GRACE_NS  MP_TIME_S_TO_NS(2)
// Read history for offset-zero restarts.
#define AVP_ES_HISTORY_BYTES (2 * 1024 * 1024)
// Huge resource lengths park Apple's raw Dolby parser. Use upstream ceiling;
// reload PCM before reaching it.
#define AVP_RESOURCE_MAX_BYTES INT32_MAX
// Brief metadata delay lets fast finite input reveal EOF. Live startup adds
// only this grace to minimum preroll.
#define AVP_INFO_PREFILL_NS MP_TIME_MS_TO_NS(250)
// Bounded Dolby items may park ~98ms before ES end without notification.
// Settle only fully delivered narrow tail; larger/startup stalls recover PCM.
#define AVP_EOF_TAIL_NS MP_TIME_MS_TO_NS(100)
#define AVP_EOF_SETTLE_NS MP_TIME_MS_TO_NS(250)
// ES lead byte budget: legal E-AC-3 maximum 6.144 Mb/s = 768 KiB/s.
#define AVP_ES_LEAD_BYTES_PER_S (768 * 1024)

static inline int64_t CMTimeGetNanoseconds(CMTime time)
{
    time = CMTimeConvertScale(time, 1000000000, kCMTimeRoundingMethod_Default);
    return time.value;
}

static inline void avp_timer_idle(struct priv *p)
{
    dispatch_source_set_timer(p->avp_timer, DISPATCH_TIME_FOREVER,
                              DISPATCH_TIME_FOREVER, 0);
}

static inline void avp_timer_arm(struct priv *p)
{
    dispatch_source_set_timer(
        p->avp_timer,
        dispatch_time(DISPATCH_TIME_NOW, AVP_TICK_NS),
        AVP_TICK_NS, AVP_TICK_NS / 2);
}

void ao_avf_avp_apply_volume(struct ao *ao);

bool ao_avf_avp_publish_clock(struct ao *ao);

void ao_avf_feed_avp(struct ao *ao);

void ao_avf_avp_create_item(struct ao *ao);

void ao_avf_avp_teardown_item(struct ao *ao);
