// Reactions 2.0 — RXSend.m: sending a tapback (DESIGN.md §8, R2 §1, R5 §7).
//
// The reaction goes out as a plain iMessage text through the conversation's own IMChat:
//   +[IMMessage instantMessageWithText:flags:] (0x100005 = finished|fromMe|wasDataDetected, the
//   64-bit flags passed through an explicit unsigned-long-long objc_msgSend cast, R2 §1.4) with the
//   body attributed __kIMMessagePartAttributeName = 0, then -[IMChat sendMessage:].
// The new message's GUID is read before sending and handed to RXStore with the optimistic vote, so
// the badge changes instantly and the daemon echo is recognised as ours. A failed send is handled
// by RXStore/RXTranscript (the row stays visible with the stock "Not Delivered"); here only a
// missing class/selector/chat or a throwing send is reported, with a stock alert (a throwing send
// also drops the optimistic vote through -[RXStore messageFailed:]).
//
// Logs: kinds, lengths and GUID tails only (DESIGN §2).

#import "RXShared.h"

#define RX_SEND_ATTR_PART   @"__kIMMessagePartAttributeName"

static NSString *RXSendStripObjectReplacement(NSString *s) {
    if (!s.length) {
        return s;
    }
    return [s stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
}

static void RXSendShowFailureAlert(void) {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Couldn\u2019t Send Reaction"
                                                    message:@"Messages couldn\u2019t send this reaction. Please try again."
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

// The bubble-data part rows of `message`, in order (DESIGN §5.3 fallback when partKey is not an
// index into -[CKIMMessage parts]).
static CKMessagePart *RXSendPartFromRows(CKTranscriptBubbleData *data, NSUInteger firstRow, NSString *guid, NSInteger partKey) {
    if (!data || partKey < 0 || !guid.length || ![data respondsToSelector:@selector(partAtIndex:)]) {
        return nil;
    }
    int count = [data count];
    NSInteger seen = 0;
    BOOL inside = NO;
    for (int row = (int)firstRow; row < count; row++) {
        id rowMessage = [data messageAtIndex:row];
        NSString *rowGUID = [rowMessage respondsToSelector:@selector(guid)] ? [rowMessage guid] : nil;
        if (![rowGUID isEqualToString:guid]) {
            if (inside) {
                break;
            }
            continue;
        }
        inside = YES;
        CKMessagePart *part = [data partAtIndex:row];
        if (!part) {
            continue;
        }
        if (seen == partKey) {
            return part;
        }
        seen++;
    }
    return nil;
}

// Finds the reacted part: parts[partKey], else the partKey-th part row in the bubble data.
static CKMessagePart *RXSendFindPart(CKTranscriptBubbleData *data, NSUInteger firstRow, CKIMMessage *message, NSInteger partKey) {
    NSArray *parts = [message respondsToSelector:@selector(parts)] ? [message parts] : nil;
    if (partKey >= 0 && (NSUInteger)partKey < parts.count) {
        id part = [parts objectAtIndex:(NSUInteger)partKey];
        if ([part respondsToSelector:@selector(type)]) {
            return part;
        }
    }
    NSString *guid = [message respondsToSelector:@selector(guid)] ? [message guid] : nil;
    return RXSendPartFromRows(data, firstRow, guid, partKey);
}

BOOL RXSendReaction(CKTranscriptController *tc, NSString *guid, NSInteger partKey, RXKind kind, NSString *emoji, BOOL removal) {
    if (!tc || !guid.length || kind == RXKindNone || (kind == RXKindEmoji && !emoji.length)) {
        RXLog(@"send: invalid request (kind %d, guid %d, emoji %d)", (int)kind, guid.length ? 1 : 0, emoji.length ? 1 : 0);
        return NO;
    }

    // Everything the IMCore path needs. Any miss = the stock-style alert (DESIGN §8).
    CKTranscriptBubbleData *data = RXResponds(tc, @selector(bubbleData)) ? [tc bubbleData] : nil;
    CKConversation *conversation = RXResponds(tc, @selector(conversation)) ? [tc conversation] : nil;
    IMChat *chat = RXResponds(conversation, @selector(chat)) ? [conversation chat] : nil;
    NSString *chatKey = RXChatKeyForConversation(conversation);
    Class messageClass = NSClassFromString(@"IMMessage");
    SEL makeSelector = @selector(instantMessageWithText:flags:);
    BOOL canMake = messageClass && [messageClass respondsToSelector:makeSelector];
    BOOL canSend = RXResponds(chat, @selector(sendMessage:));
    BOOL canFind = RXResponds(data, @selector(indexForMessageWithGUID:)) && RXResponds(data, @selector(messageAtIndex:))
                   && RXResponds(data, @selector(count));
    if (!data || !chat || !chatKey.length || !canMake || !canSend || !canFind) {
        RXLog(@"send: no path (data %d, chat %d, key %d, IMMessage %d, sendMessage %d, lookup %d)",
              data ? 1 : 0, chat ? 1 : 0, chatKey.length ? 1 : 0, canMake ? 1 : 0, canSend ? 1 : 0, canFind ? 1 : 0);
        RXSendShowFailureAlert();
        return NO;
    }

    // The target as it is in the current bubble data (the picker's snapshot may be stale).
    int count = [data count];
    NSUInteger index = [data indexForMessageWithGUID:guid];
    if (count <= 0 || index == NSNotFound || index >= (NSUInteger)count) {
        RXLog(@"send: target %@ is no longer in the transcript", RXGUIDTail(guid));
        return NO;
    }
    CKIMMessage *message = [data messageAtIndex:(int)index];
    NSString *messageGUID = [message respondsToSelector:@selector(guid)] ? [message guid] : nil;
    if (![messageGUID isEqualToString:guid]) {
        RXLog(@"send: row %lu does not hold target %@", (unsigned long)index, RXGUIDTail(guid));
        return NO;
    }
    NSString *messageChatKey = RXChatKeyForMessage(message);
    if (messageChatKey.length && ![messageChatKey isEqualToString:chatKey]) {
        RXLog(@"send: target %@ belongs to another chat", RXGUIDTail(guid));
        return NO;
    }

    // Q = the reacted part's own text (U+FFFC removed, never -previewText); media → the noun form.
    CKMessagePart *part = RXSendFindPart(data, index, message, partKey);
    RXTarget target = part ? RXTargetForPart(part) : RXTargetText;
    NSString *quote = nil;
    if (target == RXTargetText) {
        quote = part ? RXTextForPart(part) : nil;
        if (!quote.length && [message respondsToSelector:@selector(_rawPreviewText)]) {
            quote = RXSendStripObjectReplacement([message _rawPreviewText]);
        }
    } else if (target == RXTargetUnknown) {
        target = RXTargetAnyAttachment;     // deleted / unknown part: "… an attachment"
    }
    NSString *text = RXComposeReaction(kind, emoji, removal, target, quote ?: @"");
    if (!text.length) {
        RXLog(@"send: could not compose (kind %d, target %d, removal %d)", (int)kind, (int)target, removal ? 1 : 0);
        RXSendShowFailureAlert();
        return NO;
    }

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] initWithString:text];
    [body addAttribute:RX_SEND_ATTR_PART value:@0 range:NSMakeRange(0, body.length)];

    id imMessage = nil;
    @try {
        imMessage = ((id (*)(id, SEL, id, unsigned long long))objc_msgSend)(messageClass, makeSelector, body, RX_IM_FLAGS);
    } @catch (NSException *exception) {
        RXLog(@"send: IMMessage factory threw %@", exception.name);
        imMessage = nil;
    }
    NSString *sentGUID = [imMessage respondsToSelector:@selector(guid)] ? [imMessage guid] : nil;
    if (!imMessage || !sentGUID.length) {
        RXLog(@"send: IMMessage factory returned %@", imMessage ? @"no guid" : @"nil");
        RXSendShowFailureAlert();
        return NO;
    }

    // Record the GUID and the optimistic vote BEFORE sending, so a synchronous echo is recognised.
    RXStore *store = [RXStore storeForChatKey:chatKey create:YES];
    [store addOptimisticKind:kind emoji:emoji removal:removal forGUID:guid partKey:partKey sentGUID:sentGUID];

    BOOL sent = YES;
    @try {
        [chat sendMessage:imMessage];
    } @catch (NSException *exception) {
        RXLog(@"send: -[IMChat sendMessage:] threw %@", exception.name);
        sent = NO;
    }

    if (!sent) {
        // No echo and no error change will ever arrive for this message: drop the optimistic vote now
        // (-messageFailed: only reads -guid, so the IMMessage itself is accepted).
        [store messageFailed:imMessage];
    }
    RXTranscriptScheduleRefresh(tc);
    if (!sent) {
        RXSendShowFailureAlert();
        return NO;
    }
    RXLog(@"send: %@ kind %d target %d part %ld len %lu -> %@ (on %@)", removal ? @"removal" : @"add", (int)kind, (int)target,
          (long)partKey, (unsigned long)text.length, RXGUIDTail(sentGUID), RXGUIDTail(guid));
    return YES;
}
