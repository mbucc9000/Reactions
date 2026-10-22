// Reactions 2.0 — shared contract between all modules. See DESIGN.md (v2.1) for behaviour.
//
// RULES (DESIGN.md §2) that every module follows:
//  * Private ChatKit/IMCore classes are declared below so method calls type-check, but their CLASS SYMBOLS
//    must never be referenced ([CKFoo class], [CKFoo alloc], isKindOfClass:[CKFoo class]): use
//    NSClassFromString(@"CKFoo") / objc_getClass. Only UIKit, Foundation, CoreGraphics, QuartzCore are linked.
//  * Every private selector is called only after respondsToSelector: (or through the RX* helpers below),
//    and a missing one disables that feature and logs once (RXLogOnce). Messages must never crash.
//  * Never -[UIColor getRed:green:blue:alpha:]; colours are raw CGFloat arrays (RXGradient).
//  * Never UIRectFill with translucent colours; CGContextFillRect.
//  * Never write cell.layer.sublayerTransform, balloon.frame, balloon.transform.
//  * No UILabel inside table cells; our cell views draw in drawRect:.
//  * Logs never contain message text, names or phone numbers (counts, kinds, lengths, GUID tails only).
//  * Every NSDictionary/NSArray insert is nil-checked; no @{} / @[] literals with possibly-nil values.
//  * Main thread only, except RXStore persistence (serial queue) and RXTick (serial queue).
//  * ARC. iOS 6.1 SDK, armv7. No API newer than iOS 6.0.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Constants

#define RX_VERSION              @"2.1.1"
#define RX_LOG_PATH             "/var/mobile/Reactions.log"
#define RX_PREFS_PATH           @"/var/mobile/Library/Preferences/com.mbucc9000.reactions.plist"
#define RX_PREFS_NOTIFY         "com.mbucc9000.reactions/prefs"
// Pref keys: the Settings pane plist (layout/.../Reactions.plist) uses exactly these; RXCore reads them first.
#define RX_PREF_ENABLED         @"enabled"
#define RX_PREF_BADGES          @"badges"      // Show Reactions
#define RX_PREF_SENDING         @"sending"     // React & Reply (default OFF; gates picker + swipe)
#define RX_PREF_PICKER          @"picker"      // Double-Tap to React
#define RX_PREF_SWIPE           @"swipe"       // Swipe to Reply
#define RX_PREF_QUOTES          @"quotes"      // Reply Quotes
#define RX_PREF_HAPTIC          @"haptic"
#define RX_DATA_DIR             @"/var/mobile/Library/Reactions"
#define RX_REPLIES_PATH         @"/var/mobile/Library/Reactions/Replies.plist"
#define RX_MATCHED_PATH         @"/var/mobile/Library/Reactions/Matched.plist"

#define RX_BADGE_D              24.0f    // badge body diameter (DESIGN §6; tune 22-26 on device)
#define RX_BADGE_ROW_EXTRA      15.0f    // extra row height for a badge (DESIGN §5.4)
#define RX_QUOTE_GAP            2.0f     // gap between quote art and the reply/badge band
#define RX_REPLY_BAR_H          32.0f    // reply strip height H (DESIGN §10)
#define RX_SWIPE_KEY            @"RXReplySwipe"                  // CAAnimation key (DESIGN §9)
#define RX_HOLD_KEY             @"RXHoldingUpdatesReplySwipe"    // ChatKit holding-updates key (DESIGN §9)
#define RX_IM_FLAGS             0x100005ULL                      // finished|fromMe|wasDataDetected (R2 §1.2)

#pragma mark - Private ChatKit / IMCore / UIKit declarations (methods only — see RULES)
// Encodings verified against the device class dump ChatKit.objc.txt (line numbers in DESIGN.md / research).

@interface UIImage (RXPrivate)
+ (UIImage *)kitImageNamed:(NSString *)name;           // UIKit artwork, exact name incl. ".png"
+ (UIImage *)ckImageNamed:(NSString *)name;            // ChatKit bundle image (category added by ChatKit)
@end

