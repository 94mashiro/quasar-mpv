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
#if TARGET_OS_OSX
    // PCM lookahead bound: macOS only, where slider/keyboard --volume affects
    // software gain. iOS/tvOS hardware volume bypasses mpv; deep renderer
    // queue supports AirPlay.
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
#endif
};

// Eligibility only: Apple still honors the user's Off/Fixed/Head Tracked choice.
static AVAudioSpatializationFormats spatial_formats(struct priv *p)
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

static char avfoundation_queue_key;

static void feed_avp(struct ao *ao);

static int64_t CMTimeGetNanoseconds(CMTime time)
{
    time = CMTimeConvertScale(time, 1000000000, kCMTimeRoundingMethod_Default);
    return time.value;
}

static CMTime CMTimeFromNanoseconds(int64_t time)
{
    return CMTimeMake(time, 1000000000);
}

static void avp_timer_idle(struct priv *p)
{
    dispatch_source_set_timer(p->avp_timer, DISPATCH_TIME_FOREVER,
                              DISPATCH_TIME_FOREVER, 0);
}

static void avp_timer_arm(struct priv *p)
{
    dispatch_source_set_timer(
        p->avp_timer,
        dispatch_time(DISPATCH_TIME_NOW, AVP_TICK_NS),
        AVP_TICK_NS, AVP_TICK_NS / 2);
}

// Request owning core's PCM recovery; no cross-player state.
static void spdif_reload(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->spdif_reload_requested)
        return;
    p->spdif_reload_requested = true;
    [p->player setRate:0];
    avp_timer_idle(p);
    ao_update_streaming_clock(ao, 0, 0, false);
    ao_request_pcm_fallback(ao);
}

// ES playhead: read AVPlayerItem timebase, avoiding chunked currentTime
// jitter from custom loading. Timebase follows device clock continuously.
// Clamp to written range; idle reports zero, playback cannot pass write head.
static int64_t avp_current_time_ns(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->item)
        return 0;
    CMTime t = kCMTimeInvalid;
    CMTimebaseRef timebase = p->item.timebase;
    if (timebase)
        t = CMTimebaseGetTime(timebase);
    if (!CMTIME_IS_NUMERIC(t))
        t = [p->item currentTime];
    if (!CMTIME_IS_NUMERIC(t))
        return 0;
    return MPCLAMP(CMTimeGetNanoseconds(t), 0, p->es_pts);
}

// Use most-advanced playhead only for feed pacing. Some HDMI routes offset
// timebase/currentTime readings; lagging estimate reduces 2s lead, causing
// periodic write-head stalls. Advanced estimate adds only ES-window-bounded
// lead.
static int64_t avp_feed_position_ns(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->item)
        return 0;
    int64_t pos = avp_current_time_ns(ao);
    CMTime t = [p->item currentTime];
    if (CMTIME_IS_NUMERIC(t))
        pos = MPMAX(pos, CMTimeGetNanoseconds(t));
    return MPCLAMP(pos, 0, p->es_pts);
}

// Byte-swap burst payload back to raw bitstream; append to ES window.
static void avp_append_es(struct ao *ao, const uint8_t *payload, int payload_len)
{
    struct priv *p = ao->priv;

    if (payload_len & 1) {
        // (E-)AC-3 frame length: 16-bit words
        MP_WARN(ao, "discarding burst with odd payload length\n");
        spdif_reload(ao);
        return;
    }
    if (payload_len < 8 || payload_len > p->es_size - p->es_len) {
        // impossible within lead/history bounds
        MP_ERR(ao, "elementary stream window overflow; falling back to PCM\n");
        spdif_reload(ao);
        return;
    }
    if (p->es_head >= AVP_RESOURCE_MAX_BYTES - p->es_len - payload_len) {
        MP_WARN(ao, "compressed resource byte limit reached; falling back to PCM\n");
        spdif_reload(ao);
        return;
    }
    uint8_t *dst = p->es_buf + p->es_len;
    // Undo SPDIF muxer's 16-bit LE word order.
    for (int i = 0; i < payload_len; i += 2) {
        dst[i]     = payload[i + 1];
        dst[i + 1] = payload[i];
    }
    if (dst[0] != 0x0b || dst[1] != 0x77) {
        MP_WARN(ao, "discarding burst without syncframe\n");
        spdif_reload(ao);
        return;
    }
    p->es_len += payload_len;
    p->es_pts += CMTimeGetNanoseconds(
        CMTimeMake(SPDIF_FRAMES_PER_BURST, p->spdif_rate));
}

