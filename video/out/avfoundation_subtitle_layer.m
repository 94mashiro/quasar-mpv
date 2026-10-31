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

// One instanced quad per subtitle part; the fragment reads the part's pixels
// straight from the frame's buffer, so a frame costs one upload of its glyph
// area and no textures. Masks are libass A8 coverage times the part color;
// BGRA parts are premultiplied sRGB, filtered bilinearly when scaled. Both
// drawables are sRGB-encoded (HDR: extended sRGB), so parts blend in gamma
// space like the CPU OSD did. HDR boosts only the opaque body by the gain in
// linear light, so antialiased edges and soft outlines stay SDR.
static NSString *const qsub_shader_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct QSubPart { int x, y, w, h, dw, dh, stride; uint offset, color, bgra; };\n"
     "struct VOut { float4 pos [[position]]; float2 uv; uint part [[flat]]; };\n"
     "vertex VOut qsub_vertex(const device QSubPart *parts [[buffer(0)]],\n"
     "                        constant float2 &canvas [[buffer(1)]],\n"
     "                        uint vid [[vertex_id]], uint iid [[instance_id]]) {\n"
     "    QSubPart p = parts[iid];\n"
     "    float2 c = float2(vid & 1, vid >> 1);\n"
     "    float2 px = float2(p.x, p.y) + c * float2(p.dw, p.dh);\n"
     "    VOut o;\n"
     "    o.pos = float4(px.x / canvas.x * 2.0 - 1.0, 1.0 - px.y / canvas.y * 2.0, 0.0, 1.0);\n"
     "    o.uv = c * float2(p.w, p.h);\n"
     "    o.part = iid;\n"
     "    return o;\n"
     "}\n"
     "static float4 texel(const device uchar *px, QSubPart p, int2 q) {\n"
     "    q = clamp(q, int2(0), int2(p.w - 1, p.h - 1));\n"
     "    uint i = p.offset + uint(q.y * p.stride + q.x * 4);\n"
     "    return float4(px[i + 2], px[i + 1], px[i], px[i + 3]) / 255.0;\n"
     "}\n"
     // Premultiplied sRGB.
     "static float4 part_color(VOut in, const device QSubPart *parts,\n"
     "                         const device uchar *px) {\n"
     "    QSubPart p = parts[in.part];\n"
     "    if (p.bgra == 0) {\n"
     "        int2 q = clamp(int2(in.uv), int2(0), int2(p.w - 1, p.h - 1));\n"
     "        float a = px[p.offset + uint(q.y * p.stride + q.x)] / 255.0\n"
     "                  * (1.0 - (p.color & 0xFF) / 255.0);\n"
     "        float3 rgb = float3((p.color >> 24) & 0xFF, (p.color >> 16) & 0xFF,\n"
     "                            (p.color >> 8) & 0xFF) / 255.0;\n"
     "        return float4(rgb * a, a);\n"
     "    }\n"
     "    float2 f = in.uv - 0.5;\n"
     "    int2 q = int2(floor(f));\n"
     "    f -= floor(f);\n"
     "    return mix(mix(texel(px, p, q), texel(px, p, q + int2(1, 0)), f.x),\n"
     "               mix(texel(px, p, q + int2(0, 1)), texel(px, p, q + int2(1, 1)), f.x), f.y);\n"
     "}\n"
     "fragment float4 qsub_sdr(VOut in [[stage_in]], const device QSubPart *parts [[buffer(0)]],\n"
     "                         const device uchar *px [[buffer(1)]],\n"
     "                         constant float &gain [[buffer(2)]]) {\n"
     "    float4 c = part_color(in, parts, px);\n"
     "    return float4(c.rgb * gain, c.a);\n"
     "}\n"
     "fragment float4 qsub_hdr(VOut in [[stage_in]], const device QSubPart *parts [[buffer(0)]],\n"
     "                         const device uchar *px [[buffer(1)]],\n"
     "                         constant float &gain [[buffer(2)]]) {\n"
     "    float4 c = part_color(in, parts, px);\n"
     "    float a = c.a;\n"
     "    if (a <= 3.0 / 255.0) return float4(0.0);\n"
     "    float3 u = min(c.rgb, float3(a)) / a;\n"
     "    float3 lin = select(pow((u + 0.055) / 1.055, 2.4), u / 12.92, u <= 0.04045);\n"
     "    lin *= gain <= 1.0 ? gain : mix(1.0, gain, smoothstep(0.20, 0.85, a));\n"
     "    float3 enc = select(1.055 * pow(lin, 1.0 / 2.4) - 0.055, lin * 12.92, lin <= 0.0031308);\n"
     "    return float4(enc * a, a);\n"
     "}\n";

