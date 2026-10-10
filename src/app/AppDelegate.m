#import "AppDelegate.h"
#import "DisplayManager.h"
#import "Brightness.h"
#import "HiDPIInjector.h"
#import "WindowTransparency.h"
#import "WindowPiP.h"
#import "WindowManager.h"
#import "AXWindow.h"
#import "RemoteAccess.h"
#import "BrightnessBooster.h"
#import "ColorTemperature.h"
#import "Sharpen.h"
#import "Dithering.h"
#import "Caffeine.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <Carbon/Carbon.h>

static void DDRequestLogout(void) {
    const char *bundleID = "com.apple.loginwindow";
    AEAddressDesc target = { typeNull, NULL };
    if (AECreateDesc(typeApplicationBundleID, bundleID, strlen(bundleID), &target) != noErr) return;
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    if (AECreateAppleEvent(kCoreEventClass, kAEReallyLogOut, &target,
                           kAutoGenerateReturnID, kAnyTransactionID, &event) == noErr) {
        AESendMessage(&event, &reply, kAENoReply, kAEDefaultTimeout);
        AEDisposeDesc(&event);
        AEDisposeDesc(&reply);
    }
    AEDisposeDesc(&target);
}

static NSString * const kAutoManage        = @"AutoManageBuiltIn";
static NSString * const kShowNotifications = @"ShowNotifications";
static NSString * const kConfirmDisable    = @"ConfirmBeforeDisable";
static NSString * const kShowResolutions   = @"ShowResolutions";
static NSString * const kFrostedBlur        = @"FrostedBlur";
static NSString * const kTransparencyEnabled = @"TransparencyEnabled";
static NSString * const kDisableDithering = @"DisableDithering";
static NSString * const kTextSmoothingLevel = @"TextSmoothingLevel";
static NSString * const kSharpenEnabled = @"SharpenEnabled";
static NSString * const kSharpenAuto    = @"SharpenAuto";
static NSString * const kSharpenShader  = @"SharpenShader";
static NSString * const kSharpenShaderOnBattery = @"SharpenShaderOnBattery";
static NSString * const kDidSetupLogin      = @"DidSetupLoginItem";
static NSString * const kForcedHiDPI        = @"ForcedHiDPI";
static NSString * const kSnapShortcuts      = @"WindowSnapShortcuts";
static NSString * const kSnapDrag           = @"WindowSnapDrag";

static NSString * const kAutoManageNotifID = @"auto-manage";

static const CGFloat kModeTabType = 112;
static const CGFloat kModeTabRate = 184;

static const CGFloat kSliderRowWidth = 150;
static NSString *const kLargerSizesHint = @"Larger sizes = more space, softer text";
static const NSInteger kSliderItemTag = 0x51D5;
static const CGFloat kAccessoryWidth = 18;
static const CGFloat kRowEdgeInset = 14;
// Where macOS draws its own submenu arrow, so the rows built here match it.
static const CGFloat kSubmenuArrowInset = 20;
static const CGFloat kRowHeight = 24;
static const CGFloat kMenuBarGap = 5;
static const void *kDDPctLabelKey = &kDDPctLabelKey;

static NSString *ddRateString(double hz, NSString *fallback) {
    return hz > 0 ? [NSString stringWithFormat:@"%.0fHz", hz] : fallback;
}

static NSString *ddLogicalString(size_t w, size_t h) {
    return [NSString stringWithFormat:@"%zu \u00D7 %zu", w, h];
}

static NSImage *ddSymbol(NSString *name) {
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    NSImage *img = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                    imageWithSymbolConfiguration:cfg];
    img.template = YES;
    return img;
}

// The same weight and size as the arrow macOS draws on a submenu item.
static NSImage *ddSubmenuArrow(void) {
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightBold];
    NSImage *img = [[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:nil]
                    imageWithSymbolConfiguration:cfg];
    img.template = YES;
    return img;
}

// macOS 27 hides menu item images unless each item opts in.
static void ddShowMenuImages(NSMenu *menu) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
    if (@available(macOS 27.0, *)) {
        for (NSMenuItem *item in menu.itemArray) {
            if (item.image) item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
            if (item.submenu) ddShowMenuImages(item.submenu);
        }
    }
#else
    (void)menu;
#endif
}

static BOOL ddTextSmoothingLevelsIgnored(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static NSImage *ddTintedSymbol(NSString *name, NSColor *color) {
    NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:
            [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
            imageWithSymbolConfiguration:cfg];
}

static const NSSize kDDGlyphSize = { 24, 16 };

static NSRect ddGlyphScreen(NSRect dst) {
    NSRect screen = NSInsetRect(dst, 1.5, 1.5);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:screen xRadius:2.5 yRadius:2.5];
    [[NSColor colorWithWhite:0 alpha:0.30] set];
    [bg fill];
    bg.lineWidth = 1.0;
    [[NSColor colorWithWhite:0 alpha:0.55] set];
    [bg stroke];
    return screen;
}

static NSRect ddGlyphRect(NSRect screen, CGRect r) {
    return NSMakeRect(screen.origin.x + r.origin.x * screen.size.width,
                      screen.origin.y + r.origin.y * screen.size.height,
                      r.size.width  * screen.size.width,
                      r.size.height * screen.size.height);
}

static NSBezierPath *ddGlyphTile(NSRect screen, CGRect r) {
    return [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(ddGlyphRect(screen, r), 0.75, 0.75)
                                           xRadius:1.5 yRadius:1.5];
}

static NSImage *ddSnapGlyph(CGRect r) {

    NSImage *img = [NSImage imageWithSize:kDDGlyphSize flipped:NO
                            drawingHandler:^BOOL(NSRect dst) {
        NSRect screen = ddGlyphScreen(dst);
        [[NSColor colorWithWhite:0 alpha:1.0] set];
        [ddGlyphTile(screen, r) fill];
        return YES;
    }];
    img.template = YES;
    return img;
}

static NSImage *ddGlyphSymbol(NSString *name) {
    NSImage *sym = ddSymbol(name);
    NSImage *img = [NSImage imageWithSize:kDDGlyphSize flipped:NO
                            drawingHandler:^BOOL(NSRect dst) {
        NSSize s = sym.size;
        [sym drawInRect:NSMakeRect(NSMidX(dst) - s.width / 2, NSMidY(dst) - s.height / 2,
                                   s.width, s.height)];
        return YES;
    }];
    img.template = YES;
    return img;
}

static NSImage *ddArrangeGlyph(DDArrange cmd) {
    if (cmd == DDArrangeCycle)   return ddGlyphSymbol(@"arrow.triangle.2.circlepath");
    if (cmd == DDArrangeRestore) return ddGlyphSymbol(@"arrow.uturn.backward");

    NSImage *img = [NSImage imageWithSize:kDDGlyphSize flipped:NO
                            drawingHandler:^BOOL(NSRect dst) {
        NSRect screen = ddGlyphScreen(dst);
        [[NSColor colorWithWhite:0 alpha:1.0] set];
        for (int i = 0; i < 4; i++)
            [ddGlyphTile(screen, CGRectMake((i % 2) * 0.5, (i / 2) * 0.5, 0.5, 0.5)) fill];
        if (cmd == DDArrangeGrid) return YES;

        CGRect mainRect = CGRectMake(0.19, 0.19, 0.62, 0.62);
        [[NSColor colorWithWhite:0 alpha:0.30] set];
        NSRectFill(ddGlyphRect(screen, mainRect));
        NSBezierPath *win = ddGlyphTile(screen, mainRect);

        CGFloat dx = cmd == DDArrangeRotateNext ? 1 : cmd == DDArrangeRotatePrev ? -1 : 0;
        CGFloat dy = cmd == DDArrangePromote ? 1 : 0;
        if (dx != 0 || dy != 0) {
            NSPoint c = NSMakePoint(NSMidX(win.bounds), NSMidY(win.bounds));
            CGFloat tip = 1.75, half = 2.5;
            [win moveToPoint:NSMakePoint(c.x + dx * tip, c.y + dy * tip)];
            [win lineToPoint:NSMakePoint(c.x - dx * tip + dy * half, c.y - dy * tip + dx * half)];
            [win lineToPoint:NSMakePoint(c.x - dx * tip - dy * half, c.y - dy * tip - dx * half)];
            [win closePath];
            win.windingRule = NSWindingRuleEvenOdd;
        }
        [[NSColor colorWithWhite:0 alpha:1.0] set];
        [win fill];
        return YES;
    }];
    img.template = YES;
    return img;
}

static NSImage *ddSnapGlyphForLayout(DDSnap l) {
    switch (l) {
        case DDSnapLeftHalf:       return ddSnapGlyph(CGRectMake(0,      0,   0.5,    1));
        case DDSnapRightHalf:      return ddSnapGlyph(CGRectMake(0.5,    0,   0.5,    1));
        case DDSnapTopHalf:        return ddSnapGlyph(CGRectMake(0,    0.5,     1,  0.5));
        case DDSnapBottomHalf:     return ddSnapGlyph(CGRectMake(0,      0,     1,  0.5));
        case DDSnapTopLeft:        return ddSnapGlyph(CGRectMake(0,    0.5,   0.5,  0.5));
        case DDSnapTopRight:       return ddSnapGlyph(CGRectMake(0.5,  0.5,   0.5,  0.5));
        case DDSnapBottomLeft:     return ddSnapGlyph(CGRectMake(0,      0,   0.5,  0.5));
        case DDSnapBottomRight:    return ddSnapGlyph(CGRectMake(0.5,    0,   0.5,  0.5));
        case DDSnapLeftThird:      return ddSnapGlyph(CGRectMake(0,      0, 1.0/3,    1));
        case DDSnapCenterThird:    return ddSnapGlyph(CGRectMake(1.0/3,  0, 1.0/3,    1));
        case DDSnapRightThird:     return ddSnapGlyph(CGRectMake(2.0/3,  0, 1.0/3,    1));
        case DDSnapLeftTwoThirds:  return ddSnapGlyph(CGRectMake(0,      0, 2.0/3,    1));
        case DDSnapRightTwoThirds: return ddSnapGlyph(CGRectMake(1.0/3,  0, 2.0/3,    1));
        case DDSnapMaximize:       return ddSnapGlyph(CGRectMake(0,      0,     1,    1));
        case DDSnapCenter:         return ddSnapGlyph(CGRectMake(0.22, 0.2,  0.56,  0.6));
        case DDSnapRestore:        return ddGlyphSymbol(@"arrow.uturn.backward");
    }
    return nil;
}

static const void *kDDOffSymKey = &kDDOffSymKey;
static const void *kDDOnSymKey  = &kDDOnSymKey;

static void ddSetToggle(NSButton *b, BOOL on) {
    NSString *offSym = objc_getAssociatedObject(b, kDDOffSymKey);
    NSString *onSym  = objc_getAssociatedObject(b, kDDOnSymKey);
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.image = ddTintedSymbol(on ? onSym : offSym,
                             on ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor]);
}

