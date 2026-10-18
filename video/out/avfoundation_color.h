/* CoreVideo metadata mapping. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef MP_AVFOUNDATION_COLOR_H
#define MP_AVFOUNDATION_COLOR_H
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#include <libplacebo/colorspace.h>
#include "avfoundation_color_math.h"

static inline CFStringRef get_cv_color_primaries(enum pl_color_primaries primaries)
{
    switch (primaries) {
    case PL_COLOR_PRIM_BT_601_525: return kCVImageBufferColorPrimaries_SMPTE_C;
    case PL_COLOR_PRIM_BT_601_625: return kCVImageBufferColorPrimaries_EBU_3213;
    case PL_COLOR_PRIM_BT_709: return kCVImageBufferColorPrimaries_ITU_R_709_2;
    case PL_COLOR_PRIM_BT_2020: return kCVImageBufferColorPrimaries_ITU_R_2020;
    case PL_COLOR_PRIM_DCI_P3: return kCVImageBufferColorPrimaries_DCI_P3;
    case PL_COLOR_PRIM_DISPLAY_P3: return kCVImageBufferColorPrimaries_P3_D65;
    case PL_COLOR_PRIM_EBU_3213: return kCVImageBufferColorPrimaries_P22;
    default: return NULL;
    }
}
static inline CFStringRef get_cv_transfer_function(enum pl_color_transfer transfer)
{
    switch (transfer) {
    case PL_COLOR_TRC_SRGB: return kCVImageBufferTransferFunction_sRGB;
    case PL_COLOR_TRC_BT_1886: return kCVImageBufferTransferFunction_ITU_R_709_2;
    case PL_COLOR_TRC_PQ: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    case PL_COLOR_TRC_HLG: return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    case PL_COLOR_TRC_LINEAR: return kCVImageBufferTransferFunction_Linear;
    default: return NULL;
    }
}
static inline CFStringRef get_cv_ycbcr_matrix(enum pl_color_system sys)
{
    switch (sys) {
    case PL_COLOR_SYSTEM_BT_601: return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    case PL_COLOR_SYSTEM_BT_709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    case PL_COLOR_SYSTEM_SMPTE_240M: return kCVImageBufferYCbCrMatrix_SMPTE_240M_1995;
    case PL_COLOR_SYSTEM_BT_2020_NC: return kCVImageBufferYCbCrMatrix_ITU_R_2020;
    // Constant-luminance BT.2020 and ICtCp must not be tagged as BT.2020 NCL.
    default: return NULL;
    }
}
static inline CFStringRef avf_chroma_location(enum pl_chroma_location loc)
{
    switch (loc) {
    case PL_CHROMA_LEFT: return kCVImageBufferChromaLocation_Left;
    case PL_CHROMA_CENTER: return kCVImageBufferChromaLocation_Center;
    case PL_CHROMA_TOP_LEFT: return kCVImageBufferChromaLocation_TopLeft;
    case PL_CHROMA_TOP_CENTER: return kCVImageBufferChromaLocation_Top;
    case PL_CHROMA_BOTTOM_LEFT: return kCVImageBufferChromaLocation_BottomLeft;
    case PL_CHROMA_BOTTOM_CENTER: return kCVImageBufferChromaLocation_Bottom;
    default: return NULL;
    }
}
static inline void avf_set_attachment(CVBufferRef buffer, CFStringRef key, CFTypeRef value)
{
    if (value) CVBufferSetAttachment(buffer, key, value, kCVAttachmentMode_ShouldPropagate);
    else CVBufferRemoveAttachment(buffer, key);
}
static inline void set_colorspace_from_attachments(CVPixelBufferRef pixbuf)
{
    CVBufferRemoveAttachment(pixbuf, kCVImageBufferCGColorSpaceKey);
    CFDictionaryRef attachments = CVBufferGetAttachments(pixbuf, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRef cs = attachments ? CVImageBufferCreateColorSpaceFromAttachments(attachments) : NULL;
    if (cs) {
        avf_set_attachment(pixbuf, kCVImageBufferCGColorSpaceKey, cs);
        CGColorSpaceRelease(cs);
    }
}
static inline void avf_put_be16(uint8_t *p, double value)
{
    uint16_t v = (uint16_t)llround(avf_clamp(value, 0, UINT16_MAX));
    p[0] = v >> 8; p[1] = v;
}
static inline void avf_put_be32(uint8_t *p, double value)
{
    uint32_t v = (uint32_t)llround(avf_clamp(value, 0, UINT32_MAX));
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}
static inline void avf_set_data(CVBufferRef buffer, CFStringRef key, const uint8_t *data, size_t size)
{
    CFDataRef value = CFDataCreate(NULL, data, size);
    avf_set_attachment(buffer, key, value);
    CFRelease(value);
}
static inline void avf_clear_hdr_metadata(CVPixelBufferRef buffer)
{
    // Call whenever output has been tone mapped or otherwise changed to SDR.
    CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey);
    CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey);
    CVBufferRemoveAttachment(buffer, CFSTR("DolbyVisionRPUData"));
    CVBufferRemoveAttachment(buffer, CFSTR("HDR10PlusPerFrameData"));
}
static inline void avf_set_static_hdr_metadata(CVPixelBufferRef buffer, const struct pl_color_space *color)
{
    avf_clear_hdr_metadata(buffer);
    if (color->transfer != PL_COLOR_TRC_PQ && color->transfer != PL_COLOR_TRC_HLG) return;
    const struct pl_hdr_metadata *hdr = &color->hdr;
    // ISO/IEC 23001-8 MDCV payload: G, B, R, white xy at 1/50000;
    // max/min luminance at 1/10000 cd/m², all network byte order.
    if (hdr->prim.red.x > 0 && hdr->prim.green.y > 0 && hdr->prim.blue.y > 0 &&
        hdr->prim.white.x > 0 && hdr->prim.white.y > 0 && hdr->max_luma > 0 &&
        hdr->min_luma >= 0 && hdr->min_luma < hdr->max_luma) {
        struct pl_cie_xy xy[4] = {hdr->prim.green, hdr->prim.blue, hdr->prim.red, hdr->prim.white};
        uint8_t mdcv[24];
        for (int i = 0; i < 4; i++) {
            avf_put_be16(mdcv + 4 * i, xy[i].x * 50000);
            avf_put_be16(mdcv + 4 * i + 2, xy[i].y * 50000);
        }
        avf_put_be32(mdcv + 16, hdr->max_luma * 10000.0);
        avf_put_be32(mdcv + 20, hdr->min_luma * 10000.0);
        avf_set_data(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, mdcv, sizeof(mdcv));
    }
    if (hdr->max_cll > 0 || hdr->max_fall > 0) {
        uint8_t clli[4];
        avf_put_be16(clli, hdr->max_cll);
        avf_put_be16(clli + 2, hdr->max_fall);
        avf_set_data(buffer, kCVImageBufferContentLightLevelInfoKey, clli, sizeof(clli));
    }
}
static inline void avf_tag_color_metadata(CVPixelBufferRef buffer,
    const struct pl_color_space *color, enum pl_color_system sys, enum pl_chroma_location chroma)
{
    avf_set_attachment(buffer, kCVImageBufferColorPrimariesKey, get_cv_color_primaries(color->primaries));
    avf_set_attachment(buffer, kCVImageBufferTransferFunctionKey, get_cv_transfer_function(color->transfer));
    avf_set_attachment(buffer, kCVImageBufferYCbCrMatrixKey, get_cv_ycbcr_matrix(sys));
    CVBufferRemoveAttachment(buffer, kCVImageBufferICCProfileKey);
    CVBufferRemoveAttachment(buffer, kCVImageBufferGammaLevelKey);
    avf_set_attachment(buffer, kCVImageBufferChromaLocationTopFieldKey, avf_chroma_location(chroma));
    avf_set_attachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, avf_chroma_location(chroma));
    avf_set_static_hdr_metadata(buffer, color);
    set_colorspace_from_attachments(buffer);
}
static inline void avf_tag_geometry(CVPixelBufferRef buffer, int pw, int ph,
                                   int x0, int y0, int x1, int y1)
{
    int width = (int)CVPixelBufferGetWidth(buffer), height = (int)CVPixelBufferGetHeight(buffer);
    NSDictionary *par = pw > 0 && ph > 0 && pw != ph ? @{
        (id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey: @(pw),
        (id)kCVImageBufferPixelAspectRatioVerticalSpacingKey: @(ph)} : nil;
    avf_set_attachment(buffer, kCVImageBufferPixelAspectRatioKey, (__bridge CFDictionaryRef)par);
    NSDictionary *aperture = x0 >= 0 && y0 >= 0 && x1 <= width && y1 <= height && x1 > x0 && y1 > y0 ? @{
        (id)kCVImageBufferCleanApertureWidthKey: @(x1 - x0),
        (id)kCVImageBufferCleanApertureHeightKey: @(y1 - y0),
        (id)kCVImageBufferCleanApertureHorizontalOffsetKey: @((x0 + x1 - width) / 2.0),
        (id)kCVImageBufferCleanApertureVerticalOffsetKey: @((height - y0 - y1) / 2.0)} : nil;
    avf_set_attachment(buffer, kCVImageBufferCleanApertureKey, (__bridge CFDictionaryRef)aperture);
    CVBufferRemoveAttachment(buffer, kCVImageBufferPreferredCleanApertureKey);
}
static inline void copy_pixel_buffer_attachment(CVBufferRef src, CVBufferRef dst,
                                         CFStringRef key)
{
    CVAttachmentMode mode = kCVAttachmentMode_ShouldPropagate;
    CFTypeRef value = CVBufferGetAttachment(src, key, &mode);
    if (value) {
        CVBufferSetAttachment(dst, key, value, mode);
    } else {
        CVBufferRemoveAttachment(dst, key);
    }
}

static inline void copy_pixel_buffer_metadata(CVPixelBufferRef src, CVPixelBufferRef dst,
                                       OSType dst_format)
{
    bool biplanar = dst_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                    dst_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                    dst_format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                    dst_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    // Pools recycle arbitrary old attachments, including nonstandard dynamic
    // HDR keys. Clear first, then preserve both CoreVideo attachment modes.
    CVBufferRemoveAllAttachments(dst);
    for (CVAttachmentMode mode = kCVAttachmentMode_ShouldNotPropagate; mode <= kCVAttachmentMode_ShouldPropagate; mode++) {
        CFDictionaryRef dict = CVBufferGetAttachments(src, mode);
        if (dict) CVBufferSetAttachments(dst, dict, mode);
    }

    const CFStringRef keys[] = {
        kCVImageBufferCGColorSpaceKey,
        kCVImageBufferICCProfileKey,
        kCVImageBufferGammaLevelKey,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferMasteringDisplayColorVolumeKey,
        kCVImageBufferContentLightLevelInfoKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
        kCVImageBufferChromaSubsamplingKey,
        kCVImageBufferCleanApertureKey,
        kCVImageBufferPreferredCleanApertureKey,
        kCVImageBufferPixelAspectRatioKey,
    };

    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
        copy_pixel_buffer_attachment(src, dst, keys[i]);

    if (!biplanar) {
        CVBufferRemoveAttachment(dst, kCVImageBufferYCbCrMatrixKey);
        CVBufferRemoveAttachment(dst, kCVImageBufferChromaLocationTopFieldKey);
        CVBufferRemoveAttachment(dst, kCVImageBufferChromaLocationBottomFieldKey);
        CVBufferRemoveAttachment(dst, kCVImageBufferChromaSubsamplingKey);
        // CI's output canvas has already consumed source crop and aspect.
        avf_tag_geometry(dst, 1, 1, 0, 0,
                         CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst));
    }
    CFTypeRef transfer = CVBufferGetAttachment(dst, kCVImageBufferTransferFunctionKey, NULL);
    if (transfer && (!CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) &&
                      !CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG)))
        avf_clear_hdr_metadata(dst);

    if (!CVBufferGetAttachment(dst, kCVImageBufferCGColorSpaceKey, NULL) &&
        !biplanar)
        set_colorspace_from_attachments(dst);
}

static inline CIImage *avf_subtitle_image(CVPixelBufferRef sub, CGColorSpaceRef cs,
                                         const struct avf_overlay_color *color)
{
    if (CVPixelBufferLockBaseAddress(sub, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return nil;
    size_t width = CVPixelBufferGetWidth(sub), height = CVPixelBufferGetHeight(sub);
    size_t stride = CVPixelBufferGetBytesPerRow(sub);
    const uint8_t *base = CVPixelBufferGetBaseAddress(sub);
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4 * sizeof(float)];
    if (!base || !pixels) {
        CVPixelBufferUnlockBaseAddress(sub, kCVPixelBufferLock_ReadOnly);
        return nil;
    }
    float *dst = pixels.mutableBytes;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            const uint8_t *bgra = base + y * stride + x * 4;
            double rgb[3];
            avf_subtitle_nits(color, bgra, rgb);
            avf_from_nits(color->transfer, rgb, color->kr, color->kb);
            float alpha = bgra[3] / 255.0f;
            size_t offset = (y * width + x) * 4;
            for (int c = 0; c < 3; c++) dst[offset + c] = rgb[c] * alpha;
            dst[offset + 3] = alpha;
        }
    }
    CVPixelBufferUnlockBaseAddress(sub, kCVPixelBufferLock_ReadOnly);
    return [CIImage imageWithBitmapData:pixels bytesPerRow:width * 4 * sizeof(float)
                                 size:CGSizeMake(width, height) format:kCIFormatRGBAf colorSpace:cs];
}
#endif