@implementation QuasarSubtitleFrame

- (instancetype)initWithList:(struct sub_bitmap_list *)list
{
    if (!(self = [super init]))
        return nil;
    _w = list->w;
    _h = list->h;
    size_t bytes = 0;
    int count = 0;
    for (int i = 0; i < list->num_items; i++) {
        struct sub_bitmaps *g = list->items[i];
        if (g->format != SUBBITMAP_LIBASS && g->format != SUBBITMAP_BGRA)
            continue;
        size_t bpp = g->format == SUBBITMAP_BGRA ? 4 : 1;
        for (int n = 0; n < g->num_parts; n++) {
            struct sub_bitmap *b = &g->parts[n];
            if (b->bitmap && b->w > 0 && b->h > 0) {
                bytes += (size_t)b->w * b->h * bpp;
                count++;
            }
        }
    }
    if (!count)
        return self;
    if (bytes > QSUB_FRAME_MAX_BYTES) {
        _count = -1;
        return self;
    }
    // Part table first, pixels after: the GPU binds both from this one
    // buffer (shared storage, so the CPU path reads it too).
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    _pixelsOffset = sizeof(struct qsub_part) * count;
    _bytes = _pixelsOffset + bytes;
    _buffer = [device newBufferWithLength:_bytes options:MTLResourceStorageModeShared];
    if (!_buffer) {
        _count = -1;
        return self;
    }
    _parts = _buffer.contents;
    _pixels = (uint8_t *)_buffer.contents + _pixelsOffset;
    size_t off = 0;
    for (int i = 0; i < list->num_items; i++) {
        struct sub_bitmaps *g = list->items[i];
        if (g->format != SUBBITMAP_LIBASS && g->format != SUBBITMAP_BGRA)
            continue;
        bool bgra = g->format == SUBBITMAP_BGRA;
        for (int n = 0; n < g->num_parts; n++) {
            struct sub_bitmap *b = &g->parts[n];
            if (!b->bitmap || b->w <= 0 || b->h <= 0)
                continue;
            size_t row = (size_t)b->w * (bgra ? 4 : 1);
            for (int y = 0; y < b->h; y++)
                memcpy(_pixels + off + y * row, (uint8_t *)b->bitmap + (size_t)y * b->stride, row);
            _parts[_count++] = (struct qsub_part){
                .x = b->x, .y = b->y, .w = b->w, .h = b->h,
                .dw = b->dw > 0 ? b->dw : b->w, .dh = b->dh > 0 ? b->dh : b->h,
                .stride = (int32_t)row, .offset = (uint32_t)off,
                .color = b->libass.color, .bgra = bgra,
            };
            off += row * b->h;
        }
    }
    return self;
}

- (void)dealloc
{
    [_buffer release];
    [super dealloc];
}

@end

// The host app sets quasarSubtitleHosted through KVC, on main, when it moves
// the layer into the picture-in-picture window and back.
@interface QuasarSubtitleMetalLayer : CAMetalLayer
@property (nonatomic) BOOL quasarSubtitleHosted;
@property (nonatomic, assign) QuasarSubtitleLayer *owner;
@end

@implementation QuasarSubtitleMetalLayer
- (void)setQuasarSubtitleHosted:(BOOL)hosted
{
    _quasarSubtitleHosted = hosted;
    [_owner hostedDidChange];
}

// MPVUI resizes the layer with the display layer (rotation, window size)
// even while paused, when no frame attaches it. While hosted the host sizes
// it with the picture-in-picture window; the CPU image follows.
- (void)setFrame:(CGRect)frame
{
    bool resized = !CGSizeEqualToSize(frame.size, self.frame.size);
    [super setFrame:frame];
    if (_quasarSubtitleHosted) {
        if (resized)
            [_owner redraw];
    } else if (self.superlayer) {
        [_owner updatePixelSize:self.superlayer];
    }
}
@end

@implementation QuasarSubtitleLayer

