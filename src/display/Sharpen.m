#import "Sharpen.h"
#import "SharpenShader.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/ps/IOPowerSources.h>

static NSString *const kStoreKey  = @"SharpenByDisplay";
static NSString *const kShaderKey = @"SharpenShader";
static NSString *const kAutoKey   = @"SharpenAuto";
static NSString *const kEnabledKey = @"SharpenEnabled";
static NSString *const kRadiusKey  = @"SharpenRadius";
static NSString *const kShaderOnBatteryKey = @"SharpenShaderOnBattery";
static const float kAutoMaxAmount = 0.5f;

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

static void ddPowerChanged(void *context) {
    [(__bridge Sharpen *)context reapply];
}

static BOOL ddOnBattery(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SharpenSimulateBattery"]) return YES;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return NO;
    CFStringRef source = IOPSGetProvidingPowerSourceType(info);
    BOOL battery = source && CFEqual(source, CFSTR(kIOPMBatteryPowerKey));
    CFRelease(info);
    return battery;
}

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
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(overlaysChanged)
            name:@"DDOverlayWindowsChanged" object:nil];
        CFRunLoopSourceRef power = IOPSNotificationCreateRunLoopSource(ddPowerChanged, (__bridge void *)self);
        if (power) {
            CFRunLoopAddSource(CFRunLoopGetMain(), power, kCFRunLoopCommonModes);
            CFRelease(power);
        }
    }
    return self;
}

- (NSDictionary<NSString *, NSNumber *> *)store {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:kStoreKey] ?: @{};
}

// The shader's capture must leave out every DisplayDeck overlay, so restart
// it whenever one appears.
- (void)overlaysChanged {
    if (self.shaders.count == 0) return;
    for (SharpenShader *session in self.shaders.allValues) [session stop];
    [self.shaders removeAllObjects];
    [self reapply];
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

- (NSInteger)radius {
    NSInteger radius = [NSUserDefaults.standardUserDefaults integerForKey:kRadiusKey];
    return MAX(1, MIN(3, radius));
}

- (void)setRadius:(NSInteger)radius {
    [NSUserDefaults.standardUserDefaults setInteger:radius forKey:kRadiusKey];
    for (NSWindow *window in self.windows.allValues) [window close];
    [self.windows removeAllObjects];
    [self reapply];
}

- (BOOL)automatic {
    return [NSUserDefaults.standardUserDefaults boolForKey:kAutoKey];
}

- (void)setAutomatic:(BOOL)automatic {
    [NSUserDefaults.standardUserDefaults setBool:automatic forKey:kAutoKey];
    [self reapply];
}

- (float)amountForDisplay:(CGDirectDisplayID)displayID {
    if (!self.automatic) return [self store][@(displayID).stringValue].floatValue;

    CGFloat nativeWidth = ddNativePixelWidth(displayID);
    CGFloat logicalWidth = CGDisplayBounds(displayID).size.width;
    if (nativeWidth <= 0 || logicalWidth <= 0) return 0;
    // 0.5 = pixel-exact Retina (2 pixels per point), 1.0 = one pixel per point.
    CGFloat squeeze = (logicalWidth / nativeWidth - 0.5) / 0.5;
    return (float)(MAX(0.0, MIN(1.0, squeeze)) * kAutoMaxAmount);
}

- (void)setAmount:(float)amount forDisplay:(CGDirectDisplayID)displayID {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kAutoKey];
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
    radius = MAX(0.4, MIN(1.5, radius)) * self.radius;

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
    if (ddOnBattery() && ![NSUserDefaults.standardUserDefaults boolForKey:kShaderOnBatteryKey]) shader = NO;
    NSMutableDictionary<NSNumber *, NSWindow *> *keep = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, SharpenShader *> *keepShaders = [NSMutableDictionary dictionary];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *did = screen.deviceDescription[@"NSScreenNumber"];
        float amount = [self amountForDisplay:did.unsignedIntValue];
        if (![NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey]) amount = 0;
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
                session.radius = (int)self.radius;
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