@interface IMHandle : NSObject
- (NSString *)ID;
- (NSString *)firstName;
- (NSString *)name;
@end

@interface IMMessage : NSObject
+ (id)instantMessageWithText:(NSAttributedString *)text flags:(unsigned long long)flags;   // @20@0:4@8Q12
- (NSString *)guid;
- (NSString *)plainBody;
@end

@interface IMChat : NSObject
- (NSString *)chatIdentifier;
- (void)sendMessage:(id)imMessage;
- (BOOL)canHaveMultipleParticipants;
@end

@interface CKEntity : NSObject
- (NSString *)rawAddress;
- (NSString *)name;
- (IMHandle *)defaultIMHandle;
@end

@interface CKMediaObject : NSObject
- (NSString *)UTIType;
- (NSString *)filename;
- (NSString *)transferGUID;
- (int)mediaType;
@end

@interface CKMessagePart : NSObject
- (int)type;                    // 0 text, 1 media, 2 deleted, 3 unknown
- (id)text;                     // NSAttributedString for text parts, nil otherwise
- (id)parentMessage;            // CKIMMessage
- (CKMediaObject *)mediaObject;
- (UIImage *)previewImage;
@end

@interface CKConversation : NSObject
- (IMChat *)chat;
- (NSArray *)recipients;        // CKEntity
- (NSArray *)messages;
@end

@interface CKIMMessage : NSObject
- (NSString *)guid;
- (BOOL)isFromMe;
- (CKEntity *)sender;           // NEW object every call — never compare by pointer
- (NSString *)address;
- (NSArray *)parts;             // CKMessagePart
- (id)calendarDate;             // NSCalendarDate (NSDate subclass)
- (NSString *)_rawPreviewText;  // plain body; NEVER use -previewText (failure summary for failed sends)
- (BOOL)failedSend;
- (BOOL)partiallyFailedSend;
- (BOOL)pending;
- (BOOL)isPlaceholder;
- (BOOL)isTypingIndicator;
- (CKConversation *)conversation;
- (IMMessage *)IMMessage;
@end

@interface CKMultiDict : NSObject
- (NSArray *)objectsForKey:(id)key;
@end

@interface CKTranscriptBubbleData : NSObject
- (int)count;
- (id)messageAtIndex:(int)row;                 // CKIMMessage, nil for some rows
- (CKMessagePart *)partAtIndex:(int)row;       // nil for timestamp / name / status / typing rows
- (int)typeAtIndex:(int)row;
- (NSUInteger)indexForMessageWithGUID:(NSString *)guid;   // 0x7fffffff (NSNotFound) when absent
- (NSUInteger)lastIndexForMessage:(id)message;            // 0x7fffffff when absent
- (int)indexForPart:(id)part;
@end

@interface CKBalloonView : UIImageView
- (CKMessagePart *)messagePart;
- (int)orientation;             // 0 incoming, otherwise outgoing
- (BOOL)isRestoring;
- (void)hideCopyCallout;
- (void)flashHighlight;
@end

@interface CKMessageCell : UITableViewCell
- (CKBalloonView *)balloonView;
@end

@interface CKMessageEntryView : UIImageView
- (UIView *)entryField;
@end

@interface CKTranscriptController : UIViewController
- (UITableView *)transcriptTable;
- (CKTranscriptBubbleData *)bubbleData;
- (CKConversation *)conversation;
- (CKMessageEntryView *)entryView;
- (BOOL)isSendingMessage;
- (BOOL)_isHoldingUpdatesToTranscript;
- (void)_beginHoldingUpdatesToTranscriptWithKey:(NSString *)key;
- (void)_endHoldingUpdatesToTranscriptWithKey:(NSString *)key;
- (void)_reloadTranscriptLayerForcingBubbleDataReload:(BOOL)force;
- (CGRect)clippedTargetRectForBalloon:(id)balloon;   // {CGRect}12@0:4@8
- (float)_bottomInset;                                // f8@0:4
- (void)_makeContentEntryViewActive;
- (void)showKeyboardForReply;
- (BOOL)_resizeMessageEntryViewWithAnimate:(BOOL)animate;   // c12@0:4c8
@end

