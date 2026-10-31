/* Copyright (C) 2026 Quasar
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

/* Subtitle style preview for builds with --sub-text-renderer=coretext
 * (Apple platforms). */

#ifndef MPV_QUASAR_SUBTITLE_H_
#define MPV_QUASAR_SUBTITLE_H_

#include "client.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Render ASS event text as a plain text subtitle with --sub-text-renderer=
 * coretext, the way playback renders it: same options, same sizes. The
 * canvas stands for the video rect, w x h pixels.
 *
 * @param options NULL-terminated list of option name/value pairs, as given
 *                to mpv (sub-font, sub-font-size, sub-color, sub-border-size,
 *                sub-shadow-offset-x, sub-box-color, sub-margin-y,
 *                sub-scale, ...). Names that are not subtitle style options
 *                are ignored.
 * @param bgra    w x h premultiplied BGRA (kCGImageAlphaPremultipliedFirst |
 *                kCGBitmapByteOrder32Little), drawn over as is.
 * @return 0 on success, a negative value when the text needs libass or on
 *         error.
 */
MPV_EXPORT int mpv_quasar_subtitle_preview(const char *const *options, const char *text,
                                           int w, int h, unsigned char *bgra, int stride);

#ifdef __cplusplus
}
#endif

#endif
