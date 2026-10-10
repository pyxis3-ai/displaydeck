#import "SharpenShader.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

// A 5-tap Laplacian sharpen at panel-pixel scale. Contrast-adaptive
// sharpening (CAS) was tried first, but it backs off next to pure white or
// black, which is exactly where text sits, so it barely changed text.
static NSString *const kShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 position [[position]]; };\n"
"vertex VOut vmain(uint vid [[vertex_id]]) {\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    VOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;\n"
"}\n"
"// One output pixel is one panel pixel: average the k x k block of captured\n"
"// backing pixels it covers, so the downscale is exact rather than filtered.\n"
"static float3 panelPixel(texture2d<float> tex, int2 p, int k, int2 size) {\n"
"    float3 sum = float3(0.0);\n"
"    for (int y = 0; y < k; y++) for (int x = 0; x < k; x++)\n"
"        sum += tex.read(uint2(clamp(p * k + int2(x, y), int2(0), size - 1))).rgb;\n"
"    return sum / float(k * k);\n"
"}\n"
"fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
"                      constant float &amount [[buffer(0)]], constant int &k [[buffer(1)]],\n"
"                      constant int &r [[buffer(2)]]) {\n"
"    int2 size = int2(tex.get_width(), tex.get_height());\n"
"    int2 c = int2(in.position.xy);\n"
"    float3 e = panelPixel(tex, c, k, size);\n"
"    float3 b = panelPixel(tex, c + int2( 0, -r), k, size);\n"
"    float3 d = panelPixel(tex, c + int2(-r,  0), k, size);\n"
"    float3 f = panelPixel(tex, c + int2( r,  0), k, size);\n"
"    float3 h = panelPixel(tex, c + int2( 0,  r), k, size);\n"
"    // Never go past the darkest or lightest neighbour: edges tighten, but\n"
"    // grey text keeps its tone and nothing grows a halo.\n"
"    float3 mn = min(min(min(d, e), min(f, b)), h);\n"
"    float3 mx = max(max(max(d, e), max(f, b)), h);\n"
"    float3 rgb = clamp(e + amount * 2.0 * (e - (b + d + f + h) * 0.25), mn, mx);\n"
"    return float4(rgb, 1.0);\n"
"}\n";

@interface SharpenShader () <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commands;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (atomic) BOOL stopped;
@property (atomic) BOOL shown;
@property (nonatomic) int blockSize;
@end

@implementation SharpenShader

- (instancetype)initWithScreen:(NSScreen *)screen
                     displayID:(CGDirectDisplayID)displayID
                     pixelSize:(CGSize)pixelSize {
    self = [super init];
    if (!self) return nil;

    _screenFrame = screen.frame;
    CGFloat backingWidth = screen.frame.size.width * screen.backingScaleFactor;
    _blockSize = MAX(1, (int)lround(backingWidth / pixelSize.width));
    CGSize captureSize = CGSizeMake(pixelSize.width * _blockSize, pixelSize.height * _blockSize);
    _device = MTLCreateSystemDefaultDevice();
    _commands = [_device newCommandQueue];
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource options:nil error:&error];
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction   = [library newFunctionWithName:@"vmain"];
    desc.fragmentFunction = [library newFunctionWithName:@"fmain"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipeline = library ? [_device newRenderPipelineStateWithDescriptor:desc error:&error] : nil;
    if (!_pipeline) {
        NSLog(@"DisplayDeck: sharpen shader failed to build: %@", error);
        return nil;
    }

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.opaque = YES;
    _metalLayer.displaySyncEnabled = NO;
    _metalLayer.maximumDrawableCount = 2;
    _metalLayer.drawableSize = pixelSize;
    _metalLayer.magnificationFilter = kCAFilterNearest;
    _metalLayer.minificationFilter = kCAFilterNearest;

    _window = [[NSWindow alloc] initWithContentRect:screen.frame
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered defer:NO];
    _window.opaque = NO;
    _window.backgroundColor = NSColor.clearColor;
    _window.hasShadow = NO;
    _window.ignoresMouseEvents = YES;
    _window.releasedWhenClosed = NO;
    _window.alphaValue = 0.0;
    _window.level = NSScreenSaverWindowLevel;
    _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorStationary |
                                 NSWindowCollectionBehaviorIgnoresCycle |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *view = [[NSView alloc] initWithFrame:(NSRect){ NSZeroPoint, screen.frame.size }];
    view.layer = _metalLayer;
    view.wantsLayer = YES;
    _window.contentView = view;
    [_window orderFrontRegardless];

    _queue = dispatch_queue_create("com.local.DisplayDeck.sharpen",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    CGWindowID overlayID = (CGWindowID)_window.windowNumber;

    __weak __typeof(self) weakSelf = self;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *content, NSError *contentError) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;

        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays) if (d.displayID == displayID) display = d;
        SCWindow *overlay = nil;
        for (SCWindow *w in content.windows) if (w.windowID == overlayID) overlay = w;
        if (!display || !overlay) {
            NSLog(@"DisplayDeck: sharpen capture unavailable: %@", contentError);
            [self fail];
            return;
        }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                          excludingWindows:@[overlay]];
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width  = (size_t)captureSize.width;
        config.height = (size_t)captureSize.height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.queueDepth = 3;
        config.showsCursor = NO;

        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        NSError *addError = nil;
        if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen
                       sampleHandlerQueue:self.queue error:&addError]) {
            NSLog(@"DisplayDeck: sharpen capture output failed: %@", addError);
            [self fail];
            return;
        }
        [self.stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (!startError) return;
            NSLog(@"DisplayDeck: sharpen capture failed to start: %@", startError);
            [weakSelf fail];
        }];
    }];
    return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || self.stopped) return;

    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSNumber *status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
    if (status.integerValue != SCFrameStatusComplete) return;

    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = pixels ? CVPixelBufferGetIOSurface(pixels) : NULL;
    if (!surface) return;

    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:IOSurfaceGetWidth(surface)
                                    height:IOSurfaceGetHeight(surface) mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [self.device newTextureWithDescriptor:desc iosurface:surface plane:0];
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!texture || !drawable) return;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    float amount = self.amount;
    id<MTLCommandBuffer> buffer = [self.commands commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipeline];
    [encoder setFragmentTexture:texture atIndex:0];
    int block = self.blockSize;
    [encoder setFragmentBytes:&amount length:sizeof amount atIndex:0];
    int radius = MAX(1, self.radius);
    [encoder setFragmentBytes:&block length:sizeof block atIndex:1];
    [encoder setFragmentBytes:&radius length:sizeof radius atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];

    if (!self.shown) {
        self.shown = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ if (!self.stopped) self.window.alphaValue = 1.0; });
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    NSLog(@"DisplayDeck: sharpen capture stopped: %@", error);
    [self fail];
}

- (void)fail {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopped) return;
        [self stop];
        if (self.onFailure) self.onFailure();
    });
}

- (void)stop {
    if (self.stopped) return;
    self.stopped = YES;
    [self.window close];
    [self.stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
    self.stream = nil;
}

@end