static NSAttributedString *ddColumns(NSArray<NSString *> *cols, NSArray<NSNumber *> *tabs,
                                     NSFont *font, NSColor *color) {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    NSMutableArray<NSTextTab *> *stops = [NSMutableArray array];
    for (NSUInteger i = 0; i < tabs.count; i++) {
        [stops addObject:[[NSTextTab alloc] initWithType:NSLeftTabStopType
                                                location:tabs[i].doubleValue]];
    }
    ps.tabStops = stops;
    NSMutableDictionary *attrs = [@{ NSFontAttributeName: font,
                                     NSParagraphStyleAttributeName: ps } mutableCopy];
    if (color) attrs[NSForegroundColorAttributeName] = color;
    return [[NSAttributedString alloc]
            initWithString:[cols componentsJoinedByString:@"\t"] attributes:attrs];
}

// A menu row that behaves like an ordinary item - highlights under the pointer
// and runs its action on click - while leaving room for a button at its right.
@interface DDActionRowView : NSView
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, copy) void (^onClick)(void);
@property (nonatomic) BOOL hovered;
@end

@implementation DDActionRowView

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
          owner:self userInfo:nil]];
}

- (void)setHovered:(BOOL)hovered {
    _hovered = hovered;
    self.label.textColor = hovered ? NSColor.selectedMenuItemTextColor : NSColor.labelColor;
    self.iconView.contentTintColor = hovered ? NSColor.selectedMenuItemTextColor : nil;
    // Keep the row's button readable on the highlight colour.
    for (NSView *view in self.subviews) {
        if (![view isKindOfClass:[NSButton class]]) continue;
        NSButton *button = (NSButton *)view;
        BOOL on = (button.state == NSControlStateValueOn);
        NSString *symbol = objc_getAssociatedObject(button, on ? kDDOnSymKey : kDDOffSymKey);
        if (!symbol) continue;
        NSColor *color = hovered ? NSColor.selectedMenuItemTextColor
                                 : (on ? NSColor.controlAccentColor : NSColor.secondaryLabelColor);
        button.image = ddTintedSymbol(symbol, color);
    }
    self.needsDisplay = YES;
}

- (void)mouseEntered:(NSEvent *)event { (void)event; self.hovered = YES; }
- (void)mouseExited:(NSEvent *)event  { (void)event; self.hovered = NO; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.hovered = NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!self.hovered) return;
    [NSColor.selectedContentBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 5, 0) xRadius:8 yRadius:8] fill];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    [self.enclosingMenuItem.menu cancelTracking];
    if (self.onClick) self.onClick();
}

@end

@interface AppDelegate () <UNUserNotificationCenterDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *mainMenu;
@property (nonatomic, strong) DisplayManager *displayManager;
@property (nonatomic) BOOL notificationAuthRequested;
@property (nonatomic) BOOL forceRestoreTried;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self registerDefaults];

    self.displayManager = [DisplayManager shared];

    [self enableLoginItemOnFirstRun];

    [WindowTransparency shared].frostedBlur = [self pref:kFrostedBlur];
    [[WindowTransparency shared] ensureBackendLoaded];
    [[WindowTransparency shared] startLiveUpdates];
    [[Sharpen shared] reapply];
    if ([self pref:kDisableDithering]) [Dithering setDisabled:YES];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        if ([self pref:kDisableDithering]) [Dithering setDisabled:YES];
    }];

    [[ColorTemperature shared] reapply];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;

    [[WindowManager shared] setHotkeysEnabled:[self pref:kSnapShortcuts]];
    [[WindowManager shared] setDragSnapEnabled:[self pref:kSnapDrag]];

    [[RemoteAccess shared] restoreIfEnabled];
    __weak __typeof(self) weakSelfRA = self;
    [RemoteAccess shared].onPeersChanged = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelfRA rebuildMenu]; });
    };
    [[RemoteAccess shared] refreshPeers];

    [self setupStatusItems];
    [self rebuildMenu];

    __weak __typeof(self) weakSelf = self;
    [self.displayManager startMonitoringWithChangeHandler:^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.displayManager pruneStaleVirtualDisplays];
        [strongSelf.displayManager realignForcedDisplay];
        [[Brightness shared] invalidateServiceCache];
        [[BrightnessBooster shared] reapply];
        [[ColorTemperature shared] reapply];
        if ([strongSelf pref:kDisableDithering]) [Dithering setDisabled:YES];
        [strongSelf rebuildMenu];
        [strongSelf performAutoDisableIfNeeded];
        [strongSelf performAutoReenableIfNeeded];
        [strongSelf.displayManager recoverStrandedBuiltIn];
        [strongSelf restoreForcedHiDPIIfNeeded];
    }];

    [self.displayManager recoverStrandedBuiltIn];
    [self performAutoDisableIfNeeded];
    [self restoreForcedHiDPIIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [[ColorTemperature shared] restoreAll];
    [[WindowPiP shared] restoreAll];
    [[WindowTransparency shared] restoreWindowsForQuit];
    if ([self pref:kDisableDithering]) [Dithering setDisabled:NO];
    [[RemoteAccess shared] shutdown];
    [self.displayManager cleanUpAllVirtualDisplays];
    [self.displayManager stopMonitoring];
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kAutoManage:        @NO,
        kSharpenEnabled:    @YES,
        kTextSmoothingLevel: @2,
        kTransparencyEnabled: @YES,
        kShowNotifications: @YES,
        kConfirmDisable:    @YES,
        kShowResolutions:   @YES,
        kFrostedBlur:       @YES,
        kSnapShortcuts:     @YES,
        kSnapDrag:          @YES,
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center; (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)postNotification:(NSString *)title body:(NSString *)body {
    [self postNotification:title body:body identifier:[NSUUID UUID].UUIDString];
}

- (void)postNotification:(NSString *)title body:(NSString *)body identifier:(NSString *)identifier {
    if (![self pref:kShowNotifications]) return;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body  = body;
    content.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];

    dispatch_block_t deliver = ^{
        [UNUserNotificationCenter.currentNotificationCenter
            addNotificationRequest:request withCompletionHandler:nil];
    };

    if (self.notificationAuthRequested) {
        deliver();
        return;
    }
    self.notificationAuthRequested = YES;

    UNAuthorizationOptions opts = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:opts
                      completionHandler:^(BOOL granted, NSError *error) {
        if (error) NSLog(@"DisplayDeck: Notification auth error: %@", error);
        if (granted) dispatch_async(dispatch_get_main_queue(), deliver);
    }];
}

- (void)setupStatusItems {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip =
        @"DisplayDeck - click to keep awake, right-click for the menu";

    self.mainMenu = [[NSMenu alloc] init];
    self.mainMenu.autoenablesItems = NO;
    // Wide enough that every slider keeps a usable length.
    self.mainMenu.minimumWidth = 320;
    self.mainMenu.delegate = self;

    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    __weak __typeof(self) weakSelf = self;
    [Caffeine shared].onChange = ^{ [weakSelf updateStatusIcon]; };
    [self updateStatusIcon];
}

- (void)updateStatusIcon {
    BOOL awake = [Caffeine shared].active;
    NSString *symbolName = awake ? @"mug.fill" : @"mug";
    NSImage *icon = [NSImage imageWithSystemSymbolName:symbolName
                              accessibilityDescription:@"DisplayDeck"];
    [icon setTemplate:YES];

    CGFloat h = round([NSStatusBar systemStatusBar].thickness * 0.58);
    h = MAX(15, MIN(18, h));
    NSSize s = icon.size;
    if (s.height > 0) icon.size = NSMakeSize(round(s.width * h / s.height), h);

    NSStatusBarButton *button = self.statusItem.button;
    button.image = icon;
    button.imageScaling = NSImageScaleProportionallyDown;
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    NSEvent *e = NSApp.currentEvent;
    BOOL menuClick = (e.type == NSEventTypeRightMouseUp) ||
                     (e.type == NSEventTypeLeftMouseUp &&
                      (e.modifierFlags & NSEventModifierFlagControl));
    if (menuClick) {
        // Opened by hand, directly under the menu bar. Handing the menu to the
        // status item and replaying the click leaves it hanging well below
        // the bar on macOS 27.
        NSStatusBarButton *button = self.statusItem.button;
        NSRect onScreen = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
        NSScreen *screen = button.window.screen ?: NSScreen.mainScreen;
        NSPoint topLeft = NSMakePoint(NSMinX(onScreen) - 4, NSMaxY(screen.visibleFrame) - kMenuBarGap);
        [button highlight:YES];
        [self.mainMenu popUpMenuPositioningItem:nil atLocation:topLeft inView:nil];
        [button highlight:NO];
    } else {
        [[Caffeine shared] toggle];
    }
}

- (void)rebuildMenu {
    [self populateMainMenu:self.mainMenu];
}

- (void)populateMainMenu:(NSMenu *)menu {
    [menu removeAllItems];

    [self addKeepAwakeSectionToMenu:menu];

    NSArray<DDDisplayInfo *> *displays = [self.displayManager allDisplays];
    for (DDDisplayInfo *display in displays) {
        [self addDisplaySectionToMenu:menu display:display];
    }

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Window"]];
    [self addWindowSectionToMenu:menu];

    [self addRemoteSectionToMenu:menu];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Transparency"]];
    [self addTransparencySectionToMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];

    // macOS 27 draws text the same at every smoothing level; only on and off
    // differ there.
    NSButton *logOut = [NSButton buttonWithImage:ddTintedSymbol(@"rectangle.portrait.and.arrow.right", [NSColor secondaryLabelColor])
                                          target:self action:@selector(logOutToApply:)];
    logOut.bordered = NO;
    logOut.toolTip = @"Text Smoothing changes apply after you log back in. Click to log out now.";
    logOut.translatesAutoresizingMaskIntoConstraints = NO;
    // macOS 27 draws text the same at every smoothing level, so the levels
    // submenu is only offered below it.
    [menu addItem:[self toggleRow:@"Text Smoothing" icon:@"textformat.size"
                               on:([self currentFontSmoothing] != 0)
                           action:@selector(fontSmoothingToggled:)
                          submenu:(ddTextSmoothingLevelsIgnored() ? nil : [self textSmoothingLevelsMenu])
                        accessory:logOut]];

    NSMenuItem *settingsItem = [[NSMenuItem alloc]
        initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settingsItem.image = ddSymbol(@"gearshape");
    NSMenu *settingsMenu = [[NSMenu alloc] init];
    settingsMenu.autoenablesItems = NO;
    settingsMenu.delegate = self;
    settingsItem.submenu = settingsMenu;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
        action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    quit.image = ddSymbol(@"power");
    [menu addItem:quit];

    ddShowMenuImages(menu);
    [self sizeSliderRowsInMenu:menu];
}

- (void)addKeepAwakeSectionToMenu:(NSMenu *)menu {
    Caffeine *caf = [Caffeine shared];

    NSMenu *m = [[NSMenu alloc] init];
    m.autoenablesItems = NO;
    if (caf.active && caf.expiry) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.timeStyle = NSDateFormatterShortStyle;
        df.dateStyle = NSDateFormatterNoStyle;
        [self addLabelToMenu:m title:
            [NSString stringWithFormat:@"Awake until %@", [df stringFromDate:caf.expiry]]];
    }
    [m addItem:[NSMenuItem sectionHeaderWithTitle:@"Keep Awake For"]];
    NSArray *durations = @[ @[@"15 minutes", @900], @[@"30 minutes", @1800],
                            @[@"1 hour", @3600], @[@"2 hours", @7200], @[@"5 hours", @18000] ];
    for (NSArray *d in durations) {
        NSMenuItem *di = [[NSMenuItem alloc] initWithTitle:d[0]
            action:@selector(keepAwakeFor:) keyEquivalent:@""];
        di.target = self;
        di.image = ddSymbol(@"timer");
        di.representedObject = d[1];
        [m addItem:di];
    }

    [menu addItem:[self toggleRow:@"Keep Awake" icon:@"mug" on:caf.active
                           action:@selector(keepAwakeSwitchToggled:) submenu:m]];
}

