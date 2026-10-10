#import "SharpenShader.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

// AMD FidelityFX CAS, sharpen-only: the weight of the four neighbours adapts
// to local contrast so flat areas stay clean and edges do not clip.
static NSString *const kShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 position [[position]]; };\n"
"vertex VOut vmain(uint vid [[vertex_id]]) {\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    VOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;\n"
"}\n"
"fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
"                      constant float &amount [[buffer(0)]]) {\n"
"    int2 size = int2(tex.get_width(), tex.get_height());\n"
"    int2 c = clamp(int2(in.position.xy), int2(0), size - 1);\n"
"    float3 e = tex.read(uint2(c)).rgb;\n"
"    float3 b = tex.read(uint2(clamp(c + int2( 0, -1), int2(0), size - 1))).rgb;\n"
"    float3 d = tex.read(uint2(clamp(c + int2(-1,  0), int2(0), size - 1))).rgb;\n"
"    float3 f = tex.read(uint2(clamp(c + int2( 1,  0), int2(0), size - 1))).rgb;\n"
"    float3 h = tex.read(uint2(clamp(c + int2( 0,  1), int2(0), size - 1))).rgb;\n"
"    float3 mn = min(min(min(d, e), min(f, b)), h);\n"
"    float3 mx = max(max(max(d, e), max(f, b)), h);\n"
"    float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));\n"
"    float3 w = amp * (-amount / 5.0);\n"
"    float3 rgb = saturate(((b + d + f + h) * w + e) / (1.0 + 4.0 * w));\n"
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
@end

@implementation SharpenShader

- (instancetype)initWithScreen:(NSScreen *)screen
                     displayID:(CGDirectDisplayID)displayID
                     pixelSize:(CGSize)pixelSize {
    self = [super init];
    if (!self) return nil;

    _screenFrame = screen.frame;
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

    _queue = dispatch_queue_create("com.local.DisplayDeck.sharpen", DISPATCH_QUEUE_SERIAL);
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
        config.width  = (size_t)pixelSize.width;
        config.height = (size_t)pixelSize.height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.minimumFrameInterval = CMTimeMake(1, 120);
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
    [encoder setFragmentBytes:&amount length:sizeof amount atIndex:0];
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
