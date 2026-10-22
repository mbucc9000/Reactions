// Reactions 2.0 - Tweak.x: every Logos hook, kept thin. Each hook forwards into the module APIs
// declared in RXShared.h, as DESIGN.md (v2.1) specifies; all behaviour lives in the RX*.m modules.
//
// How this file behaves:
//  * Kill switch: while !RXGetPrefs().enabled every hook only calls the original. Teardown and
//    cleanup paths (RXTeardown, picker dismissal, reply-pop, the swipe-animation strip, the
//    kill-switch cell reset, the reply bar's frame/layout follow-up, which only acts on state
//    that already exists, and the event retries that drain pending work - RXTranscriptPoke and
//    RXReplyRetryPendingResize, e.g. the reload and the bar collapse a prefs change queued) still
//    run, because cleanup never checks prefs (DESIGN 2).
//  * Dealloc guard: -[CKTranscriptController dealloc] re-enters these hooks (it calls
//    _cancelMessageSendAnimation, which ends the throw hold and reloads rows). While any controller
//    is inside our dealloc hook, every hook passes straight through, so no module ever forms a
//    weak reference to a deallocating controller (fatal on the iOS 6 runtime).
//  * Main thread only: off the main thread every hook passes straight through.
//  * ChatKit classes are reached by name only (Logos looks them up with objc_getClass).
//  * Encodings match the device class dump ChatKit.objc.txt (line numbers in comments).

#import "RXShared.h"

#pragma mark - Glue state

static NSHashTable *gRXTControllers;   // live CKTranscriptControllers (weak), walked on prefs changes
static int gRXTDeallocDepth;            // > 0 while a CKTranscriptController is inside our dealloc hook
static int gRXTTeardownDepth;           // > 0 while RXTeardown runs (suppresses re-entrant pokes)

// Cleanup paths: everything except a deallocating controller or a background thread.
static BOOL RXTLive(void) {
    return gRXTDeallocDepth == 0 && [NSThread isMainThread];
}

// Feature paths: cleanup conditions plus the master switch.
static BOOL RXTActive(void) {
    return RXTLive() && RXGetPrefs().enabled;
}

// Hiding paths (append filter + every "is this message hidden" hook) share one condition, so a
// message is never treated as hidden while the append hook is letting its rows through.
static BOOL RXTHiding(void) {
    return RXTActive() && RXOn(RXGetPrefs().badges);
}

static void RXTTrack(CKTranscriptController *tc) {
    if (tc && gRXTControllers && RXTLive()) {
        [gRXTControllers addObject:tc];
    }
}

// The single teardown (DESIGN 5.7). Never checks prefs. While a controller deallocates, only its
// own dealloc teardown runs (stock dealloc can re-enter teardown hooks such as setEditing:animated:).
static void RXTTeardown(CKTranscriptController *tc, RXTeardownReason reason) {
    if (!tc || (gRXTDeallocDepth > 0 && reason != RXTeardownDealloc)) {
        return;
    }
    gRXTTeardownDepth++;
    RXTeardown(tc, reason);
    gRXTTeardownDepth--;
}

// Popped (or dismissed): reply state for this controller is dropped (DESIGN 5.7 / 10).
static BOOL RXTIsLeaving(CKTranscriptController *tc) {
    if ([tc isMovingFromParentViewController] || [tc isBeingDismissed]) {
        return YES;
    }
    UINavigationController *nav = [tc navigationController];
    return nav && ([nav isMovingFromParentViewController] || [nav isBeingDismissed]);
}

static BOOL RXTIsTranscriptTable(CKTranscriptController *tc, UITableView *table) {
    return table && RXResponds(tc, @selector(transcriptTable)) && [tc transcriptTable] == table;
}