#pragma mark - Helpers & safety (RXCore.m)

void RXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void RXLogOnce(NSString *key, NSString *message);          // logs a given key only once per process
NSString *RXGUIDTail(NSString *guid);                      // last 6 chars, for logs

BOOL RXResponds(id obj, SEL sel);                          // obj && [obj respondsToSelector:sel]; logs once when NO
id RXIvar(id obj, const char *name);                       // object ivar via class_getInstanceVariable/object_getIvar ('@' type only), nil-safe
UIViewController *RXControllerForView(UIView *view);       // walks nextResponder for a CKTranscriptController (by NSClassFromString)
BOOL RXIsTranscriptController(id obj);

NSString *RXChatKeyForConversation(CKConversation *conv);  // [[conv chat] chatIdentifier] or nil (=> pass-through everywhere)
NSString *RXChatKeyForMessage(id ckMessage);               // via -conversation; nil if unavailable
NSString *RXSafeTruncate(NSString *s, NSUInteger maxUnits);// never splits a composed character sequence
NSString *RXFirstNameForEntity(CKEntity *entity);          // [[e defaultIMHandle] firstName] ?: [e name] ?: @""

// Prefs (DESIGN §12). Read by absolute path; reloaded on Darwin notify RX_PREFS_NOTIFY.
typedef struct {
    BOOL enabled;     // master
    BOOL badges;      // F1 show reactions
    BOOL sending;     // React & Reply switch (default NO); already folded into picker and swipe
    BOOL picker;      // F2 double-tap to react (effective: sending && the picker switch)
    BOOL swipe;       // F3 swipe to reply (effective: sending && the swipe switch)
    BOOL quotes;      // F3 reply quotes in transcript
    BOOL haptic;      // swipe tick
} RXPrefs;
RXPrefs RXGetPrefs(void);
void RXPrefsStart(void (^onChange)(void));                 // call once from %ctor; onChange runs on main queue
BOOL RXOn(BOOL feature);                                   // RXGetPrefs().enabled && feature

// Artwork (DESIGN §6–§10). All cached; nil when missing (each miss logged once).
UIImage *RXKitImage(NSString *exactName);                  // +[UIImage kitImageNamed:], e.g. @"UICalloutBarLeft.png"
UIImage *RXCKImage(NSString *name);                        // +[UIImage ckImageNamed:], e.g. @"Balloon_2"
UIImage *RXBalloonDot(BOOL mine);                          // 30x32 pt resizable dot (Balloon_2 / select-text-bubble), caps {14,14.5,17,14.5}
UIImage *RXBalloonDotNamed(NSString *ckArtName);           // same dot from any ChatKit balloon art (e.g. @"Balloon_Blue", @"ImageBubbleMaskUntailed"); cached, nil when missing
void RXDrawBalloonDot(UIImage *dot, CGRect body, CGFloat alpha); // draw so the dot's BODY fills `body` (CTM-scaled; never below caps)

// Colours / tint pipeline. A gradient is top RGBA then bottom RGBA, raw components (never via UIColor getters).
typedef struct { CGFloat c[8]; } RXGradient;
RXGradient RXGrad(CGFloat r1, CGFloat g1, CGFloat b1, CGFloat a1, CGFloat r2, CGFloat g2, CGFloat b2, CGFloat a2);
RXGradient RXSolid(CGFloat r, CGFloat g, CGFloat b, CGFloat a);
UIImage *RXTint(UIImage *coverage, RXGradient g);          // coverage alpha x gradient (kCGBlendModeSourceIn), same size/scale
void RXFillGradient(CGContextRef ctx, CGRect r, RXGradient g);