// Main-thread logging. vo->log dies with the VO right after -invalidate, and
// the main-thread blocks can run later, so -invalidate clears _log under _lock.
- (void)logMain:(int)lev format:(const char *)fmt, ...
{
    pthread_mutex_lock(&_lock);
    if (_log) {
        va_list va;
        va_start(va, fmt);
        mp_msg_va(_log, lev, fmt, va);
        va_end(va);
    }
    pthread_mutex_unlock(&_lock);
}

- (instancetype)initWithTimebase:(CMTimebaseRef)timebase gain:(double)gain
                             log:(struct mp_log *)log
                            wake:(void (*)(void *))wake ctx:(void *)ctx
{
    if (!(self = [super init]))
        return nil;
    _log = log;
    _wake = wake;
    _wakeCtx = ctx;
    pthread_mutex_init(&_lock, NULL);
    _timebase = timebase ? (CMTimebaseRef)CFRetain(timebase) : NULL;
    _gain = (float)gain;
    _appliedGain = -1;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        [self release];
        return nil;
    }
    _queue = [_device newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:qsub_shader_source
                                               options:nil error:&err];
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [[lib newFunctionWithName:@"qsub_vertex"] autorelease];
    MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
    ca.blendingEnabled = YES;
    ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
    ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    bool ok = lib;
    for (int hdr = 0; ok && hdr < 2; hdr++) {
        desc.fragmentFunction =
            [[lib newFunctionWithName:hdr ? @"qsub_hdr" : @"qsub_sdr"] autorelease];
        ca.pixelFormat = hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
        _pipelines[hdr] = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
        ok = _pipelines[hdr];
    }
    if (!ok)
        mp_msg(_log, MSGL_ERR, "Subtitle layer shader failed: %s\n",
               err.localizedDescription.UTF8String ?: "?");
    [desc release];
    [lib release];
    if (!ok) {
        [self release];
        return nil;
    }
    return self;
}

// Main thread only. A CAMetalLayer created on the VO thread never shows its
// presented drawables (its implicit transaction has no run loop to commit
// it), so the layer is made on main at first attach.
- (CAMetalLayer *)layer
{
    if (!_layer) {
        QuasarSubtitleMetalLayer *ml = [[QuasarSubtitleMetalLayer alloc] init];
        ml.owner = self;
        _layer = ml;
        _layer.device = _device;
        _layer.framebufferOnly = YES;
        _layer.opaque = NO;
        _layer.hidden = YES;
        _layer.zPosition = 1;
        [self setLayerHDR:false];
    }
    return _layer;
}

- (void)dealloc
{
    for (int i = 0; i < _count; i++)
        [_entries[i].frame release];
    [_current release];
    ((QuasarSubtitleMetalLayer *)_layer).owner = nil;
    [_cpuLayer release];
    if (_timebase)
        CFRelease(_timebase);
    [_layer release];
    [_pipelines[0] release];
    [_pipelines[1] release];
    [_queue release];
    [_device release];
    pthread_mutex_destroy(&_lock);
    [super dealloc];
}

- (void)wake
{
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self schedule];
        [self release];
    });
}

// Main thread from here on.
- (bool)hosted
{
    return ((QuasarSubtitleMetalLayer *)_layer).quasarSubtitleHosted;
}

- (void)hostedDidChange
{
    [self logMain:MSGL_V format:"Subtitle layer: hosted=%d\n", [self hosted]];
    [self redraw];
}

- (void)redraw
{
    _forceDraw = true;
    [self schedule];
}

// Display link on screen; timer while hosted. The timer handler retains self
// until -stopTimer.
- (void)schedule
{
    if ([self hosted]) {
        _link.paused = YES;
        if (!_timer) {
            _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
            dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60,
                                      NSEC_PER_SEC / 240);
            dispatch_source_set_event_handler(_timer, ^{
                [self tick:CACurrentMediaTime() timer:true];
            });
            dispatch_resume(_timer);
        }
        return;
    }
    [self stopTimer];
    if (!_link) {
        _link = [[CADisplayLink displayLinkWithTarget:self
                                             selector:@selector(linkTick:)] retain];
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [self logMain:MSGL_V format:"Subtitle layer: display link started\n"];
    }
    _link.paused = NO;
}

- (void)stopTimer
{
    if (!_timer)
        return;
    dispatch_source_cancel(_timer);
    dispatch_release(_timer);
    _timer = NULL;
}

- (void)linkTick:(CADisplayLink *)link
{
    [self tick:link.targetTimestamp timer:false];
}

