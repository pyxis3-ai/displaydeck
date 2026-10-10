#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Sharpen : NSObject

+ (instancetype)shared;

- (float)amountForDisplay:(CGDirectDisplayID)displayID;
- (void)setAmount:(float)amount forDisplay:(CGDirectDisplayID)displayID;
- (void)reapply;

@end

NS_ASSUME_NONNULL_END
