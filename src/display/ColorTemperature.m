#import "ColorTemperature.h"
#import "DDUtil.h"
#include <math.h>

static NSString *const kWarmthKey = @"DDWarmth";
static NSString *const kContrastKey = @"DDContrast";
static NSString *const kAutoKey   = @"DDWarmthAuto";
static const double kNeutralKelvin = 6500.0;
static const double kWarmestKelvin = 3400.0;
static const float  kNightDefault = 0.6f;
enum { kRampSize = 256 };

static float nightRamp(void) {
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    double h = c.hour + c.minute / 60.0;
    if (h >= 20.0 || h < 6.0)       return 1.0f;
    if (h >= 18.0 && h < 20.0)      return (float)((h - 18.0) / 2.0);
    if (h >= 6.0  && h < 8.0)       return (float)(1.0 - (h - 6.0) / 2.0);
    return 0.0f;
}

static void ddColorReconfig(CGDirectDisplayID, CGDisplayChangeSummaryFlags, void *);

@interface ColorTemperature ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *warmths;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *contrasts;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) float lastRamp;
@property (nonatomic, strong) NSSet<NSNumber *> *ramped;
- (void)reapply;
- (void)reassert;
- (float)effectiveWarmthForDisplay:(CGDirectDisplayID)displayID;
@end

@implementation ColorTemperature

+ (instancetype)shared {
    static ColorTemperature *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[ColorTemperature alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _warmths = DDLoadNumberMap(kWarmthKey);
        _contrasts = DDLoadNumberMap(kContrastKey);
        _lastRamp = -1.0f;

        _timer = [NSTimer scheduledTimerWithTimeInterval:60 target:self
                    selector:@selector(tick) userInfo:nil repeats:YES];

        CGDisplayRegisterReconfigurationCallback(ddColorReconfig, (__bridge void *)self);
    }
    return self;
}

static void ddColorReconfig(CGDirectDisplayID d, CGDisplayChangeSummaryFlags flags, void *ctx) {
    (void)d;
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    ColorTemperature *self = (__bridge ColorTemperature *)ctx;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self reassert]; });
}

- (void)tick {
    float r = self.autoEnabled ? nightRamp() : -1.0f;
    if (fabsf(r - self.lastRamp) >= 0.005f) {
        self.lastRamp = r;
        [self reapply];
    } else {
        [self reassert];
    }
}

- (BOOL)autoEnabled {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:kAutoKey];
    return v ? v.boolValue : YES;
}

- (void)setAutoEnabled:(BOOL)autoEnabled {
    [[NSUserDefaults standardUserDefaults] setBool:autoEnabled forKey:kAutoKey];
    self.lastRamp = -1.0f;
    [self reapply];
}

static void temperatureGains(double kelvin, double *r, double *g, double *b) {
    double t = kelvin / 100.0, R, G, B;
    if (t <= 66) R = 255; else R = 329.698727446 * pow(t - 60, -0.1332047592);
    if (t <= 66) G = 99.4708025861 * log(t) - 161.1195681661;
    else         G = 288.1221695283 * pow(t - 60, -0.0755148492);
    if (t >= 66) B = 255; else if (t <= 19) B = 0;
    else         B = 138.5177312231 * log(t - 10) - 305.0447927307;
    *r = fmin(255, fmax(0, R)) / 255.0;
    *g = fmin(255, fmax(0, G)) / 255.0;
    *b = fmin(255, fmax(0, B)) / 255.0;
}