- (void)enqueueFrame:(QuasarSubtitleFrame *)frame pts:(int64_t)pts_ns
           immediate:(bool)immediate
{
    pthread_mutex_lock(&_lock);
    // A frame queued twice counts twice; the budget only stops pathological
    // queues, and dropping skips stale cues, never the newest.
    while (_count && (_count == QSUB_QUEUE_MAX ||
                      _queuedBytes + frame->_bytes > QSUB_QUEUE_MAX_BYTES)) {
        _queuedBytes -= _entries[0].frame->_bytes;
        [_entries[0].frame release];
        memmove(&_entries[0], &_entries[1], sizeof(_entries[0]) * (_count - 1));
        _count--;
    }
    _queuedBytes += frame->_bytes;
    _entries[_count].pts_ns = pts_ns;
    _entries[_count].frame = [frame retain];
    _entries[_count].immediate = immediate;
    _count++;
    mp_msg(_log, MSGL_DEBUG, "Subtitle layer enqueue pts=%.3f immediate=%d parts=%d\n",
           pts_ns / 1e9, immediate, frame->_count);
    pthread_mutex_unlock(&_lock);
    [self wake];
}

- (void)flushRemovingImage:(BOOL)remove
{
    pthread_mutex_lock(&_lock);
    for (int i = 0; i < _count; i++)
        [_entries[i].frame release];
    _count = 0;
    _queuedBytes = 0;
    if (remove)
        _clearPending = true;
    pthread_mutex_unlock(&_lock);
    mp_msg(_log, MSGL_DEBUG, "Subtitle layer flush remove=%d\n", remove);
    if (remove)
        [self wake];
}

- (void)setGain:(double)gain
{
    pthread_mutex_lock(&_lock);
    _gain = (float)gain;
    pthread_mutex_unlock(&_lock);
    [self wake];
}

- (void)setLayerHDR:(bool)hdr
{
    _layer.pixelFormat = hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(hdr ? kCGColorSpaceExtendedSRGB
                                                        : kCGColorSpaceSRGB);
    _layer.colorspace = cs;
    CGColorSpaceRelease(cs);
}

// EDR only while gain > 1; headroom = gain on iOS 26+.
- (void)applyGain:(float)gain
{
    if (gain == _appliedGain)
        return;
    _appliedGain = gain;
    BOOL hdr = gain > 1.0f;
    [self setLayerHDR:hdr];
#if !TARGET_OS_TV
    _layer.wantsExtendedDynamicRangeContent = hdr;
#endif
    if (@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)) {
        _layer.preferredDynamicRange = hdr ? CADynamicRangeHigh : CADynamicRangeStandard;
        _layer.contentsHeadroom = hdr ? gain : 0;
    }
    [self logMain:MSGL_V format:"Subtitle layer gain=%.2f EDR=%s\n", gain, hdr ? "on" : "off"];
}

- (void)tick:(CFTimeInterval)target timer:(bool)timer
{
    [self layer];
    bool hosted = [self hosted];
    if (hosted != timer) {
        [self schedule];
        return;
    }
    int64_t now = 0;
    if (_timebase) {
        double rate = CMTimebaseGetRate(_timebase);
        now = cm_time_to_ns(CMTimebaseGetTime(_timebase)) +
            (int64_t)((target - CACurrentMediaTime()) * rate * 1e9);
    }

    pthread_mutex_lock(&_lock);
    int pick = -1;
    for (int i = 0; i < _count; i++) {
        if (_entries[i].immediate || _entries[i].pts_ns <= now)
            pick = i;
    }
    QuasarSubtitleFrame *next = pick >= 0 ? [_entries[pick].frame retain] : nil;
    for (int i = 0; i <= pick; i++) {
        _queuedBytes -= _entries[i].frame->_bytes;
        [_entries[i].frame release];
    }
    if (pick >= 0) {
        memmove(&_entries[0], &_entries[pick + 1], sizeof(_entries[0]) * (_count - pick - 1));
        _count -= pick + 1;
    }
    bool clear = _clearPending;
    _clearPending = false;
    float gain = _gain;
    bool idle = _count == 0;
    pthread_mutex_unlock(&_lock);

    bool redraw = gain != _appliedGain || _forceDraw;
    _forceDraw = false;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self applyGain:gain];
    if (clear && pick < 0) {
        [_current release];
        _current = nil;
    }
    if (pick >= 0) {
        [_current release];
        _current = next;
        redraw = true;
    }
    if (redraw || clear)
        [self draw:gain hosted:hosted];
    [CATransaction commit];
    if (idle && timer)
        [self stopTimer];
    else if (idle)
        _link.paused = YES;
}

