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

#include "ao_avfoundation_priv.h"

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
    // ao_avf_avp_publish_clock anchors to Apple playhead. Whole-burst es_pts jumps
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
void ao_avf_avp_apply_volume(struct ao *ao)
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
    ao_avf_avp_apply_volume(ao);
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
        [p->player setRate:p->avp_rate];
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
        [p->player setRate:p->avp_rate];
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
bool ao_avf_avp_publish_clock(struct ao *ao)
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
void ao_avf_feed_avp(struct ao *ao)
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
    if (ao_avf_avp_publish_clock(ao))
        avp_update_transport(ao);
}

// ES cannot signal discontinuities. Seek/track restart creates fresh
// asset/item at byte/time zero.
void ao_avf_avp_create_item(struct ao *ao)
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
    p->item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
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

void ao_avf_avp_teardown_item(struct ao *ao)
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
        ao_avf_feed_avp(ao);
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