// DESIGN 5.1 first lines: typing indicators, placeholders, GUID-less or chat-less messages are never ingested.
static BOOL RXTIngestible(id message) {
    if (!message) {
        return NO;
    }
    CKIMMessage *msg = message;
    if ([msg respondsToSelector:@selector(isTypingIndicator)] && [msg isTypingIndicator]) {
        return NO;
    }
    if ([msg respondsToSelector:@selector(isPlaceholder)] && [msg isPlaceholder]) {
        return NO;
    }
    NSString *guid = [msg respondsToSelector:@selector(guid)] ? [msg guid] : nil;
    if ([guid length] == 0) {
        return NO;
    }
    return RXChatKeyForMessage(msg) != nil;
}

// DESIGN 7 trigger: the controller to open the picker in, or nil to let the stock double-tap run.
static CKTranscriptController *RXTPickerController(CKBalloonView *balloon, UIGestureRecognizer *recognizer) {
    if (!RXTActive() || !RXOn(RXGetPrefs().picker)) {
        return nil;
    }
    if (!recognizer || recognizer.state != UIGestureRecognizerStateEnded) {
        return nil;
    }
    if ([balloon respondsToSelector:@selector(isRestoring)] && [balloon isRestoring]) {
        return nil;
    }
    CKTranscriptController *tc = (CKTranscriptController *)RXControllerForView(balloon);
    if (!tc) {
        return nil;
    }
    UITableView *table = RXResponds(tc, @selector(transcriptTable)) ? [tc transcriptTable] : nil;
    if ([tc isEditing] || [table isEditing]) {
        return nil;
    }
    CKMessagePart *part = [balloon respondsToSelector:@selector(messagePart)] ? [balloon messagePart] : nil;
    CKIMMessage *msg = [part respondsToSelector:@selector(parentMessage)] ? [part parentMessage] : nil;
    if (!msg) {
        return nil;
    }
    // -[CKIMMessage pending] is YES for every received message (no sent count), so only outgoing ones count.
    if ([msg respondsToSelector:@selector(isFromMe)] && [msg isFromMe] &&
        [msg respondsToSelector:@selector(pending)] && [msg pending]) {
        return nil;
    }
    if ([msg respondsToSelector:@selector(failedSend)] && [msg failedSend]) {
        return nil;
    }
    if (!RXChatKeyForMessage(msg)) {
        return nil;
    }
    return tc;
}

// Entry size paths (DESIGN 10): content + H while in reply mode.
static CGSize RXTGrowEntrySize(UIView *entry, CGSize size) {
    if (!RXTActive()) {
        return size;
    }
    CGFloat extra = RXReplySizeExtra(entry);
    if (extra > 0 && size.height > 0) {
        size.height += extra;
    }
    return size;
}

// Entry frame paths (DESIGN 10): shifted by H exactly while the entry's current height includes H.
// The amount is H, not RXReplySizeExtra: after a reply is sent (or reply mode is left while ChatKit
// refuses the resize) the entry is still tall until it actually shrinks, and the field must stay
// under the strip until then. A cleanup path (it only follows an existing grown entry), so no
// kill-switch check: grown can only become YES while reply mode was on.
static CGRect RXTShiftEntryFrame(UIView *entry, CGRect frame, BOOL shrink) {
    if (!RXTLive() || !RXReplyFramesShifted(entry)) {
        return frame;
    }
    frame.origin.y += RX_REPLY_BAR_H;
    if (shrink) {
        CGFloat height = frame.size.height - RX_REPLY_BAR_H;
        frame.size.height = height > 0 ? height : 0;
    }
    return frame;
}

#pragma mark - Hook-install check (DESIGN 12: missing selectors listed once)