// Glyphs (DESIGN §6). keys: "love" "like" "dislike" "laugh" "emph" "question" "sticker". Emoji drawn in colour.
typedef enum {
    RXGlyphOnGrey = 0,       // #7D8390->#4F5562, engraved white a0.80 at +1 (heart: #FF5C7A->#D9173D)
    RXGlyphOnBlue,           // white->#E6EEFF, black a0.30 at -1
    RXGlyphOnCallout,        // white, black a0.5 at -1 (stock callout label)
} RXGlyphStyle;
UIImage *RXGlyphCoverage(NSString *key, CGFloat box);      // opaque-on-transparent coverage image of the glyph in a box x box pt square, screen scale, cached
void RXDrawGlyph(NSString *key, NSString *emoji, CGRect box, RXGlyphStyle style);   // in the current UIKit context; emoji != nil => coloured emoji
UIImage *RXReplyArrowImage(BOOL armed, BOOL wallpaper, CGFloat scale); // UIButtonBarReply.png tinted (DESIGN §9), cached per state

// Haptic (DESIGN §9): dlsym AudioServicesPlaySystemSoundWithVibration; Intensity 0.25, 12 ms; >= 250 ms apart; serial queue.
void RXTick(void);

// Wallpaper (MessageWallpapers) detection.
BOOL RXTableIsWallpapered(UITableView *table);             // CGColorGetAlpha(table.backgroundColor.CGColor) == 0
BOOL RXEntryIsWallpapered(UIView *entry);                  // entry.layer.contents == nil

#pragma mark - Parser (RXParser.m) — R5 §5 verbatim

typedef enum {
    RXKindNone = 0, RXKindLove, RXKindLike, RXKindDislike, RXKindLaugh, RXKindEmph, RXKindQuestion, RXKindSticker, RXKindEmoji
} RXKind;

typedef enum {
    RXTargetUnknown = 0,       // unmatchable (empty quote, unknown tail, app balloon, special) -> stays visible
    RXTargetText,
    RXTargetImage, RXTargetMovie, RXTargetAudio, RXTargetAnyAttachment,
    RXTargetContact, RXTargetLocation, RXTargetEvent, RXTargetPass, RXTargetOrder,
} RXTarget;

@interface RXEvent : NSObject
@property (nonatomic, assign) BOOL isEdit;             // "Edited to “X”" (editText set; nothing else)
@property (nonatomic, assign) BOOL isRemoval;
@property (nonatomic, assign) RXKind kind;
@property (nonatomic, copy) NSString *emoji;           // RXKindEmoji only
@property (nonatomic, assign) RXTarget target;
@property (nonatomic, copy) NSString *quote;           // RXTargetText: inner text as received
@property (nonatomic, assign) BOOL truncated;          // quote ended with U+2026
@property (nonatomic, copy) NSString *prefix;          // truncated: quote minus "…" minus trailing whitespace
@property (nonatomic, copy) NSString *editText;
@end

RXEvent *RXParse(NSString *text);                          // nil = ordinary message
NSString *RXNormalize(NSString *s);                        // R5 §6.2 N(x): drop U+FFFC, U+FEFF/200E/200F/2066-2069, NFC.
                                                           // Never nil: @"" for nil/non-string; an NSAttributedString uses its .string
NSString *RXKindKey(RXKind kind);                          // glyph key for RXDrawGlyph ("love"...), nil for emoji/none
// Apple's exact US-English send strings (R5 §7). quoteText = the reacted part's text (FFFC removed);
// it is cut at the last space <= 50 UTF-16 units + " …" when longer. Media targets use the noun.
// Returns nil (caller shows "Couldn't Send Reaction") for RXKindNone, RXTargetUnknown, a text target whose
// quote is empty or only U+FFFC/whitespace, and an emoji that is empty or contains whitespace/ASCII letters.
NSString *RXComposeReaction(RXKind kind, NSString *emoji, BOOL removal, RXTarget target, NSString *quoteText);
void RXParserSelfTest(void);                               // R5 §8 vectors; logs "parser self-test n/m"

