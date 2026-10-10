#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface ColorTemperature : NSObject

+ (instancetype)shared;

@property (nonatomic) BOOL autoEnabled;

- (float)warmthForDisplay:(CGDirectDisplayID)displayID;
- (void)setWarmth:(float)warmth forDisplay:(CGDirectDisplayID)displayID;
// 0 leaves tones alone; higher values bend them into an S-curve so text and
// edges stand out more. Applied in the display's gamma table: no lag, no capture.
- (float)contrastForDisplay:(CGDirectDisplayID)displayID;
- (void)setContrast:(float)contrast forDisplay:(CGDirectDisplayID)displayID;
- (void)reapply;
- (void)restoreAll;

@end

NS_ASSUME_NONNULL_END
