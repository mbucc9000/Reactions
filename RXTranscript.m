// Reactions 2.0 - RXTranscript.m
//
// Transcript integration (DESIGN section 5): the build context and bubble-data tagging, the append decision
// (through RXStore), Delivered/Read targeting, reload filtering, send-error changes, row -> part key, the extra
// row heights, our per-cell views (badge + quote), the single gated refresh/reload scheduler and RXTeardown.
//
// Checked against the device ChatKit (armdis on el-research/sdk/ChatKit) before coding:
//  * -_computeBubbleData: returns early, before touching anything, when !force and _lastMessage is still the
//    conversation's last message (CK@0xea48). Otherwise it allocs a NEW CKTranscriptBubbleData, appends
//    every message of [_conversation messages] in order, then - still inside the method - inserts status 2 (Read)
//    for the newest read outgoing message and afterwards status 1 (Delivered) for the newest delivered-after-read
//    one. Its scan skips failed/partiallyFailed messages but not our hidden ones, hence the build-only retarget.
//    A retargeted Delivered never lands on (or above) the Read row, so one bubble never shows both labels.
//    Because of the early return, the chat's store restarts lazily: on the build's first append, or at the
//    build's end when a new (empty) instance was made - never for a build that rebuilt nothing.
//  * -_reloadTranscriptLayerForcingBubbleDataReload: does nothing unless applicationState == Active; otherwise it
//    runs _computeBubbleData: -> reloadData -> scrollBubbleIndexToVisible:(count - 1) (plain setContentOffset:).
//  * -appendMessageToBubbleData: is only called from startSendAnimationForMessage: (the send throw), and
//    -_finishSendAnimation reloads the rows that were hidden for the throw (reloadRowsAtIndexPaths:).
//  * CKTranscriptTransaction _processRead/Delivered/ErrorInsert and _processRemovesToPrepareMessageFor* derive
//    rows only through insertMessageStatus:forMessage:date: and indexesToRemoveMessageStatusFlags:... - both are
//    hooked - so nothing else creates a row for a hidden message.
//
// Rules kept here (DESIGN section 2): no bubble-data row is ever added or removed by this file; beginUpdates /
// endUpdates and the forced reload only run behind the gate; only our own views' frames are set; no UILabel;
// ChatKit classes only through NSClassFromString; every private selector behind respondsToSelector:; teardown
// never reads prefs; logs carry counts, flags and GUID tails only. Main thread only.

#import "RXShared.h"
#include <math.h>

#pragma mark - Private declarations (methods only, never class symbols)

@interface UITableView (RXTranscriptPrivate)
- (BOOL)ignoresContentOffsetChanges;     // CKTranscriptTableView, c8@0:4 (CK.dump:L623)
@end

@interface CKIMMessage (RXTranscriptPrivate)
- (BOOL)isRead;                          // c8@0:4 (CK.dump, CKIMMessage); _computeBubbleData:'s status scan uses it
@end

#pragma mark - Tunables

#define RXT_RETRY_INTERVAL      0.25    // s between gate retries (DESIGN 5.6)
#define RXT_RETRY_MAX           20      // timer retries, then wait for an event (poke)
#define RXT_ROW_WALK_MAX        200     // rows walked around one message
#define RXT_STATUS_SCAN_MAX     500     // messages scanned back for the build-only status retarget
#define RXT_BADGE_OUT_TIME      0.2     // the badge's own shrink+fade is 0.15 s (DESIGN 6); keep it visible this long
#define RXT_QUOTE_DEFER_MAX     3.0     // a just-sent reply's quote waits at most this long for the send throw
#define RXT_QUOTE_FADE_TIME     0.25
#define RXT_JUMP_FLASH_DELAY    0.4     // animated scrollToRowAtIndexPath: takes ~0.3 s, then flashHighlight
#define RXT_MIN_TAP             44.0f   // quote tap target height (DESIGN 11)
#define RXT_ROW_TOP_MARGIN      5.0f    // stock space above a balloon in its row (bubbleMarginTop, R6 / CK@0x573b8)
#define RXT_BODY_TOP_HALO       1.5f    // balloon art halo above its body (R6 2.3)

#pragma mark - Private classes

// Tag on a CKTranscriptBubbleData instance. The controller is WEAK: tc -> _bubbleInfo -> tag -> tc would be a cycle.
@interface RXTBubbleTag : NSObject
@property (nonatomic, weak) CKTranscriptController *controller;
@property (nonatomic, copy) NSString *chatKey;
@end

@implementation RXTBubbleTag
@end

// Scheduler state, associated with (owned by) the controller; it never references the controller.
@interface RXTState : NSObject
@property (nonatomic, assign) BOOL needsRefresh;
@property (nonatomic, assign) BOOL needsReload;
@property (nonatomic, assign) BOOL editingRefresh;      // deferred setEditing: height refresh (exempt from edit mode)
@property (nonatomic, assign) BOOL attemptQueued;
@property (nonatomic, assign) BOOL timerArmed;
@property (nonatomic, assign) BOOL gaveUp;
@property (nonatomic, assign) NSInteger retries;
@property (nonatomic, assign) NSInteger chainedReloads; // reloads requested by our own reload's build (max 1)
@property (nonatomic, copy) NSString *chatKey;          // chat the pending work belongs to
@property (nonatomic, strong) NSMutableSet *dirtyGUIDs; // targets whose badge changed (animated on refresh)
@end

@implementation RXTState

- (instancetype)init
{
    self = [super init];
    if (self) {
        _dirtyGUIDs = [[NSMutableSet alloc] init];
    }
    return self;
}

@end

// What a cell currently shows (associated with the cell).
@interface RXTCellInfo : NSObject
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) BOOL hasBadge;
@property (nonatomic, assign) BOOL hasQuote;
@property (nonatomic, assign) BOOL outgoing;
@property (nonatomic, assign) CFTimeInterval badgeOutUntil;  // animated removal still running until then
@end

@implementation RXTCellInfo
@end

// Scroll anchor for refresh/reload (DESIGN 5.6).
@interface RXTAnchor : NSObject
@property (nonatomic, assign) BOOL pinned;
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) CGFloat delta;            // anchor row's maxY minus contentOffset.y
@end

@implementation RXTAnchor

- (instancetype)init
{
    self = [super init];
    if (self) {
        _row = NSNotFound;
        _partKey = NSNotFound;
    }
    return self;
}

@end

#pragma mark - Globals

static char kRXTTagKey;          // on a CKTranscriptBubbleData: RXTBubbleTag
static char kRXTStateKey;        // on a CKTranscriptController: RXTState
static char kRXTCellInfoKey;     // on a CKMessageCell: RXTCellInfo
static char kRXTBadgeViewKey;    // on a CKMessageCell: RXReactionBalloonView
static char kRXTQuoteViewKey;    // on a CKMessageCell: RXQuoteBalloonView

static NSInteger gBuildDepth;                       // > 0 inside -_computeBubbleData:
static __weak CKTranscriptController *gBuildTC;
static NSString *gBuildChatKey;
static NSUInteger gBuildAppends;
static NSUInteger gBuildHidden;
static NSUInteger gBuildRetargets;
static id gBuildReadTarget;                         // message that received status 2 in this build
static BOOL gBuildNeedsRestart;                     // the chat's store still has to restart for this build
static id gBuildOldData;                            // bubble data before the build (an early return makes none)
static NSInteger gOwnSendDepth;                     // > 0 inside -appendMessageToBubbleData:
static NSInteger gOwnReloadDepth;                   // > 0 inside our own forced reload
static NSHashTable *gControllers;                   // weak set of transcript controllers we have seen
static NSMutableDictionary *gDeferredQuotes;        // reply GUID -> NSNumber(CACurrentMediaTime) during the throw

#pragma mark - Small helpers

static BOOL RXTMain(void)
{
    return [NSThread isMainThread];
}

// NO while obj is deallocating: forming a __weak reference to it then is an objc fatal error.
static BOOL RXTAlive(id obj)
{
    if (!obj) {
        return NO;
    }
    static SEL allowsWeak;
    if (!allowsWeak) {
        allowsWeak = sel_getUid("allowsWeakReference");
    }
    if (![obj respondsToSelector:allowsWeak]) {
        return YES;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, allowsWeak);
}

static NSString *RXTGUIDOf(id message)
{
    CKIMMessage *m = message;
    if (!m || ![m respondsToSelector:@selector(guid)]) {
        return nil;
    }
    NSString *guid = [m guid];
    return ([guid isKindOfClass:[NSString class]] && [guid length]) ? guid : nil;
}

static BOOL RXTIsRealMessage(id message)
{
    CKIMMessage *m = message;
    if (!m) {
        return NO;
    }
    if ([m respondsToSelector:@selector(isTypingIndicator)] && [m isTypingIndicator]) {
        return NO;
    }
    if ([m respondsToSelector:@selector(isPlaceholder)] && [m isPlaceholder]) {
        return NO;
    }
    return YES;
}