- (NSMenuItem *)toggleRow:(NSString *)label icon:(NSString *)symbol
                       on:(BOOL)on action:(SEL)action submenu:(NSMenu *)submenu {
    return [self toggleRow:label icon:symbol on:on action:action submenu:submenu accessory:nil];
}

// A switch row. The switch sits against the right edge, or against the
// submenu arrow when the row has one.
- (NSMenuItem *)toggleRow:(NSString *)label icon:(NSString *)symbol
                       on:(BOOL)on action:(SEL)action submenu:(NSMenu *)submenu
                accessory:(NSButton *)accessory {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSliderRowWidth, kRowHeight)];

    NSImageView *icon = [NSImageView imageViewWithImage:ddSymbol(symbol)];
    icon.imageScaling = NSImageScaleProportionallyDown;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    NSTextField *name = [NSTextField labelWithString:label];
    name.font = [NSFont menuFontOfSize:13];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:name];

    NSImageView *chevron = [NSImageView imageViewWithImage:ddSubmenuArrow()];
    chevron.contentTintColor = [NSColor labelColor];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.hidden = (submenu == nil);
    [row addSubview:chevron];

    NSSwitch *sw = [[NSSwitch alloc] init];
    sw.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    sw.controlSize = NSControlSizeMini;
    sw.target = self;
    sw.action = action;
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:sw];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:kRowHeight],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],
        [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kSubmenuArrowInset],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        (submenu ? [sw.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-9]
                 : [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowEdgeInset]),
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:10],
    ]];
    if (accessory) {
        [row addSubview:accessory];
        [NSLayoutConstraint activateConstraints:@[
            [accessory.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-8],
            [accessory.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [accessory.widthAnchor constraintEqualToConstant:kAccessoryWidth],
        ]];
    }

    row.autoresizingMask = NSViewWidthSizable;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:@""];
    item.tag = kSliderItemTag;
    item.view = row;
    item.submenu = submenu;
    return item;
}

- (void)keepAwakeFor:(NSMenuItem *)sender {
    [[Caffeine shared] activateForDuration:[sender.representedObject doubleValue]];
    [self rebuildMenu];
}

- (void)keepAwakeSwitchToggled:(NSSwitch *)sw {
    Caffeine *caf = [Caffeine shared];
    if (sw.state == NSControlStateValueOn) {
        if (!caf.active) [caf toggle];
    } else {
        [caf deactivate];
    }
}

- (NSMenuItem *)actionItem:(NSString *)title action:(SEL)action
                 displayID:(CGDirectDisplayID)did symbol:(NSString *)symbol {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(did);
    if (symbol) item.image = ddSymbol(symbol);
    return item;
}

#pragma mark - Window management

- (NSMenuItem *)snapItem:(NSString *)title layout:(DDSnap)layout key:(NSString *)key {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title
                                                action:@selector(snapMenu:) keyEquivalent:key];
    it.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    it.target = self;
    it.representedObject = @(layout);
    it.image = ddSnapGlyphForLayout(layout);
    return it;
}

- (NSMenuItem *)arrangeItem:(NSString *)title command:(DDArrange)cmd key:(NSString *)key {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title
                                                action:@selector(arrangeMenu:) keyEquivalent:key];
    it.keyEquivalentModifierMask =
        NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;
    it.target = self;
    it.representedObject = @(cmd);
    it.image = ddArrangeGlyph(cmd);
    return it;
}

- (void)addWindowSectionToMenu:(NSMenu *)menu {
    if (!DDAXTrusted()) {
        NSMenuItem *grant = [[NSMenuItem alloc]
            initWithTitle:@"Enable Snapping…"
                   action:@selector(grantWindowAccess:) keyEquivalent:@""];
        grant.target = self;
        grant.image = ddSymbol(@"macwindow.badge.plus");
        grant.toolTip = @"Grant Accessibility permission to snap windows";
        [menu addItem:grant];
        return;
    }

    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Snap Window"
                                                  action:nil keyEquivalent:@""];
    root.image = ddSymbol(@"macwindow.on.rectangle");
    NSMenu *sm = [[NSMenu alloc] init];
    sm.autoenablesItems = NO;

    NSString *L = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    NSString *R = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *U = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
    NSString *D = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];

    [sm addItem:[self snapItem:@"Left Half"   layout:DDSnapLeftHalf   key:L]];
    [sm addItem:[self snapItem:@"Right Half"  layout:DDSnapRightHalf  key:R]];
    [sm addItem:[self snapItem:@"Top Half"    layout:DDSnapTopHalf    key:U]];
    [sm addItem:[self snapItem:@"Bottom Half" layout:DDSnapBottomHalf key:D]];
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[self snapItem:@"Top Left"     layout:DDSnapTopLeft     key:@"u"]];
    [sm addItem:[self snapItem:@"Top Right"    layout:DDSnapTopRight    key:@"i"]];
    [sm addItem:[self snapItem:@"Bottom Left"  layout:DDSnapBottomLeft  key:@"j"]];
    [sm addItem:[self snapItem:@"Bottom Right" layout:DDSnapBottomRight key:@"k"]];
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[self snapItem:@"Left Third"       layout:DDSnapLeftThird       key:@"d"]];
    [sm addItem:[self snapItem:@"Center Third"     layout:DDSnapCenterThird     key:@"f"]];
    [sm addItem:[self snapItem:@"Right Third"      layout:DDSnapRightThird      key:@"g"]];
    [sm addItem:[self snapItem:@"Left Two-Thirds"  layout:DDSnapLeftTwoThirds   key:@"e"]];
    [sm addItem:[self snapItem:@"Right Two-Thirds" layout:DDSnapRightTwoThirds  key:@"t"]];
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[self snapItem:@"Maximize" layout:DDSnapMaximize key:@"\r"]];
    [sm addItem:[self snapItem:@"Center"   layout:DDSnapCenter   key:@"c"]];
    [sm addItem:[self snapItem:@"Restore"  layout:DDSnapRestore  key:@"z"]];
    [sm addItem:[NSMenuItem separatorItem]];
    { NSMenuItem *it = [self checkItemWithTitle:@"Snap by Dragging" key:kSnapDrag]; it.image = ddGlyphSymbol(@"hand.draw"); [sm addItem:it]; }
    { NSMenuItem *it = [self checkItemWithTitle:@"Keyboard Shortcuts (⌃⌥)" key:kSnapShortcuts]; it.image = ddGlyphSymbol(@"keyboard"); [sm addItem:it]; }

    root.submenu = sm;
    [menu addItem:root];

    NSMenuItem *aroot = [[NSMenuItem alloc] initWithTitle:@"Arrange Windows"
                                                   action:nil keyEquivalent:@""];
    aroot.image = ddSymbol(@"square.grid.2x2");
    NSMenu *am = [[NSMenu alloc] init];
    am.autoenablesItems = NO;

    NSString *space = @" ";
    NSString *ret   = @"\r";
    NSString *rt    = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *lf    = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    [am addItem:[self arrangeItem:@"Grid 2×2"          command:DDArrangeGrid     key:@"g"]];
    [am addItem:[self arrangeItem:@"Centered over Grid" command:DDArrangeCentered key:@"c"]];
    [am addItem:[NSMenuItem separatorItem]];
    [am addItem:[self arrangeItem:@"Cycle Layout"       command:DDArrangeCycle    key:space]];
    [am addItem:[self arrangeItem:@"Promote to Main"    command:DDArrangePromote  key:ret]];
    [am addItem:[self arrangeItem:@"Center Next"        command:DDArrangeRotateNext key:rt]];
    [am addItem:[self arrangeItem:@"Center Previous"    command:DDArrangeRotatePrev key:lf]];
    [am addItem:[self arrangeItem:@"Restore"            command:DDArrangeRestore  key:@"z"]];

    aroot.submenu = am;
    [menu addItem:aroot];
}

- (void)snapMenu:(NSMenuItem *)sender {
    [[WindowManager shared] snap:(DDSnap)[sender.representedObject integerValue]];
}

- (void)arrangeMenu:(NSMenuItem *)sender {
    [[WindowManager shared] arrange:(DDArrange)[sender.representedObject integerValue]];
}

- (void)grantWindowAccess:(id)sender {
    (void)sender;
    DDAXRequestTrust();
}

#pragma mark - Remote access

