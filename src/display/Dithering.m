#import "Dithering.h"
#import <IOKit/IOKitLib.h>

static NSString *const kDitherProperty = @"enableDither";

@implementation Dithering

+ (void)forEachFramebuffer:(void (^)(io_registry_entry_t entry))block {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                 kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) return;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)kDitherProperty, NULL, 0);
        if (value) {
            CFRelease(value);
            block(entry);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
}

+ (BOOL)isAvailable {
    __block BOOL found = NO;
    [self forEachFramebuffer:^(io_registry_entry_t entry) { (void)entry; found = YES; }];
    return found;
}

+ (void)setDisabled:(BOOL)disabled {
    [self forEachFramebuffer:^(io_registry_entry_t entry) {
        kern_return_t result = IORegistryEntrySetCFProperty(entry, (__bridge CFStringRef)kDitherProperty,
                                                            disabled ? kCFBooleanFalse : kCFBooleanTrue);
        if (result != KERN_SUCCESS) NSLog(@"DisplayDeck: could not change dithering: 0x%x", result);
    }];
}

@end
