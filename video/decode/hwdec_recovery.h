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

#ifndef MP_HWDEC_RECOVERY_H
#define MP_HWDEC_RECOVERY_H

#include <stdbool.h>
#include <limits.h>

// Previously working native HEVC gets two keyframe recovery attempts. Ceiling
// counts decode errors, not frames/time; also bounds keyframe-free streams.
// Explicit software-fallback=yes/no/N bypasses grace.
#define MP_HWDEC_RECOVERY_KEYFRAMES 2
#define MP_HWDEC_RECOVERY_MAX_ERRORS 240
#define MP_HWDEC_FALLBACK_DEFAULT 3

struct mp_hwdec_recovery {
    int errors;
    int keyframes;
    bool had_frame;
};

static inline int mp_hwdec_fallback_threshold(int option)
{
    return option == -1 ? MP_HWDEC_FALLBACK_DEFAULT : option;
}

// Flush/seek/decoder replacement resets error debt and prior-frame success
// proof.
static inline void mp_hwdec_recovery_reset(struct mp_hwdec_recovery *state)
{
    *state = (struct mp_hwdec_recovery){0};
}

static inline void mp_hwdec_recovery_frame(struct mp_hwdec_recovery *state)
{
    *state = (struct mp_hwdec_recovery){.had_frame = true};
}

static inline void mp_hwdec_recovery_packet(struct mp_hwdec_recovery *state,
                                             bool keyframe)
{
    if (state->errors > 0 && keyframe &&
        state->keyframes < MP_HWDEC_RECOVERY_KEYFRAMES)
        state->keyframes++;
}

static inline bool mp_hwdec_recovery_error(struct mp_hwdec_recovery *state,
                                           int option, bool eligible)
{
    // Saturate counters; disabled fallback supports unbounded playback.
    if (state->errors < INT_MAX)
        state->errors++;
    if (option == INT_MAX ||
        state->errors < mp_hwdec_fallback_threshold(option))
        return false;

    if (option != -1 || !eligible || !state->had_frame)
        return true;

    return state->keyframes >= MP_HWDEC_RECOVERY_KEYFRAMES ||
           state->errors >= MP_HWDEC_RECOVERY_MAX_ERRORS;
}

#endif