- (void)addRemoteSectionToMenu:(NSMenu *)menu {
    RemoteAccess *ra = [RemoteAccess shared];

    NSMenu *m = [[NSMenu alloc] init];
    m.autoenablesItems = NO;

    [m addItem:[NSMenuItem sectionHeaderWithTitle:@"Relay"]];
    NSString *endpoint = ra.isConfigured
        ? [NSString stringWithFormat:@"%@@%@:%@", ra.relayUser, ra.relayHost, ra.relayPort]
        : @"";
    [m addItem:[self relayFieldRow:endpoint placeholder:@"tunnel@host:22"
                            action:@selector(relayEndpointFieldChanged:)]];
    NSString *stateText, *stateIcon;
    if (!ra.isConfigured)    { stateText = @"Set the relay above"; stateIcon = @"exclamationmark.triangle"; }
    else if (!ra.isEnabled)  { stateText = @"Off";                 stateIcon = @"circle"; }
    else if (ra.isConnected) { stateText = @"Connected";           stateIcon = @"circle.fill"; }
    else if (ra.lastError)   { stateText = ra.lastError;           stateIcon = @"exclamationmark.triangle"; }
    else                     { stateText = @"Connecting…";         stateIcon = @"circle.dotted"; }
    [self addInfoRow:m title:stateText image:ddSymbol(stateIcon)];
    if (ra.isConfigured) {
        [self addInfoRow:m title:[NSString stringWithFormat:@"This Mac, ssh %d, vnc %d", ra.sshPort, ra.vncPort]
                   image:ddSymbol(@"desktopcomputer")];
    }
    NSMenuItem *key = [[NSMenuItem alloc] initWithTitle:@"Copy This Mac's Relay Key"
        action:@selector(copyRemoteAuthLine:) keyEquivalent:@""];
    key.target = self; key.image = ddSymbol(@"key");
    [m addItem:key];
    NSMenuItem *awake = [[NSMenuItem alloc] initWithTitle:@"Keep Awake While On"
        action:@selector(keepAwakeRemoteToggled:) keyEquivalent:@""];
    awake.target = self;
    awake.image = ddSymbol(@"powersleep");
    awake.state = ra.keepAwake ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:awake];

    [m addItem:[NSMenuItem sectionHeaderWithTitle:@"Connect to a Mac"]];
    NSArray<NSDictionary *> *peers = ra.peers;
    if (peers.count == 0) {
        [self addInfoRow:m title:@"No Macs found" image:ddSymbol(@"magnifyingglass")];
    }
    for (NSDictionary *peer in peers) {
        BOOL isSelf = [peer[@"self"] boolValue];
        NSString *name = isSelf ? [NSString stringWithFormat:@"%@ (this Mac)", peer[@"name"]]
                                : peer[@"name"];

        [self addInfoRow:m title:name
                   image:ddSymbol([peer[@"online"] boolValue] ? @"circle.fill" : @"circle")];
        if (isSelf) continue;
        NSMenuItem *ss = [[NSMenuItem alloc] initWithTitle:@"Screen Share"
            action:@selector(connectScreenShare:) keyEquivalent:@""];
        ss.target = self; ss.image = ddSymbol(@"display"); ss.representedObject = peer;
        [m addItem:ss];
        NSMenuItem *sh = [[NSMenuItem alloc] initWithTitle:@"SSH"
            action:@selector(connectSSH:) keyEquivalent:@""];
        sh.target = self; sh.image = ddSymbol(@"terminal"); sh.representedObject = peer;
        [m addItem:sh];
        NSMenuItem *sf = [[NSMenuItem alloc] initWithTitle:@"Files"
            action:@selector(connectSFTP:) keyEquivalent:@""];
        sf.target = self; sf.image = ddSymbol(@"folder"); sf.representedObject = peer;
        [m addItem:sf];
    }
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh"
        action:@selector(refreshRemotePeers:) keyEquivalent:@""];
    refresh.target = self; refresh.image = ddSymbol(@"arrow.clockwise");
    [m addItem:refresh];

    ddShowMenuImages(m);
    [self sizeSliderRowsInMenu:m];
    [menu addItem:[self toggleRow:@"Remote Access" icon:@"network" on:ra.isEnabled
                           action:@selector(remoteSwitchToggled:) submenu:m]];
}

- (NSMenuItem *)switchRow:(NSString *)label icon:(NSString *)symbol
                       on:(BOOL)on action:(SEL)action width:(CGFloat)width {
    (void)width;
    return [self toggleRow:label icon:symbol on:on action:action submenu:nil];
}

- (void)remoteSwitchToggled:(NSSwitch *)sw {
    RemoteAccess *ra = [RemoteAccess shared];
    if (sw.state == NSControlStateValueOn) { [ra enable]; } else { [ra disable]; }
}

- (NSMenuItem *)relayFieldRow:(NSString *)value
                  placeholder:(NSString *)placeholder action:(SEL)action {

    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 30)];

    NSTextField *field = [[NSTextField alloc] init];
    field.stringValue = value ?: @"";
    field.placeholderString = placeholder;
    field.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    field.controlSize = NSControlSizeSmall;
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.editable = YES;
    field.selectable = YES;
    field.target = self;
    field.action = action;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:30],
        [field.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [field.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [field.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.tag = kSliderItemTag;
    item.view = row;
    return item;
}

- (NSString *)trimmed:(NSString *)s {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)relayEndpointFieldChanged:(NSTextField *)f {
    NSString *s = [self trimmed:f.stringValue];
    RemoteAccess *ra = [RemoteAccess shared];
    if (s.length == 0) { [ra setRelayHost:@"" user:nil port:nil]; return; }

    NSString *user = nil, *host = s, *port = nil;
    NSRange at = [s rangeOfString:@"@"];
    if (at.location != NSNotFound) {
        user = [s substringToIndex:at.location];
        host = [s substringFromIndex:NSMaxRange(at)];
    }
    NSRange colon = [host rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        NSString *p = [host substringFromIndex:NSMaxRange(colon)];
        NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if (p.length && [p rangeOfCharacterFromSet:nonDigit].location == NSNotFound) {
            port = p;
            host = [host substringToIndex:colon.location];
        }
    }
    [ra setRelayHost:[self trimmed:host] user:[self trimmed:(user ?: @"")] port:port];
}

- (void)copyRemoteAuthLine:(id)sender {
    (void)sender;
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:([RemoteAccess shared].authorizeLine ?: @"")
                                        forType:NSPasteboardTypeString];
}

- (void)connectScreenShare:(NSMenuItem *)sender {
    [[RemoteAccess shared] screenSharePeer:sender.representedObject];
}
- (void)connectSSH:(NSMenuItem *)sender {
    [[RemoteAccess shared] sshPeer:sender.representedObject];
}
- (void)connectSFTP:(NSMenuItem *)sender {
    [[RemoteAccess shared] sftpPeer:sender.representedObject];
}
- (void)keepAwakeRemoteToggled:(NSMenuItem *)sender {
    [RemoteAccess shared].keepAwake = ![RemoteAccess shared].keepAwake;
    sender.state = [RemoteAccess shared].keepAwake ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)refreshRemotePeers:(id)sender {
    (void)sender;
    [[RemoteAccess shared] refreshPeers];
}

- (void)addDisplaySectionToMenu:(NSMenu *)menu display:(DDDisplayInfo *)display {
    BOOL forced = [self.displayManager isHiDPIForcedForDisplay:display.displayID];

    NSString *suffix;
    if (forced)                 suffix = @"  \u00B7  HiDPI forced";
    else if (!display.isActive) suffix = @"  \u00B7  off";
    else if (display.isHiDPI)   suffix = @"  \u00B7  HiDPI";
    else                        suffix = @"";
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:
        [display.name stringByAppendingString:suffix]]];

    if (forced) {
        [self addBrightnessWarmthToMenu:menu display:display];
        NSArray<DDDisplayMode *> *options =
            [self.displayManager forceHiDPIOptionsForDisplay:display.displayID];
        DDDisplayMode *target = [self.displayManager forcedTargetForDisplay:display.displayID];
        NSMutableString *title = [NSMutableString stringWithString:@"Resolution"];
        if (target) [title appendFormat:@"   %@", ddLogicalString(target.logicalWidth, target.logicalHeight)];
        NSMenuItem *fh = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        fh.image = ddSymbol(@"rectangle.on.rectangle");
        fh.submenu = [self buildForceHiDPISubmenuForDisplay:display.displayID options:options];
        [fh.submenu addItem:[NSMenuItem separatorItem]];
        [fh.submenu addItem:[self actionItem:@"Stop Forced HiDPI"
                                      action:@selector(stopForcedHiDPI:) displayID:display.displayID
                                      symbol:@"arrow.uturn.backward"]];
        [menu addItem:fh];
        return;
    }
    if (!display.isActive) {
        if (display.logicalWidth > 0) {
            NSMutableString *line = [NSMutableString stringWithString:
                ddLogicalString(display.logicalWidth, display.logicalHeight)];
            if (display.isHiDPI) [line appendString:@"  HiDPI"];
            if (display.refreshRate > 0) [line appendFormat:@" %.0fHz", display.refreshRate];
            [self addInfoRow:menu title:line image:ddSymbol(@"display")];
        }
        [menu addItem:[self actionItem:@"Enable Display"
                                action:@selector(enableDisplay:) displayID:display.displayID
                                symbol:@"power"]];
        return;
    }

    [self addBrightnessWarmthToMenu:menu display:display];
    {
        NSArray<DDDisplayMode *> *modes =
            [self curatedModes:[self.displayManager modesForDisplay:display.displayID]
               includeNonHiDPI:[self pref:kShowResolutions]];
        size_t lw = display.logicalWidth ?: display.pixelWidth;
        size_t lh = display.logicalHeight ?: display.pixelHeight;
        NSMutableString *rt = [NSMutableString stringWithString:@"Resolution"];
        if (lw) [rt appendFormat:@"   %@", ddLogicalString(lw, lh)];
        NSMenuItem *res = [[NSMenuItem alloc] initWithTitle:rt action:nil keyEquivalent:@""];
        res.image = ddSymbol(@"rectangle.on.rectangle");
        res.submenu = [self buildModesSubmenuForDisplay:display.displayID modes:modes];
        [menu addItem:res];
    }
    if (display.isBuiltIn) {
        // One row for both: click it to turn the display off now, or use its
        // button to have that happen whenever an external display connects.
        NSButton *automatic = [self prefToggle:kAutoManage symbol:@"a.circle" onSymbol:@"a.circle.fill"
                                       tooltip:@"Turn off automatically when an external display connects"];
        CGDirectDisplayID did = display.displayID;
        __weak __typeof(self) weakSelf = self;
        [menu addItem:[self actionRow:@"Disable Display" icon:@"power" accessory:automatic onClick:^{
            NSMenuItem *carrier = [[NSMenuItem alloc] init];
            carrier.representedObject = @(did);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf disableDisplay:carrier]; });
        }]];
    } else {
        [menu addItem:[self actionItem:@"Disable Display"
                                action:@selector(disableDisplay:) displayID:display.displayID
                                symbol:@"power"]];
    }
}

- (NSMenuItem *)actionRow:(NSString *)label icon:(NSString *)symbol
                accessory:(NSButton *)accessory onClick:(void (^)(void))onClick {
    DDActionRowView *row = [[DDActionRowView alloc] initWithFrame:NSMakeRect(0, 0, kSliderRowWidth, kRowHeight)];
    row.onClick = onClick;

    row.iconView = [NSImageView imageViewWithImage:ddSymbol(symbol)];
    row.iconView.imageScaling = NSImageScaleProportionallyDown;
    row.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:row.iconView];

    row.label = [NSTextField labelWithString:label];
    row.label.font = [NSFont menuFontOfSize:13];
    row.label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:row.label];
    [row addSubview:accessory];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:kRowHeight],
        [row.iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [row.iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.iconView.widthAnchor constraintEqualToConstant:16],
        [row.iconView.heightAnchor constraintEqualToConstant:16],
        [row.label.leadingAnchor constraintEqualToAnchor:row.iconView.trailingAnchor constant:8],
        [row.label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [accessory.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowEdgeInset],
        [accessory.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [accessory.widthAnchor constraintEqualToConstant:kAccessoryWidth],
    ]];

    row.autoresizingMask = NSViewWidthSizable;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:@""];
    item.tag = kSliderItemTag;
    item.view = row;
    return item;
}