// Pull/unwrap IEC 61937; append complete burst payloads. Return false on
// starvation, EOF, or reload.
static bool avp_pull(struct ao *ao)
{
    struct priv *p = ao->priv;
    int samplerate = ao->samplerate;
    int sstride = ao->sstride;
    bool eof = false;

    int request_sample_count = samplerate / 10;
    if ((p->stash_size - p->stash_len) / sstride < request_sample_count)
        request_sample_count = (p->stash_size - p->stash_len) / sstride;
    if (request_sample_count <= 0)
        return false;

    // Core transfers pulled duration from queue to native clock atomically;
    // avp_publish_clock anchors to Apple playhead. Whole-burst es_pts jumps
    // up to 32ms on partial pulls; use only as EOF bound.
    void *data[] = {p->stash + p->stash_len};
    int real_sample_count = ao_read_data(ao, data, request_sample_count,
        0, &eof, false, true);
    if (eof)
        p->avp_eof = true; // Keep native clock until queue drains.
    if (real_sample_count == 0) {
        if (eof && p->stash_len)
            spdif_reload(ao);
        return false;
    }
    p->stash_len += real_sample_count * sstride;
    p->pulled_samples += real_sample_count;

    // Consume complete repetition periods, padding included.
    // Damaged/unexpected IEC cannot supply reliable clock.
    int pos = 0;
    while (pos < p->stash_len) {
        int payload_len = 0;
        int result = avfoundation_iec_payload(p->stash + pos, p->stash_len - pos,
            p->spdif_data_type, p->spdif_burst_size, &payload_len);
        if (result < 0) {
            MP_ERR(ao, "invalid IEC 61937 burst; falling back to PCM\n");
            spdif_reload(ao);
            return false;
        }
        if (!result)
            break;
        avp_append_es(ao, p->stash + pos + IEC61937_HEADER_SIZE, payload_len);
        if (p->spdif_reload_requested)
            return false;
        pos += p->spdif_burst_size;
    }
    if (pos > 0) {
        memmove(p->stash, p->stash + pos, p->stash_len - pos);
        p->stash_len -= pos;
    }
    if (eof && p->stash_len) {
        MP_ERR(ao, "truncated IEC 61937 burst at EOF; falling back to PCM\n");
        spdif_reload(ao);
        return false;
    }
    return !eof;
}