#pragma mark - Store (RXStore.m) — DESIGN §4

// One reaction kind as shown on a badge.
@interface RXReaction : NSObject
@property (nonatomic, assign) RXKind kind;
@property (nonatomic, copy) NSString *emoji;
@property (nonatomic, assign) NSInteger count;         // reactors with this kind (others only for grey entries)
@property (nonatomic, strong) NSArray *names;          // first names of those reactors ("You" never included here)
@property (nonatomic, assign) BOOL isMine;             // used by captionEntries for the "You" entry
@end

// What a bubble part shows. `others` = grey entries (ordered newest kind first); `mine` = my kind or nil.
@interface RXBadgeModel : NSObject
@property (nonatomic, strong) NSArray *others;         // RXReaction
@property (nonatomic, strong) RXReaction *mine;
@property (nonatomic, readonly) BOOL isEmpty;
// Caption entries for the picker's "who reacted" line, in display order: "You" first (if mine), then
// others by kind. Each entry is an RXReaction with exactly one name in .names (or @"You") — the picker
// draws "Name" text + the glyph via RXDrawGlyph (never glyph characters in a string).
- (NSArray *)captionEntries;
- (NSString *)accessibilityString;                     // "Loved by Alex and you" (words only)
@end

@interface RXReplyLink : NSObject
@property (nonatomic, copy) NSString *parentGUID;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) RXTarget kind;           // RXTargetText or a media kind
@property (nonatomic, copy) NSString *snippet;         // <=120 units, composed-safe
@property (nonatomic, assign) BOOL parentIsMine;
@property (nonatomic, copy) NSString *parentName;      // first name, "You" when mine
@property (nonatomic, strong) NSDate *date;
@end

RXTarget RXTargetForPart(CKMessagePart *part);            // text part -> RXTargetText; media by media-object class / UTI
NSString *RXTextForPart(CKMessagePart *part);              // text part's plain string (FFFC removed), else nil

@interface RXStore : NSObject
+ (RXStore *)storeForChatKey:(NSString *)chatKey create:(BOOL)create;  // LRU: on-screen chat + 4 more
@property (nonatomic, readonly, copy) NSString *chatKey;

// Build lifecycle (DESIGN §5.1). Order = append order within one bubble-data instance.
- (void)restartBuild;                                   // keeps reply links, matched list, optimistic votes
- (BOOL)ingestMessage:(CKIMMessage *)msg allowHide:(BOOL)allowHide;   // returns YES => caller must hide (skip %orig)
- (BOOL)isHiddenGUID:(NSString *)guid;
- (BOOL)isKnownGUID:(NSString *)guid;

// Badges.
- (RXBadgeModel *)badgeForGUID:(NSString *)guid partKey:(NSInteger)partKey;
- (RXReaction *)myReactionForGUID:(NSString *)guid partKey:(NSInteger)partKey;
- (NSSet *)takeDirtyGUIDs;                              // targets whose badge changed since last call
- (BOOL)takeNeedsReload;                                // visibility changed after the fact (late match / failure)

// Optimistic votes (DESIGN §4.4) and failures.
- (void)addOptimisticKind:(RXKind)kind emoji:(NSString *)emoji removal:(BOOL)removal
                forGUID:(NSString *)guid partKey:(NSInteger)partKey sentGUID:(NSString *)sentGUID;
- (void)messageFailed:(CKIMMessage *)msg;               // un-hide a failed outgoing reaction, drop its optimistic vote

// Reply links (DESIGN §4.3) — persisted (binary plist, coalesced, serial queue, .bad on parse failure).
- (void)setReplyLink:(RXReplyLink *)link forReplyGUID:(NSString *)replyGUID;
- (RXReplyLink *)replyLinkForGUID:(NSString *)replyGUID;
@end