- (void)addBrightnessWarmthToMenu:(NSMenu *)menu display:(DDDisplayInfo *)display {
    if ([[Brightness shared] supportsBrightness:display.displayID]) {
        int b = [[Brightness shared] brightnessPercentForDisplay:display.displayID];
        if (b < 0) b = 100;
        float boost = [[BrightnessBooster shared] boostForDisplay:display.displayID];
        int shown = boost > 1.0f ? (int)lroundf(boost * 100.0f) : b;
        int maxPct = (int)lroundf([[BrightnessBooster shared]
                                   maxBoostForDisplay:display.displayID] * 100.0f);
        if (maxPct < 100) maxPct = 100;
        if (shown > maxPct) shown = maxPct;
        NSButton *autoToggle = nil;
        if ([[Brightness shared] supportsAutoBrightness:display.displayID]) {
            autoToggle = [self rowToggleWithSymbol:@"a.circle" onSymbol:@"a.circle.fill"
                state:[[Brightness shared] autoBrightnessEnabled:display.displayID]
                  tag:(NSInteger)display.displayID
               action:@selector(toggleAutoBrightness:) tooltip:@"Auto-brightness"];
        }
        [menu addItem:[self sliderRowWithLabel:@"Brightness" icon:ddSymbol(@"sun.max")
                                       percent:shown minPct:10
                                        maxPct:maxPct continuous:YES tag:display.displayID
                                        action:@selector(brightnessSliderChanged:)
                                     accessories:(autoToggle ? @[autoToggle] : @[])]];
    }
    int warmth = (int)lroundf([[ColorTemperature shared]
                               warmthForDisplay:display.displayID] * 100.0f);
    NSButton *autoWarm = [self rowToggleWithSymbol:@"moon" onSymbol:@"moon.fill"
        state:[ColorTemperature shared].autoEnabled
          tag:(NSInteger)display.displayID
       action:@selector(toggleAutoWarmth:) tooltip:@"Auto-warm at night"];
    {
        NSMenuItem *row = [self sliderRowWithLabel:@"Warmth" icon:ddSymbol(@"thermometer.sun")
                                   percent:warmth minPct:0
                                    maxPct:100 continuous:YES tag:display.displayID
                                    action:@selector(warmthSliderChanged:)
                                 accessories:@[autoWarm]];
        [self makeIconOfRow:row clickable:@selector(resetSliderFromIcon:) tag:0 tooltip:@"Click to reset Warmth"];
        [menu addItem:row];
    }
    int contrast = (int)lroundf([[ColorTemperature shared] contrastForDisplay:display.displayID] * 100.0f);
    {
        NSMenuItem *row = [self sliderRowWithLabel:@"Contrast" icon:ddSymbol(@"circle.righthalf.filled")
                                   percent:contrast minPct:0
                                    maxPct:100 continuous:YES tag:display.displayID
                                    action:@selector(contrastSliderChanged:)
                                 accessories:((display.isBuiltIn && [Dithering isAvailable])
        ? @[[self prefToggle:kDisableDithering symbol:@"circle.dotted" onSymbol:@"circle.dotted.circle.fill"
                     tooltip:@"Disable panel dithering (keeps every pixel still)"]] : @[])];
        [self makeIconOfRow:row clickable:@selector(resetSliderFromIcon:) tag:0 tooltip:@"Click to reset Contrast"];
        [menu addItem:row];
    }
    int sharpen = (int)lroundf([[Sharpen shared] amountForDisplay:display.displayID] * 100.0f);
    BOOL sharpenOn = [self pref:kSharpenEnabled];
    NSMenuItem *sharpenRow = [self sliderRowWithLabel:@"Sharpen" icon:ddSymbol(sharpenOn ? @"diamond.fill" : @"diamond")
                                   percent:sharpen minPct:0
                                    maxPct:100 continuous:YES tag:display.displayID
                                    action:@selector(sharpenSliderChanged:)
                                 accessories:@[[self rowToggleWithSymbol:@"a.circle" onSymbol:@"a.circle.fill"
                                     state:[Sharpen shared].automatic tag:0
                                    action:@selector(toggleSharpenAuto:)
                                   tooltip:@"Auto-sharpen for the current resolution"],
                                               [self rowToggleWithSymbol:@"camera.filters" onSymbol:@"camera.filters"
                                     state:[Sharpen shared].usesShader tag:0
                                    action:@selector(toggleSharpenShader:)
                                   tooltip:@"Shader mode (captures the screen)"]]
                                     submenu:[self sharpenOptionsMenu]];
    [self makeIconOfRow:sharpenRow clickable:@selector(toggleSharpenFromIcon:) tag:0
                tooltip:(sharpenOn ? @"Click to turn Sharpen off" : @"Click to turn Sharpen on")];
    [menu addItem:sharpenRow];
}

