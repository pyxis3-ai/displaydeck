#import "Sharpen.h"
#import "SharpenShader.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kStoreKey  = @"SharpenByDisplay";
static NSString *const kShaderKey = @"SharpenShader";

@interface NSObject (DDCAFilter)
+ (id)filterWithType:(NSString *)type;
@end

// Sharpening without reading the screen: a click-through window whose layers
// are window-server backdrops of whatever is beneath it. An unsharp mask is
// composed from them - the original, plus a high-pass (original mixed 50/50
// with an inverted blur) blended over it in linear light.
@interface Sharpen ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, SharpenShader *> *shaders;
@property (nonatomic) BOOL shaderFailed;
@end

@implementation Sharpen

+ (instancetype)shared {
    static Sharpen *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[Sharpen alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [NSMutableDictionary dictionary];
        _shaders = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reapply)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}

- (NSDictionary<NSString *, NSNumber *> *)store {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:kStoreKey] ?: @{};
}

- (BOOL)usesShader {
    return [NSUserDefaults.standardUserDefaults boolForKey:kShaderKey];
}

- (void)setUsesShader:(BOOL)usesShader {
    [NSUserDefaults.standardUserDefaults setBool:usesShader forKey:kShaderKey];
    self.shaderFailed = NO;
    [self reapply];
}

- (BOOL)shaderActive {
    return self.shaders.count > 0;
}

- (float)amountForDisplay:(CGDirectDisplayID)displayID {
    return [self store][@(displayID).stringValue].floatValue;
}

- (void)setAmount:(float)amount forDisplay:(CGDirectDisplayID)displayID {
    NSMutableDictionary *store = [[self store] mutableCopy];
    if (amount > 0.005f) store[@(displayID).stringValue] = @(amount);
    else                 [store removeObjectForKey:@(displayID).stringValue];
    if (store.count) [NSUserDefaults.standardUserDefaults setObject:store forKey:kStoreKey];
    else             [NSUserDefaults.standardUserDefaults removeObjectForKey:kStoreKey];
    [self reapply];
}

static id ddFilter(NSString *type, NSDictionary *values) {
    id filter = [NSClassFromString(@"CAFilter") filterWithType:type];
    for (NSString *key in values) [filter setValue:values[key] forKey:key];
    return filter;
}

static CGFloat ddNativePixelWidth(CGDirectDisplayID displayID) {
    size_t width = 0;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pixels = CGDisplayModeGetPixelWidth(mode);
        if (pixels == CGDisplayModeGetWidth(mode) && pixels > width) width = pixels;
    }
    if (modes) CFRelease(modes);
    return (CGFloat)width;
}

static CALayer *ddBackdrop(CGRect frame, NSArray *filters) {
    CALayer *layer = [NSClassFromString(@"CABackdropLayer") layer];
    layer.frame = frame;
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [layer setValue:@YES forKey:@"windowServerAware"];
    [layer setValue:@1.0 forKey:@"scale"];
    layer.filters = filters;
    return layer;
}

- (NSWindow *)makeWindowForScreen:(NSScreen *)screen displayID:(CGDirectDisplayID)displayID {
    if (!NSClassFromString(@"CABackdropLayer") || !NSClassFromString(@"CAFilter")) return nil;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.releasedWhenClosed = NO;
    window.level = NSScreenSaverWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;

    // About one physical pixel of blur, whatever the "looks like" size is.
    CGFloat nativeWidth = ddNativePixelWidth(displayID);
    CGFloat radius = nativeWidth > 0 ? screen.frame.size.width / nativeWidth : 1.0;
    radius = MAX(0.4, MIN(1.5, radius));

    NSView *view = [[NSView alloc] initWithFrame:(NSRect){ NSZeroPoint, screen.frame.size }];
    CALayer *root = [CALayer layer];
    view.layer = root;
    view.wantsLayer = YES;
    CGRect bounds = (CGRect){ CGPointZero, screen.frame.size };

    [root addSublayer:ddBackdrop(bounds, @[])];

    CALayer *highPass = [CALayer layer];
    highPass.frame = bounds;
    highPass.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    highPass.name = @"highPass";
    highPass.compositingFilter = @"linearLightBlendMode";
    [highPass addSublayer:ddBackdrop(bounds, @[])];
    CALayer *inverted = ddBackdrop(bounds, @[ ddFilter(@"gaussianBlur", @{ @"inputRadius": @(radius) }),
                                              ddFilter(@"colorInvert", @{}) ]);
    inverted.opacity = 0.5;
    [highPass addSublayer:inverted];
    [root addSublayer:highPass];

    window.contentView = view;
    return window;
}

- (void)reapply {
    static BOOL askedForCapture = NO;
    if (self.usesShader && !CGPreflightScreenCaptureAccess() && !askedForCapture) {
        askedForCapture = YES;
        CGRequestScreenCaptureAccess();
    }
    BOOL shader = self.usesShader && !self.shaderFailed && CGPreflightScreenCaptureAccess();
    NSMutableDictionary<NSNumber *, NSWindow *> *keep = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, SharpenShader *> *keepShaders = [NSMutableDictionary dictionary];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *did = screen.deviceDescription[@"NSScreenNumber"];
        float amount = [self amountForDisplay:did.unsignedIntValue];
        if (amount <= 0.005f) continue;

        if (shader) {
            SharpenShader *session = self.shaders[did];
            if (session && !NSEqualRects(session.screenFrame, screen.frame)) { [session stop]; session = nil; }
            if (!session) {
                CGFloat width = ddNativePixelWidth(did.unsignedIntValue);
                if (width <= 0) width = screen.frame.size.width * screen.backingScaleFactor;
                CGSize pixels = CGSizeMake(width, round(width * screen.frame.size.height / screen.frame.size.width));
                session = [[SharpenShader alloc] initWithScreen:screen displayID:did.unsignedIntValue
                                                      pixelSize:pixels];
                __weak __typeof(self) weakSelf = self;
                session.onFailure = ^{ weakSelf.shaderFailed = YES; [weakSelf reapply]; };
            }
            if (session) {
                session.amount = amount;
                keepShaders[did] = session;
                continue;
            }
        }

        NSWindow *window = self.windows[did];
        if (window && !NSEqualRects(window.frame, screen.frame)) { [window close]; window = nil; }
        if (!window) window = [self makeWindowForScreen:screen displayID:did.unsignedIntValue];
        if (!window) continue;

        for (CALayer *layer in window.contentView.layer.sublayers)
            if ([layer.name isEqualToString:@"highPass"]) layer.opacity = amount;
        [window orderFrontRegardless];
        keep[did] = window;
    }
    for (NSNumber *did in self.windows)
        if (keep[did] != self.windows[did]) [self.windows[did] close];
    for (NSNumber *did in self.shaders)
        if (keepShaders[did] != self.shaders[did]) [self.shaders[did] stop];
    self.windows = keep;
    self.shaders = keepShaders;
}

@end