#pragma mark - Transcript (RXTranscript.m) — DESIGN §5

void RXTranscriptBuildBegin(CKTranscriptController *tc);   // -_computeBubbleData: before %orig
void RXTranscriptBuildEnd(CKTranscriptController *tc);     // after %orig
void RXTranscriptBubbleDataCleared(CKTranscriptBubbleData *data);
void RXTranscriptSetInOwnSend(BOOL inside);                // around -appendMessageToBubbleData:
BOOL RXTranscriptShouldHideAppend(CKTranscriptBubbleData *data, id message);   // ingests; YES => return empty set
BOOL RXTranscriptIsHiddenMessage(id message);
// insertMessageStatus: returns the message to pass to %orig, or nil => return NSNotFound without %orig.
id RXTranscriptStatusTarget(CKTranscriptBubbleData *data, int status, id message);
BOOL RXTranscriptInBuild(void);
NSIndexSet *RXTranscriptFilterReloads(CKTranscriptController *tc, NSIndexSet *reloaded);   // drop indexes >= count
void RXTranscriptMessageErrorChanged(id message);          // from CKTranscriptTransaction messageErrorChanged:

CGFloat RXTranscriptExtraHeight(CKTranscriptController *tc, UITableView *table, NSInteger row);
void RXTranscriptConfigureCell(CKTranscriptController *tc, UITableView *table, UITableViewCell *cell, NSIndexPath *path);
void RXTranscriptLayoutCell(UITableViewCell *cell);        // from -[CKMessageCell layoutSubviews] after %orig
void RXTranscriptResetCell(UITableViewCell *cell);         // kill-switch reuse reset: hide/clear our views, strip swipe anims (no store access, no prefs)
NSInteger RXTranscriptPartKeyForRow(CKTranscriptBubbleData *data, NSInteger row);   // DESIGN §5.3 (NSNotFound if not a part row)

void RXTranscriptScheduleRefresh(CKTranscriptController *tc);   // gated (DESIGN §5.6)
void RXTranscriptScheduleReload(CKTranscriptController *tc);    // gated
void RXTranscriptPoke(CKTranscriptController *tc);              // event-driven retry of dirty work
void RXTranscriptEditingChanged(CKTranscriptController *tc);    // right after setEditing:animated: %orig
void RXTranscriptRestyle(CKTranscriptController *tc);           // setNeedsDisplay our visible views (MW style)

// Single teardown (DESIGN §5.7). Never checks prefs. Every reason: dismiss picker + RXSwipeTeardown. Dealloc: nothing
// else (no weak refs, no scheduling). Prefs: also clears our cell views, RXReplyResetAll, one gated reload.
typedef enum { RXTeardownDisappear, RXTeardownConversation, RXTeardownEditing, RXTeardownRotate,
               RXTeardownSuspend, RXTeardownUnload, RXTeardownDealloc, RXTeardownResetHolds, RXTeardownPrefs } RXTeardownReason;
void RXTeardown(CKTranscriptController *tc, RXTeardownReason reason);

#pragma mark - Views (RXBadge.m) — DESIGN §6, §11

@interface RXReactionBalloonView : UIView                 // "Balloon" in the name: MessageWallpapers' hold skips it
@property (nonatomic, strong) RXBadgeModel *model;
@property (nonatomic, assign) BOOL outgoing;              // badge on an outgoing (right) bubble
@property (nonatomic, assign) BOOL wallpaper;
@property (nonatomic, copy) void (^onTap)(void);
- (void)setModel:(RXBadgeModel *)model animated:(BOOL)animated;   // pop in/out per DESIGN §6
// Frame itself (incl. dots, padding, 44 pt touch area handled in pointInside:) from the balloon frame, clamped to bounds.
- (void)layoutForBalloonFrame:(CGRect)balloonFrame outgoing:(BOOL)outgoing inBounds:(CGRect)bounds;
- (CGRect)artRectInSuperview;                             // union of drawn art (for picker targeting)
@end

