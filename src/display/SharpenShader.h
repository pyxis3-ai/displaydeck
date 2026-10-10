#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Sharpens one display by capturing it and redrawing it through a sharpening
// shader at the panel's pixel scale. Needs Screen Recording permission.
@interface SharpenShader : NSObject

@property (atomic) float amount;
@property (atomic) int radius;
@property (nonatomic, readonly) NSRect screenFrame;
@property (nonatomic, readonly) CGFloat backingScale;
@property (nonatomic, copy, nullable) void (^onFailure)(void);

- (nullable instancetype)initWithScreen:(NSScreen *)screen
                              displayID:(CGDirectDisplayID)displayID
                              pixelSize:(CGSize)pixelSize;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