static const char *const kRXTHookTargets[][2] = {
    { "CKTranscriptController", "viewDidAppear:" },
    { "CKTranscriptController", "viewWillAppear:" },
    { "CKTranscriptController", "viewWillDisappear:" },
    { "CKTranscriptController", "viewDidUnload" },
    { "CKTranscriptController", "dealloc" },
    { "CKTranscriptController", "setConversation:" },
    { "CKTranscriptController", "setEditing:animated:" },
    { "CKTranscriptController", "willRotateToInterfaceOrientation:duration:" },
    { "CKTranscriptController", "prepareForSuspend" },
    { "CKTranscriptController", "resetHoldingUpdates" },
    { "CKTranscriptController", "_computeBubbleData:" },
    { "CKTranscriptController", "_reloadTranscriptLayerForcingBubbleDataReload:" },
    { "CKTranscriptController", "appendMessageToBubbleData:" },
    { "CKTranscriptController", "_processRemovedIndices:insertedIndices:reloadedIndices:" },
    { "CKTranscriptController", "tableView:heightForRowAtIndexPath:" },
    { "CKTranscriptController", "tableView:cellForRowAtIndexPath:" },
    { "CKTranscriptController", "scrollViewWillBeginDragging:" },
    { "CKTranscriptController", "scrollViewDidEndDragging:willDecelerate:" },
    { "CKTranscriptController", "_endHoldingUpdatesToTranscriptWithKey:" },
    { "CKTranscriptController", "_finishSendAnimation" },
    { "CKTranscriptController", "sendMessage:" },
    { "CKTranscriptController", "_idealSizeForEntryView:" },
    { "CKTranscriptBubbleData", "appendBubbleDataForMessage:" },
    { "CKTranscriptBubbleData", "clearBubbleData" },
    { "CKTranscriptBubbleData", "insertMessageStatus:forMessage:date:" },
    { "CKTranscriptBubbleData", "indexesToRemoveMessageStatusFlags:forMessage:removeFlagForEverythingElse:" },
    { "CKTranscriptBubbleData", "removeMessageStatus:forMessage:andThisStatusForEverythingElse:" },
    { "CKTranscriptBubbleData", "indexesToDeleteMessage:" },
    { "CKTranscriptBubbleData", "deleteMessageAtIndex:" },
    { "CKTranscriptTransaction", "messageRead:" },
    { "CKTranscriptTransaction", "messageDelivered:" },
    { "CKTranscriptTransaction", "messageErrorChanged:" },
    { "CKMessageCell", "layoutSubviews" },
    { "CKBalloonView", "oneFingerDoubleTap:" },
    { "CKBalloonView", "prepareForReuse" },
    { "CKMessageEntryView", "desiredSize" },
    { "CKMessageEntryView", "sizeThatFits:" },
    { "CKMessageEntryView", "contentFieldViewFrame:" },
    { "CKMessageEntryView", "balloonViewFrame:" },
    { "CKMessageEntryView", "characterCountFrame:" },
    { "CKMessageEntryView", "layoutSubviews" },
    { "CKMessageEntryView", "didMoveToWindow" },
    { "CKConversation", "newMessageWithComposition:guid:addToConversation:" },
};

static void RXTCheckHookTargets(void) {
    unsigned long total = sizeof(kRXTHookTargets) / sizeof(kRXTHookTargets[0]);
    unsigned long missing = 0;
    for (unsigned long i = 0; i < total; i++) {
        NSString *className = [NSString stringWithUTF8String:kRXTHookTargets[i][0]];
        NSString *selectorName = [NSString stringWithUTF8String:kRXTHookTargets[i][1]];
        Class cls = NSClassFromString(className);
        if (cls && class_getInstanceMethod(cls, NSSelectorFromString(selectorName))) {
            continue;
        }
        missing++;
        NSString *target = [NSString stringWithFormat:@"-[%@ %@]", className, selectorName];
        RXLogOnce([@"hook " stringByAppendingString:target],
                  [NSString stringWithFormat:@"hook target missing (%@): %@", cls ? @"no method" : @"no class", target]);
    }
    RXLog(@"hooks: %lu of %lu targets present", total - missing, total);
}

#pragma mark - Prefs changes (DESIGN 12)

