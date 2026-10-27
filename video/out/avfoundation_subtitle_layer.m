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

static NSString *const qsub_shader_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "vertex VOut qsub_vertex(uint vid [[vertex_id]]) {\n"
     "    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);\n"
     "    VOut o; o.pos = float4(p, 0.0, 1.0);\n"
     "    o.uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);\n"
     "    return o;\n"
     "}\n"
     // BGRA OSD is premultiplied sRGB. Decode to linear for the extended
     // linear sRGB drawable; boost only the opaque body so antialiased edges
     // and soft outlines stay SDR.
     "fragment float4 qsub_fragment(VOut in [[stage_in]],\n"
     "                              texture2d<float> tex [[texture(0)]],\n"
     "                              constant float &gain [[buffer(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    float4 c = tex.sample(s, in.uv);\n"
     "    float a = c.a;\n"
     "    if (a <= 3.0 / 255.0) return float4(0.0);\n"
     "    float3 u = min(c.rgb, float3(a)) / a;\n"
     "    float3 lin = select(pow((u + 0.055) / 1.055, 2.4), u / 12.92, u <= 0.04045);\n"
     "    float boost = gain <= 1.0 ? gain : mix(1.0, gain, smoothstep(0.20, 0.85, a));\n"
     "    return float4(lin * a * boost, a);\n"
     "}\n";

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
{
    if (!(self = [super init]))
        return nil;
    _log = log;
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
    desc.fragmentFunction = [[lib newFunctionWithName:@"qsub_fragment"] autorelease];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    _pipeline = lib ? [_device newRenderPipelineStateWithDescriptor:desc error:&err] : nil;
    if (!_pipeline)
        mp_msg(_log, MSGL_ERR, "Subtitle layer shader failed: %s\n",
               err.localizedDescription.UTF8String ?: "?");
    [desc release];
    [lib release];
    if (!_pipeline ||
        CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_textureCache) != kCVReturnSuccess) {
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
        _layer.pixelFormat = MTLPixelFormatRGBA16Float;
        _layer.framebufferOnly = YES;
        _layer.opaque = NO;
        _layer.hidden = YES;
        _layer.zPosition = 1;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        _layer.colorspace = cs;
        CGColorSpaceRelease(cs);
    }
    return _layer;
}

- (void)dealloc
{
    for (int i = 0; i < _count; i++)
        CVPixelBufferRelease(_entries[i].buf);
    CVPixelBufferRelease(_current);
    ((QuasarSubtitleMetalLayer *)_layer).owner = nil;
    [_cpuLayer release];
    if (_textureCache)
        CFRelease(_textureCache);
    if (_timebase)
        CFRelease(_timebase);
    [_layer release];
    [_pipeline release];
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

- (void)enqueueSampleBuffer:(CMSampleBufferRef)buf
{
    CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(buf);
    bool immediate = false;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(buf, false);
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(att, 0);
        immediate = CFDictionaryGetValue(d, kCMSampleAttachmentKey_DisplayImmediately) == kCFBooleanTrue;
    }
    pthread_mutex_lock(&_lock);
    if (_count == QSUB_QUEUE_MAX) {
        CVPixelBufferRelease(_entries[0].buf);
        memmove(&_entries[0], &_entries[1], sizeof(_entries[0]) * (QSUB_QUEUE_MAX - 1));
        _count--;
    }
    _entries[_count].pts_ns = cm_time_to_ns(CMSampleBufferGetPresentationTimeStamp(buf));
    _entries[_count].buf = CVPixelBufferRetain(pix);
    _entries[_count].immediate = immediate;
    _count++;
    mp_msg(_log, MSGL_DEBUG, "Subtitle layer enqueue pts=%.3f immediate=%d buf=%p\n",
           _entries[_count - 1].pts_ns / 1e9, immediate, pix);
    pthread_mutex_unlock(&_lock);
    [self wake];
}

- (void)flushRemovingImage:(BOOL)remove
{
    pthread_mutex_lock(&_lock);
    for (int i = 0; i < _count; i++)
        CVPixelBufferRelease(_entries[i].buf);
    _count = 0;
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

// EDR only while gain > 1; headroom = gain on iOS 26+.
- (void)applyGain:(float)gain
{
    if (gain == _appliedGain)
        return;
    _appliedGain = gain;
    BOOL hdr = gain > 1.0f;
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
    CVPixelBufferRef next = pick >= 0 ? CVPixelBufferRetain(_entries[pick].buf) : NULL;
    for (int i = 0; i <= pick; i++)
        CVPixelBufferRelease(_entries[i].buf);
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
        CVPixelBufferRelease(_current);
        _current = NULL;
    }
    if (pick >= 0) {
        CVPixelBufferRelease(_current);
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

// No GPU work: the render server composites the OSD IOSurface itself. SDR
// only; the EDR gain needs the shader.
- (void)drawHosted:(CVPixelBufferRef)buf
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
    _cpuLayer.contents = buf ? (id)CVPixelBufferGetIOSurface(buf) : nil;
    _cpuLayer.hidden = !buf;
}

// An empty OSD sample (cue ended) is a fully transparent buffer; hiding the
// layer covers it and the cleared state without a GPU pass.
- (void)draw:(float)gain hosted:(bool)hosted
{
    CVPixelBufferRef buf = _current;
    if (hosted) {
        [self drawHosted:buf];
        return;
    }
    [_cpuLayer removeFromSuperlayer];
    if (!buf) {
        _layer.hidden = YES;
        return;
    }
    size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
    CVMetalTextureRef texRef = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, buf, NULL,
            MTLPixelFormatBGRA8Unorm, w, h, 0, &texRef) != kCVReturnSuccess) {
        [self logMain:MSGL_WARN format:"Subtitle layer: cannot map OSD buffer to Metal\n"];
        return;
    }
    if (!CGSizeEqualToSize(_layer.drawableSize, CGSizeMake(w, h)))
        _layer.drawableSize = CGSizeMake(w, h);
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) {
        [self logMain:MSGL_WARN format:"Subtitle layer: no drawable (layer %.0fx%.0f)\n",
               _layer.bounds.size.width, _layer.bounds.size.height];
        CFRelease(texRef);
        return;
    }
    if (!_loggedFirst) {
        _loggedFirst = true;
        [self logMain:MSGL_V format:"Subtitle layer: first cue %zux%zu gain=%.2f layer=%.0fx%.0f "
               "superlayer=%s\n", w, h, gain, _layer.bounds.size.width,
               _layer.bounds.size.height, _layer.superlayer ? "yes" : "no"];
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setFragmentTexture:CVMetalTextureGetTexture(texRef) atIndex:0];
    [enc setFragmentBytes:&gain length:sizeof(gain) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
    CVPixelBufferRetain(buf);
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
        CFRelease(texRef);
        CVPixelBufferRelease(buf);
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
        // The OSD buffer is frame-space (video size), so the same gravity
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

// Never sync-enter main from the VO (libmpv teardown may wait on it); the
// async block runs after every pending attach.
- (void)invalidate
{
    [self flushRemovingImage:NO];
    pthread_mutex_lock(&_lock);
    _log = NULL;
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