// Background-safe: no GPU work. Composites the parts on the CPU into one
// image the size the picture-in-picture window shows the canvas at (same
// aspect, so the gravity still maps it onto the video). SDR only; the EDR
// gain needs the shader.
- (void)drawHosted:(QuasarSubtitleFrame *)f
{
    _layer.hidden = YES;
    if (!_cpuLayer) {
        _cpuLayer = [[CALayer alloc] init];
        _cpuLayer.zPosition = 1;
    }
    if (_cpuLayer.superlayer != _layer.superlayer)
        [_layer.superlayer addSublayer:_cpuLayer];
    _cpuLayer.frame = _layer.frame;
    _cpuLayer.contentsGravity = _layer.contentsGravity;
    CGImageRef image = NULL;
    if (f && f->_count > 0 && f->_w > 0 && f->_h > 0) {
        CGFloat scale = MAX(_scale, 1);
        CGSize b = _cpuLayer.bounds.size;
        // max() also covers aspect fill, which shows the canvas larger.
        double s = fmin(1.0, fmax(b.width * scale / f->_w, b.height * scale / f->_h));
        size_t iw = MAX(1, (size_t)ceil(f->_w * s)), ih = MAX(1, (size_t)ceil(f->_h * s));
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef cg = CGBitmapContextCreate(NULL, iw, ih, 8, 0, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (cg) {
            CGContextScaleCTM(cg, iw / (double)f->_w, ih / (double)f->_h);
            CGContextSetInterpolationQuality(cg, kCGInterpolationMedium);
        }
        for (int i = 0; cg && i < f->_count; i++) {
            struct qsub_part *q = &f->_parts[i];
            CGDataProviderRef dp = CGDataProviderCreateWithData(
                NULL, f->_pixels + q->offset, (size_t)q->stride * q->h, NULL);
            CGRect rect = CGRectMake(q->x, f->_h - q->y - q->dh, q->dw, q->dh);
            if (q->bgra) {
                CGImageRef img = CGImageCreate(q->w, q->h, 8, 32, q->stride, cs,
                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                    dp, NULL, false, kCGRenderingIntentDefault);
                if (img)
                    CGContextDrawImage(cg, rect, img);
                CGImageRelease(img);
            } else {
                // libass 255 = opaque; CGImageMask paints where 0.
                CGFloat decode[] = {1, 0};
                CGImageRef mask = CGImageMaskCreate(q->w, q->h, 8, 8, q->stride, dp,
                                                    decode, false);
                if (mask) {
                    uint32_t c = q->color;
                    CGContextSaveGState(cg);
                    CGContextClipToMask(cg, rect, mask);
                    CGContextSetRGBFillColor(cg, (c >> 24 & 0xFF) / 255.0,
                                             (c >> 16 & 0xFF) / 255.0,
                                             (c >> 8 & 0xFF) / 255.0,
                                             1.0 - (c & 0xFF) / 255.0);
                    CGContextFillRect(cg, rect);
                    CGContextRestoreGState(cg);
                    CGImageRelease(mask);
                }
            }
            CGDataProviderRelease(dp);
        }
        image = cg ? CGBitmapContextCreateImage(cg) : NULL;
        CGContextRelease(cg);
        CGColorSpaceRelease(cs);
    }
    _cpuLayer.contents = (id)image;
    _cpuLayer.hidden = !image;
    CGImageRelease(image);
}

// An empty frame (cue ended) and the cleared state just hide the layer.
- (void)draw:(float)gain hosted:(bool)hosted
{
    QuasarSubtitleFrame *f = _current;
    if (hosted) {
        [self drawHosted:f];
        return;
    }
    [_cpuLayer removeFromSuperlayer];
    if (!f || f->_count <= 0 || f->_w <= 0 || f->_h <= 0) {
        _layer.hidden = YES;
        return;
    }
    CGSize size = CGSizeMake(f->_w, f->_h);
    if (!CGSizeEqualToSize(_layer.drawableSize, size)) {
        [self logMain:MSGL_V format:"Subtitle layer: canvas %dx%d\n", f->_w, f->_h];
        _layer.drawableSize = size;
    }
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) {
        [self logMain:MSGL_WARN format:"Subtitle layer: no drawable (layer %.0fx%.0f)\n",
               _layer.bounds.size.width, _layer.bounds.size.height];
        return;
    }
    if (!_loggedFirst) {
        _loggedFirst = true;
        [self logMain:MSGL_V format:"Subtitle layer: first cue %dx%d parts=%d bytes=%zu "
               "gain=%.2f layer=%.0fx%.0f superlayer=%s\n", f->_w, f->_h, f->_count,
               f->_bytes, gain, _layer.bounds.size.width, _layer.bounds.size.height,
               _layer.superlayer ? "yes" : "no"];
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    float canvas[2] = {f->_w, f->_h};
    [enc setRenderPipelineState:_pipelines[gain > 1.0f]];
    [enc setVertexBuffer:f->_buffer offset:0 atIndex:0];
    [enc setVertexBytes:canvas length:sizeof(canvas) atIndex:1];
    [enc setFragmentBuffer:f->_buffer offset:0 atIndex:0];
    [enc setFragmentBuffer:f->_buffer offset:f->_pixelsOffset atIndex:1];
    [enc setFragmentBytes:&gain length:sizeof(gain) atIndex:2];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4
          instanceCount:f->_count];
    [enc endEncoding];
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
        // Refused in the background (picture in picture closed from the home
        // screen): hide the stale drawable and redraw on the next wake.
        if (b.status == MTLCommandBufferStatusError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_layer.hidden = YES;
                self->_forceDraw = true;
            });
        }
    }];
    [cmd presentDrawable:drawable];
    [cmd commit];
    _layer.hidden = NO;
}