// Full teardown first regardless of flags (RXTeardown(Prefs) also drops every chat's reply state and
// queues the one gated reload per live transcript), then the swipe recognizer if Swipe is on now.
static void RXTPrefsChanged(void) {
    NSArray *live = [gRXTControllers allObjects];
    for (CKTranscriptController *tc in live) {
        RXTTeardown(tc, RXTeardownPrefs);
        if (RXTLive() && RXOn(RXGetPrefs().swipe) && [tc isViewLoaded]) {
            RXReplyInstallPan(tc);
        }
    }
    RXLog(@"prefs changed: %lu live transcript(s)", (unsigned long)[live count]);
}

#pragma mark - CKTranscriptController (CK.dump L133-604)

%hook CKTranscriptController

// v12@0:4c8 (L307). The resize retry and the poke only finish pending work (a no-op when nothing is
// pending), so they are cleanup paths and run with the kill switch off too (DESIGN 2).
- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    RXTTrack(self);
    if (!RXTLive()) {
        return;
    }
    if (RXTActive() && RXOn(RXGetPrefs().swipe)) {
        RXReplyInstallPan(self);
    }
    RXReplyRetryPendingResize(self);
    RXTranscriptPoke(self);
}

// v12@0:4c8 (L306)
- (void)viewWillAppear:(BOOL)animated
{
    %orig;
    RXTTrack(self);
    if (!RXTLive()) {
        return;
    }
    if (RXTActive()) {
        RXTranscriptRestyle(self);     // now + next run loop (after MessageWallpapers), then pending work
    }
    RXTranscriptPoke(self);            // cleanup-safe: drains a pending (e.g. prefs) reload with Enabled off
}

// v12@0:4c8 (L308)
- (void)viewWillDisappear:(BOOL)animated
{
    RXTTeardown(self, RXTeardownDisappear);
    if (RXTLive() && RXTIsLeaving(self)) {
        RXReplyControllerPopped(self);
    }
    %orig;
}

// v8@0:4 (L304)
- (void)viewDidUnload
{
    RXTTeardown(self, RXTeardownUnload);
    %orig;
}

// v8@0:4 (L301). The guard stays raised until the original dealloc has returned.
- (void)dealloc
{
    gRXTDeallocDepth++;
    RXTTeardown(self, RXTeardownDealloc);
    %orig;
    gRXTDeallocDepth--;
}

// v12@0:4@8 (L362). For the conversation it already shows, stock returns almost at once (CK@0xb340:
// _conversation == arg -> 0xb57e, no _computeBubbleData:), so nothing rebuilds: pending refresh/reload
// work is dropped, and reply mode re-applied, only when the conversation really changes.
- (void)setConversation:(CKConversation *)conversation
{
    CKConversation *current = (RXTLive() && RXResponds(self, @selector(conversation))) ? [self conversation] : nil;
    BOOL changed = (conversation != current);
    RXTTeardown(self, changed ? RXTeardownConversation : RXTeardownDisappear);
    %orig;
    RXTTrack(self);
    if (!RXTActive()) {
        return;
    }
    if (changed) {
        RXReplyConversationChanged(self);
    }
    RXTranscriptRestyle(self);
}

// v16@0:4c8c12 (L383)
- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    RXTTeardown(self, RXTeardownEditing);
    %orig;
    if (RXTActive()) {
        RXTranscriptEditingChanged(self);
    }
}

// v20@0:4i8d12 (L314)
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    RXTTeardown(self, RXTeardownRotate);
    %orig;
}

// v8@0:4 (L330)
- (void)prepareForSuspend
{
    RXTTeardown(self, RXTeardownSuspend);
    %orig;
}

// v8@0:4 (L420). Teardown first, so our swipe hold is ended while it is still on ChatKit's stack.
- (void)resetHoldingUpdates
{
    RXTTeardown(self, RXTeardownResetHolds);
    %orig;
}

