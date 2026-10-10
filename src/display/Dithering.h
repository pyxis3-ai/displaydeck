#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Apple Silicon panels flicker individual pixels between neighbouring colours
// (temporal dithering) to fake extra colour depth. Turning it off keeps every
// pixel still, at the cost of slightly coarser gradients.
@interface Dithering : NSObject

+ (BOOL)isAvailable;
+ (void)setDisabled:(BOOL)disabled;

@end

NS_ASSUME_NONNULL_END
