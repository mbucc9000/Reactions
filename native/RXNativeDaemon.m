#import "RXNativeBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <unistd.h>
#include <string.h>

// Verified block signature from the iOS 6 iMessage sender: v24@?0@4@8@12c16I20.
typedef void (^RXDeliveryCompletion)(id, id, id, BOOL, unsigned int);
typedef void (*RXSendOriginal)(id, SEL, id, id, id, id, RXDeliveryCompletion);
typedef void (*RXSerializeOriginal)(id, SEL, id, id, id, id, id, id, id, id, id, id, RXDeliveryCompletion);
static RXSendOriginal gSend;
static RXSerializeOriginal gSerialize;
static int gReadyToken;
static BOOL gInstalled;
static BOOL gSMSInstalled;
static void (*gSMS)(id, SEL, id, id, unsigned char);

static void RXNoSMS(id self, SEL cmd, id message, id chat, unsigned char style) {
    SEL guidSEL = sel_registerName("guid");
    NSString *guid = [message respondsToSelector:guidSEL] ?
                     ((id (*)(id, SEL))objc_msgSend)(message, guidSEL) : nil;
    if (!RXNativeIsGUID(guid)) { gSMS(self, cmd, message, chat, style); return; }
    SEL error = sel_registerName("setErrorCode:");
    SEL sent = sel_registerName("didSendMessage:forChat:style:");
    if ([message respondsToSelector:error] && [self respondsToSelector:sent]) {
        ((void (*)(id, SEL, unsigned int))objc_msgSend)(message, error, 26);
        ((void (*)(id, SEL, id, id, unsigned char))objc_msgSend)(self, sent, message, chat, style);
    }
}

static NSString *RXMessageGUID(id message) {
    SEL selector = sel_registerName("guid");
    return [message respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(message, selector) : nil;
}

static void RXReject(id controller, id message, id people, RXDeliveryCompletion completion) {
    // Same completion arguments as the stock encryption-failure path (error 26).
    if (completion) completion(controller, message, people, NO, 26);
}

static void RXSend(id self, SEL cmd, id message, id people, id fromID,
                   id identity, RXDeliveryCompletion completion) {
    NSString *guid = RXMessageGUID(message);
    if (RXNativeIsGUID(guid) && !RXNativeRead(guid)) {
        RXReject(self, message, people, completion);
        return;
    }
    gSend(self, cmd, message, people, fromID, identity, completion);
}

static void RXSerialize(id self, SEL cmd, id message, id text, id dictionary, id fromID,
                        id identity, id toID, id token, id sessionToken, id people,
                        id ack, RXDeliveryCompletion completion) {
    NSString *guid = RXMessageGUID(message);
    if (!RXNativeIsGUID(guid)) {
        gSerialize(self, cmd, message, text, dictionary, fromID, identity, toID,
                   token, sessionToken, people, ack, completion);
        return;
    }
    NSDictionary *updated = RXNativeDecorate(dictionary, RXNativeRead(guid));
    if (!updated) {
        RXReject(self, message, people, completion);
        return;
    }
    gSerialize(self, cmd, message, text, updated, fromID, identity, toID,
               token, sessionToken, people, ack, completion);
}

static void RXInstall(void) {
    if (!gSMSInstalled) {
        Class sms = objc_getClass("SMSServiceSession");
        SEL smsSEL = sel_registerName("sendMessage:toChat:style:");
        Method m = sms ? class_getInstanceMethod(sms, smsSEL) : NULL;
        if (m && !strcmp(method_getTypeEncoding(m), "v20@0:4@8@12C16")) {
            MSHookMessageEx(sms, smsSEL, (IMP)RXNoSMS, (IMP *)&gSMS);
            gSMSInstalled = gSMS != NULL;
        }
    }
    if (gInstalled) return;
    if (!gSMSInstalled) return;
    Class cls = objc_getClass("MessageDeliveryController");
    SEL send = sel_registerName("sendMessage:toPeople:fromID:fromIdentity:completionBlock:");
    SEL serialize = sel_registerName("_sendMessage:messageString:messageDictionary:fromID:fromIdentity:toID:toToken:toSessionToken:toPeople:ackBlock:completionBlock:");
    Method a = cls ? class_getInstanceMethod(cls, send) : NULL;
    Method b = cls ? class_getInstanceMethod(cls, serialize) : NULL;
    if (!a || !b || strcmp(method_getTypeEncoding(a), "v28@0:4@8@12@16@20@?24") ||
        strcmp(method_getTypeEncoding(b), "v52@0:4@8@12@16@20@24@28@32@36@40@?44@?48")) return;
    MSHookMessageEx(cls, send, (IMP)RXSend, (IMP *)&gSend);
    MSHookMessageEx(cls, serialize, (IMP)RXSerialize, (IMP *)&gSerialize);
    if (!gSend || !gSerialize) return;
    gInstalled = YES;
    if (notify_register_check(RX_NATIVE_READY, &gReadyToken) == NOTIFY_STATUS_OK)
        notify_set_state(gReadyToken, (RX_NATIVE_PROTOCOL << 32) | (uint32_t)getpid());
}

static void RXImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    // Runs after dyld has registered ObjC classes; no Foundation hooks are installed globally.
    dispatch_async(dispatch_get_main_queue(), ^{ RXInstall(); });
}

__attribute__((constructor)) static void RXNativeStart(void) {
    _dyld_register_func_for_add_image(RXImageAdded);
}