// c12@0:4c8 (L400): the build context (DESIGN 5.1). A build that made new bubble data is followed by a
// reloadData outside _processRemovedIndices:, so it closes an open picker (DESIGN 7 "a forced reload").
// Our own gated reload only runs with the picker closed.
- (BOOL)_computeBubbleData:(BOOL)force
{
    BOOL pickerOpen = RXTLive() && RXPickerIsOpen(self);
    id before = (pickerOpen && RXResponds(self, @selector(bubbleData))) ? [self bubbleData] : nil;
    BOOL active = RXTActive();
    if (active) {
        RXTranscriptBuildBegin(self);
    }
    BOOL result = %orig;
    if (active) {
        RXTranscriptBuildEnd(self);
    }
    if (before && [self bubbleData] != before) {
        RXPickerDismiss(self, NO);
    }
    return result;
}

// v12@0:4c8 (L363): every ChatKit forced reload (_reloadTranscriptLayer, refreshTranscriptWithAnimation:,
// _dequeueStatusActions CK@0xa384, sendMessage: CK@0x12604) rebuilds and reloadData's the table here,
// outside _processRemovedIndices:, so it closes an open picker (DESIGN 7 "a forced reload").
- (void)_reloadTranscriptLayerForcingBubbleDataReload:(BOOL)force
{
    if (RXTLive() && RXPickerIsOpen(self)) {
        RXPickerDismiss(self, NO);
    }
    %orig;
}

// @12@0:4@8 (L401): the user's own Send always appends its rows (DESIGN 5.1). The send throw reloads rows
// (_setMessagesHiddenForRows: -> reloadData), so an open picker closes first (DESIGN 7).
- (id)appendMessageToBubbleData:(id)message
{
    if (RXTLive() && RXPickerIsOpen(self)) {
        RXPickerDismiss(self, NO);
    }
    if (!RXTActive()) {
        return %orig;
    }
    RXTranscriptSetInOwnSend(YES);
    id result = %orig;
    RXTranscriptSetInOwnSend(NO);
    return result;
}

// v20@0:4@8@12@16 (L348): drop reload indexes past the end (DESIGN 5.2); rows changing closes the picker (DESIGN 7).
- (void)_processRemovedIndices:(NSIndexSet *)removed insertedIndices:(NSIndexSet *)inserted reloadedIndices:(NSIndexSet *)reloaded
{
    if (RXTLive() && RXPickerIsOpen(self)) {
        RXPickerDismiss(self, YES);
    }
    if (!RXTActive() || !reloaded) {
        %orig;
        return;
    }
    NSIndexSet *filtered = RXTranscriptFilterReloads(self, reloaded);
    %orig(removed, inserted, filtered ? filtered : reloaded);
}

// f16@0:4@8@12 (L481): badge band / quote space above the bubble (DESIGN 5.4).
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat height = %orig;
    if (!RXTActive() || indexPath.section != 0 || !RXTIsTranscriptTable(self, table)) {
        return height;
    }
    return height + RXTranscriptExtraHeight(self, table, indexPath.row);
}

// @16@0:4@8@12 (L478): create/reuse our cell views (DESIGN 5.5).
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = %orig;
    if (!cell || !RXTLive()) {
        return cell;
    }
    if (!RXGetPrefs().enabled) {
        RXTranscriptResetCell(cell);   // kill-switch reuse reset (cleanup: no store, no prefs)
        return cell;
    }
    if (RXTIsTranscriptTable(self, table)) {
        RXTranscriptConfigureCell(self, table, cell, indexPath);
    }
    return cell;
}

// v12@0:4@8 (L390): scrolling closes the picker (DESIGN 7).
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if (RXTLive() && RXPickerIsOpen(self)) {
        RXPickerDismiss(self, YES);
    }
    %orig;
}

