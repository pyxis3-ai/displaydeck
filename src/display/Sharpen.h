#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Sharpen : NSObject

+ (instancetype)shared;

// Capture the screen and sharpen it in a shader instead of the no-capture
// compositor path. Falls back to the compositor without Screen Recording access.
@property (nonatomic) BOOL usesShader;
@property (nonatomic, readonly) BOOL shaderActive;

- (float)amountForDisplay:(CGDirectDisplayID)displayID;
- (void)setAmount:(float)amount forDisplay:(CGDirectDisplayID)displayID;
- (void)reapply;

@end

NS_ASSUME_NONNULL_END
