#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Sharpen : NSObject

+ (instancetype)shared;

// Picks the strength from how far the current resolution is from the
// panel-native one: off at pixel-exact Retina, strongest at "More Space".
@property (nonatomic) BOOL automatic;

// Width of the sharpening in panel pixels (1-3). Wider gives a bolder edge.
@property (nonatomic) NSInteger radius;

// Capture the screen and sharpen it in a shader instead of the no-capture
// compositor path. Falls back to the compositor without Screen Recording access.
@property (nonatomic) BOOL usesShader;
@property (nonatomic, readonly) BOOL shaderActive;

- (float)amountForDisplay:(CGDirectDisplayID)displayID;
- (void)setAmount:(float)amount forDisplay:(CGDirectDisplayID)displayID;
- (void)reapply;

@end

NS_ASSUME_NONNULL_END