- (void)attachToDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer
{
    if (!displayLayer)
        return;
    [self retain];
    [displayLayer retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *layer = [self layer];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        // The host app may move the layer into the picture-in-picture window
        // (the system shows only the display layer's samples there, and
        // Dolby Vision frames cannot take composited subtitles). While it is
        // marked hosted, the host owns its superlayer and frame.
        bool hosted = [self hosted];
        if (!hosted && layer.superlayer != displayLayer)
            [displayLayer addSublayer:layer];
        if (!hosted && !CGRectEqualToRect(layer.frame, displayLayer.bounds))
            layer.frame = displayLayer.bounds;
        [self updatePixelSize:displayLayer];
        // The OSD canvas has the video's display aspect, so the same gravity
        // puts it on the video rect.
        NSString *g = displayLayer.videoGravity;
        NSString *cg = [g isEqualToString:AVLayerVideoGravityResizeAspectFill]
            ? kCAGravityResizeAspectFill
            : [g isEqualToString:AVLayerVideoGravityResize] ? kCAGravityResize
                                                           : kCAGravityResizeAspect;
        if (![layer.contentsGravity isEqualToString:cg])
            layer.contentsGravity = cg;
        [CATransaction commit];
        [self release];
        [displayLayer release];
    });
}

// Main thread. MPVUI keeps the display layer's contentsScale at the screen
// scale.
- (void)updatePixelSize:(CALayer *)displayLayer
{
    CGFloat scale = MAX(displayLayer.contentsScale, 1);
    int w = (int)lround(displayLayer.bounds.size.width * scale);
    int h = (int)lround(displayLayer.bounds.size.height * scale);
    _scale = scale;
    pthread_mutex_lock(&_lock);
    bool changed = w != _pixelW || h != _pixelH;
    _pixelW = w;
    _pixelH = h;
    if (changed && _wake)
        _wake(_wakeCtx);
    pthread_mutex_unlock(&_lock);
}

- (void)getPixelWidth:(int *)w height:(int *)h
{
    pthread_mutex_lock(&_lock);
    *w = _pixelW;
    *h = _pixelH;
    pthread_mutex_unlock(&_lock);
}

// Never sync-enter main from the VO (libmpv teardown may wait on it); the
// async block runs after every pending attach.
- (void)invalidate
{
    [self flushRemovingImage:NO];
    pthread_mutex_lock(&_lock);
    _log = NULL;
    _wake = NULL;
    pthread_mutex_unlock(&_lock);
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_link invalidate];
        [self->_link release];
        self->_link = nil;
        [self stopTimer];
        ((QuasarSubtitleMetalLayer *)self->_layer).owner = nil;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self->_cpuLayer removeFromSuperlayer];
        [self->_layer removeFromSuperlayer];
        [CATransaction commit];
        [self release];
    });
}

@end
