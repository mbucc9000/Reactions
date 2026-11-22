#import "RXNativeReaction.h"
#include <limits.h>

NSDictionary *RXNativeReactionFields(NSString *targetGUID, NSUInteger part,
                                    unsigned int reaction, BOOL removal,
                                    NSString *targetText, BOOL media,
                                    NSUInteger rangeLocation, NSUInteger rangeLength) {
    int type = RXNativeType(reaction, removal);
    if (![targetGUID isKindOfClass:[NSString class]] ||
        !RXNativeGUIDIsValid([targetGUID UTF8String]) || type < 0 || part > INT_MAX ||
        ![targetText isKindOfClass:[NSString class]]) return nil;
    if (media) {
        if (rangeLocation != 0 || rangeLength != 0) return nil;
    } else if (rangeLocation > targetText.length ||
               rangeLength > targetText.length - rangeLocation) return nil;

    // amc=9 describes an iMessage app balloon, not a photo attachment.
    NSDictionary *summary = @{ @"ams": targetText, @"amc": @1 };
    NSData *notification = [NSPropertyListSerialization dataWithPropertyList:summary
                                format:NSPropertyListBinaryFormat_v1_0
                                options:0 error:NULL];
    if (!notification) return nil;
    NSString *target = [NSString stringWithFormat:@"p:%lu/%@", (unsigned long)part, [targetGUID uppercaseString]];
    return @{ @"amk": target, @"amt": @(type), @"amrlc": @(rangeLocation),
              @"amrln": @(rangeLength), @"msi": notification };
}

NSDictionary *RXNativeReplyFields(NSString *targetGUID, NSUInteger part,
                                  NSUInteger location, NSUInteger length) {
    if (![targetGUID isKindOfClass:[NSString class]] ||
        !RXNativeGUIDIsValid(targetGUID.UTF8String) || part > INT_MAX ||
        location > INT_MAX || length > INT_MAX || length > INT_MAX - location) return nil;
    return @{@"tg": [NSString stringWithFormat:@"r:%lu:%lu:%lu:%@",
        (unsigned long)part, (unsigned long)location, (unsigned long)length,
        [targetGUID uppercaseString]]};
}
