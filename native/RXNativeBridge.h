#import <Foundation/Foundation.h>
#import "RXNativeReaction.h"

#define RX_NATIVE_READY "com.mbucc9000.reactions.native.v1"
#define RX_NATIVE_PROTOCOL 0x52584E02ULL
#define RX_NATIVE_DIRECTORY @"/var/mobile/Library/Reactions/NativeRequests"
#define RX_NATIVE_PREFIX @"52584E54-"

BOOL RXNativeIsGUID(NSString *guid);
BOOL RXNativeAvailable(void);
NSString *RXNativeNewGUID(void);
BOOL RXNativeStage(NSString *guid, NSString *fallback, NSDictionary *fields);
NSDictionary *RXNativeRead(NSString *guid);
void RXNativeDiscard(NSString *guid);
NSDictionary *RXNativeDecorate(NSDictionary *original, NSDictionary *request);