// v16@0:4@8c12 (L391): gate retry when the drag ends without deceleration (DESIGN 5.6). Cleanup-safe.
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    %orig;
    if (!decelerate && RXTLive()) {
        RXTranscriptPoke(self);
    }
}

// CKTranscriptController does not implement this delegate method on iOS 6.1.2 (CK.dump), so it is
// added: the gate retry after deceleration (DESIGN 5.6). Cleanup-safe.
%new
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    if (RXTLive()) {
        RXTranscriptPoke(self);
    }
}

// v12@0:4@8 (L419): gate retry once ChatKit's hold stack is empty (DESIGN 5.6). Cleanup-safe.
- (void)_endHoldingUpdatesToTranscriptWithKey:(NSString *)key
{
    %orig;
    if (gRXTTeardownDepth > 0 || !RXTLive()) {
        return;
    }
    if (RXResponds(self, @selector(_isHoldingUpdatesToTranscript)) && [self _isHoldingUpdatesToTranscript]) {
        return;
    }
    RXTranscriptPoke(self);
}

// v8@0:4 (L416). Cleanup-safe retries (pending bar resize, pending transcript work).
- (void)_finishSendAnimation
{
    %orig;
    if (!RXTLive()) {
        return;
    }
    RXReplyRetryPendingResize(self);
    RXTranscriptPoke(self);
}

// v12@0:4@8 (L425): reply send capture (DESIGN 10). The send throw reloads rows and the entry (in the
// keyboard's window) is outside the picker's catcher, so an open picker closes first (DESIGN 7).
- (void)sendMessage:(id)composition
{
    if (RXTLive() && RXPickerIsOpen(self)) {
        RXPickerDismiss(self, NO);
    }
    if (!RXTActive()) {
        %orig;
        return;
    }
    RXReplyCaptureBegin(self);
    %orig;
    RXReplyCaptureEnd(self);
}

// {CGSize=ff}16@0:4{CGSize=ff}8 (L545): the stock clamp applies to the content, then H is added back.
- (CGSize)_idealSizeForEntryView:(CGSize)contentSize
{
    CGFloat extra = 0;
    if (RXTActive()) {
        UIView *entry = RXResponds(self, @selector(entryView)) ? [self entryView] : nil;
        extra = entry ? RXReplySizeExtra(entry) : 0;
    }
    if (extra <= 0) {
        return %orig;
    }
    CGSize content = contentSize;
    content.height -= extra;
    CGSize ideal = %orig(content);
    ideal.height += extra;
    return ideal;
}

%end

#pragma mark - CKTranscriptBubbleData (CK.dump L1126-1196)

%hook CKTranscriptBubbleData

// @12@0:4@8 (L1169): the single entry point for message rows (DESIGN 5.1). Gated on the master switch
// only: RXTranscriptShouldHideAppend itself ingests/hides only with Show Reactions on (the same
// condition as RXTHiding), and with Reply Quotes alone it still defers a just-sent reply's quote.
- (id)appendBubbleDataForMessage:(id)message
{
    if (!RXTActive() || !RXTIngestible(message)) {
        return %orig;
    }
    if (RXTranscriptShouldHideAppend(self, message)) {
        return [NSMutableIndexSet indexSet];
    }
    return %orig;
}

// v8@0:4: a restart point for the store's append order (DESIGN 5.1). Cleanup: no prefs check.
- (void)clearBubbleData
{
    %orig;
    if (RXTLive()) {
        RXTranscriptBubbleDataCleared(self);
    }
}

// i20@0:4i8@12@16: Delivered/Read never lands on a hidden reaction (DESIGN 5.2).
// All five callers handle NSNotFound (0x7fffffff).
- (int)insertMessageStatus:(int)status forMessage:(id)message date:(id)date
{
    if (!RXTHiding() || !message) {
        return %orig;
    }
    id target = RXTranscriptStatusTarget(self, status, message);
    if (!target) {
        return (int)NSNotFound;
    }
    return %orig(status, target, date);
}

