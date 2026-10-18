/* Per-frame HDR10+ bridge. This header is also compiled by the sanitizer tests.
 * Copyright (c) 2026 MPVUI contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef MP_AVFOUNDATION_HDR10PLUS_H
#define MP_AVFOUNDATION_HDR10PLUS_H

#include <CoreMedia/CoreMedia.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <stdbool.h>
#include <string.h>

enum avf_hdr10plus_result {
    AVF_HDR10PLUS_NONE = 0,
    AVF_HDR10PLUS_ATTACHED,
    AVF_HDR10PLUS_INVALID,
    AVF_HDR10PLUS_TRANSFORMED,
    AVF_HDR10PLUS_UNAVAILABLE,
};

// A new immutable CFData belongs to this sample only. No previous-frame cache:
// decoder reordering, mp_image reference copies, seeks and flushes keep the
// metadata paired with the exact frame whose pixels are enqueued.
static inline enum avf_hdr10plus_result avf_attach_hdr10plus(
    CMSampleBufferRef sample, const void *metadata, size_t metadata_size,
    bool pixels_transformed)
{
    if (!sample) return AVF_HDR10PLUS_INVALID;
    if (@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)) {
        CFArrayRef array = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (!array || CFArrayGetCount(array) != 1)
            return AVF_HDR10PLUS_INVALID;
        CFMutableDictionaryRef attachments = (CFMutableDictionaryRef)
            CFArrayGetValueAtIndex(array, 0);
        // Also safe if a caller reuses a sample: absent/malformed/transformed
        // input must never inherit another frame's HDR10+ payload.
        CFDictionaryRemoveValue(attachments, kCMSampleAttachmentKey_HDR10PlusPerFrameData);
        if (!metadata) return AVF_HDR10PLUS_NONE;
        if (pixels_transformed) return AVF_HDR10PLUS_TRANSFORMED;
        if (metadata_size < sizeof(AVDynamicHDRPlus)) return AVF_HDR10PLUS_INVALID;
        AVDynamicHDRPlus hdr;
        memcpy(&hdr, metadata, sizeof(hdr));
        // FFmpeg's parser excludes the registered T.35 header and leaves
        // country_code zero. Accept that decoded representation or explicit US.
        if ((hdr.itu_t_t35_country_code && hdr.itu_t_t35_country_code != 0xb5) ||
            hdr.application_version > 1)
            return AVF_HDR10PLUS_INVALID;
        // The pinned parser emits absolute integral window coordinates. The
        // serializer cannot reconstruct fractional, normalized coordinates.
        if (hdr.num_windows > 3) return AVF_HDR10PLUS_INVALID;
        for (int w = 1; w < hdr.num_windows; w++) {
            AVHDRPlusColorTransformParams *p = &hdr.params[w];
            if (p->window_upper_left_corner_x.den != 1 ||
                p->window_upper_left_corner_y.den != 1 ||
                p->window_lower_right_corner_x.den != 1 ||
                p->window_lower_right_corner_y.den != 1)
                return AVF_HDR10PLUS_INVALID;
        }
        // The public Apple sample key takes the complete registered T.35 SEI
        // payload, starting at country_code. Match FFmpeg libaomenc.c's six
        // byte HDR10+ header: US, Samsung provider, provider-oriented code1,
        // application identifier4. The FFmpeg API emits the remaining bits.
        uint8_t bytes[6 + AV_HDR_PLUS_MAX_PAYLOAD_SIZE] = {0xb5, 0, 0x3c, 0, 1, 4};
        uint8_t *payload = bytes + 6;
        size_t size = sizeof(bytes) - 6;
        if (av_dynamic_hdr_plus_to_t35(&hdr, &payload, &size) < 0)
            return AVF_HDR10PLUS_INVALID;
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, size + 6);
        if (!data) return AVF_HDR10PLUS_INVALID;
        CFDictionarySetValue(attachments, kCMSampleAttachmentKey_HDR10PlusPerFrameData, data);
        CFRelease(data);
        return AVF_HDR10PLUS_ATTACHED;
    }
    return metadata ? AVF_HDR10PLUS_UNAVAILABLE : AVF_HDR10PLUS_NONE;
}
#endif