static BOOL RXTIsFromMe(id message)
{
    CKIMMessage *m = message;
    return m && [m respondsToSelector:@selector(isFromMe)] && [m isFromMe];
}

static BOOL RXTMessageFailed(id message)
{
    CKIMMessage *m = message;
    if (!m) {
        return NO;
    }
    if ([m respondsToSelector:@selector(failedSend)] && [m failedSend]) {
        return YES;
    }
    return [m respondsToSelector:@selector(partiallyFailedSend)] && [m partiallyFailedSend];
}

static BOOL RXTSameMessage(id a, id b)
{
    if (!a || !b) {
        return NO;
    }
    return a == b || [a isEqual:b];
}

static BOOL RXTIsMessageCell(UITableViewCell *cell)
{
    static Class cellClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cellClass = NSClassFromString(@"CKMessageCell");
    });
    return cell && cellClass && [cell isKindOfClass:cellClass];
}

static CKBalloonView *RXTBalloonOf(UITableViewCell *cell)
{
    if (!RXTIsMessageCell(cell)) {
        return nil;
    }
    CKMessageCell *messageCell = (CKMessageCell *)cell;
    if (!RXResponds(messageCell, @selector(balloonView))) {
        return nil;
    }
    id balloon = [messageCell balloonView];
    return [balloon isKindOfClass:[UIView class]] ? (CKBalloonView *)balloon : nil;
}

static BOOL RXTBalloonIsOutgoing(CKBalloonView *balloon, BOOL fallback)
{
    if (balloon && [balloon respondsToSelector:@selector(orientation)]) {
        return [balloon orientation] != 0;
    }
    return fallback;
}

static void RXTStripSwipe(UIView *view)
{
    if (view && [view.layer animationForKey:RX_SWIPE_KEY]) {
        [view.layer removeAnimationForKey:RX_SWIPE_KEY];
    }
}

// Balloon, _failedButton and our views (covers balloon subclasses whose prepareForReuse skips super).
static void RXTStripCellSwipe(UITableViewCell *cell)
{
    RXTStripSwipe(RXTBalloonOf(cell));
    id failed = RXIvar(cell, "_failedButton");
    if ([failed isKindOfClass:[UIView class]]) {
        RXTStripSwipe((UIView *)failed);
    }
    RXTStripSwipe(objc_getAssociatedObject(cell, &kRXTBadgeViewKey));
    RXTStripSwipe(objc_getAssociatedObject(cell, &kRXTQuoteViewKey));
}

#pragma mark - Controllers, state, tags

static void RXTRegister(CKTranscriptController *tc)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gControllers = [NSHashTable weakObjectsHashTable];
        // Coming back from an inactive state (e.g. Notification Center) re-opens the gate: retry pending work.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            for (CKTranscriptController *controller in [gControllers allObjects]) {
                RXTranscriptPoke(controller);
            }
        }];
    });
    if (tc && RXTAlive(tc) && ![gControllers containsObject:tc]) {
        [gControllers addObject:tc];
    }
}