// @20@0:4i8@12i16
- (id)indexesToRemoveMessageStatusFlags:(int)flags forMessage:(id)message removeFlagForEverythingElse:(int)everythingElse
{
    if (RXTHiding() && message && RXTranscriptIsHiddenMessage(message)) {
        return [NSMutableIndexSet indexSet];
    }
    return %orig;
}

// @20@0:4i8@12i16
- (id)removeMessageStatus:(int)status forMessage:(id)message andThisStatusForEverythingElse:(int)everythingElse
{
    if (RXTHiding() && message && RXTranscriptIsHiddenMessage(message)) {
        return [NSMutableIndexSet indexSet];
    }
    return %orig;
}

// @12@0:4@8
- (id)indexesToDeleteMessage:(id)message
{
    if (RXTHiding() && message && RXTranscriptIsHiddenMessage(message)) {
        return [NSMutableIndexSet indexSet];
    }
    return %orig;
}

// @12@0:4I8
- (id)deleteMessageAtIndex:(unsigned int)row
{
    if (RXTHiding() && [self respondsToSelector:@selector(count)] && [self respondsToSelector:@selector(messageAtIndex:)]) {
        int count = [self count];
        if (count > 0 && row < (unsigned int)count) {
            id message = [self messageAtIndex:(int)row];
            if (message && RXTranscriptIsHiddenMessage(message)) {
                return [NSMutableIndexSet indexSet];
            }
        }
    }
    return %orig;
}

%end

#pragma mark - CKTranscriptTransaction (CK.dump L3289-3330)

// Live read/delivered/error updates for hidden reactions (DESIGN 5.2). Checked on device binary:
// _processReadMessageInsert:inserts:, _processDeliveredMessageInsert:inserts: and
// _processErrorInsert:inserts: derive rows only through insertMessageStatus:forMessage:date:
// (NSNotFound handled); the _processRemoves... paths only through indexesToRemoveMessageStatusFlags:...
%hook CKTranscriptTransaction

// v12@0:4@8 (L3312)
- (void)messageRead:(id)message
{
    if (RXTHiding() && message && RXTranscriptIsHiddenMessage(message)) {
        return;
    }
    %orig;
}

// v12@0:4@8 (L3313)
- (void)messageDelivered:(id)message
{
    if (RXTHiding() && message && RXTranscriptIsHiddenMessage(message)) {
        return;
    }
    %orig;
}

// v12@0:4@8 (L3314): a hidden reaction that fails is un-hidden by a gated reload instead (no %orig for
// its absent rows); a visible one (e.g. my reaction still in the send throw) gets the stock failure row
// from %orig and then loses its optimistic vote (DESIGN 4.4 / 8). Any other error change of a hidden
// reaction (not failedSend / partiallyFailedSend) only skips %orig and leaves it hidden.
- (void)messageErrorChanged:(id)message
{
    BOOL hiding = RXTHiding() && message != nil;
    if (hiding && RXTranscriptIsHiddenMessage(message)) {
        RXTranscriptMessageErrorChanged(message);
        return;
    }
    %orig;
    if (hiding) {
        RXTranscriptMessageErrorChanged(message);
    }
}

%end

#pragma mark - CKMessageCell (CK.dump L1007)

%hook CKMessageCell

// v8@0:4: frame our views from the balloon frame (DESIGN 5.5). Only our own frames are set.
- (void)layoutSubviews
{
    %orig;
    if (RXTActive()) {
        RXTranscriptLayoutCell(self);
    }
}

%end

#pragma mark - CKBalloonView (CK.dump L74)

%hook CKBalloonView