@interface RXQuoteBalloonView : UIView
@property (nonatomic, strong) RXReplyLink *link;
@property (nonatomic, strong) UIImage *thumbnail;         // media parents (may be nil)
@property (nonatomic, assign) BOOL wallpaper;
@property (nonatomic, copy) void (^onTap)(void);          // nil => not tappable
+ (CGFloat)heightForLink:(RXReplyLink *)link width:(CGFloat)width;   // quote art height (excl. gap)
// Positions quote + connector above the reply balloon; `withBadge` routes the connector under the badge band.
- (void)layoutForReplyBalloonFrame:(CGRect)replyFrame replyOutgoing:(BOOL)replyOutgoing
                         withBadge:(BOOL)withBadge inBounds:(CGRect)bounds;
@end

#pragma mark - Picker (RXPicker.m) — DESIGN §7

void RXPickerToggle(CKTranscriptController *tc, CKBalloonView *balloon);   // open, or close if open for this balloon
void RXPickerPresentForBadge(CKTranscriptController *tc, UITableViewCell *cell);
void RXPickerDismiss(CKTranscriptController *tc, BOOL animated);
BOOL RXPickerIsOpen(CKTranscriptController *tc);          // also YES while an animated close fades (<= 0.25 s)

#pragma mark - Send (RXSend.m) — DESIGN §8

// Sends the add/removal text for (guid, partKey) of the current conversation; applies the optimistic vote.
BOOL RXSendReaction(CKTranscriptController *tc, NSString *guid, NSInteger partKey, RXKind kind, NSString *emoji, BOOL removal);

#pragma mark - Reply (RXReply.m) — DESIGN §9, §10

void RXReplyInstallPan(CKTranscriptController *tc);         // once per table (viewDidAppear:)
BOOL RXSwipeSessionActive(void);
void RXSwipeTeardown(CKTranscriptController *tc);           // end hold if still on stack, strip animations, remove arrow

void RXReplyBegin(CKTranscriptController *tc, CKIMMessage *parent, NSInteger partKey);
void RXReplyCancel(CKTranscriptController *tc);             // clear button
void RXReplyResetAll(CKTranscriptController *tc);           // prefs change: clears EVERY chat's reply state, then leaves reply mode for tc with resize
BOOL RXReplyActive(CKTranscriptController *tc);             // reply mode for tc's current chat
void RXReplyConversationChanged(CKTranscriptController *tc);// show/hide the bar for the new chat
void RXReplyControllerPopped(CKTranscriptController *tc);   // isMovingFromParentViewController
void RXReplyRetryPendingResize(CKTranscriptController *tc); // _finishSendAnimation / viewDidAppear: / keyboard did show / entry didMoveToWindow

// Entry-view hooks (CKMessageEntryView). H = RX_REPLY_BAR_H while in reply mode, else 0.
CGFloat RXReplySizeExtra(UIView *entry);                    // for desiredSize / sizeThatFits: / _idealSizeForEntryView:
BOOL RXReplyFramesShifted(UIView *entry);                   // the entry's current height includes H (frame hooks shift by RX_REPLY_BAR_H);
                                                            // YES only after a resize made in reply mode, NO again once it shrank
void RXReplyLayoutEntry(UIView *entry);                     // -[CKMessageEntryView layoutSubviews] after %orig

// Send capture (DESIGN §10).
void RXReplyCaptureBegin(CKTranscriptController *tc);       // -[CKTranscriptController sendMessage:] before %orig
void RXReplyCaptureGUID(NSString *guidArg);                 // newMessageWithComposition:guid:... before %orig (may be nil)
void RXReplyCaptureMessage(id createdMessage);              // ...after %orig (fallback when guidArg was nil)
void RXReplyCaptureEnd(CKTranscriptController *tc);         // after %orig: leave reply mode