- (NSMenu *)buildForceHiDPISubmenuForDisplay:(CGDirectDisplayID)displayID
                                     options:(NSArray<DDDisplayMode *> *)options {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *font = [NSFont menuFontOfSize:13];
    NSFont *bold = [NSFont boldSystemFontOfSize:12];

    DDDisplayMode *currentlyForced = [self.displayManager forcedTargetForDisplay:displayID];
    CGSize panel = [self.displayManager physicalPixelsForDisplay:displayID];
    __block BOOL hasExact = NO;

    NSMenuItem * (^makeRow)(DDDisplayMode *) = ^NSMenuItem *(DDDisplayMode *mode) {
        BOOL isCurrent = (currentlyForced &&
                          currentlyForced.logicalWidth  == mode.logicalWidth &&
                          currentlyForced.logicalHeight == mode.logicalHeight);
        NSString *size = ddLogicalString(mode.logicalWidth, mode.logicalHeight);
        NSString *rate = ddRateString(mode.refreshRate, @"");
        // Two rendered pixels per panel pixel: the mirror needs no resampling.
        if (mode.logicalWidth * 2 == (size_t)panel.width) { rate = [rate stringByAppendingString:@"  ★"]; hasExact = YES; }
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@""
                   action:isCurrent ? nil : @selector(forceHiDPIAtMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !isCurrent;
        item.representedObject = @{ @"displayID": @(displayID), @"mode": mode };
        item.attributedTitle = ddColumns(@[size, rate], @[@(kModeTabType)],
                                         isCurrent ? bold : font, nil);
        if (isCurrent) item.state = NSControlStateValueOn;
        return item;
    };

    NSMenuItem *colHeader = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    colHeader.attributedTitle = ddColumns(@[@"Looks Like", @"Rate"],
                                          @[@(kModeTabType)],
                                          bold, [NSColor secondaryLabelColor]);
    colHeader.enabled = NO;
    [submenu addItem:colHeader];
    [submenu addItem:[NSMenuItem separatorItem]];

    // While forced, the panel reports the forced size as one of its own, which
    // drops it from the options; put it back so the current size shows ticked.
    NSMutableArray<DDDisplayMode *> *rows = [options mutableCopy];
    if (currentlyForced) {
        NSUInteger at = 0;
        BOOL listed = NO;
        for (DDDisplayMode *m in rows) {
            if (m.logicalWidth == currentlyForced.logicalWidth && m.logicalHeight == currentlyForced.logicalHeight) listed = YES;
            if (m.logicalWidth > currentlyForced.logicalWidth) at++;
        }
        if (!listed) [rows insertObject:currentlyForced atIndex:at];
    }
    for (DDDisplayMode *m in rows) [submenu addItem:makeRow(m)];

    [submenu addItem:[NSMenuItem separatorItem]];
    if (hasExact) [self addLabelToMenu:submenu title:@"★ = pixel-exact (crispest)"];
    [self addLabelToMenu:submenu title:kLargerSizesHint];
    [self addLabelToMenu:submenu title:@"Comes back after a restart or reconnect"];

    return submenu;
}

- (void)addTransparencySectionToMenu:(NSMenu *)menu {
    WindowTransparency *wt = [WindowTransparency shared];

    if (![wt backendAvailable]) {
        [self addInfoRow:menu title:@"Backend not loaded" image:ddSymbol(@"exclamationmark.triangle")];
        return;
    }

    NSArray<DDAppWindows *> *apps = [wt appsWithWindows];
    if (apps.count == 0) {
        [self addInfoRow:menu title:@"No windows" image:ddSymbol(@"macwindow")];
    }
    if (wt.applyFailing) {
        [self addInfoRow:menu title:@"Changes aren't applying" image:ddSymbol(@"exclamationmark.triangle")];
    }
    for (DDAppWindows *app in apps) {
        int pct = (int)lroundf(app.alpha * 100.0f);
        NSImage *appIcon = [[NSRunningApplication
            runningApplicationWithProcessIdentifier:app.pid] icon];
        NSButton *pip = [self rowToggleWithSymbol:@"pip.enter" onSymbol:@"pip.exit"
            state:[[WindowPiP shared] isActiveForApp:app.pid] tag:app.pid
           action:@selector(togglePiPApp:) tooltip:@"Picture in Picture"];
        NSButton *pin = [self rowToggleWithSymbol:@"pin" onSymbol:@"pin.fill"
            state:app.pinned tag:app.pid
           action:@selector(togglePinApp:) tooltip:@"Keep on Top"];
        {
            NSMenuItem *row = [self sliderRowWithLabel:app.name icon:appIcon
                                       percent:pct minPct:20
                                        maxPct:100 continuous:YES tag:app.pid
                                        action:@selector(opacitySliderChanged:)
                                   accessories:@[pip, pin]];
            [self makeIconOfRow:row clickable:@selector(resetSliderFromIcon:) tag:1 tooltip:@"Click to reset to 100%"];
            [menu addItem:row];
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *all = [self sliderRowWithLabel:@"All Apps" icon:ddSymbol(@"square.on.square")
                                       percent:(int)lroundf(wt.alphaForAllApps * 100.0f) minPct:20
                                        maxPct:100 continuous:YES tag:0
                                        action:@selector(opacitySliderChanged:)
                                   accessories:@[
        [self prefToggle:kFrostedBlur symbol:@"drop" onSymbol:@"drop.fill" tooltip:@"Frosted glass blur"],
        [self prefToggle:kTransparencyEnabled symbol:@"eye.slash" onSymbol:@"eye" tooltip:@"Transparency on or off"]]];
    [self makeIconOfRow:all clickable:@selector(resetAllTransparency:) tag:0 tooltip:@"Click to reset every app to 100%"];
    [menu addItem:all];
}

// A small on/off button for a setting, for a row's button slots.
- (NSButton *)prefToggle:(NSString *)key symbol:(NSString *)off onSymbol:(NSString *)on tooltip:(NSString *)tooltip {
    NSButton *button = [self rowToggleWithSymbol:off onSymbol:on state:[self pref:key] tag:0
                                          action:@selector(prefButtonToggled:) tooltip:tooltip];
    button.identifier = key;
    return button;
}

- (void)prefButtonToggled:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [NSUserDefaults.standardUserDefaults setBool:on forKey:sender.identifier];
    ddSetToggle(sender, on);
    if ([sender.superview isKindOfClass:[DDActionRowView class]]) {
        DDActionRowView *row = (DDActionRowView *)sender.superview;
        row.hovered = row.hovered;
    }
    [self prefChanged:sender.identifier];
}

- (NSButton *)rowToggleWithSymbol:(NSString *)offSymbol
                         onSymbol:(NSString *)onSymbol
                            state:(BOOL)on
                              tag:(NSInteger)tag
                           action:(SEL)action
                          tooltip:(NSString *)tooltip {
    NSButton *b = [NSButton buttonWithImage:[NSImage new] target:self action:action];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    [b setButtonType:NSButtonTypePushOnPushOff];
    objc_setAssociatedObject(b, kDDOffSymKey, offSymbol, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(b, kDDOnSymKey, onSymbol, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    b.tag = tag;
    b.toolTip = tooltip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    ddSetToggle(b, on);
    return b;
}

- (NSMenuItem *)sliderRowWithLabel:(NSString *)label
                              icon:(NSImage *)icon
                           percent:(int)pct
                            minPct:(int)minPct
                            maxPct:(int)maxPct
                        continuous:(BOOL)continuous
                               tag:(NSInteger)tag
                            action:(SEL)action
                       accessories:(NSArray<NSButton *> *)accessories {
    return [self sliderRowWithLabel:label icon:icon percent:pct minPct:minPct maxPct:maxPct
                         continuous:continuous tag:tag action:action accessories:accessories submenu:nil];
}

- (NSMenuItem *)sliderRowWithLabel:(NSString *)label
                              icon:(NSImage *)icon
                           percent:(int)pct
                            minPct:(int)minPct
                            maxPct:(int)maxPct
                        continuous:(BOOL)continuous
                               tag:(NSInteger)tag
                            action:(SEL)action
                       accessories:(NSArray<NSButton *> *)accessories
                           submenu:(NSMenu *)submenu {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSliderRowWidth, 24)];

    NSImageView *iconView = nil;
    if (icon) {
        iconView = [NSImageView imageViewWithImage:icon];
        iconView.imageScaling = NSImageScaleProportionallyDown;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:iconView];
    }

    NSTextField *name = [NSTextField labelWithString:label];
    name.font = [NSFont menuFontOfSize:13];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [name setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSSlider *slider = [NSSlider sliderWithValue:pct / 100.0
                                        minValue:minPct / 100.0
                                        maxValue:maxPct / 100.0
                                          target:self
                                          action:action];
    slider.continuous = continuous;
    slider.controlSize = NSControlSizeSmall;
    slider.tag = tag;
    slider.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *value = [NSTextField labelWithString:[NSString stringWithFormat:@"%d%%", pct]];
    value.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    value.textColor = [NSColor secondaryLabelColor];
    value.alignment = NSTextAlignmentRight;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [value setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    [row addSubview:name];
    [row addSubview:slider];
    [row addSubview:value];
    objc_setAssociatedObject(slider, kDDPctLabelKey, value, OBJC_ASSOCIATION_ASSIGN);

    for (NSButton *btn in accessories) [row addSubview:btn];

    NSMutableArray<NSLayoutConstraint *> *constraints = [@[
        [row.heightAnchor constraintEqualToConstant:24],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.widthAnchor constraintEqualToConstant:74],
        [slider.leadingAnchor constraintEqualToAnchor:name.trailingAnchor constant:8],
        [slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:8],
        [value.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:30],
    ] mutableCopy];

    // The row's contents run to the right edge: buttons sit against it (or
    // against the submenu arrow), and the slider takes whatever is left.
    CGFloat edge = submenu ? -(kSubmenuArrowInset + 14) : -kRowEdgeInset;
    NSLayoutXAxisAnchor *right = row.trailingAnchor;
    for (NSInteger i = (NSInteger)accessories.count - 1; i >= 0; i--) {
        NSButton *btn = accessories[i];
        [constraints addObjectsFromArray:@[
            [btn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [btn.widthAnchor constraintEqualToConstant:kAccessoryWidth],
            [btn.trailingAnchor constraintEqualToAnchor:right constant:(right == row.trailingAnchor ? edge : -4)],
        ]];
        right = btn.leadingAnchor;
    }
    [constraints addObject:
        [value.trailingAnchor constraintEqualToAnchor:right constant:(right == row.trailingAnchor ? edge : -7)]];

    if (iconView) {
        [constraints addObjectsFromArray:@[
            [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
            [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:16],
            [iconView.heightAnchor constraintEqualToConstant:16],
            [name.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:8],
        ]];
    } else {
        [constraints addObject:
            [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14]];
    }
    if (submenu) {
        NSImageView *chevron = [NSImageView imageViewWithImage:ddSubmenuArrow()];
        chevron.contentTintColor = [NSColor labelColor];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:chevron];
        [constraints addObjectsFromArray:@[
            [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kSubmenuArrowInset],
            [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    row.autoresizingMask = NSViewWidthSizable;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:@""];
    item.tag = kSliderItemTag;
    item.view = row;
    item.submenu = submenu;
    return item;
}

- (NSMenu *)sharpenOptionsMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    [menu addItem:[self checkItemWithTitle:@"Sharpen Enabled" key:kSharpenEnabled symbol:@"diamond"]];
    [menu addItem:[self checkItemWithTitle:@"Keep Shader Mode on Battery" key:kSharpenShaderOnBattery symbol:@"battery.75percent"]];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Edge Width"]];
    NSArray<NSString *> *radii = @[@"Fine", @"Medium", @"Wide"];
    for (NSUInteger i = 0; i < radii.count; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:radii[i]
            action:@selector(setSharpenRadius:) keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)i + 1;
        item.state = ([Sharpen shared].radius == item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    return menu;
}

- (NSMenu *)textSmoothingLevelsMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    NSArray<NSString *> *levels = @[@"Light", @"Medium", @"Strong"];
    NSInteger currentLevel = [NSUserDefaults.standardUserDefaults integerForKey:kTextSmoothingLevel];
    for (NSUInteger i = 0; i < levels.count; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:levels[i]
            action:@selector(setTextSmoothingLevel:) keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)i + 1;
        item.state = (currentLevel == item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    return menu;
}

- (void)sizeSliderRowsInMenu:(NSMenu *)menu {
    CGFloat w = menu.size.width;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag != kSliderItemTag || !item.view) continue;
        NSRect f = item.view.frame;
        if (f.size.width == w) continue;
        f.size.width = w;
        item.view.frame = f;
        [item.view layoutSubtreeIfNeeded];
    }
}

- (void)syncSliderLabel:(NSSlider *)slider {
    NSTextField *value = objc_getAssociatedObject(slider, kDDPctLabelKey);
    value.stringValue = [NSString stringWithFormat:@"%d%%", (int)lround(slider.doubleValue * 100)];
}

- (void)opacitySliderChanged:(NSSlider *)sender {
    [self syncSliderLabel:sender];
    pid_t pid = (pid_t)sender.tag;
    NSError *error = nil;
    if (pid == 0) [[WindowTransparency shared] setAlphaForAllWindows:sender.floatValue error:&error];
    else          [[WindowTransparency shared] setAlpha:sender.floatValue forApp:pid error:&error];
    if (error) NSLog(@"DisplayDeck: transparency failed: %@", error);
}

- (void)toggleAutoBrightness:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [[Brightness shared] setAutoBrightness:on forDisplay:(CGDirectDisplayID)sender.tag];
    ddSetToggle(sender, on);
}

- (void)setSharpenRadius:(NSMenuItem *)sender {
    [Sharpen shared].radius = sender.tag;
}

- (void)toggleSharpenAuto:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [Sharpen shared].automatic = on;
    ddSetToggle(sender, on);
    [self rebuildMenu];
}

- (void)toggleSharpenShader:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [Sharpen shared].usesShader = on;
    ddSetToggle(sender, on);
}

- (void)contrastSliderChanged:(NSSlider *)sender {
    [self syncSliderLabel:sender];
    [[ColorTemperature shared] setContrast:sender.floatValue forDisplay:(CGDirectDisplayID)sender.tag];
}

- (void)setTextSmoothingLevel:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:kTextSmoothingLevel];
    if ([self currentFontSmoothing] != 0) [self applyFontSmoothing:sender.tag];
}

- (void)sharpenSliderChanged:(NSSlider *)sender {
    [self syncSliderLabel:sender];
    [[Sharpen shared] setAmount:sender.floatValue forDisplay:(CGDirectDisplayID)sender.tag];
}

- (void)warmthSliderChanged:(NSSlider *)sender {
    [self syncSliderLabel:sender];
    [[ColorTemperature shared] setWarmth:sender.floatValue
                              forDisplay:(CGDirectDisplayID)sender.tag];
}

- (void)toggleAutoWarmth:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [ColorTemperature shared].autoEnabled = on;
    ddSetToggle(sender, on);
}

- (void)brightnessSliderChanged:(NSSlider *)sender {
    double val = sender.doubleValue;
    if (fabs(val - 1.0) < 0.04) {
        val = 1.0;
        sender.doubleValue = 1.0;
    }
    [self syncSliderLabel:sender];
    CGDirectDisplayID did = (CGDirectDisplayID)sender.tag;
    NSError *error = nil;
    if (val <= 1.0) {
        [[BrightnessBooster shared] setBoost:1.0f forDisplay:did];
        [[Brightness shared] setBrightnessPercent:(uint8_t)lround(val * 100)
                                       forDisplay:did error:&error];
    } else {
        [[Brightness shared] setBrightnessPercent:100 forDisplay:did error:&error];
        [[BrightnessBooster shared] setBoost:(float)val forDisplay:did];
    }
    if (error) NSLog(@"DisplayDeck: brightness failed: %@", error);
}

- (void)togglePinApp:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    NSError *error = nil;
    [[WindowTransparency shared] setPinned:on forApp:(pid_t)sender.tag error:&error];
    if (error) NSLog(@"DisplayDeck: pin failed: %@", error);
    ddSetToggle(sender, on);
}

- (void)togglePiPApp:(NSButton *)sender {
    WindowPiP *pip = [WindowPiP shared];
    if (!DDAXTrusted()) {
        DDAXRequestTrust();
        ddSetToggle(sender, NO);
        return;
    }
    BOOL active = [pip toggleForApp:(pid_t)sender.tag];
    ddSetToggle(sender, active);
}

- (void)resetAllTransparency:(NSMenuItem *)sender {
    (void)sender;
    NSError *error = nil;
    if (![[WindowTransparency shared] resetAllWindows:&error]) {
        NSLog(@"DisplayDeck: reset transparency failed: %@", error);
    }
    [self rebuildMenu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.mainMenu) {
        [[RemoteAccess shared] refreshPeers];
        [self populateMainMenu:menu];
        return;
    }

    [menu removeAllItems];

    [menu addItem:[self checkItemWithTitle:@"Show Notifications" key:kShowNotifications symbol:@"bell"]];
    [menu addItem:[self checkItemWithTitle:@"Confirm Before Disabling a Display" key:kConfirmDisable symbol:@"exclamationmark.shield"]];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
        action:@selector(toggleLoginItem:) keyEquivalent:@""];
    login.target = self;
    login.image = ddSymbol(@"arrow.up.forward.app");
    login.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Help & Support"]];
    [menu addItem:[self linkItem:@"Support DisplayDeck…" symbol:@"heart"
        url:@"https://donate.stripe.com/3cI6oI7Gh1PG0eV8MJ5kk00"]];
    [menu addItem:[self linkItem:@"Report a Bug…" symbol:@"ladybug"
        url:@"https://github.com/pyxis3-ai/displaydeck/issues/new?labels=bug&title=Bug%3A+"]];
    [menu addItem:[self linkItem:@"Request a Feature…" symbol:@"lightbulb"
        url:@"https://github.com/pyxis3-ai/displaydeck/issues/new?labels=enhancement&title=Feature%3A+"]];
    ddShowMenuImages(menu);
}

