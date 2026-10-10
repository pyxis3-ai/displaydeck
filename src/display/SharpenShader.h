#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Sharpens one display by capturing it and redrawing it through a
// contrast-adaptive sharpening shader. Needs Screen Recording permission.
@interface SharpenShader : NSObject

@property (atomic) float amount;
@property (nonatomic, readonly) NSRect screenFrame;
@property (nonatomic, copy, nullable) void (^onFailure)(void);

- (nullable instancetype)initWithScreen:(NSScreen *)screen
                              displayID:(CGDirectDisplayID)displayID
                              pixelSize:(CGSize)pixelSize;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
