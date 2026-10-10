#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

NSError *DDError(NSErrorDomain domain, NSInteger code, NSString *format, ...)
    NS_FORMAT_FUNCTION(3, 4);
NSString *DDAppleScriptEscape(NSString *s);

NSMutableDictionary<NSNumber *, NSNumber *> *DDLoadNumberMap(NSString *key);
void DDSaveNumberMap(NSDictionary<NSNumber *, NSNumber *> *map, NSString *key);

typedef CGError (*DDDisplayListFn)(uint32_t, CGDirectDisplayID * _Nullable, uint32_t *);
NSArray<NSNumber *> *DDQueryDisplayList(DDDisplayListFn fn);

// The physical display behind `displayID`: while HiDPI is forced the screen
// macOS reports is a virtual one that the real panel mirrors.
CGDirectDisplayID DDPanelDisplay(CGDirectDisplayID displayID);

NS_ASSUME_NONNULL_END