// v12@0:4@8 (L117): double-tap opens the picker instead of Copy; long-press Copy stays stock (DESIGN 7).
- (void)oneFingerDoubleTap:(UITapGestureRecognizer *)recognizer
{
    CKTranscriptController *tc = RXTPickerController(self, recognizer);
    if (!tc) {
        %orig;
        return;
    }
    if (RXResponds(self, @selector(hideCopyCallout))) {
        [self hideCopyCallout];
    }
    RXPickerToggle(tc, self);
}

// v8@0:4 (L104): ChatKit never removes animations on reuse (R4 4.1). Cleanup: no prefs check.
- (void)prepareForReuse
{
    %orig;
    [self.layer removeAnimationForKey:RX_SWIPE_KEY];
}

%end

#pragma mark - CKMessageEntryView (CK.dump L1-73)

%hook CKMessageEntryView

// {CGSize=ff}8@0:4 (L51)
- (CGSize)desiredSize
{
    CGSize size = %orig;
    return RXTGrowEntrySize(self, size);
}

// {CGSize=ff}16@0:4{CGSize=ff}8 (L52)
- (CGSize)sizeThatFits:(CGSize)fitSize
{
    CGSize size = %orig;
    return RXTGrowEntrySize(self, size);
}

// {CGRect}24@0:4{CGRect}8 (L29)
- (CGRect)contentFieldViewFrame:(CGRect)rect
{
    CGRect frame = %orig;
    return RXTShiftEntryFrame(self, frame, YES);
}

// {CGRect}24@0:4{CGRect}8 (L28): frames _inputFieldBackground and _inputFieldCover.
- (CGRect)balloonViewFrame:(CGRect)rect
{
    CGRect frame = %orig;
    return RXTShiftEntryFrame(self, frame, YES);
}

// {CGRect}24@0:4{CGRect}8 (L30)
- (CGRect)characterCountFrame:(CGRect)rect
{
    CGRect frame = %orig;
    return RXTShiftEntryFrame(self, frame, NO);
}

// v8@0:4 (L43): frame the reply bar. Cleanup path: it only acts when a bar or reply state already
// exists, so after a prefs change the bar still collapses and hides with the entry.
- (void)layoutSubviews
{
    %orig;
    if (RXTLive()) {
        RXReplyLayoutEntry(self);
    }
}

// v8@0:4, inherited from UIView (not in CK.dump; Substrate adds the override): back in a window is a
// pending-resize retry event (DESIGN 10). Deferred one turn so no resize runs inside a hierarchy change.
// Cleanup-safe (a pending collapse after a prefs change must still finish with Enabled off).
- (void)didMoveToWindow
{
    %orig;
    if (!RXTLive() || !self.window) {
        return;
    }
    id delegate = RXIvar(self, "_delegate");
    if (!RXIsTranscriptController(delegate)) {
        return;
    }
    __weak CKTranscriptController *weakTC = (CKTranscriptController *)delegate;
    dispatch_async(dispatch_get_main_queue(), ^{
        CKTranscriptController *tc = weakTC;
        if (tc && RXTLive()) {
            RXReplyRetryPendingResize(tc);
        }
    });
}

%end

#pragma mark - CKConversation (CK.dump L1936)

%hook CKConversation

// @20@0:4@8@12c16 (L2095). Returns +1. Pure pass-through (DESIGN 2): the result is never substituted.
- (id)newMessageWithComposition:(id)composition guid:(NSString *)guid addToConversation:(BOOL)add
{
    if (!RXTActive()) {
        return %orig;
    }
    RXReplyCaptureGUID(guid);
    id m = %orig;
    RXReplyCaptureMessage(m);
    return m;
}

%end

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        gRXTControllers = [NSHashTable weakObjectsHashTable];
        RXTCheckHookTargets();
        %init;
        RXPrefsStart(^{
            RXTPrefsChanged();
        });
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        RXLog(@"Reactions %@ loaded in %@", RX_VERSION, bundleID ? bundleID : @"?");
#ifdef DEBUG
        RXParserSelfTest();
#endif
    }
}