static RXTState *RXTStateFor(CKTranscriptController *tc, BOOL create)
{
    if (!tc) {
        return nil;
    }
    RXTState *state = objc_getAssociatedObject(tc, &kRXTStateKey);
    if (!state && create && RXTAlive(tc)) {
        state = [[RXTState alloc] init];
        objc_setAssociatedObject(tc, &kRXTStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static UITableView *RXTTableFor(CKTranscriptController *tc)
{
    if (!tc || !RXResponds(tc, @selector(transcriptTable))) {
        return nil;
    }
    UITableView *table = [tc transcriptTable];
    return [table isKindOfClass:[UITableView class]] ? table : nil;
}

// The CKTranscriptBubbleData selectors this file calls directly (CK.dump L1137-1159), checked once per class
// (RXResponds logs a miss once): a missing one turns the transcript features off instead of crashing.
static BOOL RXTDataOK(id data)
{
    static Class checkedClass;
    static BOOL checkedOK;
    if (!data) {
        return NO;
    }
    Class cls = object_getClass(data);
    if (cls != checkedClass) {
        checkedOK = RXResponds(data, @selector(count)) && RXResponds(data, @selector(messageAtIndex:)) &&
                    RXResponds(data, @selector(partAtIndex:)) && RXResponds(data, @selector(indexForMessageWithGUID:)) &&
                    RXResponds(data, @selector(lastIndexForMessage:));
        checkedClass = cls;
    }
    return checkedOK;
}

static CKTranscriptBubbleData *RXTDataFor(CKTranscriptController *tc)
{
    if (!tc || !RXResponds(tc, @selector(bubbleData))) {
        return nil;
    }
    CKTranscriptBubbleData *data = [tc bubbleData];
    return RXTDataOK(data) ? data : nil;
}

static NSString *RXTChatKeyForTC(CKTranscriptController *tc)
{
    if (!tc || !RXResponds(tc, @selector(conversation))) {
        return nil;
    }
    return RXChatKeyForConversation([tc conversation]);
}

static void RXTTagData(CKTranscriptBubbleData *data, CKTranscriptController *tc)
{
    if (!data || !tc || !RXTAlive(tc)) {
        return;
    }
    RXTBubbleTag *tag = objc_getAssociatedObject(data, &kRXTTagKey);
    if (tag && tag.controller == tc) {
        return;
    }
    if (!tag) {
        tag = [[RXTBubbleTag alloc] init];
        objc_setAssociatedObject(data, &kRXTTagKey, tag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tag.controller = tc;
    tag.chatKey = RXTChatKeyForTC(tc);
}

// The controller that owns `data`: its tag, else the build's controller, else any registered controller
// whose bubbleData is this instance. Tags the instance on the way (never resets anything).
static CKTranscriptController *RXTControllerForData(CKTranscriptBubbleData *data)
{
    if (!data) {
        return nil;
    }
    RXTBubbleTag *tag = objc_getAssociatedObject(data, &kRXTTagKey);
    CKTranscriptController *tc = tag.controller;
    if (tc) {
        return tc;
    }
    if (gBuildDepth > 0) {
        CKTranscriptController *building = gBuildTC;
        if (building && RXTDataFor(building) == data) {
            tc = building;
        }
    }
    if (!tc) {
        for (CKTranscriptController *candidate in [gControllers allObjects]) {
            if (RXTDataFor(candidate) == data) {
                tc = candidate;
                break;
            }
        }
    }
    if (tc) {
        RXTTagData(data, tc);
    }
    return tc;
}

#pragma mark - Rows (DESIGN 5.3)

NSInteger RXTranscriptPartKeyForRow(CKTranscriptBubbleData *data, NSInteger row)
{
    if (!RXTDataOK(data) || row < 0 || row >= (NSInteger)[data count]) {
        return NSNotFound;
    }
    CKMessagePart *part = [data partAtIndex:(int)row];
    CKIMMessage *msg = (CKIMMessage *)[data messageAtIndex:(int)row];
    if (!part || !msg) {
        return NSNotFound;
    }
    NSArray *parts = [msg respondsToSelector:@selector(parts)] ? [msg parts] : nil;
    if ([parts isKindOfClass:[NSArray class]]) {
        NSUInteger index = [parts indexOfObjectIdenticalTo:part];
        if (index != NSNotFound) {
            return (NSInteger)index;
        }
    }
    // Fallback: this row's position among the message's part rows.
    NSInteger key = 0;
    NSInteger steps = 0;
    for (NSInteger r = row - 1; r >= 0 && steps < RXT_ROW_WALK_MAX; r--, steps++) {
        if (!RXTSameMessage([data messageAtIndex:(int)r], msg)) {
            break;
        }
        if ([data partAtIndex:(int)r]) {
            key++;
        }
    }
    return key;
}

// YES when no earlier row of the same message carries a part (a reply's quote goes on its first row).
static BOOL RXTIsFirstPartRow(CKTranscriptBubbleData *data, NSInteger row, id msg)
{
    NSInteger steps = 0;
    for (NSInteger r = row - 1; r >= 0 && steps < RXT_ROW_WALK_MAX; r--, steps++) {
        if (!RXTSameMessage([data messageAtIndex:(int)r], msg)) {
            break;
        }
        if ([data partAtIndex:(int)r]) {
            return NO;
        }
    }
    return YES;
}

// Row of (guid, partKey); the message's first part row when the key isn't found; NSNotFound when the
// message isn't in the bubble data (indexForMessageWithGUID: >= count).
static NSInteger RXTRowForGUIDPart(CKTranscriptBubbleData *data, NSString *guid, NSInteger partKey)
{
    if (!data || !guid) {
        return NSNotFound;
    }
    NSInteger count = (NSInteger)[data count];
    NSUInteger first = [data indexForMessageWithGUID:guid];
    if (first == NSNotFound || count <= 0 || first >= (NSUInteger)count) {
        return NSNotFound;
    }
    id msg = [data messageAtIndex:(int)first];
    NSInteger firstPart = NSNotFound;
    NSInteger steps = 0;
    for (NSInteger r = (NSInteger)first; r < count && steps < RXT_ROW_WALK_MAX; r++, steps++) {
        if (r > (NSInteger)first && !RXTSameMessage([data messageAtIndex:(int)r], msg)) {
            break;
        }
        if (![data partAtIndex:(int)r]) {
            continue;
        }
        if (firstPart == NSNotFound) {
            firstPart = r;
        }
        if (partKey == NSNotFound || RXTranscriptPartKeyForRow(data, r) == partKey) {
            return r;
        }
    }
    return firstPart != NSNotFound ? firstPart : (NSInteger)first;
}

// Badge model and reply link for a row (each nil when off, absent or not on this row).
static BOOL RXTResolveRow(CKTranscriptBubbleData *data, NSInteger row, BOOL wantBadge, BOOL wantQuote,
                          CKIMMessage **outMsg, NSString **outGUID, NSInteger *outPartKey,
                          RXBadgeModel **outBadge, RXReplyLink **outLink)
{
    if (outMsg) {
        *outMsg = nil;
    }
    if (outGUID) {
        *outGUID = nil;
    }
    if (outPartKey) {
        *outPartKey = NSNotFound;
    }
    if (outBadge) {
        *outBadge = nil;
    }
    if (outLink) {
        *outLink = nil;
    }
    if (!data || row < 0 || row >= (NSInteger)[data count]) {
        return NO;
    }
    if (![data partAtIndex:(int)row]) {
        return NO;
    }
    CKIMMessage *msg = (CKIMMessage *)[data messageAtIndex:(int)row];
    NSString *guid = RXTGUIDOf(msg);
    NSString *chatKey = guid ? RXChatKeyForMessage(msg) : nil;
    if (!chatKey) {
        return NO;
    }
    RXStore *store = [RXStore storeForChatKey:chatKey create:NO];
    if (!store) {
        return NO;
    }
    NSInteger partKey = RXTranscriptPartKeyForRow(data, row);
    RXBadgeModel *badge = nil;
    if (wantBadge && partKey != NSNotFound) {
        RXBadgeModel *model = [store badgeForGUID:guid partKey:partKey];
        if (model && !model.isEmpty) {
            badge = model;
        }
    }
    RXReplyLink *link = nil;
    if (wantQuote) {
        RXReplyLink *candidate = [store replyLinkForGUID:guid];
        if ([candidate.parentGUID length] && RXTIsFirstPartRow(data, row, msg)) {
            link = candidate;
        }
    }
    if (outMsg) {
        *outMsg = msg;
    }
    if (outGUID) {
        *outGUID = guid;
    }
    if (outPartKey) {
        *outPartKey = partKey;
    }
    if (outBadge) {
        *outBadge = badge;
    }
    if (outLink) {
        *outLink = link;
    }
    return YES;
}

static UIImage *RXTPartThumbnail(CKTranscriptBubbleData *data, NSInteger row)
{
    if (!data || row == NSNotFound || row < 0 || row >= (NSInteger)[data count]) {
        return nil;
    }
    CKMessagePart *part = [data partAtIndex:(int)row];
    if (!part || ![part respondsToSelector:@selector(previewImage)]) {
        return nil;
    }
    id image = [part previewImage];
    return [image isKindOfClass:[UIImage class]] ? image : nil;
}

#pragma mark - Quote deferral during the send throw (DESIGN 11)

static BOOL RXTQuoteDeferred(NSString *guid)
{
    if (!guid || [gDeferredQuotes count] == 0) {
        return NO;
    }
    NSNumber *since = [gDeferredQuotes objectForKey:guid];
    if (!since) {
        return NO;
    }
    if (CACurrentMediaTime() - [since doubleValue] > RXT_QUOTE_DEFER_MAX) {
        [gDeferredQuotes removeObjectForKey:guid];
        return NO;
    }
    return YES;
}

// Fades in visible deferred quotes once the throw is over (_sending cleared - CK@0x119ea - and no ChatKit hold),
// or now when forced.
static void RXTRevealQuotes(CKTranscriptController *tc, BOOL force)
{
    if ([gDeferredQuotes count] == 0) {
        return;
    }
    if (!force) {
        if (RXResponds(tc, @selector(isSendingMessage)) && [tc isSendingMessage]) {
            return;
        }
        if (RXResponds(tc, @selector(_isHoldingUpdatesToTranscript)) && [tc _isHoldingUpdatesToTranscript]) {
            return;
        }
    }
    UITableView *table = RXTTableFor(tc);
    for (UITableViewCell *cell in [table visibleCells]) {
        RXTCellInfo *info = objc_getAssociatedObject(cell, &kRXTCellInfoKey);
        RXQuoteBalloonView *quote = objc_getAssociatedObject(cell, &kRXTQuoteViewKey);
        if (!info.guid || !quote || !info.hasQuote || ![gDeferredQuotes objectForKey:info.guid]) {
            continue;
        }
        [gDeferredQuotes removeObjectForKey:info.guid];
        if (quote.hidden) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = RXT_QUOTE_FADE_TIME;
            [quote.layer addAnimation:fade forKey:@"RXQuoteFade"];
        }
        RXTranscriptLayoutCell(cell);
    }
}

static void RXTDeferQuote(NSString *guid, CKTranscriptController *tc)
{
    if (!guid) {
        return;
    }
    if (!gDeferredQuotes) {
        gDeferredQuotes = [[NSMutableDictionary alloc] init];
    }
    CFTimeInterval now = CACurrentMediaTime();
    for (NSString *key in [gDeferredQuotes allKeys]) {
        if (now - [[gDeferredQuotes objectForKey:key] doubleValue] > RXT_QUOTE_DEFER_MAX) {
            [gDeferredQuotes removeObjectForKey:key];
        }
    }
    [gDeferredQuotes setObject:[NSNumber numberWithDouble:now] forKey:guid];
    if (tc && RXTAlive(tc)) {
        __weak CKTranscriptController *weakTC = tc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((RXT_QUOTE_DEFER_MAX + 0.05) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CKTranscriptController *controller = weakTC;
            if (controller) {
                RXTRevealQuotes(controller, YES);
            }
        });
    }
}

#pragma mark - Cell views (DESIGN 5.5)

// Puts `view` directly above `below` in `host` when it isn't already; returns the view to stack the next one on.
static UIView *RXTPlaceAbove(UIView *host, UIView *view, UIView *below)
{
    if (!view) {
        return below;
    }
    NSArray *subviews = host.subviews;
    NSUInteger belowIndex = [subviews indexOfObjectIdenticalTo:below];
    if (belowIndex == NSNotFound) {
        return below;
    }
    NSUInteger viewIndex = (view.superview == host) ? [subviews indexOfObjectIdenticalTo:view] : NSNotFound;
    if (viewIndex == NSNotFound || viewIndex != belowIndex + 1) {
        [host insertSubview:view aboveSubview:below];
    }
    return view;
}

// Z-order: balloon < quote < badge (addBalloonView: re-adds the balloon on top on every reuse).
static void RXTEnsureOrder(UIView *host, UIView *balloon, UIView *quote, UIView *badge)
{
    if (!host || !balloon || balloon.superview != host) {
        return;
    }
    UIView *top = RXTPlaceAbove(host, quote, balloon);
    RXTPlaceAbove(host, badge, top);
}

static void RXTFlashParent(CKTranscriptController *tc, NSString *guid, NSInteger partKey)
{
    UITableView *table = RXTTableFor(tc);
    CKTranscriptBubbleData *data = RXTDataFor(tc);
    if (!table || !data || [table numberOfSections] < 1) {
        return;
    }
    NSInteger row = RXTRowForGUIDPart(data, guid, partKey);
    if (row == NSNotFound || row >= [table numberOfRowsInSection:0]) {
        return;
    }
    UITableViewCell *cell = [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    CKBalloonView *balloon = RXTBalloonOf(cell);
    if (balloon && RXResponds(balloon, @selector(flashHighlight))) {
        [balloon flashHighlight];
    }
}

// Quote tap (DESIGN 11): animated scroll to the parent row, then flash it. Only when the parent is loaded and
// the table isn't ignoring offset changes.
static void RXTJumpToParent(CKTranscriptController *tc, NSString *guid, NSInteger partKey)
{
    if (!tc || !guid || !RXTAlive(tc)) {
        return;
    }
    UITableView *table = RXTTableFor(tc);
    CKTranscriptBubbleData *data = RXTDataFor(tc);
    if (!table || !table.window || !data || [table numberOfSections] < 1) {
        return;
    }
    if ([table respondsToSelector:@selector(ignoresContentOffsetChanges)] && [table ignoresContentOffsetChanges]) {
        return;
    }
    NSUInteger first = [data indexForMessageWithGUID:guid];
    if (first == NSNotFound || first >= (NSUInteger)MAX(0, [data count])) {
        return;
    }
    NSInteger row = RXTRowForGUIDPart(data, guid, partKey);
    if (row == NSNotFound || row >= [table numberOfRowsInSection:0]) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    CGRect rowRect = [table rectForRowAtIndexPath:path];
    UIEdgeInsets insets = table.contentInset;
    CGRect visible = UIEdgeInsetsInsetRect(table.bounds, UIEdgeInsetsMake(insets.top, 0, insets.bottom, 0));
    BOOL scroll = !CGRectContainsRect(visible, rowRect);
    if (scroll) {
        [table scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    }
    RXLog(@"quote jump to %@ (row %ld, scrolled %d)", RXGUIDTail(guid), (long)row, (int)scroll);
    __weak CKTranscriptController *weakTC = tc;
    NSString *parentGUID = [guid copy];
    double delay = scroll ? RXT_JUMP_FLASH_DELAY : 0.01;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CKTranscriptController *controller = weakTC;
        if (controller) {
            RXTFlashParent(controller, parentGUID, partKey);
        }
    });
}

// Creates/reuses our views for the cell and sets their data (or hides them). `animateGUIDs` = targets whose
// badge changed (refresh path); nil on cellForRow (the reuse reset).
static void RXTApplyCell(CKTranscriptController *tc, UITableView *table, UITableViewCell *cell, NSIndexPath *path,
                         NSSet *animateGUIDs)
{
    RXPrefs prefs = RXGetPrefs();
    BOOL wantBadge = prefs.enabled && prefs.badges;
    BOOL wantQuote = prefs.enabled && prefs.quotes;
    CKTranscriptBubbleData *data = nil;
    if (tc && table && path && path.section == 0 && (wantBadge || wantQuote) && table == RXTTableFor(tc)) {
        data = RXTDataFor(tc);
    }
    CKIMMessage *msg = nil;
    NSString *guid = nil;
    NSInteger partKey = NSNotFound;
    RXBadgeModel *model = nil;
    RXReplyLink *link = nil;
    if (data) {
        RXTResolveRow(data, path.row, wantBadge, wantQuote, &msg, &guid, &partKey, &model, &link);
    }

    RXTCellInfo *info = objc_getAssociatedObject(cell, &kRXTCellInfoKey);
    RXReactionBalloonView *badge = objc_getAssociatedObject(cell, &kRXTBadgeViewKey);
    RXQuoteBalloonView *quote = objc_getAssociatedObject(cell, &kRXTQuoteViewKey);
    if (!model && !link && !badge && !quote) {
        if (info) {
            objc_setAssociatedObject(cell, &kRXTCellInfoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!info) {
        info = [[RXTCellInfo alloc] init];
        objc_setAssociatedObject(cell, &kRXTCellInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL outgoing = RXTBalloonIsOutgoing(RXTBalloonOf(cell), RXTIsFromMe(msg));
    BOOL wallpaper = table ? RXTableIsWallpapered(table) : NO;
    BOOL animated = guid && [animateGUIDs containsObject:guid];
    __weak CKTranscriptController *weakTC = RXTAlive(tc) ? tc : nil;
    __weak UITableViewCell *weakCell = cell;
    info.guid = guid;
    info.partKey = partKey;
    info.outgoing = outgoing;

    // Badge (DESIGN 6).
    if (model) {
        if (!badge) {
            badge = [[RXReactionBalloonView alloc] initWithFrame:CGRectZero];
            objc_setAssociatedObject(cell, &kRXTBadgeViewKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (badge.wallpaper != wallpaper) {
            badge.wallpaper = wallpaper;
        }
        if (badge.outgoing != outgoing) {
            badge.outgoing = outgoing;
        }
        if (prefs.enabled && prefs.picker && weakTC) {
            badge.onTap = ^{
                CKTranscriptController *controller = weakTC;
                UITableViewCell *tapped = weakCell;
                if (controller && tapped && RXOn(RXGetPrefs().picker)) {
                    RXPickerPresentForBadge(controller, tapped);
                }
            };
        } else {
            badge.onTap = nil;
        }
        info.hasBadge = YES;
        info.badgeOutUntil = 0;
        badge.hidden = NO;
        [badge setModel:model animated:animated];
    } else if (badge) {
        BOOL wasShowing = info.hasBadge && !badge.hidden;
        info.hasBadge = NO;
        badge.onTap = nil;
        if (animated && wasShowing) {
            info.badgeOutUntil = CACurrentMediaTime() + RXT_BADGE_OUT_TIME;
            [badge setModel:nil animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((RXT_BADGE_OUT_TIME + 0.05) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UITableViewCell *faded = weakCell;
                if (faded) {
                    RXTranscriptLayoutCell(faded);
                }
            });
        } else {
            info.badgeOutUntil = 0;
            [badge setModel:nil animated:NO];
            badge.hidden = YES;
        }
    }

    // Quote (DESIGN 11): on the reply's first row; tappable only when the parent is loaded.
    if (link) {
        if (!quote) {
            quote = [[RXQuoteBalloonView alloc] initWithFrame:CGRectZero];
            objc_setAssociatedObject(cell, &kRXTQuoteViewKey, quote, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSInteger parentRow = RXTRowForGUIDPart(data, link.parentGUID, link.partKey);
        if (quote.wallpaper != wallpaper) {
            quote.wallpaper = wallpaper;
        }
        quote.link = link;
        quote.thumbnail = (link.kind != RXTargetText) ? RXTPartThumbnail(data, parentRow) : nil;
        if (parentRow != NSNotFound && weakTC) {
            NSString *parentGUID = [link.parentGUID copy];
            NSInteger parentPart = link.partKey;
            quote.onTap = ^{
                CKTranscriptController *controller = weakTC;
                if (controller) {
                    RXTJumpToParent(controller, parentGUID, parentPart);
                }
            };
        } else {
            quote.onTap = nil;
        }
        info.hasQuote = YES;
    } else if (quote) {
        quote.onTap = nil;
        quote.link = nil;
        quote.thumbnail = nil;
        quote.hidden = YES;
        info.hasQuote = NO;
    }
    RXTranscriptLayoutCell(cell);
}

static void RXTClearCellViews(UITableViewCell *cell)
{
    RXReactionBalloonView *badge = objc_getAssociatedObject(cell, &kRXTBadgeViewKey);
    RXQuoteBalloonView *quote = objc_getAssociatedObject(cell, &kRXTQuoteViewKey);
    RXTCellInfo *info = objc_getAssociatedObject(cell, &kRXTCellInfoKey);
    if (badge) {
        badge.onTap = nil;
        [badge setModel:nil animated:NO];
        badge.hidden = YES;
    }
    if (quote) {
        quote.onTap = nil;
        quote.link = nil;
        quote.thumbnail = nil;
        quote.hidden = YES;
    }
    if (info) {
        info.hasBadge = NO;
        info.hasQuote = NO;
        info.badgeOutUntil = 0;
    }
}

static void RXTStripVisible(UITableView *table, BOOL clearViews)
{
    for (UITableViewCell *cell in [table visibleCells]) {
        if (!RXTIsMessageCell(cell)) {
            continue;
        }
        RXTStripCellSwipe(cell);
        if (clearViews) {
            RXTClearCellViews(cell);
        }
    }
}

static void RXTReapplyVisible(CKTranscriptController *tc, UITableView *table, NSSet *animateGUIDs)
{
    for (UITableViewCell *cell in [table visibleCells]) {
        if (!RXTIsMessageCell(cell)) {
            continue;
        }
        NSIndexPath *path = [table indexPathForCell:cell];
        if (!path) {
            continue;
        }
        RXTApplyCell(tc, table, cell, path, animateGUIDs);
        [cell setNeedsLayout];
    }
}

// Kill-switch reuse reset (cellForRow while Reactions is off): our views hidden and emptied, swipe
// animations stripped. No store access and no prefs (cleanup path).
void RXTranscriptResetCell(UITableViewCell *cell)
{
    if (!cell || !RXTMain()) {
        return;
    }
    if (RXTIsMessageCell(cell)) {
        RXTStripCellSwipe(cell);
    }
    RXTClearCellViews(cell);
}

void RXTranscriptConfigureCell(CKTranscriptController *tc, UITableView *table, UITableViewCell *cell,
                               NSIndexPath *path)
{
    if (!cell || !RXTMain() || !RXTIsMessageCell(cell)) {
        return;
    }
    RXTRegister(tc);
    RXTStripCellSwipe(cell);
    RXTApplyCell(tc, table, cell, path, nil);
}

// After -[CKMessageCell layoutSubviews]: z-order, visibility and our own frames from the balloon frame.
void RXTranscriptLayoutCell(UITableViewCell *cell)
{
    if (!cell) {
        return;
    }
    RXReactionBalloonView *badge = objc_getAssociatedObject(cell, &kRXTBadgeViewKey);
    RXQuoteBalloonView *quote = objc_getAssociatedObject(cell, &kRXTQuoteViewKey);
    if (!badge && !quote) {
        return;
    }
    RXTCellInfo *info = objc_getAssociatedObject(cell, &kRXTCellInfoKey);
    CKBalloonView *balloon = RXTBalloonOf(cell);
    UIView *host = balloon.superview;
    if (balloon && host) {
        RXTEnsureOrder(host, balloon, quote, badge);
    }
    // Edit mode centres the balloons, a hidden balloon is mid-throw or mid-preview: show nothing then.
    BOOL usable = info && balloon && host && !balloon.hidden && !cell.isEditing;
    BOOL outgoing = RXTBalloonIsOutgoing(balloon, info.outgoing);
    CGRect balloonFrame = balloon ? balloon.frame : CGRectZero;
    CGRect bounds = host ? host.bounds : CGRectZero;

    if (badge) {
        RXBadgeModel *model = badge.model;
        if (usable && info.hasBadge && model && !model.isEmpty) {
            badge.hidden = NO;
            if (badge.outgoing != outgoing) {
                badge.outgoing = outgoing;
            }
            [badge layoutForBalloonFrame:balloonFrame outgoing:outgoing inBounds:bounds];
        } else {
            BOOL fadingOut = usable && !info.hasBadge && info.badgeOutUntil > CACurrentMediaTime();
            if (!fadingOut) {
                badge.hidden = YES;
            }
        }
    }
    if (quote) {
        if (usable && info.hasQuote && quote.link && !RXTQuoteDeferred(info.guid)) {
            quote.hidden = NO;
            [quote layoutForReplyBalloonFrame:balloonFrame
                                replyOutgoing:outgoing
                                    withBadge:info.hasBadge
                                     inBounds:bounds];
        } else {
            quote.hidden = YES;
        }
    }
}

// DESIGN 5.4: badge band 15 + (quote height + 2); 0 while editing.
CGFloat RXTranscriptExtraHeight(CKTranscriptController *tc, UITableView *table, NSInteger row)
{
    if (!tc || !table || !RXTMain() || table.isEditing) {
        return 0;
    }
    RXPrefs prefs = RXGetPrefs();
    BOOL wantBadge = prefs.enabled && prefs.badges;
    BOOL wantQuote = prefs.enabled && prefs.quotes;
    if ((!wantBadge && !wantQuote) || table != RXTTableFor(tc)) {
        return 0;
    }
    RXBadgeModel *badge = nil;
    RXReplyLink *link = nil;
    if (!RXTResolveRow(RXTDataFor(tc), row, wantBadge, wantQuote, NULL, NULL, NULL, &badge, &link)) {
        return 0;
    }
    CGFloat extra = 0;
    if (badge) {
        extra += RX_BADGE_ROW_EXTRA;
    }
    if (link) {
        // The quote lays itself out from the cell bounds (= table width), so measure with the same width.
        CGFloat quoteHeight = [RXQuoteBalloonView heightForLink:link width:table.bounds.size.width];
        if (quoteHeight > 0 && quoteHeight < 2000) {
            extra += quoteHeight + RX_QUOTE_GAP;
            // Tap area >= 44 pt (DESIGN 11): UIKit never delivers a touch outside this row and the quote's
            // target must stop at the reply's body, so it can use the row's top margin, the quote, the gap,
            // the reply art's top halo and the badge band. Pad the row (space above the quote) if short.
            CGFloat reach = RXT_ROW_TOP_MARGIN + quoteHeight + RX_QUOTE_GAP + RXT_BODY_TOP_HALO +
                            (badge ? RX_BADGE_ROW_EXTRA : 0.0f);
            if (reach < RXT_MIN_TAP) {
                extra += ceilf(RXT_MIN_TAP - reach);
            }
        }
    }
    return extra;
}

#pragma mark - Gated refresh / reload (DESIGN 5.6)

static CGFloat RXTMaxOffsetY(UITableView *table)
{
    UIEdgeInsets insets = table.contentInset;
    CGFloat maxY = table.contentSize.height + insets.bottom - table.bounds.size.height;
    return MAX(-insets.top, maxY);
}

static RXTAnchor *RXTCaptureAnchor(CKTranscriptController *tc, UITableView *table)
{
    RXTAnchor *anchor = [[RXTAnchor alloc] init];
    CGPoint offset = table.contentOffset;
    anchor.pinned = offset.y >= RXTMaxOffsetY(table) - 1.0f;
    CKTranscriptBubbleData *data = RXTDataFor(tc);
    if (!data) {
        return anchor;
    }
    NSInteger count = (NSInteger)[data count];
    CGFloat visibleTop = offset.y + table.contentInset.top;
    NSArray *paths = [[table indexPathsForVisibleRows] sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *path in paths) {
        if (path.section != 0 || path.row >= count) {
            continue;
        }
        CGRect rect = [table rectForRowAtIndexPath:path];
        if (CGRectGetMaxY(rect) <= visibleTop || ![data partAtIndex:(int)path.row]) {
            continue;
        }
        NSString *guid = RXTGUIDOf([data messageAtIndex:(int)path.row]);
        if (!guid) {
            continue;
        }
        anchor.guid = guid;
        anchor.row = path.row;
        anchor.partKey = RXTranscriptPartKeyForRow(data, path.row);
        anchor.delta = CGRectGetMaxY(rect) - offset.y;    // bubbles are bottom-anchored: keep the bubble still
        break;
    }
    return anchor;
}

// Pinned -> stay at the bottom; else keep the anchor bubble where it was (content grows upward).
static void RXTRestoreAnchor(CKTranscriptController *tc, UITableView *table, RXTAnchor *anchor, BOOL animated)
{
    if (!anchor || !table) {
        return;
    }
    if ([table respondsToSelector:@selector(ignoresContentOffsetChanges)] && [table ignoresContentOffsetChanges]) {
        return;
    }
    CGPoint offset = table.contentOffset;
    CGFloat minY = -table.contentInset.top;
    CGFloat maxY = RXTMaxOffsetY(table);
    CGFloat target = offset.y;
    if (anchor.pinned) {
        target = maxY;
    } else if (anchor.guid) {
        CKTranscriptBubbleData *data = RXTDataFor(tc);
        NSInteger rows = [table numberOfSections] > 0 ? [table numberOfRowsInSection:0] : 0;
        NSInteger row = NSNotFound;
        if (data && anchor.row != NSNotFound && anchor.row < rows && anchor.row < (NSInteger)[data count]) {
            NSString *guid = RXTGUIDOf([data messageAtIndex:(int)anchor.row]);
            if ([guid isEqualToString:anchor.guid] && RXTranscriptPartKeyForRow(data, anchor.row) == anchor.partKey) {
                row = anchor.row;
            }
        }
        if (row == NSNotFound && data) {
            row = RXTRowForGUIDPart(data, anchor.guid, anchor.partKey);
        }
        if (row == NSNotFound || row >= rows) {
            return;
        }
        CGRect rect = [table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        target = CGRectGetMaxY(rect) - anchor.delta;
    } else {
        return;
    }
    target = MAX(minY, MIN(target, maxY));
    if (fabs((double)(target - offset.y)) <= 0.5) {
        return;
    }
    [table setContentOffset:CGPointMake(offset.x, target) animated:animated];
}

// nil = open. `editingRefresh`: the setEditing: refresh, exempt from !isEditing (and from the picker, which the
// editing teardown is fading out).
static NSString *RXTGateClosedReason(CKTranscriptController *tc, BOOL editingRefresh)
{
    if (gBuildDepth > 0 || gOwnReloadDepth > 0) {
        return @"build";
    }
    if (![tc isViewLoaded] || !tc.view.window) {
        return @"offscreen";
    }
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        return @"inactive";
    }
    if (RXResponds(tc, @selector(_isHoldingUpdatesToTranscript)) && [tc _isHoldingUpdatesToTranscript]) {
        return @"hold";
    }
    if (RXResponds(tc, @selector(isSendingMessage)) && [tc isSendingMessage]) {
        return @"sending";
    }
    UITableView *table = RXTTableFor(tc);
    CKTranscriptBubbleData *data = RXTDataFor(tc);
    if (!table || !data) {
        return @"table";
    }
    if (!editingRefresh && table.isEditing) {
        return @"editing";
    }
    if (table.isDragging) {
        return @"dragging";
    }
    if (table.isDecelerating) {
        return @"decelerating";
    }
    for (UIGestureRecognizer *recognizer in table.gestureRecognizers) {
        UIGestureRecognizerState state = recognizer.state;
        if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
            return @"gesture";
        }
    }
    if (RXSwipeSessionActive()) {
        return @"swipe";
    }
    if (!editingRefresh && RXPickerIsOpen(tc)) {
        return @"picker";
    }
    if ([table numberOfSections] < 1) {
        return @"sections";
    }
    if ([table numberOfRowsInSection:0] != (NSInteger)[data count]) {
        return @"count";
    }
    return nil;
}

static void RXTDropPending(RXTState *state)
{
    state.needsRefresh = NO;
    state.needsReload = NO;
    state.editingRefresh = NO;
    [state.dirtyGUIDs removeAllObjects];
    state.chatKey = nil;
    state.retries = 0;
    state.gaveUp = NO;
}

static void RXTAttempt(CKTranscriptController *tc);

static void RXTQueueAttempt(CKTranscriptController *tc)
{
    if (!tc || !RXTAlive(tc)) {
        return;
    }
    RXTState *state = RXTStateFor(tc, YES);
    if (!state || state.attemptQueued) {
        return;
    }
    state.attemptQueued = YES;
    __weak CKTranscriptController *weakTC = tc;
    dispatch_async(dispatch_get_main_queue(), ^{
        CKTranscriptController *controller = weakTC;
        if (!controller) {
            return;
        }
        RXTState *current = RXTStateFor(controller, NO);
        if (current) {
            current.attemptQueued = NO;
        }
        RXTAttempt(controller);
    });
}

static void RXTArmRetry(CKTranscriptController *tc, RXTState *state, NSString *why)
{
    if (state.timerArmed) {
        return;
    }
    if (state.retries >= RXT_RETRY_MAX) {
        if (!state.gaveUp) {
            state.gaveUp = YES;
            RXLog(@"transcript gate still closed (%@) after %ld tries; waiting for an event", why,
                  (long)state.retries);
        }
        return;
    }
    if (state.retries == 0) {
        RXLog(@"transcript gate closed (%@); retrying", why);
    }
    state.retries++;
    state.timerArmed = YES;
    __weak CKTranscriptController *weakTC = tc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RXT_RETRY_INTERVAL * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CKTranscriptController *controller = weakTC;
        if (!controller) {
            return;
        }
        RXTState *current = RXTStateFor(controller, NO);
        if (!current) {
            return;
        }
        current.timerArmed = NO;
        RXTAttempt(controller);
    });
}

// Votes changed on rows already in the table: heights + view data, then the anchor.
static void RXTDoRefresh(CKTranscriptController *tc, RXTState *state)
{
    UITableView *table = RXTTableFor(tc);
    if (!table) {
        return;
    }
    NSSet *animate = [state.dirtyGUIDs copy];
    state.needsRefresh = NO;
    state.editingRefresh = NO;             // a height refresh covers the deferred setEditing: one
    [state.dirtyGUIDs removeAllObjects];
    state.retries = 0;
    state.gaveUp = NO;
    if (!state.needsReload) {
        state.chatKey = nil;
    }
    RXTAnchor *anchor = RXTCaptureAnchor(tc, table);
    [table beginUpdates];
    [table endUpdates];
    RXTReapplyVisible(tc, table, animate);
    RXTRestoreAnchor(tc, table, anchor, YES);
    RXLog(@"refresh: %lu changed target(s), pinned %d", (unsigned long)[animate count], (int)anchor.pinned);
}

// Visibility changed after the fact (late match, failed reaction, prefs): ChatKit's own forced reload.
static void RXTDoReload(CKTranscriptController *tc, RXTState *state)
{
    UITableView *table = RXTTableFor(tc);
    RXTDropPending(state);
    if (!table || !RXResponds(tc, @selector(_reloadTranscriptLayerForcingBubbleDataReload:))) {
        return;
    }
    RXTAnchor *anchor = RXTCaptureAnchor(tc, table);
    gOwnReloadDepth++;
    [tc _reloadTranscriptLayerForcingBubbleDataReload:YES];
    gOwnReloadDepth--;
    RXTRestoreAnchor(tc, table, anchor, NO);
    CKTranscriptBubbleData *data = RXTDataFor(tc);
    RXLog(@"reload: %d rows, pinned %d", data ? [data count] : 0, (int)anchor.pinned);
}

static void RXTAttempt(CKTranscriptController *tc)
{
    if (!tc || !RXTMain() || !RXTAlive(tc)) {
        return;
    }
    RXTState *state = RXTStateFor(tc, YES);
    if (!state) {
        return;
    }
    RXTRevealQuotes(tc, NO);
    NSString *chatKey = RXTChatKeyForTC(tc);
    RXStore *store = chatKey ? [RXStore storeForChatKey:chatKey create:NO] : nil;
    if (store) {
        NSSet *dirty = [store takeDirtyGUIDs];
        if ([dirty count]) {
            state.needsRefresh = YES;
            [state.dirtyGUIDs unionSet:dirty];
            if (!state.chatKey) {
                state.chatKey = chatKey;
            }
        }
        if ([store takeNeedsReload]) {
            state.needsReload = YES;
            if (!state.chatKey) {
                state.chatKey = chatKey;
            }
        }
    }
    if (!state.needsRefresh && !state.needsReload && !state.editingRefresh) {
        state.retries = 0;
        state.gaveUp = NO;
        return;
    }
    if (!chatKey || (state.chatKey && ![state.chatKey isEqualToString:chatKey])) {
        RXLog(@"transcript: pending work dropped (chat changed)");
        RXTDropPending(state);
        return;
    }
    NSString *why = RXTGateClosedReason(tc, NO);
    if (why && state.editingRefresh && [why isEqualToString:@"editing"]) {
        // The deferred setEditing: height refresh keeps its exemption from edit mode on every retry
        // (DESIGN 5.4); a pending reload still waits for edit mode to end.
        NSString *exempt = RXTGateClosedReason(tc, YES);
        if (!exempt) {
            RXTDoRefresh(tc, state);
            if (!state.needsReload) {
                return;
            }
        } else {
            why = exempt;
        }
    }
    if (why) {
        RXTArmRetry(tc, state, why);
        return;
    }
    if (state.needsReload) {
        RXTDoReload(tc, state);
    } else {
        RXTDoRefresh(tc, state);
    }
}

static void RXTSchedule(CKTranscriptController *tc, BOOL reload)
{
    if (!tc || !RXTMain() || !RXTAlive(tc)) {
        return;
    }
    RXTRegister(tc);
    RXTState *state = RXTStateFor(tc, YES);
    if (reload) {
        state.needsReload = YES;
    } else {
        state.needsRefresh = YES;
    }
    if (!state.chatKey) {
        state.chatKey = RXTChatKeyForTC(tc);
    }
    RXTQueueAttempt(tc);
}

void RXTranscriptScheduleRefresh(CKTranscriptController *tc)
{
    RXTSchedule(tc, NO);
}

void RXTranscriptScheduleReload(CKTranscriptController *tc)
{
    RXTSchedule(tc, YES);
}

void RXTranscriptPoke(CKTranscriptController *tc)
{
    if (!tc || !RXTMain() || !RXTAlive(tc)) {
        return;
    }
    RXTRegister(tc);
    RXTState *state = RXTStateFor(tc, YES);
    state.retries = 0;
    state.gaveUp = NO;
    RXTQueueAttempt(tc);
}

// Right after -setEditing:animated: %orig, inside the same transition (DESIGN 5.4).
void RXTranscriptEditingChanged(CKTranscriptController *tc)
{
    if (!tc || !RXTMain() || !RXTAlive(tc)) {
        return;
    }
    RXTRegister(tc);
    UITableView *table = RXTTableFor(tc);
    if (!table) {
        return;
    }
    NSString *why = RXTGateClosedReason(tc, YES);
    if (why) {
        // Retried as an editing refresh, so the exemption from !isEditing survives (RXTAttempt).
        RXLog(@"edit-mode height refresh deferred (%@)", why);
        RXTState *state = RXTStateFor(tc, YES);
        if (state) {
            state.editingRefresh = YES;
            if (!state.chatKey) {
                state.chatKey = RXTChatKeyForTC(tc);
            }
            RXTQueueAttempt(tc);
        }
        return;
    }
    RXTState *pending = RXTStateFor(tc, NO);
    if (pending) {
        pending.editingRefresh = NO;       // covered by this refresh
    }
    RXTAnchor *anchor = RXTCaptureAnchor(tc, table);
    [table beginUpdates];
    [table endUpdates];
    RXTReapplyVisible(tc, table, nil);
    RXTRestoreAnchor(tc, table, anchor, YES);
}

static void RXTRestyleNow(CKTranscriptController *tc)
{
    UITableView *table = RXTTableFor(tc);
    if (!table) {
        return;
    }
    BOOL wallpaper = RXTableIsWallpapered(table);
    for (UITableViewCell *cell in [table visibleCells]) {
        RXReactionBalloonView *badge = objc_getAssociatedObject(cell, &kRXTBadgeViewKey);
        RXQuoteBalloonView *quote = objc_getAssociatedObject(cell, &kRXTQuoteViewKey);
        if (badge) {
            if (badge.wallpaper != wallpaper) {
                badge.wallpaper = wallpaper;
            }
            [badge setNeedsDisplay];
        }
        if (quote) {
            if (quote.wallpaper != wallpaper) {
                quote.wallpaper = wallpaper;
            }
            [quote setNeedsDisplay];
        }
    }
}

// viewWillAppear: / setConversation: (after %orig): MW style now and on the next run loop, then pending work.
void RXTranscriptRestyle(CKTranscriptController *tc)
{
    if (!tc || !RXTMain() || !RXTAlive(tc)) {
        return;
    }
    RXTRestyleNow(tc);
    __weak CKTranscriptController *weakTC = tc;
    dispatch_async(dispatch_get_main_queue(), ^{
        CKTranscriptController *controller = weakTC;
        if (controller) {
            RXTRestyleNow(controller);
            RXTQueueAttempt(controller);
        }
    });
}

#pragma mark - Build and append (DESIGN 5.1)

// Restarts the building chat's store (keeps reply links, the matched list and optimistic votes).
static void RXTRestartBuildStore(void)
{
    gBuildNeedsRestart = NO;
    if (!gBuildChatKey) {
        return;
    }
    RXPrefs prefs = RXGetPrefs();
    BOOL wanted = prefs.enabled && (prefs.badges || prefs.quotes);
    RXStore *store = [RXStore storeForChatKey:gBuildChatKey create:wanted];
    [store restartBuild];
}

void RXTranscriptBuildBegin(CKTranscriptController *tc)
{
    if (!RXTMain()) {
        return;
    }
    gBuildDepth++;
    if (gBuildDepth > 1) {
        return;
    }
    BOOL alive = tc && RXTAlive(tc);
    gBuildTC = alive ? tc : nil;
    gBuildChatKey = alive ? RXTChatKeyForTC(tc) : nil;
    gBuildOldData = alive ? RXTDataFor(tc) : nil;
    gBuildNeedsRestart = (gBuildChatKey != nil);   // done on the first append (see the header comment)
    gBuildAppends = 0;
    gBuildHidden = 0;
    gBuildRetargets = 0;
    gBuildReadTarget = nil;
    if (alive) {
        RXTRegister(tc);
    }
}

void RXTranscriptBuildEnd(CKTranscriptController *tc)
{
    if (!RXTMain() || gBuildDepth <= 0) {
        return;
    }
    gBuildDepth--;
    if (gBuildDepth > 0) {
        return;
    }
    CKTranscriptController *controller = gBuildTC;
    if (!controller && tc && RXTAlive(tc)) {
        controller = tc;
    }
    NSString *chatKey = gBuildChatKey;
    CKTranscriptBubbleData *data = controller ? RXTDataFor(controller) : nil;
    BOOL rebuilt = data && data != gBuildOldData;
    if (rebuilt && gBuildNeedsRestart) {
        RXTRestartBuildStore();            // a rebuild that appended nothing (empty conversation)
    }
    if (rebuilt) {
        RXTTagData(data, controller);
    }
    RXLog(@"build: rebuilt %d, %lu messages, %lu hidden, %lu status retargets, %d rows", (int)rebuilt,
          (unsigned long)gBuildAppends, (unsigned long)gBuildHidden, (unsigned long)gBuildRetargets,
          data ? [data count] : 0);
    gBuildTC = nil;
    gBuildChatKey = nil;
    gBuildOldData = nil;
    gBuildReadTarget = nil;
    gBuildNeedsRestart = NO;
    if (!rebuilt || !controller) {
        return;                            // early return inside ChatKit: nothing changed, keep pending work
    }

    BOOL reload = NO;
    RXStore *store = chatKey ? [RXStore storeForChatKey:chatKey create:NO] : nil;
    if (store) {
        [store takeDirtyGUIDs];            // the table is rebuilt from scratch right after a build
        reload = [store takeNeedsReload];  // a late match inside the build
    }
    RXTState *state = RXTStateFor(controller, YES);
    if (!state) {
        return;
    }
    state.needsRefresh = NO;               // the rebuild covers whatever was pending
    state.needsReload = NO;
    state.editingRefresh = NO;
    [state.dirtyGUIDs removeAllObjects];
    state.chatKey = nil;
    if (!reload) {
        state.chainedReloads = 0;
        return;
    }
    // A late match inside a build: the matched list now hides it, so one more (gated) reload settles it.
    // The store reports each GUID once; never chain more than one reload from our own reloads anyway.
    if (gOwnReloadDepth > 0 && state.chainedReloads >= 1) {
        RXLog(@"build: late match inside a chained reload; not reloading again");
        state.chainedReloads = 0;
        return;
    }
    state.chainedReloads = (gOwnReloadDepth > 0) ? state.chainedReloads + 1 : 0;
    RXTSchedule(controller, YES);
}

void RXTranscriptBubbleDataCleared(CKTranscriptBubbleData *data)
{
    if (!data || !RXTMain() || gBuildDepth > 0) {
        return;                            // inside a build the build context owns the restart
    }
    RXTBubbleTag *tag = objc_getAssociatedObject(data, &kRXTTagKey);
    NSString *chatKey = tag.chatKey;
    if (!chatKey) {
        chatKey = RXTChatKeyForTC(RXTControllerForData(data));
    }
    if (!chatKey) {
        return;
    }
    RXStore *store = [RXStore storeForChatKey:chatKey create:NO];
    if (store) {
        [store restartBuild];
        RXLog(@"bubble data cleared: store restarted");
    }
}

void RXTranscriptSetInOwnSend(BOOL inside)
{
    if (!RXTMain()) {
        return;
    }
    if (inside) {
        gOwnSendDepth++;
    } else if (gOwnSendDepth > 0) {
        gOwnSendDepth--;
    }
}

BOOL RXTranscriptShouldHideAppend(CKTranscriptBubbleData *data, id message)
{
    if (!RXTMain()) {
        return NO;
    }
    if (gBuildDepth > 0 && gBuildNeedsRestart) {
        RXTRestartBuildStore();            // the first append proves this build really rebuilds
    }
    if (!message || !RXTIsRealMessage(message)) {
        return NO;
    }
    NSString *guid = RXTGUIDOf(message);
    NSString *chatKey = guid ? RXChatKeyForMessage(message) : nil;
    if (!chatKey) {
        return NO;
    }
    BOOL inBuild = gBuildDepth > 0;
    BOOL ownSend = gOwnSendDepth > 0;
    RXPrefs prefs = RXGetPrefs();
    CKTranscriptController *tc = RXTControllerForData(data);    // tags the instance on its first append

    // A reply we are sending right now: its quote waits for the throw to finish, then fades in.
    if (ownSend && prefs.enabled && prefs.quotes) {
        RXStore *linkStore = [RXStore storeForChatKey:chatKey create:NO];
        if ([linkStore replyLinkForGUID:guid]) {
            RXTDeferQuote(guid, tc);
        }
    }
    if (!(prefs.enabled && prefs.badges)) {
        return NO;
    }
    RXStore *store = [RXStore storeForChatKey:chatKey create:YES];
    if (!store) {
        return NO;
    }
    BOOL hide;
    if (!inBuild && [store isKnownGUID:guid]) {
        hide = [store isHiddenGUID:guid];   // re-append into the same instance: same answer, no double ingest
    } else {
        hide = [store ingestMessage:(CKIMMessage *)message allowHide:!ownSend];
    }
    if (ownSend) {
        hide = NO;                          // the send throw needs its rows
    }
    if (inBuild) {
        gBuildAppends++;
        if (hide) {
            gBuildHidden++;
        }
    } else if (tc) {
        RXTQueueAttempt(tc);                // picks up dirty targets / late matches through the gate
    }
    return hide;
}

BOOL RXTranscriptIsHiddenMessage(id message)
{
    if (!message || !RXTMain()) {
        return NO;
    }
    RXPrefs prefs = RXGetPrefs();
    if (!(prefs.enabled && prefs.badges)) {
        return NO;
    }
    NSString *guid = RXTGUIDOf(message);
    NSString *chatKey = guid ? RXChatKeyForMessage(message) : nil;
    if (!chatKey) {
        return NO;
    }
    RXStore *store = [RXStore storeForChatKey:chatKey create:NO];
    return store ? [store isHiddenGUID:guid] : NO;
}

BOOL RXTranscriptInBuild(void)
{
    return gBuildDepth > 0;
}

#pragma mark - Status rows (DESIGN 5.2)

// Newest message before `hidden` (conversation order = the build's order) that is outgoing, not failed, not
// hidden, and has rows in `data`.
static CKIMMessage *RXTPreviousVisibleOutgoing(CKTranscriptBubbleData *data, CKIMMessage *hidden, RXStore *store)
{
    CKConversation *conversation = [hidden respondsToSelector:@selector(conversation)] ? [hidden conversation] : nil;
    if (!conversation) {
        CKTranscriptController *tc = RXTControllerForData(data);
        if (!tc) {
            tc = gBuildTC;
        }
        if (tc && RXResponds(tc, @selector(conversation))) {
            conversation = [tc conversation];
        }
    }
    NSArray *messages = [conversation respondsToSelector:@selector(messages)] ? [conversation messages] : nil;
    if (![messages isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSUInteger index = [messages indexOfObjectIdenticalTo:hidden];
    if (index == NSNotFound) {
        index = [messages indexOfObject:hidden];
    }
    if (index == NSNotFound) {
        return nil;
    }
    Class messageClass = NSClassFromString(@"CKIMMessage");
    NSUInteger rows = (NSUInteger)MAX(0, [data count]);
    NSUInteger scanned = 0;
    while (index > 0 && scanned < RXT_STATUS_SCAN_MAX) {
        index--;
        scanned++;
        CKIMMessage *candidate = [messages objectAtIndex:index];
        if (messageClass && ![candidate isKindOfClass:messageClass]) {
            continue;
        }
        if (!RXTIsRealMessage(candidate) || !RXTIsFromMe(candidate) || RXTMessageFailed(candidate)) {
            continue;
        }
        NSString *guid = RXTGUIDOf(candidate);
        if (!guid || (store && [store isHiddenGUID:guid])) {
            continue;
        }
        NSUInteger last = [data lastIndexForMessage:candidate];
        if (last == NSNotFound || last >= rows) {
            continue;
        }
        return candidate;
    }
    return nil;
}

id RXTranscriptStatusTarget(CKTranscriptBubbleData *data, int status, id message)
{
    if (!message || !RXTMain()) {
        return message;
    }
    BOOL inBuild = gBuildDepth > 0;
    if (!RXTranscriptIsHiddenMessage(message)) {
        if (inBuild && status == 2) {
            gBuildReadTarget = message;
        }
        return message;
    }
    // Hidden: live path -> NSNotFound (a tapback never moves Delivered/Read). Build -> statuses 1/2 only.
    if (!inBuild || (status != 1 && status != 2) || !RXTDataOK(data)) {
        return nil;
    }
    NSString *chatKey = RXChatKeyForMessage(message);
    if (!chatKey) {
        chatKey = gBuildChatKey;
    }
    RXStore *store = chatKey ? [RXStore storeForChatKey:chatKey create:NO] : nil;
    CKIMMessage *target = RXTPreviousVisibleOutgoing(data, (CKIMMessage *)message, store);
    if (!target) {
        return nil;
    }
    if (status == 1) {
        // Read (status 2) is inserted first; Delivered must stay strictly below it, never on the same bubble.
        // A read target can't take Delivered either (covers a hook layer that skips visible status calls).
        if ([target respondsToSelector:@selector(isRead)] && [target isRead]) {
            return nil;
        }
        if (gBuildReadTarget) {
            if (RXTSameMessage(target, gBuildReadTarget)) {
                return nil;
            }
            NSUInteger readRow = [data lastIndexForMessage:gBuildReadTarget];
            NSUInteger targetRow = [data lastIndexForMessage:target];
            if (readRow != NSNotFound && targetRow != NSNotFound && targetRow <= readRow) {
                return nil;
            }
        }
    }
    if (status == 2) {
        gBuildReadTarget = target;
    }
    gBuildRetargets++;
    return target;
}

NSIndexSet *RXTranscriptFilterReloads(CKTranscriptController *tc, NSIndexSet *reloaded)
{
    if (![reloaded isKindOfClass:[NSIndexSet class]] || [reloaded count] == 0 || !RXTMain()) {
        return reloaded;
    }
    CKTranscriptBubbleData *data = RXTDataFor(tc);
    if (!data) {
        return reloaded;
    }
    NSUInteger count = (NSUInteger)MAX(0, [data count]);
    NSUInteger last = [reloaded lastIndex];
    if (last < count) {
        return reloaded;
    }
    NSMutableIndexSet *kept = [reloaded mutableCopy];
    [kept removeIndexesInRange:NSMakeRange(count, last - count + 1)];
    RXLog(@"reload filter: dropped %lu index(es) >= %lu", (unsigned long)([reloaded count] - [kept count]),
          (unsigned long)count);
    return kept;
}

// From -[CKTranscriptTransaction messageErrorChanged:]: a hidden reaction that failed becomes visible again
// (stock Not Delivered / red ! / Try Again) through a gated reload (the hook skips %orig for it); a visible
// failed one (called after %orig) just loses its vote / optimistic entry. _dequeueStatusActions sends
// messageErrorChanged: for EVERY error change and only then checks failedSend / partiallyFailedSend
// (CK@0xa0f8-0xa11c), so a change that is not a failure (e.g. an error cleared on a resend) changes nothing:
// the hidden reaction keeps its matched-list entry and its vote.
void RXTranscriptMessageErrorChanged(id message)
{
    if (!message || !RXTMain()) {
        return;
    }
    NSString *guid = RXTGUIDOf(message);
    NSString *chatKey = guid ? RXChatKeyForMessage(message) : nil;
    if (!chatKey) {
        return;
    }
    RXStore *store = [RXStore storeForChatKey:chatKey create:NO];
    if (!store) {
        return;
    }
    if (!RXTMessageFailed(message)) {
        return;                             // not a failure: the hook already skipped %orig for hidden rows
    }
    BOOL hidden = [store isHiddenGUID:guid];
    [store messageFailed:(CKIMMessage *)message];
    RXLog(@"error change %@: failed, hidden %d", RXGUIDTail(guid), (int)hidden);
    for (CKTranscriptController *tc in [gControllers allObjects]) {
        NSString *key = RXTChatKeyForTC(tc);
        if (!key || ![key isEqualToString:chatKey]) {
            continue;
        }
        if (hidden) {
            RXTranscriptScheduleReload(tc);
        } else {
            RXTQueueAttempt(tc);            // refreshes only if the store reports changed targets
        }
    }
}

#pragma mark - Teardown (DESIGN 5.7)

// One teardown for every trigger. Never reads prefs. Reply mode is left only on a prefs change (DESIGN 12:
// every chat's reply state is dropped and tc's entry shrinks); a pop is handled by the hook layer
// (RXReplyControllerPopped), a chat switch by RXReplyConversationChanged.
void RXTeardown(CKTranscriptController *tc, RXTeardownReason reason)
{
    if (!tc || !RXTMain()) {
        return;
    }
    BOOL hadPicker = RXPickerIsOpen(tc);
    BOOL hadSwipe = RXSwipeSessionActive();
    BOOL animated = (reason == RXTeardownEditing || reason == RXTeardownPrefs);
    RXPickerDismiss(tc, animated);
    RXSwipeTeardown(tc);
    if (reason == RXTeardownDealloc) {
        // The controller is deallocating: no weak references, no scheduling, no table work.
        return;
    }
    UITableView *table = RXTTableFor(tc);
    if (table) {
        RXTStripVisible(table, reason == RXTeardownPrefs);
    }
    if (reason == RXTeardownPrefs) {
        RXReplyResetAll(tc);
    }
    BOOL dropped = NO;
    RXTState *state = RXTStateFor(tc, NO);
    if (state && (reason == RXTeardownConversation || reason == RXTeardownUnload)) {
        dropped = state.needsRefresh || state.needsReload || state.editingRefresh;
        RXTDropPending(state);
    }
    if (reason == RXTeardownPrefs) {
        RXTSchedule(tc, YES);              // one gated reload once the new prefs are in
    } else if (reason == RXTeardownResetHolds) {
        RXTQueueAttempt(tc);               // ChatKit's holds are gone: pending work may run now
    }
    // Teardown runs on every disappear / rotation / suspend / edit toggle, also with Reactions off: log
    // only when something was actually torn down.
    if (hadPicker || hadSwipe || dropped || reason == RXTeardownPrefs || reason == RXTeardownResetHolds) {
        RXLog(@"teardown: reason %d (picker %d, swipe %d, dropped %d)", (int)reason, (int)hadPicker,
              (int)hadSwipe, (int)dropped);
    }
}