- (void)fillRampForDisplay:(CGDirectDisplayID)displayID
                       red:(CGGammaValue *)r green:(CGGammaValue *)g blue:(CGGammaValue *)b {
    float warmth = [self effectiveWarmthForDisplay:displayID];
    double kelvin = kNeutralKelvin - warmth * (kNeutralKelvin - kWarmestKelvin);
    // Gains relative to the neutral point, so no warmth means no tint at all
    // (the fitted curve is a touch off white at 6500K).
    double rg = 1.0, gg = 1.0, bg = 1.0;
    if (warmth > 0.001f) {
        double rn, gn, bn;
        temperatureGains(kNeutralKelvin, &rn, &gn, &bn);
        temperatureGains(kelvin, &rg, &gg, &bg);
        rg = fmin(1.0, rg / rn); gg = fmin(1.0, gg / gn); bg = fmin(1.0, bg / bn);
    }
    double contrast = [self contrastForDisplay:displayID];
    for (uint32_t i = 0; i < kRampSize; i++) {
        double v = (double)i / (kRampSize - 1);
        v += contrast * (v * v * (3.0 - 2.0 * v) - v);
        r[i] = v * rg;
        g[i] = v * gg;
        b[i] = v * bg;
    }
}

- (float)effectiveWarmthForDisplay:(CGDirectDisplayID)displayID {
    float slider = self.warmths[@(displayID)] ? self.warmths[@(displayID)].floatValue : 0.0f;
    if (!self.autoEnabled) return slider;
    float peak = slider > 0.001f ? slider : kNightDefault;
    return peak * nightRamp();
}

- (float)warmthForDisplay:(CGDirectDisplayID)displayID {
    return self.warmths[@(displayID)] ? self.warmths[@(displayID)].floatValue : 0.0f;
}

- (float)contrastForDisplay:(CGDirectDisplayID)displayID {
    return self.contrasts[@(displayID)].floatValue;
}

- (void)setContrast:(float)contrast forDisplay:(CGDirectDisplayID)displayID {
    if (contrast <= 0.001f) [self.contrasts removeObjectForKey:@(displayID)];
    else                    self.contrasts[@(displayID)] = @(contrast);
    DDSaveNumberMap(self.contrasts, kContrastKey);
    [self reapply];
}

- (BOOL)needsRampForDisplay:(CGDirectDisplayID)displayID {
    return [self effectiveWarmthForDisplay:displayID] > 0.001f ||
           [self contrastForDisplay:displayID] > 0.001f;
}

- (void)persist {
    DDSaveNumberMap(self.warmths, kWarmthKey);
}

- (void)setWarmth:(float)warmth forDisplay:(CGDirectDisplayID)displayID {
    if (warmth <= 0.001f) [self.warmths removeObjectForKey:@(displayID)];
    else                  self.warmths[@(displayID)] = @(warmth);
    [self persist];
    self.lastRamp = -1.0f;
    [self reapply];
}

- (void)reapply {
    self.lastRamp = self.autoEnabled ? nightRamp() : -1.0f;
    // Restoring resets every display to its profile, which flashes. Only do it
    // when a display that had a ramp no longer wants one.
    NSSet<NSNumber *> *wanted = [self displaysNeedingRamp];
    if (!self.ramped || ![self.ramped isSubsetOfSet:wanted]) CGDisplayRestoreColorSyncSettings();
    [self reassert];
}

// Settings belong to the physical panel; while HiDPI is forced the active
// display is a virtual one the panel mirrors.
- (NSSet<NSNumber *> *)displaysNeedingRamp {
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
    for (NSNumber *d in DDQueryDisplayList(CGGetActiveDisplayList))
        if ([self needsRampForDisplay:DDPanelDisplay(d.unsignedIntValue)]) [out addObject:d];
    return out;
}

- (void)reassert {
    NSSet<NSNumber *> *wanted = [self displaysNeedingRamp];
    for (NSNumber *d in wanted) {
        CGDirectDisplayID panel = DDPanelDisplay(d.unsignedIntValue);
        CGGammaValue r[kRampSize], g[kRampSize], b[kRampSize];
        [self fillRampForDisplay:panel red:r green:g blue:b];
        CGSetDisplayTransferByTable(d.unsignedIntValue, kRampSize, r, g, b);
        if (panel != d.unsignedIntValue) CGSetDisplayTransferByTable(panel, kRampSize, r, g, b);
    }
    self.ramped = wanted;
}

- (void)restoreAll {
    CGDisplayRestoreColorSyncSettings();
    self.ramped = nil;
}

@end
