/*
 * IEC 61937 validation for the AVFoundation compressed audio output.
 * Copyright (c) 2026 MPVUI contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef MPV_AVFOUNDATION_IEC_H
#define MPV_AVFOUNDATION_IEC_H

#include <stdbool.h>
#include <stdint.h>
#include <limits.h>

// 1 = complete period; 0 = need bytes; -1 = invalid. Consume periods, never
// scan padding for sync: mpv's isochronous SPDIF stream would lose clock time
// on resync.
static inline int avfoundation_iec_payload(const uint8_t *data, int size,
                                          int type, int period, int *payload)
{
    if (size < 0 || (type != 0x01 && type != 0x15) ||
        period != (type == 0x01 ? 6144 : 24576))
        return -1;
    if (size < 8)
        return 0;
    if (data[0] != 0x72 || data[1] != 0xf8 ||
        data[2] != 0x1f || data[3] != 0x4e ||
        (data[4] & 0x7f) != type || (data[4] & 0x80))
        return -1;
    int pd = data[6] | (data[7] << 8);
    if (type == 0x01 && pd % 8)
        return -1;
    int length = type == 0x01 ? pd / 8 : pd;
    if (length < 8 || (length & 1) || length > period - 8)
        return -1;
    if (size < period)
        return 0;
    // Payload words: LE. Dolby syncframe starts 0b 77.
    if (data[8] != 0x77 || data[9] != 0x0b)
        return -1;
    *payload = length;
    return 1;
}

// Validate loader ranges before pointer math. All-remaining requests ignore
// requestedLength, per Apple API.
static inline bool avfoundation_request_end(int64_t offset, int64_t length,
                                            bool all, int64_t *end)
{
    if (offset < 0)
        return false;
    if (all) {
        *end = INT64_MAX;
        return true;
    }
    if (length < 0 || length > INT64_MAX - offset)
        return false;
    *end = offset + length;
    return true;
}
#endif
