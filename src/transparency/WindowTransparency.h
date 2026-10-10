#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDWindow : NSObject
@property (nonatomic) uint32_t windowID;
@property (nonatomic) float alpha;
@end

@interface DDAppWindows : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) float alpha;
@property (nonatomic, strong) NSArray<DDWindow *> *windows;
@property (nonatomic) BOOL pinned;
@end

@interface WindowTransparency : NSObject

+ (instancetype)shared;

@property (nonatomic) BOOL frostedBlur;
// Off shows every window at 100% while keeping the stored values.
@property (nonatomic) BOOL enabled;
@property (nonatomic, readonly) BOOL applyFailing;
@property (nonatomic, readonly) float alphaForAllApps;

- (BOOL)backendAvailable;
- (void)ensureBackendLoaded;

- (NSArray<DDAppWindows *> *)appsWithWindows;

- (BOOL)setAlpha:(float)alpha forApp:(pid_t)pid error:(NSError **)error;
- (BOOL)setAlphaForAllWindows:(float)alpha error:(NSError **)error;
- (BOOL)resetAllWindows:(NSError **)error;
- (void)startLiveUpdates;
- (void)restoreWindowsForQuit;
- (void)reapplyBlurForAllWindows;

- (BOOL)setPinned:(BOOL)pinned forApp:(pid_t)pid error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
