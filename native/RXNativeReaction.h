#ifndef RX_NATIVE_REACTION_H
#define RX_NATIVE_REACTION_H

#include <stddef.h>
#include <stdint.h>

/* Protocol order, deliberately independent of RXKind's enum order. */
enum RXNativeReaction {
    RXNativeHeart = 0,
    RXNativeLike = 1,
    RXNativeDislike = 2,
    RXNativeLaugh = 3,
    RXNativeEmphasize = 4,
    RXNativeQuestion = 5
};

static inline int RXNativeType(unsigned int reaction, int removal) {
    return reaction <= RXNativeQuestion ? (removal ? 3000 : 2000) + (int)reaction : -1;
}

/* Validate before using a GUID in a target key or a handoff filename. */
static inline int RXNativeGUIDIsValid(const char *guid) {
    size_t i;
    if (!guid) return 0;
    for (i = 0; i < 36; ++i) {
        unsigned char c = (unsigned char)guid[i];
        if (!c) return 0;
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return 0;
        } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                     (c >= 'A' && c <= 'F'))) return 0;
    }
    return guid[36] == '\0';
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>

/* Produces metadata only. The existing encrypted send dictionary owns routing.
 * targetText is the ORIGINAL untruncated target; rangeLength is UTF-16 units.
 * Returns nil for unsupported reactions, malformed IDs or invalid ranges.
 */
NSDictionary *RXNativeReactionFields(NSString *targetGUID, NSUInteger part,
                                    unsigned int reaction, BOOL removal,
                                    NSString *targetText, BOOL media,
                                    NSUInteger rangeLocation, NSUInteger rangeLength);
#endif
#endif