- (NSMenuItem *)linkItem:(NSString *)title symbol:(NSString *)symbol url:(NSString *)url {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
        action:@selector(openLink:) keyEquivalent:@""];
    item.target = self;
    item.image = ddSymbol(symbol);
    item.representedObject = url;
    return item;
}

- (void)openLink:(NSMenuItem *)sender {
    NSString *url = sender.representedObject;
    if (url) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (NSMenuItem *)checkItemWithTitle:(NSString *)title key:(NSString *)key symbol:(NSString *)symbol {
    NSMenuItem *item = [self checkItemWithTitle:title key:key];
    item.image = ddSymbol(symbol);
    return item;
}

// Lets a slider row's icon double as a button: one click resets the slider
// (tag 0 = to its lowest value, 1 = to its highest) or runs `action`.
- (void)makeIconOfRow:(NSMenuItem *)item clickable:(SEL)action tag:(NSInteger)tag tooltip:(NSString *)tooltip {
    for (NSView *view in item.view.subviews) {
        if (![view isKindOfClass:[NSImageView class]]) continue;
        NSButton *button = [NSButton buttonWithTitle:@"" target:self action:action];
        button.transparent = YES;
        button.tag = tag;
        button.toolTip = tooltip;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [item.view addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
            [button.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
            [button.widthAnchor constraintEqualToConstant:22],
            [button.heightAnchor constraintEqualToConstant:22],
        ]];
        return;
    }
}

- (void)resetSliderFromIcon:(NSButton *)sender {
    for (NSView *view in sender.superview.subviews) {
        if (![view isKindOfClass:[NSSlider class]]) continue;
        NSSlider *slider = (NSSlider *)view;
        slider.doubleValue = sender.tag ? slider.maxValue : slider.minValue;
        [slider sendAction:slider.action to:slider.target];
    }
}

- (void)toggleSharpenFromIcon:(NSButton *)sender {
    (void)sender;
    [self flipPref:kSharpenEnabled];
    [self prefChanged:kSharpenEnabled];
    [self rebuildMenu];
}

- (void)logOutToApply:(id)sender {
    (void)sender;
    DDRequestLogout();
}

- (NSMenuItem *)checkItemWithTitle:(NSString *)title key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:@selector(toggleCheckSetting:)
                                          keyEquivalent:@""];
    item.target = self;
    item.representedObject = key;
    item.state = [self pref:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (NSInteger)currentFontSmoothing {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("AppleFontSmoothing"),
        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    NSInteger n = -1;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)v, kCFNumberNSIntegerType, &n);
        CFRelease(v);
    }
    return n;
}

- (void)applyFontSmoothing:(NSInteger)level {
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberNSIntegerType, &level);
    CFPreferencesSetValue(CFSTR("AppleFontSmoothing"), num, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    CFRelease(num);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

- (void)fontSmoothingToggled:(NSSwitch *)sw {
    NSInteger level = MAX(1, [NSUserDefaults.standardUserDefaults integerForKey:kTextSmoothingLevel]);
    [self applyFontSmoothing:(sw.state == NSControlStateValueOn) ? level : 0];
}

- (NSArray<DDDisplayMode *> *)curatedModes:(NSArray<DDDisplayMode *> *)modes
                           includeNonHiDPI:(BOOL)includeNonHiDPI {
    NSMutableArray<DDDisplayMode *> *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *index = [NSMutableDictionary dictionary];
    for (DDDisplayMode *m in modes) {
        if (!m.isCurrent) {
            if (!includeNonHiDPI && !m.isHiDPI) continue;
            if (m.logicalWidth < 1024) continue;
        }
        NSString *key = [NSString stringWithFormat:@"%zux%zu_%d",
                         m.logicalWidth, m.logicalHeight, (int)m.isHiDPI];
        NSNumber *at = index[key];
        if (!at) {
            index[key] = @(out.count);
            [out addObject:m];
            continue;
        }
        DDDisplayMode *existing = out[at.unsignedIntegerValue];
        if (existing.isCurrent) continue;
        if (m.isCurrent ||
            m.refreshRate > existing.refreshRate ||
            (m.refreshRate == existing.refreshRate && m.pixelWidth > existing.pixelWidth)) {
            out[at.unsignedIntegerValue] = m;
        }
    }
    return out;
}

- (NSMenu *)buildModesSubmenuForDisplay:(CGDirectDisplayID)displayID
                                  modes:(NSArray<DDDisplayMode *> *)modes {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *font = [NSFont menuFontOfSize:13];
    NSFont *bold = [NSFont boldSystemFontOfSize:12];

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    header.attributedTitle = ddColumns(@[@"Looks Like", @"Type", @"Rate"], @[@(kModeTabType), @(kModeTabRate)],
                                       bold, [NSColor secondaryLabelColor]);
    header.enabled = NO;
    [submenu addItem:header];
    [submenu addItem:[NSMenuItem separatorItem]];

    CGSize native = [self.displayManager nativePanelPixelsForDisplay:displayID];
    DDDisplayMode *nativeMode = nil;
    for (DDDisplayMode *mode in modes) {
        if (mode.pixelWidth != (size_t)native.width || mode.pixelHeight != (size_t)native.height) continue;
        if (!nativeMode || (mode.isHiDPI && !nativeMode.isHiDPI)) nativeMode = mode;
    }
    for (DDDisplayMode *mode in modes) {
        NSString *rate = ddRateString(mode.refreshRate, @"-");
        if (mode == nativeMode) rate = [rate stringByAppendingString:@"  ★"];
        NSString *type = mode.isHiDPI ? @"HiDPI" : @"Standard";
        NSString *logical = ddLogicalString(mode.logicalWidth, mode.logicalHeight);

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@""
                   action:mode.isCurrent ? nil : @selector(switchMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !mode.isCurrent;
        item.representedObject = @{ @"mode": mode, @"displayID": @(displayID) };
        item.attributedTitle = ddColumns(@[logical, type, rate], @[@(kModeTabType), @(kModeTabRate)],
                                         mode.isCurrent ? bold : font, nil);
        if (mode.isCurrent) item.state = NSControlStateValueOn;
        [submenu addItem:item];
    }

    // Sizes the panel does not offer itself, reached by forcing HiDPI through a
    // virtual display. Same list, so there is one place to pick a size.
    NSArray<DDDisplayMode *> *forceOptions = NSClassFromString(@"CGVirtualDisplay")
        ? [self.displayManager forceHiDPIOptionsForDisplay:displayID] : @[];
    if (forceOptions.count > 0) {
        [submenu addItem:[NSMenuItem sectionHeaderWithTitle:@"Force HiDPI"]];
        for (DDDisplayMode *mode in forceOptions) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@""
                action:@selector(forceHiDPIAtMode:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = @{ @"displayID": @(displayID), @"mode": mode };
            item.attributedTitle = ddColumns(@[ddLogicalString(mode.logicalWidth, mode.logicalHeight), @"Forced",
                                               ddRateString(mode.refreshRate, @"-")],
                                             @[@(kModeTabType), @(kModeTabRate)], font, nil);
            [submenu addItem:item];
        }
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    [self addLabelToMenu:submenu title:@"★ = panel-native (crispest)"];
    [self addLabelToMenu:submenu title:kLargerSizesHint];
    if (forceOptions.count > 0)
        [self addLabelToMenu:submenu title:@"Forced sizes come back after a restart"];
    [submenu addItem:[NSMenuItem separatorItem]];
    [submenu addItem:[self checkItemWithTitle:@"Show Non-HiDPI Resolutions" key:kShowResolutions symbol:@"eye"]];
    BOOL installed = [[HiDPIInjector shared] isInstalledForDisplay:displayID];
    [submenu addItem:[self actionItem:(installed ? @"Remove Extra HiDPI Resolutions\u2026"
                                                 : @"Install Extra HiDPI Resolutions\u2026")
                               action:(installed ? @selector(uninstallCrispHiDPI:) : @selector(installCrispHiDPI:))
                            displayID:displayID symbol:@"sparkles"]];

    return submenu;
}

- (void)addLabelToMenu:(NSMenu *)menu title:(NSString *)title {
    [self addInfoRow:menu title:title image:nil];
}

- (void)addInfoRow:(NSMenu *)menu title:(NSString *)title image:(NSImage *)image {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    item.image = image;
    [menu addItem:item];
}

- (BOOL)pref:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

- (void)flipPref:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:![defaults boolForKey:key] forKey:key];
}

- (void)switchMode:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    DDDisplayMode *mode = info[@"mode"];
    CGDirectDisplayID did = [info[@"displayID"] unsignedIntValue];

    NSError *error = nil;
    if ([self.displayManager setMode:mode forDisplay:did error:&error]) {
        NSString *label = mode.isHiDPI ? @"HiDPI" : @"Standard";
        NSMutableString *body = [NSMutableString stringWithFormat:
            @"%@ %@", ddLogicalString(mode.logicalWidth, mode.logicalHeight), label];
        if (mode.refreshRate > 0) {
            [body appendFormat:@" %.0fHz", mode.refreshRate];
        }
        [self postNotification:@"Resolution Changed" body:body];
    } else {
        NSLog(@"DisplayDeck: Failed to set mode: %@", error);
        [self postNotification:@"Resolution Change Failed"
                          body:error.localizedDescription];
    }
}

- (void)disableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSUInteger activeCount = 0;
    for (DDDisplayInfo *d in [self.displayManager allDisplays]) {
        if (d.isActive) activeCount++;
    }
    if (activeCount <= 1) {
        [self postNotification:@"Cannot Disable"
                          body:@"Refusing to disable the only active display."];
        return;
    }

    BOOL strandRisk = CGDisplayIsBuiltin(did) && [self.displayManager hasExternalDisplay];
    if (strandRisk || [self pref:kConfirmDisable]) {
        NSString *info = strandRisk
            ? @"While an external display is connected, macOS can only re-enable the built-in after you log out and back in - there is no in-app way to undo it."
            : @"You can re-enable it from this menu.";
        if (![self confirmDestructive:[NSString stringWithFormat:@"Disable “%@”?", name]
                                 info:info
                           actionName:@"Disable"]) {
            return;
        }
    }

    NSError *error = nil;
    if ([self.displayManager disableDisplay:did error:&error]) {
        [self postNotification:@"Display Disabled"
                          body:[NSString stringWithFormat:@"%@ has been disabled.", name]];
    } else {
        NSLog(@"DisplayDeck: Failed to disable 0x%X: %@", did, error);
        [self postNotification:@"Disable Failed"
                          body:error.localizedDescription];
    }
}