// Serve pending requests from ES window; trim consumed history.
static void avp_serve_requests(struct ao *ao)
{
    struct priv *p = ao->priv;
    NSMutableArray<AVAssetResourceLoadingRequest *> *reqs = p->loader->requests;

    for (NSUInteger i = 0; i < reqs.count; ) {
        AVAssetResourceLoadingRequest *req = reqs[i];
        if (req.finished || req.cancelled) {
            [reqs removeObjectAtIndex:i];
            continue;
        }
        AVAssetResourceLoadingContentInformationRequest *info = req.contentInformationRequest;
        if (info && !info.contentType) {
            if (!p->avp_info_deadline)
                p->avp_info_deadline = mp_time_ns() + AVP_INFO_PREFILL_NS;
            // Give fast finite input brief EOF-detection grace. Live startup
            // must not depend on configurable lead. Full capacity starts
            // immediately to avoid deadlock.
            if (!p->avp_eof && p->es_size - p->es_len >= p->stash_size &&
                (p->es_pts < AVP_START_MIN_NS || mp_time_ns() < p->avp_info_deadline)) {
                i++;
                continue;
            }
            info.contentType = [NSString stringWithUTF8String:p->spdif_uti];
            info.contentLength = p->avp_eof ? p->es_head + p->es_len
                                          : AVP_RESOURCE_MAX_BYTES;
            info.byteRangeAccessSupported = NO;
            p->avp_bounded_length |= !p->avp_eof;
            MP_VERBOSE(ao, "compressed resource length %lld (%s)\n",
                       (long long)info.contentLength, p->avp_eof ? "finite" : "bounded stream");
        }
        if (!req.dataRequest) {
            [req finishLoading];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        AVAssetResourceLoadingDataRequest *dr = req.dataRequest;
        int64_t off = dr.currentOffset;
        int64_t req_end;
        if (!avfoundation_request_end(dr.requestedOffset, dr.requestedLength,
                                     dr.requestsAllDataToEndOfResource, &req_end) ||
            off < dr.requestedOffset || off > req_end) {
            [req finishLoadingWithError:
                [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        if (off < p->es_head) {
            // history gone; fail item, poll recovers PCM
            MP_ERR(ao, "loader requested offset %lld below the retained "
                   "window at %lld\n", (long long)off, (long long)p->es_head);
            [req finishLoadingWithError:
                [NSError errorWithDomain:NSPOSIXErrorDomain code:ESPIPE userInfo:nil]];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        int64_t write_head = p->es_head + p->es_len;
        if (off < write_head) {
            // real stream data
            int64_t n = MPMIN(write_head - off, req_end - off);
            NSData *chunk = [NSData dataWithBytes:p->es_buf + (off - p->es_head)
                                           length:n];
            [dr respondWithData:chunk];
            // Cancellation may make respondWithData a no-op. Credit accepted
            // Apple offset only.
            int64_t accepted = MPCLAMP(dr.currentOffset, off, off + n);
            if (off <= p->es_served_until)
                p->es_served_until = MPMAX(p->es_served_until, accepted);
            MP_TRACE(ao, "served %lld bytes at offset %lld\n",
                     (long long)n, (long long)off);
        } else if (off > write_head) {
            // Preroll probes ~183 MiB regardless of contentLength to estimate
            // duration/bitrate. Never fabricate bytes: Apple caches by
            // offset, then plays stale fabricated frames at ~30-40min DD+ and
            // reads past write head (plezy#1776). Reject probe to resume
            // sequential reads at write head.
            MP_VERBOSE(ao, "refusing read at %lld past the write head %lld\n",
                       (long long)off, (long long)write_head);
            [req finishLoadingWithError:
                [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:nil]];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        if ((!dr.requestsAllDataToEndOfResource && dr.currentOffset >= req_end) ||
            (p->avp_eof && dr.currentOffset >= write_head)) {
            // Finite-range completion alone does not signal EOF.
            if (p->avp_eof && dr.currentOffset >= write_head &&
                (dr.requestsAllDataToEndOfResource || dr.currentOffset < req_end))
                p->avp_eof_response = true;
            [req finishLoading];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        i++;
    }

    // Trim history beyond bound.
    int64_t low = p->es_head + p->es_len;
    for (AVAssetResourceLoadingRequest *req in reqs)
        low = MPMIN(low, req.dataRequest.currentOffset);
    int64_t drop = MPCLAMP((low - AVP_ES_HISTORY_BYTES) - p->es_head, 0, p->es_len);
    if (drop > 0) {
        memmove(p->es_buf, p->es_buf + drop, p->es_len - drop);
        p->es_head += drop;
        p->es_len -= drop;
    }
}

// IEC bytes cannot carry multiplied gain. Apply software
// volume/replaygain/mute at decoded Apple output, combining separate
// ao-volume/ao-mute. AVPlayer attenuates only: 0..1.
static void avp_apply_volume(struct ao *ao)
{
    struct priv *p = ao->priv;
    float gain = atomic_load_explicit(&ao->gain, memory_order_relaxed);
    if (!isfinite(gain) || gain < 0)
        gain = 0;
    if (p->avp_volume * gain > 1 && !p->avp_gain_warned) {
        MP_WARN(ao, "compressed AVPlayer volume cannot amplify above unity; clamping gain\n");
        p->avp_gain_warned = true;
    }
    [p->player setMuted:p->avp_muted || gain == 0];
    [p->player setVolume:MPCLAMP(p->avp_volume * gain, 0, 1)];
}

// Apply transport state. Prime; if playhead stalls, seek to start once, then
// recover PCM.
static void avp_update_transport(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->avp_playing || !p->item || p->spdif_reload_requested ||
        (p->avp_eof && p->es_pts == 0))
        return;
    avp_apply_volume(ao);
    int64_t now = mp_time_ns();
    if (!p->avp_rate_applied) {
        bool primed = p->es_pts >= AVP_START_MIN_NS || p->avp_eof;
        if (!primed) {
            // Start startup clock after priming.
            p->avp_start_deadline = now + AVP_START_GRACE_NS;
            return;
        }
        // Do not await item readiness: preroll may need more reads after
        // rejected probes. Seek-to-start breaks remaining park.
        [p->player setRate:1];
        p->avp_rate_applied = true;
        p->avp_start_deadline = now + AVP_START_GRACE_NS;
        return;
    }
    int64_t position = avp_current_time_ns(ao);
    if (p->avp_start_deadline < 0) {
        // Bound decoder stalls with ample queued audio. Source
        // underruns/pauses spend no budget.
        if (position > p->avp_last_position ||
            (!p->avp_eof && p->es_pts - position < AVP_START_MIN_NS)) {
            p->avp_last_position = position;
            p->avp_last_progress = now;
        } else if (now - p->avp_last_progress >
                   MP_TIME_S_TO_NS(p->avp_eof ? 2 : 10)) {
            MP_ERR(ao, "native compressed playback stalled; falling back to PCM\n");
            spdif_reload(ao);
        }
        return;
    }
    if (position > 0) {
        MP_VERBOSE(ao, "native compressed clock started at %.6fs\n", position / 1e9);
        p->avp_start_deadline = -1;
        p->avp_last_position = position;
        p->avp_last_progress = now;
        return;
    }
    // Slow realtime/CPU-bound transcodes may fill preroll late. Keep waiting
    // while priming advances. Startup gate bounds grace: parked player fills
    // it at full pull speed, progress stops, deadline resumes.
    if (p->es_pts > p->avp_primed_pts && p->es_pts < AVP_START_LEAD_NS(p)) {
        p->avp_primed_pts = p->es_pts;
        p->avp_start_deadline = now + AVP_START_GRACE_NS;
        return;
    }
    if (now < p->avp_start_deadline)
        return;
    if (!p->avp_start_seeked) {
        MP_WARN(ao, "playback did not engage; seeking to the stream start\n");
        p->avp_start_seeked = true;
        p->avp_start_deadline = now + AVP_START_GRACE_NS;
        [p->item seekToTime:kCMTimeZero completionHandler:nil];
        [p->player setRate:1];
        return;
    }
    MP_ERR(ao, "native compressed playback did not start; falling back to PCM\n");
    spdif_reload(ao);
}

// After all bytes and EOF arrive, bounded Dolby item may auto-pause ~98ms
// before ES end. Narrow settling restores liveness without advancing reported
// Apple clock; audible tail still needs route testing.
static bool avp_stream_tail_drained(struct ao *ao, int64_t position, double rate,
                                    bool clock_valid)
{
    struct priv *p = ao->priv;
    int64_t remaining = p->es_pts - position;
    int64_t sample_ns = (1000000000LL + p->spdif_rate - 1) / p->spdif_rate;
    bool eligible = p->avp_bounded_length && p->avp_eof && !p->stash_len &&
        p->avp_eof_response && p->es_served_until == p->es_head + p->es_len &&
        p->avp_playing && p->avp_start_deadline < 0 && position > 0 &&
        p->avp_last_position > 0 && remaining > sample_ns &&
        remaining <= AVP_EOF_TAIL_NS + sample_ns && clock_valid && rate == 0 &&
        p->item.status == AVPlayerItemStatusReadyToPlay && !p->item.error &&
        !p->player.error && p->player.timeControlStatus == AVPlayerTimeControlStatusPaused;
    if (!eligible) {
        p->avp_eof_parked_since = 0;
        return false;
    }
    int64_t now = mp_time_ns();
    if (!p->avp_eof_parked_since || position != p->avp_eof_parked_position ||
        p->es_pts != p->avp_eof_parked_end) {
        p->avp_eof_parked_since = now;
        p->avp_eof_parked_position = position;
        p->avp_eof_parked_end = p->es_pts;
        return false;
    }
    if (now - p->avp_eof_parked_since < MPMAX(AVP_EOF_SETTLE_NS, remaining + 2 * AVP_TICK_NS))
        return false;
    MP_VERBOSE(ao, "settled bounded compressed EOF tail of %.6fs at parked native clock\n",
               remaining / 1e9);
    return true;
}

// Publish actual Apple timeline through source EOF. Interpolate only running
// native timebase. Freeze at observed position during priming, pause, or
// stall.
static bool avp_publish_clock(struct ao *ao)
{
    struct priv *p = ao->priv;
    int64_t position = avp_current_time_ns(ao);
    int64_t written = CMTimeGetNanoseconds(
        CMTimeMake(p->pulled_samples, ao->samplerate)) - p->es_dropped_ns;
    int64_t delay = MPMAX(written - position, 0);
    int64_t sample_ns = (1000000000LL + p->spdif_rate - 1) / p->spdif_rate;
    double rate = 0;
    CMTimebaseRef timebase = p->item.timebase;
    bool clock_valid = position > 0 && p->avp_playing && timebase;
    if (clock_valid)
        rate = CMTimebaseGetEffectiveRate(timebase);
    bool drained = (p->avp_eof && !p->stash_len && p->es_pts - position <= sample_ns) ||
                   avp_stream_tail_drained(ao, position, rate, clock_valid);
    // Device underrun permits refill/re-arm start(). Reuse item; EOF/seek
    // starts new epoch.
    bool underrun = !p->avp_eof && p->avp_start_deadline < 0 && !delay;
    ao_update_streaming_clock(ao, delay, rate, !drained && !underrun);
    if (drained) {
        MP_VERBOSE(ao, "native compressed audio drained at %.6fs of %.6fs\n",
                   position / 1e9, p->es_pts / 1e9);
        avp_timer_idle(p);
        return false;
    }
    return true;
}

// Compressed driver on p->queue; triggered by timer or loader request.
static void feed_avp(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->spdif_reload_requested || !p->item)
        return;

    // Log player/item transitions for startup diagnosis.
    int item_status = (int)[p->item status];
    int tcs = (int)[p->player timeControlStatus];
    if (item_status != p->avp_last_item_status || tcs != p->avp_last_tcs) {
        MP_VERBOSE(ao, "item status %d -> %d, time control %d -> %d, "
                   "pos %.3fs, fed %.3fs\n",
                   p->avp_last_item_status, item_status,
                   p->avp_last_tcs, tcs,
                   avp_current_time_ns(ao) / 1e9, p->es_pts / 1e9);
        p->avp_last_item_status = item_status;
        p->avp_last_tcs = tcs;
    }
    if (++p->avp_heartbeat % 100 == 0) {
        CMTime t = [p->item currentTime];
        int64_t write_head = p->es_head + p->es_len;
        int64_t reader_gap = -1;
        for (AVAssetResourceLoadingRequest *req in p->loader->requests) {
            AVAssetResourceLoadingDataRequest *dr = req.dataRequest;
            if (!dr || dr.currentOffset > write_head)
                continue;
            int64_t gap = write_head - dr.currentOffset;
            if (reader_gap < 0 || gap < reader_gap)
                reader_gap = gap;
        }
        MP_VERBOSE(ao, "heartbeat: raw pos %.3fs, clamped %.3fs, fed %.3fs, "
                   "status %d, tc %d, reader gap %lld B\n",
                   CMTIME_IS_NUMERIC(t) ? CMTimeGetNanoseconds(t) / 1e9 : -1.0,
                   avp_current_time_ns(ao) / 1e9, p->es_pts / 1e9,
                   item_status, tcs, (long long)reader_gap);
    }
    if ([p->item status] == AVPlayerItemStatusFailed || [p->player error]) {
        NSError *error = [p->item error] ? [p->item error] : [p->player error];
        MP_ERR(ao, "player rejected the compressed stream: %s (%s:%ld)\n",
               error ? error.localizedDescription.UTF8String : "unknown",
               error ? error.domain.UTF8String : "-",
               error ? (long)error.code : 0);
        MP_ERR(ao, "falling back to PCM\n");
        spdif_reload(ao);
        return;
    }

    for (int guard = 0; guard < 64 && p->avp_playing && !p->avp_eof; guard++) {
        int64_t cur = avp_feed_position_ns(ao);
        if (p->es_pts - cur >= (cur > 0 ? p->avp_lead_ns : AVP_START_LEAD_NS(p)))
            break;
        // Pull may drain whole stash; reserve full-stash payload capacity
        // first.
        if (p->es_size - p->es_len < p->stash_size)
            break; // backpressure; serving trims window
        if (!avp_pull(ao))
            break;
    }
    if (p->spdif_reload_requested)
        return;
    avp_serve_requests(ao);
    if (avp_publish_clock(ao))
        avp_update_transport(ao);
}

// ES cannot signal discontinuities. Seek/track restart creates fresh
// asset/item at byte/time zero.
static void avp_create_item(struct ao *ao)
{
    struct priv *p = ao->priv;

    NSString *urlstr = [NSString stringWithFormat:@"mpv-passthrough://stream/audio.%s",
                        p->spdif_ext];
    NSURL *url = [NSURL URLWithString:urlstr];
    p->asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    [p->asset.resourceLoader setDelegate:p->loader queue:p->queue];
    p->item = [[AVPlayerItem alloc] initWithAsset:p->asset];
    if (@available(tvOS 15.0, iOS 15.0, macOS 12.0, *))
        p->item.allowedAudioSpatializationFormats = spatial_formats(p);
    p->item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    [p->player replaceCurrentItemWithPlayerItem:p->item];

    p->stash_len = 0;
    p->es_len = 0;
    p->es_head = 0;
    p->es_pts = 0;
    p->pulled_samples = 0;
    p->es_dropped_ns = 0;
    p->avp_eof = false;
    p->avp_info_deadline = 0;
    p->avp_bounded_length = false;
    p->avp_eof_response = false;
    p->es_served_until = 0;
    p->avp_eof_parked_since = 0;
    p->avp_eof_parked_position = 0;
    p->avp_eof_parked_end = 0;
    p->avp_rate_applied = false;
    p->avp_start_seeked = false;
    p->avp_primed_pts = 0;
    p->avp_last_position = 0;
    p->avp_last_progress = mp_time_ns();
    p->avp_start_deadline = mp_time_ns() + AVP_READY_GRACE_NS;
    p->avp_last_item_status = -1;
    p->avp_last_tcs = -1;
}

static void avp_teardown_item(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->item)
        return;
    [p->player setRate:0];
    for (AVAssetResourceLoadingRequest *req in p->loader->requests) {
        if (!req.finished && !req.cancelled)
            [req finishLoadingWithError:
                [NSError errorWithDomain:NSURLErrorDomain
                                    code:NSURLErrorCancelled userInfo:nil]];
    }
    [p->loader->requests removeAllObjects];
    [p->asset.resourceLoader setDelegate:nil queue:nil];
    [p->player replaceCurrentItemWithPlayerItem:nil];
    [p->item release];
    p->item = nil;
    [p->asset release];
    p->asset = nil;
    p->stash_len = 0;
    p->es_len = 0;
    p->es_head = 0;
    p->es_pts = 0;
    p->pulled_samples = 0;
    p->es_dropped_ns = 0;
    p->avp_eof = false;
    p->avp_info_deadline = 0;
    p->avp_bounded_length = false;
    p->avp_eof_response = false;
    p->es_served_until = 0;
    p->avp_eof_parked_since = 0;
    p->avp_eof_parked_position = 0;
    p->avp_eof_parked_end = 0;
    p->avp_rate_applied = false;
    p->avp_start_seeked = false;
    p->avp_primed_pts = 0;
    p->avp_last_position = 0;
    p->avp_last_progress = mp_time_ns();
}

#if TARGET_OS_OSX
static void feed(struct ao *ao);

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
#endif  // TARGET_OS_OSX

static void feed(struct ao *ao)
{
    struct priv *p = ao->priv;
    int samplerate = ao->samplerate;
    int sstride = ao->sstride;

#if TARGET_OS_OSX
    if (p->pcm_lookahead_ns) {
        int64_t now = CMTimeGetNanoseconds([p->synchronizer currentTime]);
        if (p->end_time_av - now >= p->pcm_lookahead_ns) {
            pcm_pause_feeding(ao);
            return;
        }
    }
#endif

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
            avp_apply_volume(ao);
            p->avp_playing = true;
            p->avp_last_progress = mp_time_ns();
            // Published drain/underrun permits restart when data arrives. EOF
            // also needs fresh finite epoch.
            if (p->avp_eof)
                avp_teardown_item(ao);
            if (!p->item)
                avp_create_item(ao);
            else if (p->avp_rate_applied)
                [p->player setRate:1];
            avp_timer_arm(p);
            feed_avp(ao);
        };
        if (dispatch_get_specific(&avfoundation_queue_key) == p)
            start_block();
        else
            dispatch_sync(p->queue, start_block);
        return;
    }

    p->end_time_av = -1;
    [p->synchronizer setRate:1];
#if TARGET_OS_OSX
    // Unbounded path needs no gate; retain direct initial arm.
    if (p->pcm_lookahead_ns) {
        pcm_set_feeding(ao, true);
        return;
    }
#endif
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
            avp_teardown_item(ao);
            ao_update_streaming_clock(ao, 0, 0, false);
            return;
        }
        [p->renderer stopRequestingMediaData];
        [p->renderer flush];
        [p->synchronizer setRate:0];
#if TARGET_OS_OSX
        // Frozen clock cannot drain; unschedule feed until start().
        p->feed_enabled = false;
        pcm_cancel_pending_feed(p);
#endif
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
            avp_apply_volume(ao);
            p->avp_playing = !paused;
            if (paused) {
                avp_timer_idle(p);
                [p->player setRate:0];
                avp_publish_clock(ao);
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
                feed_avp(ao);
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
#if TARGET_OS_OSX
        // Stopped clock cannot lower queue depth; stop requests instead of
        // polling every half-bound.
        if (p->pcm_lookahead_ns)
            pcm_set_feeding(ao, false);
#endif
    } else {
#if TARGET_OS_OSX
        if (p->pcm_lookahead_ns)
            pcm_set_feeding(ao, true);
#endif
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
                avp_apply_volume(ao);
                break;
            case AOCONTROL_SET_VOLUME:
                p->avp_volume = MPCLAMP(*(float*)arg / 100, 0, 1);
                avp_apply_volume(ao);
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

@implementation AVPLoader
- (instancetype)initWithAO:(struct ao*)_ao {
    self = [super init];
    if (self) {
        ao = _ao;
        requests = [[NSMutableArray alloc] init];
    }
    return self;
}
// Delegate and feed timer share p->queue; no extra locking.
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    @synchronized(self) {
        if (!ao)
            return NO;
        struct priv *p = ao->priv;
        // Cancelled epoch may have queued delegate callback.
        if (resourceLoader != p->asset.resourceLoader || p->spdif_reload_requested)
            return NO;
        if (requests.count >= 16) {
            [request finishLoadingWithError:
                [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOBUFS userInfo:nil]];
            return YES;
        }
        AVAssetResourceLoadingContentInformationRequest *info =
            request.contentInformationRequest;
        AVAssetResourceLoadingDataRequest *dr = request.dataRequest;
        MP_VERBOSE(ao, "loading request: info=%d data=%d offset=%lld "
                   "length=%ld allToEnd=%d\n", !!info, !!dr,
                   dr ? (long long)dr.requestedOffset : -1,
                   dr ? (long)dr.requestedLength : -1,
                   dr ? dr.requestsAllDataToEndOfResource : 0);
        // Information-only requests also await bounded metadata prefill.
        [requests addObject:request];
        feed_avp(ao);
        return YES;
    }
}
- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request {
    @synchronized(self) {
        [requests removeObjectIdenticalTo:request];
        if (ao)
            MP_VERBOSE((struct ao *)ao, "loading request cancelled\n");
    }
}
- (void)invalidate {
    @synchronized(self) {
        ao = NULL;
        [requests removeAllObjects];
    }
}
- (void)dealloc {
    [requests release];
    [super dealloc];
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
        avp_apply_volume(ao);
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
            feed_avp(ao);
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

#if TARGET_OS_OSX
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
#endif

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

    // AVSampleBufferAudioRenderer read ahead aggressively
    ao->device_buffer = ao->samplerate * 2;

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
#if TARGET_OS_OSX
    if (p->feed_timer) {
        dispatch_source_cancel(p->feed_timer);
        dispatch_release(p->feed_timer);
        p->feed_timer = NULL;
    }
#endif
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
#if TARGET_OS_OSX
        if (p->feed_timer) {
            dispatch_sync(p->queue, ^{
                dispatch_source_cancel(p->feed_timer);
            });
            dispatch_release(p->feed_timer);
            p->feed_timer = NULL;
        }
#endif
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
#if TARGET_OS_OSX
        .opt_max_lookahead = 0,
#endif
    },
    .options = (const struct m_option[]) {
#if TARGET_OS_OSX
        {"max-lookahead", OPT_DOUBLE(opt_max_lookahead), M_RANGE(0, 10)},
#endif
        {"spatial-audio", OPT_CHOICE(opt_spatial_audio,
            {"no", 0}, {"multichannel", 1}, {"all", 2})},
        {"manage-audio-session", OPT_BOOL(opt_manage_session)},
        {"accept-compressed", OPT_BOOL(opt_accept_compressed)},
        {"compressed-lead", OPT_DOUBLE(opt_compressed_lead), M_RANGE(1, 30)},
        {0}
    },
    .options_prefix = "ao-avfoundation",
};