- (void)enableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];
    NSError *error = nil;
    if ([self.displayManager enableDisplay:did error:&error]) {
        [self postNotification:@"Display Enabled"
                          body:[NSString stringWithFormat:@"%@ has been enabled.", name]];
    } else {
        NSLog(@"DisplayDeck: Failed to enable 0x%X: %@", did, error);
        [NSApp activate];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Couldn’t re-enable “%@”", name];
        alert.informativeText = @"macOS can only re-enable a display that was turned off while another display is connected by restarting your login session. Click “Log Out…” to do that now and restore it. You’ll be prompted to save any open work first.";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"Log Out…"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            DDRequestLogout();
        }
    }
}

- (void)forceHiDPIAtMode:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    [self forceHiDPIOnDisplay:[info[@"displayID"] unsignedIntValue] mode:info[@"mode"] announce:YES];
}

// The forced size is remembered per monitor model and put back at launch and
// when that monitor reconnects, until the user stops it.
- (void)restoreForcedHiDPIIfNeeded {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kForcedHiDPI];
    if (!saved) return;
    DDDisplayInfo *match = nil;
    for (DDDisplayInfo *d in [self.displayManager allDisplays]) {
        if ([self.displayManager isHiDPIForcedForDisplay:d.displayID]) return;
        if (d.isActive && CGDisplayVendorNumber(d.displayID) == [saved[@"vendor"] unsignedIntValue] &&
            CGDisplayModelNumber(d.displayID) == [saved[@"model"] unsignedIntValue]) match = d;
    }
    if (!match) { self.forceRestoreTried = NO; return; }
    if (self.forceRestoreTried) return;
    self.forceRestoreTried = YES;

    size_t width = [saved[@"width"] unsignedLongValue], height = [saved[@"height"] unsignedLongValue];
    for (DDDisplayMode *option in [self.displayManager forceHiDPIOptionsForDisplay:match.displayID]) {
        if (option.logicalWidth != width || option.logicalHeight != height) continue;
        [self forceHiDPIOnDisplay:match.displayID mode:option announce:NO];
        return;
    }
}

- (void)forceHiDPIOnDisplay:(CGDirectDisplayID)did mode:(DDDisplayMode *)mode announce:(BOOL)announce {
    NSString *name = [self.displayManager nameForDisplayID:did];
    // Changing size while forced: let go of the current one first.
    if ([self.displayManager isHiDPIForcedForDisplay:did])
        [self.displayManager stopForcedHiDPIForDisplay:did error:NULL];
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"vendor": @(CGDisplayVendorNumber(did)), @"model": @(CGDisplayModelNumber(did)),
        @"width": @(mode.logicalWidth), @"height": @(mode.logicalHeight) } forKey:kForcedHiDPI];
    self.forceRestoreTried = YES;

    __weak __typeof(self) weakSelf = self;
    [self.displayManager forceHiDPIForDisplay:did atMode:mode
                                   completion:^(BOOL success, NSError *error) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            NSMutableString *body = [NSMutableString stringWithFormat:
                @"HiDPI enabled for %@ at %@.",
                name, ddLogicalString(mode.logicalWidth, mode.logicalHeight)];
            if (announce) [strongSelf postNotification:@"HiDPI Forced" body:body];
            [strongSelf rebuildMenu];
        } else {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kForcedHiDPI];
            NSLog(@"DisplayDeck: Failed to force HiDPI for 0x%X: %@", did, error);
            [strongSelf postNotification:@"Force HiDPI Failed"
                                    body:error.localizedDescription];
        }
    }];
}

- (void)stopForcedHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSError *error = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kForcedHiDPI];
    if ([self.displayManager stopForcedHiDPIForDisplay:did error:&error]) {
        [self postNotification:@"HiDPI Stopped"
                          body:[NSString stringWithFormat:
                                @"Restored native rendering for %@.", name]];
        [self rebuildMenu];
    } else {
        NSLog(@"DisplayDeck: Failed to stop forced HiDPI for 0x%X: %@", did, error);
    }
}

- (void)installCrispHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSArray<NSValue *> *presets = [[HiDPIInjector shared] defaultResolutionsForDisplay:did];

    NSMutableString *list = [NSMutableString string];
    for (NSValue *v in presets) {
        NSSize s = v.sizeValue;
        [list appendFormat:@"  \u2022 %d \u00D7 %d\n", (int)s.width, (int)s.height];
    }

    [NSApp activate];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:
        @"Install extra HiDPI resolutions on \"%@\"?", name];
    alert.informativeText = [NSString stringWithFormat:
        @"Writes /Library/Displays/…/DisplayVendorID-%x/DisplayProductID-%x "
        @"with these logical resolutions as native HiDPI modes:\n\n%@\n"
        @"Requires your admin password and a reboot to activate. You can undo "
        @"via the same menu afterwards.",
        CGDisplayVendorNumber(did), CGDisplayModelNumber(did), list];
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    __weak __typeof(self) weakSelf = self;
    [[HiDPIInjector shared] installForDisplay:did resolutions:presets
                                   completion:^(BOOL ok, NSError *err) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ok) {
            NSLog(@"DisplayDeck: HiDPI install failed: %@", err);
            if (err.code != -128) {
                [strongSelf postNotification:@"Install Failed"
                                        body:err.localizedDescription];
            }
            return;
        }
        [strongSelf rebuildMenu];
        [strongSelf offerRebootWithMessage:
            [NSString stringWithFormat:
             @"Extra HiDPI resolutions installed for \"%@\".", name]];
    }];
}

- (void)uninstallCrispHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    if (![self confirmDestructive:[NSString stringWithFormat:
                                   @"Remove extra HiDPI resolutions for \"%@\"?", name]
                             info:@"Requires admin password. A reboot is needed "
                                  @"to fully revert to macOS defaults."
                       actionName:@"Remove"]) {
        return;
    }

    __weak __typeof(self) weakSelf = self;
    [[HiDPIInjector shared] uninstallForDisplay:did
                                     completion:^(BOOL ok, NSError *err) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ok) {
            NSLog(@"DisplayDeck: HiDPI uninstall failed: %@", err);
            if (err.code != -128) {
                [strongSelf postNotification:@"Remove Failed"
                                        body:err.localizedDescription];
            }
            return;
        }
        [strongSelf rebuildMenu];
        [strongSelf offerRebootWithMessage:
            [NSString stringWithFormat:
             @"Extra HiDPI resolutions removed for \"%@\".", name]];
    }];
}

- (void)offerRebootWithMessage:(NSString *)message {
    [NSApp activate];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = @"The change applies only after a reboot. Would you "
                             @"like to restart now?";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:
        @"tell application \"System Events\" to restart"];
    NSDictionary *asErr = nil;
    [as executeAndReturnError:&asErr];
    if (asErr) NSLog(@"DisplayDeck: restart script error: %@", asErr);
}

- (void)enableLoginItemOnFirstRun {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kDidSetupLogin]) return;
    [defaults setBool:YES forKey:kDidSetupLogin];

    SMAppService *service = [SMAppService mainAppService];
    if (service.status != SMAppServiceStatusEnabled) {
        NSError *error = nil;
        if (![service registerAndReturnError:&error]) {
            NSLog(@"DisplayDeck: default login-item registration failed: %@", error);
        }
    }
}

- (void)toggleLoginItem:(NSMenuItem *)sender {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;

    if (service.status == SMAppServiceStatusEnabled) {
        if (![service unregisterAndReturnError:&error]) {
            NSLog(@"DisplayDeck: Failed to unregister login item: %@", error);
        }
    } else {
        if (![service registerAndReturnError:&error]) {
            NSLog(@"DisplayDeck: Failed to register login item: %@", error);
            if (service.status == SMAppServiceStatusRequiresApproval) {
                [SMAppService openSystemSettingsLoginItems];
            }
        }
    }

    sender.state = (service.status == SMAppServiceStatusEnabled)
                   ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleCheckSetting:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    [self flipPref:key];
    sender.state = [self pref:key] ? NSControlStateValueOn : NSControlStateValueOff;
    [self prefChanged:key];
}

- (void)prefChanged:(NSString *)key {
    if ([key isEqualToString:kShowResolutions]) [self rebuildMenu];
    if ([key isEqualToString:kAutoManage] && [self pref:kAutoManage]) {
        [self performAutoDisableIfNeeded];
    }
    if ([key isEqualToString:kSharpenShader]) [Sharpen shared].usesShader = [self pref:kSharpenShader];
    else if ([key hasPrefix:@"Sharpen"]) [[Sharpen shared] reapply];
    if ([key isEqualToString:kDisableDithering]) [Dithering setDisabled:[self pref:kDisableDithering]];
    if ([key isEqualToString:kTransparencyEnabled])
        [WindowTransparency shared].enabled = [self pref:kTransparencyEnabled];
    if ([key isEqualToString:kFrostedBlur]) {
        [WindowTransparency shared].frostedBlur = [self pref:kFrostedBlur];
        [[WindowTransparency shared] reapplyBlurForAllWindows];
    }
    if ([key isEqualToString:kSnapDrag]) {
        [[WindowManager shared] setDragSnapEnabled:[self pref:kSnapDrag]];
    }
    if ([key isEqualToString:kSnapShortcuts]) {
        [[WindowManager shared] setHotkeysEnabled:[self pref:kSnapShortcuts]];
    }
}

- (BOOL)confirmDestructive:(NSString *)message
                      info:(NSString *)info
                actionName:(NSString *)actionName {
    [NSApp activate];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:actionName];
    [alert addButtonWithTitle:@"Cancel"];

    return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)performAutoDisableIfNeeded {
    if (![self pref:kAutoManage]) return;

    DDDisplayInfo *builtIn = [self.displayManager builtInDisplay];
    if (!builtIn || !builtIn.isActive) return;
    if (![self.displayManager hasExternalDisplay]) return;

    NSError *error = nil;
    if ([self.displayManager disableDisplay:builtIn.displayID error:&error]) {
        [self postNotification:@"Built-in Display Disabled"
                          body:@"External monitor detected."
                    identifier:kAutoManageNotifID];
    } else {
        NSLog(@"DisplayDeck: Auto-disable failed: %@", error);
    }
}

- (void)performAutoReenableIfNeeded {
    if (![self pref:kAutoManage]) return;

    DDDisplayInfo *builtIn = [self.displayManager builtInDisplay];
    if (!builtIn) return;
    if (builtIn.isActive) return;
    if ([self.displayManager hasExternalDisplay]) return;

    NSError *error = nil;
    if ([self.displayManager enableDisplay:builtIn.displayID error:&error]) {
        [self postNotification:@"Built-in Display Re-enabled"
                          body:@"No external monitor detected."
                    identifier:kAutoManageNotifID];
    } else {
        NSLog(@"DisplayDeck: Auto-reenable failed: %@", error);
    }
}

@end
