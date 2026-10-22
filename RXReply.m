// Reactions 2.0 — RXReply.m: swipe to reply (DESIGN.md §9, R4 §5) and reply mode in the entry bar
// (DESIGN.md §10, R2 §2.3/§3.6, R6 §5/§6).
//
// Swipe: RXReplyPanGestureRecognizer on the transcript table (raw start/last points, because UIKit
// strips the hysteresis from -translationInView: before asking the delegate, R4 U7). The only failure
// edge is table.panGestureRecognizer -> ours. The bubble, our badge/quote views and the cell's
// _failedButton move through an additive, presentation-only transform.translation.x animation keyed
// RX_SWIPE_KEY (no model frame/transform/sublayerTransform is ever written, DESIGN §2). Transcript
// updates are held with RX_HOLD_KEY for the session; the hold is released exactly once, either by
// the session's dispatch_after(0.45 s) after the spring-back or by RXSwipeTeardown, and only if
// ChatKit's _holdingUpdatesKeyStack still holds our key (resetHoldingUpdates may have emptied it).
//
// Reply mode: state per chat (memory only). RXReplyBarView is a custom UIView subclass (so
// MessageWallpapers never fades it) at index 0 of CKMessageEntryView, covering its full bounds: the
// 32 pt strip on top, MessageEntryBG from y = H down (its top lines are the seam), or, when MW has
// cleared the bar, only a floating white pill. The entry grows by H through the size hooks
// (RXReplySizeExtra) and the field moves down through the frame hooks (RXReplyFramesShifted), which
// follow whether the entry's current height actually includes H (tracked per entry from height
// changes: a height change computed while reply mode is on includes H, one computed while it is off
// does not). Enter/leave = state -> (enter: _makeContentEntryViewActive) ->
// _resizeMessageEntryViewWithAnimate:YES; when ChatKit refuses, a pending resize is retried only from
// RXReplyRetryPendingResize (events, never polling).
//
// Logs: counts, kinds, lengths, GUID tails only (DESIGN §2).

#import "RXShared.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#include <math.h>

#pragma mark - Constants

#define RX_SWIPE_EDGE           10.0f   // SwipeBack's edge zones, nav-view coordinates (R4 §2.2)
#define RX_SWIPE_SLOP           10.0f   // raw rightward travel before we may begin (= UIKit hysteresis)
#define RX_SWIPE_CONE           0.58f   // |dy| <= 0.58 dx  (within 30 degrees)
#define RX_SWIPE_R              100.0f  // d = R (1 - e^(-t/R))
#define RX_SWIPE_CAP            96.0f
#define RX_SWIPE_ARM            45.0f
#define RX_SWIPE_DISARM         37.0f
#define RX_SWIPE_HIT_INSET      (-4.0f) // body rect inset for touches
#define RX_SPRING_T             0.36f   // critically damped spring-back (R4 §5.4)
#define RX_SPRING_W             22.0f
#define RX_SPRING_N             24
#define RX_SESSION_END_DELAY    0.45    // hold release after the spring-back
#define RX_ARROW_FADE           0.15
#define RX_ARROW_POP            0.12
#define RX_ARROW_POP_KEY        @"RXReplyArrowPop"
#define RX_REPLY_FADE           0.25    // strip contents fade (DESIGN §10)
#define RX_REPLY_HIDE_DELAY     0.4     // idle bar hidden after the collapse animation
#define RX_SNIPPET_MAX          120     // UTF-16 units (DESIGN §4.3)
// MessageWallpapers' text-box opacity (MWStore.h:38-41 / MWStore.m): its own setting, posted in-process.
#define RX_MW_PREFS_PATH        @"/var/mobile/Library/Preferences/com.mbucc9000.messagewallpapers.plist"
#define RX_MW_OPACITY_KEY       @"FieldOpacity"
#define RX_MW_OPACITY_DEFAULT   0.94f
#define RX_MW_OPACITY_CHANGED   @"MWFieldOpacityChanged"

#pragma mark - Private UIKit declaration

@interface UIPanGestureRecognizer (RXReplyPrivate)
- (void)setFailsPastMaxTouches:(BOOL)fails;     // UIKit.objc.txt:15257 v12@0:4c8 (R4 U9); used after respondsToSelector:
@end

#pragma mark - Model objects

@class RXReplyBarView, RXReplyPanGestureRecognizer, RXReplyArrowView;

// Reply mode for one chat (DESIGN §10). Immutable after creation.
@interface RXReplyState : NSObject
@property (nonatomic, copy) NSString *chatKey;
@property (nonatomic, copy) NSString *parentGUID;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) RXTarget kind;             // RXTargetText or a media kind
@property (nonatomic, copy) NSString *snippet;           // <= 120 units, composed-safe ("" for media)
@property (nonatomic, assign) BOOL isMine;
@property (nonatomic, copy) NSString *name;              // first name, "You" when mine
@property (nonatomic, strong) UIImage *thumbnail;        // media parents (may be nil)
@end

@implementation RXReplyState
@end

// Per CKMessageEntryView: does its current height include H, and our bar.
@interface RXReplyEntryInfo : NSObject
@property (nonatomic, assign) BOOL seen;
@property (nonatomic, assign) BOOL grown;
@property (nonatomic, assign) CGFloat lastHeight;
@property (nonatomic, strong) RXReplyBarView *bar;
@end

@implementation RXReplyEntryInfo
@end

// A stock send made while in reply mode (DESIGN §10 send capture).
@interface RXReplyCapture : NSObject
@property (nonatomic, weak) CKTranscriptController *controller;
@property (nonatomic, strong) RXReplyState *state;
@property (nonatomic, assign) BOOL stored;
@end

@implementation RXReplyCapture
@end

// One swipe (DESIGN §9). The object itself is the session token.
@interface RXSwipeSession : NSObject
@property (nonatomic, weak) RXReplyPanGestureRecognizer *pan;
@property (nonatomic, weak) CKTranscriptController *controller;
@property (nonatomic, weak) UITableView *table;
@property (nonatomic, strong) CKIMMessage *message;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, strong) NSArray *views;            // balloon, our badge/quote views, _failedButton
@property (nonatomic, strong) RXReplyArrowView *arrow;
@property (nonatomic, assign) CGRect body;               // original bubble body, balloon-superview coordinates
@property (nonatomic, assign) CGFloat arrowY;
@property (nonatomic, assign) CGFloat d;
@property (nonatomic, assign) BOOL outgoing;
@property (nonatomic, assign) BOOL wallpaper;
@property (nonatomic, assign) BOOL armed;
@property (nonatomic, assign) BOOL everArmed;
@property (nonatomic, assign) BOOL holding;
@property (nonatomic, assign) BOOL holdReleased;
@property (nonatomic, assign) BOOL released;
@property (nonatomic, assign) BOOL finished;
@end

@implementation RXSwipeSession
@end

#pragma mark - Globals (main thread only)

static NSMutableDictionary *gReplyStates;       // chatKey -> RXReplyState
static RXReplyCapture *gReplyCapture;           // non-nil only inside -[CKTranscriptController sendMessage:]
static NSHashTable *gReplyPending;              // weak CKTranscriptControllers with a pending resize
static id gReplyKeyboardObserver;
static RXSwipeSession *gSwipeSession;
static char kRXEntryInfoKey;
static char kRXPendingKey;
static char kRXPanKey;

#pragma mark - Forward declarations

static RXReplyEntryInfo *RXReplyObserve(UIView *entry);
static RXReplyState *RXReplyStateForEntry(UIView *entry);
static CKTranscriptController *RXReplyControllerForEntry(UIView *entry);

#pragma mark - Small helpers

// Visible bubble body inside a balloon frame (R6 §1.2/§2.3): the art has a 1.5 pt halo on top, 4.5 pt of
// halo/shadow below, 2 pt on the plain side and 9.5 pt (tail) on the tail side.
static CGRect RXReplyBodyRect(CGRect b, BOOL outgoing) {
    CGFloat left = outgoing ? 2.0f : 9.5f;
    CGFloat right = outgoing ? 9.5f : 2.0f;
    CGRect r = CGRectMake(b.origin.x + left, b.origin.y + 1.5f, b.size.width - left - right, b.size.height - 6.0f);
    if (r.size.width < 1.0f || r.size.height < 1.0f) {
        return b;
    }
    return r;
}

static NSString *RXReplyChatKey(CKTranscriptController *tc) {
    if (!tc || ![tc respondsToSelector:@selector(conversation)]) {
        return nil;
    }
    return RXChatKeyForConversation([tc conversation]);
}

// Cheap first: with no chat in reply mode (always the case with Reactions off - a prefs change clears
// every state) no conversation -> chat -> chatIdentifier walk runs on the entry's hot paths.
static RXReplyState *RXReplyStateForController(CKTranscriptController *tc) {
    if (![gReplyStates count]) {
        return nil;
    }
    NSString *key = RXReplyChatKey(tc);
    if (!key.length) {
        return nil;
    }
    return [gReplyStates objectForKey:key];
}

// The entry view's controller is its _delegate ivar (R2 §5.1).
static CKTranscriptController *RXReplyControllerForEntry(UIView *entry) {
    if (!entry) {
        return nil;
    }
    id delegate = RXIvar(entry, "_delegate");
    return RXIsTranscriptController(delegate) ? (CKTranscriptController *)delegate : nil;
}

static RXReplyState *RXReplyStateForEntry(UIView *entry) {
    if (![gReplyStates count]) {
        return nil;
    }
    return RXReplyStateForController(RXReplyControllerForEntry(entry));
}

// -[CKTranscriptController entryView] is a plain ivar getter and may be nil before first use.
static CKMessageEntryView *RXReplyEntryForController(CKTranscriptController *tc) {
    if (!tc || !RXResponds(tc, @selector(entryView))) {
        return nil;
    }
    return [tc entryView];
}

static CGFloat RXReplyDefaultEntryHeight(void) {
    static CGFloat height;
    if (height <= 0.0f) {
        Class entryClass = NSClassFromString(@"CKMessageEntryView");
        SEL sel = NSSelectorFromString(@"defaultHeight");     // +defaultHeight f8@0:4 (CK.dump:22)
        if (entryClass && [entryClass respondsToSelector:sel]) {
            height = ((float (*)(id, SEL))objc_msgSend)(entryClass, sel);
        }
        if (height <= 0.0f) {
            height = 40.0f;
        }
    }
    return height;
}

static NSString *RXReplyOneLine(NSString *s) {
    if (!s.length) {
        return @"";
    }
    NSArray *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *joined = [lines componentsJoinedByString:@" "];
    return [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *RXReplyMediaNoun(RXTarget kind) {
    switch (kind) {
        case RXTargetImage:
            return @"Photo";
        case RXTargetMovie:
            return @"Video";
        case RXTargetAudio:
            return @"Audio Message";
        case RXTargetLocation:
            return @"Location";
        case RXTargetContact:
            return @"Contact";
        default:
            return @"Attachment";
    }
}

static NSString *RXReplySecondLine(RXReplyState *state) {
    if (state.kind != RXTargetText) {
        return RXReplyMediaNoun(state.kind);
    }
    NSString *snippet = RXReplyOneLine(state.snippet);
    if (!snippet.length) {
        return @"Message";
    }
    return [NSString stringWithFormat:@"\u201C%@\u201D", snippet];
}

#pragma mark - Artwork

// UIButtonBarReply.png tinted for the strip (R6 §6): stock #7A808C->#5A606C with a white a0.5 copy at
// (0,+1); wallpaper #8C929E->#6C727E, flat. Tinted with RXTint (raw components, never UIColor getters).
static UIImage *RXReplyStripGlyph(BOOL wallpaper, BOOL shadow) {
    static UIImage *cache[3];
    int slot = wallpaper ? 2 : (shadow ? 1 : 0);
    if (cache[slot]) {
        return cache[slot];
    }
    UIImage *mask = RXKitImage(@"UIButtonBarReply.png");
    if (!mask) {
        return nil;
    }
    RXGradient gradient;
    if (wallpaper) {
        gradient = RXGrad(0.549f, 0.573f, 0.620f, 1.0f, 0.424f, 0.447f, 0.494f, 1.0f);
    } else if (shadow) {
        gradient = RXSolid(1.0f, 1.0f, 1.0f, 0.5f);
    } else {
        gradient = RXGrad(0.478f, 0.502f, 0.549f, 1.0f, 0.353f, 0.376f, 0.424f, 1.0f);
    }
    cache[slot] = RXTint(mask, gradient);
    return cache[slot];
}

// MessageEntryBG as the entry draws it: contentStretch {0.125, 0.45, 0.75, 0.05} (R6 §1.4) as cap
// insets, stretched (not tiled).
static UIImage *RXReplyBodyArt(void) {
    static UIImage *art;
    static BOOL tried;
    if (art || tried) {
        return art;
    }
    tried = YES;
    UIImage *bg = RXCKImage(@"MessageEntryBG");
    CGSize s = bg.size;
    if (!bg || s.width < 2.0f || s.height < 4.0f) {
        return nil;
    }
    CGFloat top = floorf(s.height * 0.45f);
    CGFloat bottom = s.height - top - MAX(1.0f, floorf(s.height * 0.05f));
    CGFloat side = floorf(s.width * 0.125f);
    art = [bg resizableImageWithCapInsets:UIEdgeInsetsMake(top, side, bottom, side) resizingMode:UIImageResizingModeStretch];
    return art;
}

// The 32 pt strip (R6 §6.1, mockup v2-replybar): MessageEntryBG's top 1.5 pt unchanged (#A6A6A6 /
// #D2D2D2 / #FFFFFF), the rest of its gradient squeezed into the remaining 30.5 pt. Stretches only
// horizontally.
static UIImage *RXReplyStripArt(void) {
    static UIImage *art;
    static BOOL tried;
    if (art || tried) {
        return art;
    }
    tried = YES;
    UIImage *bg = RXCKImage(@"MessageEntryBG");
    CGSize s = bg.size;
    CGFloat lines = 1.5f;
    if (!bg || s.width < 2.0f || s.height <= lines + 1.0f) {
        return nil;
    }
    CGSize size = CGSizeMake(s.width, RX_REPLY_BAR_H);
    UIGraphicsBeginImageContextWithOptions(size, NO, bg.scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(0, 0, size.width, lines));
        [bg drawInRect:CGRectMake(0, 0, size.width, s.height)];
        CGContextRestoreGState(ctx);
        CGFloat sy = (size.height - lines) / (s.height - lines);
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(0, lines, size.width, size.height - lines));
        [bg drawInRect:CGRectMake(0, lines - lines * sy, size.width, s.height * sy)];
        CGContextRestoreGState(ctx);
    }
    UIImage *strip = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!strip) {
        return nil;
    }
    CGFloat side = floorf(s.width * 0.125f);
    art = [strip resizableImageWithCapInsets:UIEdgeInsetsMake(0, side, 0, side) resizingMode:UIImageResizingModeStretch];
    return art;
}

#pragma mark - Strip contents (drawn; no UILabel)

static const CGFloat kRXStripText[4]     = {0.443f, 0.471f, 0.502f, 1.0f};   // #717880
static const CGFloat kRXStripName[4]     = {0.188f, 0.392f, 0.671f, 1.0f};   // #3064AB (stock sender-name blue)
static const CGFloat kRXPillText[4]      = {0.227f, 0.247f, 0.282f, 1.0f};   // #3A3F48
static const CGFloat kRXPillName[4]      = {0.184f, 0.373f, 0.620f, 1.0f};   // #2F5F9E
static const CGFloat kRXPillSnippet[4]   = {0.478f, 0.502f, 0.549f, 1.0f};   // #7A808C

typedef struct {
    CGFloat centerY;
    CGFloat glyphX;
    CGFloat clearX;
} RXReplyStripGeometry;

// Geometry from the strip width (DESIGN §10 "x from entry width"; mockup src_v2/transcript.py).
static RXReplyStripGeometry RXReplyGeometry(CGRect bounds, BOOL wallpaper, CGRect pill) {
    RXReplyStripGeometry g;
    if (wallpaper && pill.size.width > 0.0f) {
        g.centerY = CGRectGetMidY(pill);
        g.glyphX = CGRectGetMinX(pill) + 9.0f;
        g.clearX = CGRectGetMaxX(pill) - 5.0f - 19.0f;
    } else {
        g.centerY = RX_REPLY_BAR_H / 2.0f + 0.5f;
        g.glyphX = 10.0f;
        g.clearX = bounds.size.width - 27.0f;
    }
    return g;
}

// One line at a baseline, tail-truncated, with the hard (0,+1) white a0.5 copy in stock mode.
static CGFloat RXReplyDrawText(NSString *text, UIFont *font, CGFloat x, CGFloat baseline, CGFloat maxWidth,
                               const CGFloat *rgba, BOOL engraved) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx || !text.length || !font || maxWidth <= 1.0f) {
        return 0.0f;
    }
    CGPoint p = CGPointMake(x, baseline - font.ascender);
    if (engraved) {
        CGContextSetRGBFillColor(ctx, 1.0f, 1.0f, 1.0f, 0.5f);
        [text drawAtPoint:CGPointMake(p.x, p.y + 1.0f) forWidth:maxWidth withFont:font lineBreakMode:NSLineBreakByTruncatingTail];
    }
    CGContextSetRGBFillColor(ctx, rgba[0], rgba[1], rgba[2], rgba[3]);
    CGSize drawn = [text drawAtPoint:p forWidth:maxWidth withFont:font lineBreakMode:NSLineBreakByTruncatingTail];
    return drawn.width;
}

static void RXReplyDrawThumbnail(UIImage *image, CGRect r, CGFloat scale) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGSize s = image.size;
    if (!ctx || s.width <= 0.0f || s.height <= 0.0f) {
        return;
    }
    CGFloat f = MAX(r.size.width / s.width, r.size.height / s.height);
    CGSize fill = CGSizeMake(s.width * f, s.height * f);
    CGRect dest = CGRectMake(CGRectGetMidX(r) - fill.width / 2.0f, CGRectGetMidY(r) - fill.height / 2.0f, fill.width, fill.height);
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:3.0f] addClip];
    [image drawInRect:dest];
    CGContextRestoreGState(ctx);
    CGFloat hair = 1.0f / MAX(scale, 1.0f);
    UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, hair / 2.0f, hair / 2.0f) cornerRadius:3.0f];
    edge.lineWidth = hair;
    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.0f, 0.0f, 0.25f);
    [edge stroke];
}

@interface RXReplyContentView : UIView
@property (nonatomic, strong) RXReplyState *state;
@property (nonatomic, assign) BOOL wallpaper;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, assign) CGRect pillRect;           // MW field pill line-up (wallpaper mode)
@property (nonatomic, assign) CGFloat pillAlpha;         // MW's text-box fill opacity (wallpaper mode)
- (CGRect)clearRect;
- (CGRect)clearHitRect;
@end

@implementation RXReplyContentView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clearsContextBeforeDrawing = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.userInteractionEnabled = NO;
        _pillAlpha = RX_MW_OPACITY_DEFAULT;
    }
    return self;
}

- (CGRect)clearRect {
    RXReplyStripGeometry g = RXReplyGeometry(self.bounds, self.wallpaper, self.pillRect);
    UIImage *art = RXKitImage(@"UITextFieldClearButton.png");
    CGSize s = art ? art.size : CGSizeMake(19.0f, 19.0f);
    return CGRectMake(g.clearX, roundf(g.centerY - s.height / 2.0f), s.width, s.height);
}

// >= 44 x 32 pt around the clear button (DESIGN §10).
- (CGRect)clearHitRect {
    CGRect c = [self clearRect];
    CGFloat height = MAX(RX_REPLY_BAR_H, self.bounds.size.height);
    return CGRectMake(CGRectGetMidX(c) - 22.0f, 0.0f, 44.0f, height);
}

- (void)drawRect:(CGRect)rect {
    RXReplyState *state = self.state;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!state || !ctx) {
        return;
    }
    BOOL wall = self.wallpaper;
    CGFloat scale = self.contentScaleFactor > 0.0f ? self.contentScaleFactor : 1.0f;
    RXReplyStripGeometry g = RXReplyGeometry(self.bounds, wall, self.pillRect);

    // MessageWallpapers: a floating white pill matching MW's field (white at MW's own text-box opacity,
    // default a0.94; 1 px black a0.22).
    CGRect pill = self.pillRect;
    if (wall && pill.size.width > 0.0f && pill.size.height > 0.0f) {
        CGFloat hair = 1.0f / scale;
        CGRect inner = CGRectInset(pill, hair / 2.0f, hair / 2.0f);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:MIN(14.0f, inner.size.height / 2.0f)];
        CGContextSetRGBFillColor(ctx, 1.0f, 1.0f, 1.0f, self.pillAlpha);
        [path fill];
        path.lineWidth = hair;
        CGContextSetRGBStrokeColor(ctx, 0.0f, 0.0f, 0.0f, 0.22f);
        [path stroke];
    }

    // Reply glyph at 0.62.
    UIImage *glyph = RXReplyStripGlyph(wall, NO);
    if (glyph) {
        CGSize gs = CGSizeMake(glyph.size.width * 0.62f, glyph.size.height * 0.62f);
        CGRect gr = CGRectMake(g.glyphX, g.centerY - gs.height / 2.0f, gs.width, gs.height);
        if (!wall) {
            [RXReplyStripGlyph(NO, YES) drawInRect:CGRectOffset(gr, 0.0f, 1.0f)];
        }
        [glyph drawInRect:gr];
    }

    CGRect clear = [self clearRect];
    CGFloat textX = g.glyphX + 15.5f + 7.0f;
    CGFloat right = CGRectGetMinX(clear) - 6.0f;
    if (state.kind != RXTargetText && state.thumbnail) {
        CGRect thumb = CGRectMake(CGRectGetMinX(clear) - 6.0f - 24.0f, roundf(g.centerY - 12.0f), 24.0f, 24.0f);
        RXReplyDrawThumbnail(state.thumbnail, thumb, scale);
        right = CGRectGetMinX(thumb) - 6.0f;
    }
    CGFloat maxWidth = right - textX;
    if (maxWidth > 8.0f) {
        UIFont *bold = [UIFont boldSystemFontOfSize:12.0f];
        UIFont *plain = [UIFont systemFontOfSize:12.0f];
        CGFloat line1 = g.centerY - 2.0f;
        CGFloat line2 = g.centerY + 11.0f;
        NSString *lead = @"Replying to";
        CGFloat leadWidth = RXReplyDrawText(lead, bold, textX, line1, maxWidth, wall ? kRXPillText : kRXStripText, !wall);
        CGFloat space = [@" " sizeWithFont:bold].width;
        if (space <= 0.0f) {
            space = 3.0f;
        }
        CGFloat nameX = textX + leadWidth + space;
        if (state.name.length && right - nameX > 8.0f) {
            RXReplyDrawText(state.name, bold, nameX, line1, right - nameX, wall ? kRXPillName : kRXStripName, !wall);
        }
        RXReplyDrawText(RXReplySecondLine(state), plain, textX, line2, maxWidth, wall ? kRXPillSnippet : kRXStripText, !wall);
    }

    UIImage *clearArt = RXKitImage(self.pressed ? @"UITextFieldClearButtonPressed.png" : @"UITextFieldClearButton.png");
    if (!clearArt && self.pressed) {
        clearArt = RXKitImage(@"UITextFieldClearButton.png");
    }
    [clearArt drawInRect:clear];
}

@end

#pragma mark - RXReplyBarView

@interface RXReplyBarView : UIView
@property (nonatomic, strong, readonly) UIImageView *bodyArt;     // MessageEntryBG from y = H (or 0) down
@property (nonatomic, strong, readonly) UIView *strip;            // 32 pt container, at y = 0 when grown, -H otherwise (clipped)
@property (nonatomic, strong, readonly) UIImageView *stripArt;
@property (nonatomic, strong, readonly) RXReplyContentView *content;
@property (nonatomic, assign) BOOL wallpaper;
@property (nonatomic, assign) BOOL active;                        // reply mode on and entry grown: clear button live
@property (nonatomic, assign) BOOL tracking;
@property (nonatomic, assign) NSUInteger hideToken;
@end

@implementation RXReplyBarView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingNone;
        self.isAccessibilityElement = NO;

        _bodyArt = [[UIImageView alloc] initWithImage:RXReplyBodyArt()];
        _bodyArt.frame = self.bounds;
        _bodyArt.userInteractionEnabled = NO;
        [self addSubview:_bodyArt];

        _strip = [[UIView alloc] initWithFrame:CGRectMake(0.0f, -RX_REPLY_BAR_H, frame.size.width, RX_REPLY_BAR_H)];
        _strip.opaque = NO;
        _strip.backgroundColor = [UIColor clearColor];
        _strip.userInteractionEnabled = NO;
        [self addSubview:_strip];

        _stripArt = [[UIImageView alloc] initWithImage:RXReplyStripArt()];
        _stripArt.frame = _strip.bounds;
        _stripArt.userInteractionEnabled = NO;
        [_strip addSubview:_stripArt];

        _content = [[RXReplyContentView alloc] initWithFrame:_strip.bounds];
        _content.alpha = 0.0f;
        _content.isAccessibilityElement = YES;
        _content.accessibilityTraits = UIAccessibilityTraitStaticText;
        [_strip addSubview:_content];
    }
    return self;
}

// Only the clear button takes touches; everything else falls through to the entry view.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.active || self.hidden || self.content.alpha < 0.5f) {
        return NO;
    }
    CGRect hit = [self convertRect:[self.content clearHitRect] fromView:self.content];
    return CGRectContainsPoint(hit, point);
}

- (void)rx_setPressed:(BOOL)pressed {
    if (self.content.pressed != pressed) {
        self.content.pressed = pressed;
        [self.content setNeedsDisplay];
    }
}

- (BOOL)rx_touchesNearClearButton:(NSSet *)touches {
    UITouch *touch = [touches anyObject];
    if (!touch) {
        return NO;
    }
    CGRect hit = [self convertRect:[self.content clearHitRect] fromView:self.content];
    return CGRectContainsPoint(CGRectInset(hit, -24.0f, -24.0f), [touch locationInView:self]);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    self.tracking = YES;
    [self rx_setPressed:YES];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (self.tracking) {
        [self rx_setPressed:[self rx_touchesNearClearButton:touches]];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    BOOL fire = self.tracking && self.content.pressed && self.active;
    self.tracking = NO;
    [self rx_setPressed:NO];
    if (fire) {
        CKTranscriptController *tc = RXReplyControllerForEntry(self.superview);
        if (tc) {
            RXReplyCancel(tc);
        }
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    self.tracking = NO;
    [self rx_setPressed:NO];
}

@end

// The swipe arrow (a class of its own so leftovers can be found and removed).
@interface RXReplyArrowView : UIImageView
@end

@implementation RXReplyArrowView
@end

#pragma mark - MessageWallpapers text-box opacity (DESIGN §10: the strip pill matches MW's field pill)

static NSHashTable *gReplyBars;                 // weak RXReplyBarViews, restyled when MW's opacity changes
static id gReplyMWObserver;
static BOOL gReplyMWSavedRead;
static CGFloat gReplyMWSaved = RX_MW_OPACITY_DEFAULT;

static CGFloat RXReplyClampUnit(CGFloat v) {
    if (!(v >= 0.0f)) {
        return 0.0f;
    }
    return v > 1.0f ? 1.0f : v;
}

// MW's saved setting ("FieldOpacity", default 0.94, clamped to 0...1 like MWFieldOpacity()).
static CGFloat RXReplyMWSavedOpacity(void) {
    if (!gReplyMWSavedRead) {
        gReplyMWSavedRead = YES;
        gReplyMWSaved = RX_MW_OPACITY_DEFAULT;
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:RX_MW_PREFS_PATH];
        id value = [prefs isKindOfClass:[NSDictionary class]] ? [prefs objectForKey:RX_MW_OPACITY_KEY] : nil;
        if ([value isKindOfClass:[NSNumber class]]) {
            gReplyMWSaved = RXReplyClampUnit([value floatValue]);
        }
    }
    return gReplyMWSaved;
}

// The live value: MW's field CALayer is a sublayer of entry.layer that belongs to no view (delegate nil)
// and has a border and rounded corners (MW Tweak.x MWStyleField); its fill is white at MWFieldOpacity()
// and follows MW's slider while it is dragged (unsaved). Else MW's saved setting.
static CGFloat RXReplyMWFieldOpacity(UIView *entry) {
    for (CALayer *layer in entry.layer.sublayers) {
        if (layer.delegate != nil || layer.borderWidth <= 0.0f || layer.cornerRadius <= 0.0f || !layer.backgroundColor) {
            continue;
        }
        return RXReplyClampUnit(CGColorGetAlpha(layer.backgroundColor));
    }
    return RXReplyMWSavedOpacity();
}

static void RXReplyUpdatePillAlpha(RXReplyBarView *bar, UIView *entry) {
    if (!bar || !entry || !bar.wallpaper) {
        return;
    }
    CGFloat alpha = RXReplyMWFieldOpacity(entry);
    if (fabsf(alpha - bar.content.pillAlpha) > 0.001f) {
        bar.content.pillAlpha = alpha;
        [bar.content setNeedsDisplay];
    }
}

// MW posts @"MWFieldOpacityChanged" in-process when its Text Box slider moves (MWStore.h:39); the visible
// strip pills follow on the next turn, after MW's own observer has recoloured its layer.
static void RXReplyWatchMWOpacity(RXReplyBarView *bar) {
    if (!bar) {
        return;
    }
    if (!gReplyBars) {
        gReplyBars = [NSHashTable weakObjectsHashTable];
    }
    [gReplyBars addObject:bar];
    if (gReplyMWObserver) {
        return;
    }
    gReplyMWObserver = [[NSNotificationCenter defaultCenter] addObserverForName:RX_MW_OPACITY_CHANGED
                                                                         object:nil
                                                                          queue:nil
                                                                     usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gReplyMWSavedRead = NO;             // re-read the saved value on the next fallback
            for (RXReplyBarView *view in [gReplyBars allObjects]) {
                RXReplyUpdatePillAlpha(view, view.superview);
            }
        });
    }];
}

#pragma mark - Entry tracking and bar layout

static RXReplyEntryInfo *RXReplyInfoForEntry(UIView *entry) {
    if (!entry) {
        return nil;
    }
    RXReplyEntryInfo *info = objc_getAssociatedObject(entry, &kRXEntryInfoKey);
    if (!info) {
        info = [[RXReplyEntryInfo alloc] init];
        objc_setAssociatedObject(entry, &kRXEntryInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return info;
}

// Does the entry's current height include H? Every entry resize goes through the size hooks, which add
// H exactly while reply mode is on, so a height change observed while reply mode is on means "grown"
// and one observed while it is off means "not grown". First sight: guess from the height.
static RXReplyEntryInfo *RXReplyObserve(UIView *entry) {
    RXReplyEntryInfo *info = RXReplyInfoForEntry(entry);
    if (!info) {
        return nil;
    }
    CGFloat height = entry.bounds.size.height;
    if (!info.seen) {
        info.seen = YES;
        info.lastHeight = height;
        info.grown = RXReplyStateForEntry(entry) != nil && height >= RXReplyDefaultEntryHeight() + RX_REPLY_BAR_H - 0.5f;
    } else if (fabsf(height - info.lastHeight) > 0.25f) {
        info.lastHeight = height;
        info.grown = RXReplyStateForEntry(entry) != nil;
    }
    return info;
}

static RXReplyBarView *RXReplyEnsureBar(UIView *entry, RXReplyEntryInfo *info, BOOL contentVisible) {
    if (!entry || !info) {
        return nil;
    }
    if (info.bar) {
        return info.bar;
    }
    BOOL animations = [UIView areAnimationsEnabled];
    [UIView setAnimationsEnabled:NO];
    RXReplyBarView *bar = [[RXReplyBarView alloc] initWithFrame:entry.bounds];
    bar.hidden = YES;
    bar.content.alpha = contentVisible ? 1.0f : 0.0f;
    [entry insertSubview:bar atIndex:0];
    [UIView setAnimationsEnabled:animations];
    info.bar = bar;
    RXReplyWatchMWOpacity(bar);
    return bar;
}

// Wallpaper pill: the same x/width as MW's field pill (fill frame inset x+1, w-8; MW Tweak.x:411-433),
// 28 pt tall, 2 pt below the entry's top.
static CGRect RXReplyPillRect(UIView *entry) {
    CGFloat width = entry.bounds.size.width;
    CGFloat x = 38.0f;
    CGFloat w = width - 76.0f;
    UIView *fill = RXIvar(entry, "_inputFieldBackground");
    if ([fill isKindOfClass:[UIView class]] && fill.frame.size.width > 16.0f) {
        x = fill.frame.origin.x;
        w = fill.frame.size.width;
    }
    return CGRectMake(x + 1.0f, 2.0f, MAX(w - 8.0f, 0.0f), RX_REPLY_BAR_H - 4.0f);
}

static void RXReplyScheduleHide(UIView *entry, RXReplyBarView *bar) {
    NSUInteger token = bar.hideToken + 1;
    bar.hideToken = token;
    __weak RXReplyBarView *weakBar = bar;
    __weak UIView *weakEntry = entry;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RX_REPLY_HIDE_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RXReplyBarView *strongBar = weakBar;
        UIView *strongEntry = weakEntry;
        if (!strongBar || !strongEntry || strongBar.hideToken != token) {
            return;
        }
        RXReplyEntryInfo *info = RXReplyObserve(strongEntry);
        if (info.grown || RXReplyStateForEntry(strongEntry)) {
            return;
        }
        strongBar.hidden = YES;
        strongBar.active = NO;
        strongBar.content.alpha = 0.0f;
        strongBar.content.state = nil;
    });
}

// Frames only (no layoutIfNeeded, no rendering): safe from -[CKMessageEntryView layoutSubviews] and
// inside ChatKit's resize animation, which then animates the strip in (y -H -> 0, clipped by the bar)
// while the MessageEntryBG part slides down by H — the field row stays put on screen.
static void RXReplyLayoutBar(UIView *entry, RXReplyEntryInfo *info, RXReplyState *state) {
    RXReplyBarView *bar = info.bar;
    if (!entry || !bar) {
        return;
    }
    if (bar.superview != entry) {
        [entry insertSubview:bar atIndex:0];
    } else if (entry.subviews.count && [entry.subviews objectAtIndex:0] != bar) {
        [entry sendSubviewToBack:bar];
    }
    CGRect bounds = entry.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    CGFloat H = RX_REPLY_BAR_H;
    BOOL grown = info.grown;
    if (!CGRectEqualToRect(bar.frame, bounds)) {
        bar.frame = bounds;
    }

    // Wallpaper mode = MW has emptied the entry's backing store; re-checked on every layout.
    BOOL wall = RXEntryIsWallpapered(entry);
    if (bar.wallpaper != wall || bar.content.wallpaper != wall) {
        bar.wallpaper = wall;
        bar.content.wallpaper = wall;
        [bar.content setNeedsDisplay];
    }
    bar.stripArt.hidden = wall;
    bar.bodyArt.hidden = wall;

    bar.strip.frame = CGRectMake(0.0f, grown ? 0.0f : -H, width, H);
    bar.stripArt.frame = bar.strip.bounds;
    bar.content.frame = bar.strip.bounds;
    CGRect pill = RXReplyPillRect(entry);
    if (!CGRectEqualToRect(pill, bar.content.pillRect)) {
        bar.content.pillRect = pill;
        [bar.content setNeedsDisplay];
    }
    RXReplyUpdatePillAlpha(bar, entry);
    if (state && bar.content.state != state) {
        bar.content.state = state;
        bar.content.accessibilityLabel = state.isMine ? @"Replying to your message" : @"Replying to a message";
        [bar.content setNeedsDisplay];
    }
    CGFloat top = grown ? H : 0.0f;
    bar.bodyArt.frame = CGRectMake(0.0f, top, width, MAX(height - top, 0.0f));

    bar.active = state != nil && grown;
    if (state || grown) {
        bar.hideToken = bar.hideToken + 1;      // cancels a scheduled hide
        bar.hidden = NO;
    } else if (!bar.hidden) {
        RXReplyScheduleHide(entry, bar);
    }
}

static void RXReplyFadeContent(RXReplyBarView *bar, BOOL show, BOOL animated) {
    UIView *content = bar.content;
    if (!content) {
        return;
    }
    CGFloat target = show ? 1.0f : 0.0f;
    if (animated && bar.window && !bar.hidden) {
        [UIView animateWithDuration:RX_REPLY_FADE
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             content.alpha = target;
                         }
                         completion:nil];
    } else {
        content.alpha = target;
    }
}

#pragma mark - Pending resize (events only)

static BOOL RXReplyIsPending(CKTranscriptController *tc) {
    return tc && objc_getAssociatedObject(tc, &kRXPendingKey) != nil;
}

static void RXReplySetPending(CKTranscriptController *tc, BOOL pending) {
    if (!tc) {
        return;
    }
    BOOL was = RXReplyIsPending(tc);
    objc_setAssociatedObject(tc, &kRXPendingKey, pending ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!pending) {
        [gReplyPending removeObject:tc];
        return;
    }
    if (!gReplyPending) {
        gReplyPending = [NSHashTable weakObjectsHashTable];
    }
    [gReplyPending addObject:tc];
    if (!gReplyKeyboardObserver) {
        // UIKeyboardDidShow is one of the retry events (DESIGN §10); retrying with nothing pending is a no-op.
        gReplyKeyboardObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                                                   object:nil
                                                                                    queue:[NSOperationQueue mainQueue]
                                                                               usingBlock:^(NSNotification *note) {
            for (CKTranscriptController *controller in [gReplyPending allObjects]) {
                RXReplyRetryPendingResize(controller);
            }
        }];
    }
    if (!was) {
        RXLog(@"reply: resize pending");
    }
}

#pragma mark - Reply mode transitions

typedef enum {
    RXReplyFadeNone = 0,     // leave the contents' alpha alone (retries)
    RXReplyFadeAnimated,     // 0.25 s (immediate when off screen)
} RXReplyFadeMode;

// Brings the entry in line with the reply state of tc's current chat.
// Enter: state -> _makeContentEntryViewActive -> _resizeMessageEntryViewWithAnimate:YES (same turn).
// Leave: state -> _resizeMessageEntryViewWithAnimate:YES (no activation: leaving must never raise the
// keyboard, e.g. on pop or a prefs change). ChatKit refuses while throwing a send, off-window, or when
// the size already matches; whatever is still mismatched afterwards is marked pending.
static void RXReplyApply(CKTranscriptController *tc, BOOL activate, RXReplyFadeMode fade) {
    if (!tc) {
        return;
    }
    RXReplyState *state = RXReplyStateForController(tc);
    if (activate && state) {
        if (RXReplyEntryForController(tc)) {
            if (RXResponds(tc, @selector(_makeContentEntryViewActive))) {
                [tc _makeContentEntryViewActive];
            }
        } else if (RXResponds(tc, @selector(showKeyboardForReply))) {
            [tc showKeyboardForReply];          // creates the entry (R2 §3.2)
        }
    }
    CKMessageEntryView *entry = RXReplyEntryForController(tc);
    if (!entry) {
        RXReplySetPending(tc, state != nil);
        return;
    }
    RXReplyEntryInfo *info = RXReplyObserve(entry);
    if (state || info.bar) {
        RXReplyEnsureBar(entry, info, NO);
        RXReplyLayoutBar(entry, info, state);   // outside the resize animation: its start state
        if (fade == RXReplyFadeAnimated) {
            RXReplyFadeContent(info.bar, state != nil, YES);
        }
    }
    BOOL want = state != nil;
    if (info.grown != want && RXResponds(tc, @selector(_resizeMessageEntryViewWithAnimate:))) {
        [tc _resizeMessageEntryViewWithAnimate:YES];
        info = RXReplyObserve(entry);
    }
    RXReplySetPending(tc, info.grown != want);
}

static RXReplyState *RXReplyMakeState(CKIMMessage *parent, NSInteger partKey, NSString *chatKey) {
    RXReplyState *state = [[RXReplyState alloc] init];
    state.chatKey = chatKey;
    state.parentGUID = [parent guid];
    NSArray *parts = [parent respondsToSelector:@selector(parts)] ? [parent parts] : nil;
    CKMessagePart *part = nil;
    if (partKey >= 0 && (NSUInteger)partKey < parts.count) {
        part = [parts objectAtIndex:(NSUInteger)partKey];
    } else if (parts.count) {
        part = [parts objectAtIndex:0];
    }
    if (part && ![part respondsToSelector:@selector(type)]) {
        part = nil;
    }
    state.partKey = partKey >= 0 ? partKey : 0;

    RXTarget kind = part ? RXTargetForPart(part) : RXTargetText;
    NSString *text = nil;
    if (kind == RXTargetText) {
        text = part ? RXTextForPart(part) : nil;
        if (!text.length && [parent respondsToSelector:@selector(_rawPreviewText)]) {
            text = [parent _rawPreviewText];       // never -previewText (failure summary)
        }
    } else if (kind == RXTargetUnknown) {
        text = part ? RXTextForPart(part) : nil;
        kind = text.length ? RXTargetText : RXTargetAnyAttachment;
    }
    state.kind = kind;
    if (kind == RXTargetText) {
        NSString *clean = text.length ? RXNormalize(text) : @"";
        clean = RXReplyOneLine(clean ?: @"");
        state.snippet = RXSafeTruncate(clean, RX_SNIPPET_MAX) ?: @"";
    } else {
        state.snippet = @"";
        if (part && [part respondsToSelector:@selector(previewImage)]) {
            state.thumbnail = [part previewImage];
        }
    }

    BOOL mine = [parent respondsToSelector:@selector(isFromMe)] && [parent isFromMe];
    state.isMine = mine;
    NSString *name = nil;
    if (mine) {
        name = @"You";
    } else {
        CKEntity *sender = [parent respondsToSelector:@selector(sender)] ? [parent sender] : nil;
        name = RXFirstNameForEntity(sender);
        if (!name.length && [parent respondsToSelector:@selector(address)]) {
            name = [parent address];
        }
    }
    state.name = name ?: @"";
    return state;
}

#pragma mark - Reply mode API (DESIGN §10)

void RXReplyBegin(CKTranscriptController *tc, CKIMMessage *parent, NSInteger partKey) {
    if (!tc || !parent || !RXOn(RXGetPrefs().swipe)) {
        return;
    }
    NSString *guid = [parent respondsToSelector:@selector(guid)] ? [parent guid] : nil;
    NSString *chatKey = RXReplyChatKey(tc);
    if (!guid.length || !chatKey.length) {
        RXLog(@"reply: not started (guid %d, chat %d)", guid.length ? 1 : 0, chatKey.length ? 1 : 0);
        return;
    }
    NSString *parentKey = RXChatKeyForMessage(parent);
    if (parentKey.length && ![parentKey isEqualToString:chatKey]) {
        RXLog(@"reply: parent %@ belongs to another chat", RXGUIDTail(guid));
        return;
    }
    RXReplyState *state = RXReplyMakeState(parent, partKey, chatKey);
    if (!state.parentGUID.length) {
        return;
    }
    // Observe the entry before the state exists, so its current height is recorded as "not grown".
    CKMessageEntryView *entry = RXReplyEntryForController(tc);
    if (entry) {
        RXReplyObserve(entry);
    }
    if (!gReplyStates) {
        gReplyStates = [NSMutableDictionary dictionary];
    }
    [gReplyStates setObject:state forKey:chatKey];
    RXReplyApply(tc, YES, RXReplyFadeAnimated);
    RXLog(@"reply: begin kind %d part %ld parent %@ snippet %lu media-thumb %d", (int)state.kind, (long)state.partKey,
          RXGUIDTail(state.parentGUID), (unsigned long)state.snippet.length, state.thumbnail ? 1 : 0);
}

void RXReplyCancel(CKTranscriptController *tc) {
    if (!tc) {
        return;
    }
    NSString *chatKey = RXReplyChatKey(tc);
    BOOL had = chatKey.length && [gReplyStates objectForKey:chatKey] != nil;
    if (had) {
        [gReplyStates removeObjectForKey:chatKey];
    }
    RXReplyApply(tc, NO, RXReplyFadeAnimated);
    if (had) {
        RXLog(@"reply: cancelled");
    }
}

// Prefs change (DESIGN 12, via RXTeardown): no chat keeps a reply bar, then tc's entry shrinks. Never
// checks prefs. Called once per live controller; the first call clears the states, every call fixes tc.
void RXReplyResetAll(CKTranscriptController *tc) {
    NSUInteger cleared = [gReplyStates count];
    [gReplyStates removeAllObjects];
    if (tc) {
        RXReplyApply(tc, NO, RXReplyFadeAnimated);
    }
    if (cleared) {
        RXLog(@"reply: %lu reply state(s) cleared (prefs change)", (unsigned long)cleared);
    }
}

BOOL RXReplyActive(CKTranscriptController *tc) {
    return RXReplyStateForController(tc) != nil;
}

void RXReplyConversationChanged(CKTranscriptController *tc) {
    if (!tc) {
        return;
    }
    // The size hooks already answer for the new chat; this shows/hides the strip and fixes the size.
    RXReplyApply(tc, NO, RXReplyFadeAnimated);
}

void RXReplyControllerPopped(CKTranscriptController *tc) {
    if (!tc) {
        return;
    }
    NSString *chatKey = RXReplyChatKey(tc);
    if (chatKey.length && [gReplyStates objectForKey:chatKey]) {
        [gReplyStates removeObjectForKey:chatKey];
        RXLog(@"reply: cleared (controller popped)");
    }
    RXReplyApply(tc, NO, RXReplyFadeAnimated);
}

void RXReplyRetryPendingResize(CKTranscriptController *tc) {
    if (!RXReplyIsPending(tc)) {
        return;
    }
    RXReplyApply(tc, NO, RXReplyFadeNone);
    if (!RXReplyIsPending(tc)) {
        RXLog(@"reply: pending resize applied");
    }
}

#pragma mark - Entry-view hooks

CGFloat RXReplySizeExtra(UIView *entry) {
    return RXReplyStateForEntry(entry) ? RX_REPLY_BAR_H : 0.0f;
}

// An entry never tracked while no reply state exists for it is stock: nothing to shift or lay out, and
// no RXReplyEntryInfo is attached (these run on every entry layout / frame computation, also with
// Reactions off). RXReplyBegin / RXReplyApply observe the entry before any state exists, so "grown"
// tracking is unaffected.
static BOOL RXReplyEntryUntracked(UIView *entry) {
    return objc_getAssociatedObject(entry, &kRXEntryInfoKey) == nil && RXReplyStateForEntry(entry) == nil;
}

BOOL RXReplyFramesShifted(UIView *entry) {
    if (!entry || RXReplyEntryUntracked(entry)) {
        return NO;
    }
    // "Grown" can only become YES while reply mode is on, and stays until the entry has actually
    // shrunk again (e.g. by the send throw), so field and bar always agree with the entry's height.
    return RXReplyObserve(entry).grown;
}

void RXReplyLayoutEntry(UIView *entry) {
    if (!entry || RXReplyEntryUntracked(entry)) {
        return;
    }
    RXReplyEntryInfo *info = RXReplyObserve(entry);
    RXReplyState *state = RXReplyStateForEntry(entry);
    if (!info.bar && !state) {
        return;
    }
    RXReplyEnsureBar(entry, info, state != nil);
    RXReplyLayoutBar(entry, info, state);
}

#pragma mark - Send capture (DESIGN §10, R2 §2.3)

void RXReplyCaptureBegin(CKTranscriptController *tc) {
    gReplyCapture = nil;
    RXReplyState *state = RXReplyStateForController(tc);
    if (!state) {
        return;
    }
    RXReplyCapture *capture = [[RXReplyCapture alloc] init];
    capture.controller = tc;
    capture.state = state;
    gReplyCapture = capture;
}

static void RXReplyStoreLink(NSString *replyGUID) {
    RXReplyCapture *capture = gReplyCapture;
    if (!capture || capture.stored || !replyGUID.length) {
        return;
    }
    capture.stored = YES;
    RXReplyState *state = capture.state;
    RXReplyLink *link = [[RXReplyLink alloc] init];
    link.parentGUID = state.parentGUID;
    link.partKey = state.partKey;
    link.kind = state.kind;
    link.snippet = state.snippet ?: @"";
    link.parentIsMine = state.isMine;
    link.parentName = state.name ?: @"";
    link.date = [NSDate date];
    RXStore *store = state.chatKey.length ? [RXStore storeForChatKey:state.chatKey create:YES] : nil;
    if (!store) {
        RXLog(@"reply: no store for the link of %@", RXGUIDTail(replyGUID));
        return;
    }
    [store setReplyLink:link forReplyGUID:replyGUID];
    RXLog(@"reply: link %@ -> %@ (kind %d, part %ld)", RXGUIDTail(replyGUID), RXGUIDTail(state.parentGUID),
          (int)state.kind, (long)state.partKey);
}

void RXReplyCaptureGUID(NSString *guidArg) {
    RXReplyStoreLink(guidArg);
}

void RXReplyCaptureMessage(id createdMessage) {
    if (!gReplyCapture || gReplyCapture.stored || !createdMessage) {
        return;
    }
    NSString *guid = [createdMessage respondsToSelector:@selector(guid)] ? [createdMessage guid] : nil;
    RXReplyStoreLink(guid);
}

void RXReplyCaptureEnd(CKTranscriptController *tc) {
    RXReplyCapture *capture = gReplyCapture;
    gReplyCapture = nil;
    if (!capture || !capture.stored) {
        return;     // nothing was created: keep reply mode so the user can try again
    }
    CKTranscriptController *controller = capture.controller ?: tc;
    RXReplyState *state = capture.state;
    if (state.chatKey.length && [gReplyStates objectForKey:state.chatKey] == state) {
        [gReplyStates removeObjectForKey:state.chatKey];
    }
    // Leave without resizing: the stock send throw collapses the bar (it resizes through the size
    // hooks, which no longer add H). Anything it doesn't do is retried from _finishSendAnimation.
    CKMessageEntryView *entry = RXReplyEntryForController(controller);
    if (entry) {
        RXReplyEntryInfo *info = RXReplyObserve(entry);
        RXReplyFadeContent(info.bar, NO, YES);
        RXReplySetPending(controller, info.grown);
    }
    RXLog(@"reply: sent; leaving reply mode");
}

#pragma mark - Swipe recognizer (DESIGN §9, R4 §5)

@interface RXReplyPanGestureRecognizer : UIPanGestureRecognizer
@property (nonatomic, assign) CGPoint rxStart;            // raw first-touch location in the table
@property (nonatomic, assign) CGPoint rxLast;             // raw latest location (set before super's touchesMoved)
@property (nonatomic, weak) CKTranscriptController *rxController;
@property (nonatomic, weak) UITableViewCell *rxCell;
@property (nonatomic, weak) CKBalloonView *rxBalloon;
@property (nonatomic, strong) NSIndexPath *rxPath;
@property (nonatomic, strong) CKIMMessage *rxMessage;
@property (nonatomic, copy) NSString *rxGUID;
@property (nonatomic, assign) NSInteger rxPartKey;
@end

@implementation RXReplyPanGestureRecognizer

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    if (touch && self.numberOfTouches == 0) {
        CGPoint p = [touch locationInView:self.view];
        self.rxStart = p;
        self.rxLast = p;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    if (touch) {
        self.rxLast = [touch locationInView:self.view];
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)reset {
    [super reset];
    self.rxController = nil;
    self.rxCell = nil;
    self.rxBalloon = nil;
    self.rxPath = nil;
    self.rxMessage = nil;
    self.rxGUID = nil;
    self.rxPartKey = 0;
}

@end

@interface RXReplySwipeController : NSObject <UIGestureRecognizerDelegate>
+ (RXReplySwipeController *)shared;
- (void)rxPan:(RXReplyPanGestureRecognizer *)pan;
@end

static CKIMMessage *RXSwipeMessageForBalloon(CKTranscriptController *tc, CKBalloonView *balloon, NSInteger row) {
    id message = nil;
    CKMessagePart *part = [balloon respondsToSelector:@selector(messagePart)] ? [balloon messagePart] : nil;
    if ([part respondsToSelector:@selector(parentMessage)]) {
        message = [part parentMessage];
    }
    if (!message) {
        CKTranscriptBubbleData *data = [tc respondsToSelector:@selector(bubbleData)] ? [tc bubbleData] : nil;
        if ([data respondsToSelector:@selector(count)] && [data respondsToSelector:@selector(messageAtIndex:)] &&
            row >= 0 && row < [data count]) {
            message = [data messageAtIndex:(int)row];
        }
    }
    if (![message respondsToSelector:@selector(guid)]) {
        return nil;
    }
    return message;
}

static NSInteger RXSwipePartKey(CKTranscriptController *tc, CKBalloonView *balloon, CKIMMessage *message, NSInteger row) {
    CKTranscriptBubbleData *data = [tc respondsToSelector:@selector(bubbleData)] ? [tc bubbleData] : nil;
    NSInteger key = data ? RXTranscriptPartKeyForRow(data, row) : NSNotFound;
    if (key == NSNotFound) {
        CKMessagePart *part = [balloon respondsToSelector:@selector(messagePart)] ? [balloon messagePart] : nil;
        NSArray *parts = [message respondsToSelector:@selector(parts)] ? [message parts] : nil;
        NSUInteger index = part ? [parts indexOfObjectIdenticalTo:part] : NSNotFound;
        key = index == NSNotFound ? 0 : (NSInteger)index;
    }
    return key;
}

// The stashed candidate still maps to the same row, balloon and message (cells can be reused).
static BOOL RXSwipeCandidateValid(RXReplyPanGestureRecognizer *pan) {
    UITableView *table = [pan.view isKindOfClass:[UITableView class]] ? (UITableView *)pan.view : nil;
    CKTranscriptController *tc = pan.rxController;
    UITableViewCell *cell = pan.rxCell;
    CKBalloonView *balloon = pan.rxBalloon;
    if (!table || !tc || !cell || !balloon || !pan.rxPath || !pan.rxMessage || table.isEditing) {
        return NO;
    }
    if (RXPickerIsOpen(tc) || gSwipeSession) {
        return NO;
    }
    NSIndexPath *path = [table indexPathForCell:cell];
    if (!path || ![path isEqual:pan.rxPath]) {
        return NO;
    }
    if (![cell respondsToSelector:@selector(balloonView)] || [(CKMessageCell *)cell balloonView] != balloon) {
        return NO;
    }
    CKMessagePart *part = [balloon respondsToSelector:@selector(messagePart)] ? [balloon messagePart] : nil;
    id current = [part respondsToSelector:@selector(parentMessage)] ? [part parentMessage] : nil;
    if ([current respondsToSelector:@selector(guid)] && ![[current guid] isEqualToString:pan.rxGUID]) {
        return NO;
    }
    return YES;
}

static void RXSwipeCancelRecognizer(UIGestureRecognizer *recognizer) {
    if (recognizer && recognizer.enabled) {
        recognizer.enabled = NO;
        recognizer.enabled = YES;
    }
}

// Vertical centre of the bubble's visible part (table bounds minus its content insets).
static CGFloat RXSwipeArrowY(UITableView *table, UIView *host, CGRect body) {
    CGFloat y = CGRectGetMidY(body);
    if (!table || !host) {
        return y;
    }
    UIEdgeInsets inset = table.contentInset;
    CGRect visible = table.bounds;
    visible.origin.y += inset.top;
    visible.size.height -= inset.top + inset.bottom;
    if (visible.size.height <= 0.0f) {
        return y;
    }
    CGRect inHost = [table convertRect:visible toView:host];
    CGRect shown = CGRectIntersection(body, inHost);
    if (CGRectIsNull(shown) || CGRectIsEmpty(shown)) {
        return y;
    }
    return CGRectGetMidY(shown);
}

// Additive, presentation-only offset (R4 §5.5): replaces the previous frame's animation.
static void RXSwipeHold(CALayer *layer, CGFloat d) {
    if (!layer) {
        return;
    }
    CABasicAnimation *hold = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    hold.additive = YES;
    hold.fromValue = @(d);
    hold.toValue = @(d);
    hold.duration = 1.0e6;
    hold.fillMode = kCAFillModeBoth;
    hold.removedOnCompletion = NO;
    [layer addAnimation:hold forKey:RX_SWIPE_KEY];
}

// 0.36 s critically damped spring back: x(t) = d (1 + wt) e^(-wt), w = 22, 24 keyframes, last 0.
static void RXSwipeSpringBack(CALayer *layer, CGFloat d) {
    if (!layer) {
        return;
    }
    if (d <= 0.01f) {
        [layer removeAnimationForKey:RX_SWIPE_KEY];
        return;
    }
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:RX_SPRING_N + 1];
    for (int i = 0; i <= RX_SPRING_N; i++) {
        float t = RX_SPRING_T * (float)i / (float)RX_SPRING_N;
        float v = (i == RX_SPRING_N) ? 0.0f : d * (1.0f + RX_SPRING_W * t) * expf(-RX_SPRING_W * t);
        [values addObject:@(v)];
    }
    CAKeyframeAnimation *spring = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    spring.additive = YES;
    spring.values = values;
    spring.duration = RX_SPRING_T;
    [layer addAnimation:spring forKey:RX_SWIPE_KEY];
}

static void RXSwipeStripCell(UITableViewCell *cell) {
    if (![cell respondsToSelector:@selector(balloonView)]) {
        return;
    }
    CKBalloonView *balloon = [(CKMessageCell *)cell balloonView];
    [balloon.layer removeAnimationForKey:RX_SWIPE_KEY];
    UIView *host = balloon.superview ?: cell;
    for (UIView *view in [host.subviews copy]) {
        if ([view isKindOfClass:[RXReplyArrowView class]]) {
            [view removeFromSuperview];
        } else if ([view isKindOfClass:[RXReactionBalloonView class]] || [view isKindOfClass:[RXQuoteBalloonView class]]) {
            [view.layer removeAnimationForKey:RX_SWIPE_KEY];
        }
    }
    UIView *failed = RXIvar(cell, "_failedButton");
    if ([failed isKindOfClass:[UIView class]]) {
        [failed.layer removeAnimationForKey:RX_SWIPE_KEY];
    }
}

// Ends our hold exactly once, and only if ChatKit still has it (resetHoldingUpdates empties the stack).
static void RXSwipeEndHold(RXSwipeSession *session) {
    if (!session || !session.holding || session.holdReleased) {
        return;
    }
    session.holdReleased = YES;
    CKTranscriptController *tc = session.controller;
    if (!tc) {
        return;
    }
    BOOL held = YES;
    if (class_getInstanceVariable(object_getClass(tc), "_holdingUpdatesKeyStack")) {
        id stack = RXIvar(tc, "_holdingUpdatesKeyStack");      // CKMultiDict (CK.dump:228)
        if (!stack) {
            held = NO;
        } else if ([stack respondsToSelector:@selector(objectsForKey:)]) {
            held = [[stack objectsForKey:RX_HOLD_KEY] count] > 0;
        }
    } else {
        // Can't verify: ending is the lesser risk (a stuck hold would freeze the transcript).
        RXLogOnce(@"reply.holdstack", @"swipe: _holdingUpdatesKeyStack missing; hold ended unchecked");
    }
    if (!held) {
        RXLog(@"swipe: hold already released by ChatKit");
        return;
    }
    if (RXResponds(tc, @selector(_endHoldingUpdatesToTranscriptWithKey:))) {
        [tc _endHoldingUpdatesToTranscriptWithKey:RX_HOLD_KEY];
    }
}

static void RXSwipeFinish(RXSwipeSession *session) {
    if (!session || session.finished) {
        return;
    }
    session.finished = YES;
    if (gSwipeSession == session) {
        gSwipeSession = nil;
    }
    [session.arrow removeFromSuperview];
    session.arrow = nil;
    RXSwipeEndHold(session);
    CKTranscriptController *tc = session.controller;
    session.views = nil;
    if (tc) {
        RXTranscriptPoke(tc);       // swipe-session end is a gated-refresh retry event (DESIGN §5.6)
    }
}

static void RXSwipeUpdateArrow(RXSwipeSession *session, BOOL wasArmed) {
    RXReplyArrowView *arrow = session.arrow;
    if (!arrow) {
        return;
    }
    CGFloat d = session.d;
    CGFloat p = MIN(1.0f, d / RX_SWIPE_ARM);
    CGFloat scale = 0.6f + 0.4f * p;
    CGFloat alpha = 1.0f;
    if (!session.armed) {
        CGFloat rise = (d - 8.0f) / (RX_SWIPE_ARM - 8.0f);
        alpha = 0.6f * MAX(0.0f, MIN(1.0f, rise));
    }
    if (session.armed != wasArmed) {
        UIImage *image = RXReplyArrowImage(session.armed, session.wallpaper, 1.0f);
        if (image) {
            arrow.image = image;
            arrow.bounds = CGRectMake(0.0f, 0.0f, image.size.width, image.size.height);
        }
    }
    arrow.transform = CGAffineTransformMakeScale(scale, scale);
    arrow.center = CGPointMake(MAX(12.0f, CGRectGetMinX(session.body) + d / 2.0f), session.arrowY);
    arrow.alpha = alpha;
    if (session.armed && !wasArmed) {
        CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        pop.values = @[@1.0f, @1.15f, @1.0f];
        pop.duration = RX_ARROW_POP;
        [arrow.layer addAnimation:pop forKey:RX_ARROW_POP_KEY];
    }
}

static void RXSwipeBegin(RXReplyPanGestureRecognizer *pan) {
    CKTranscriptController *tc = pan.rxController;
    UITableView *table = [pan.view isKindOfClass:[UITableView class]] ? (UITableView *)pan.view : nil;
    UITableViewCell *cell = pan.rxCell;
    CKBalloonView *balloon = pan.rxBalloon;
    UIView *host = balloon.superview;
    if (gSwipeSession || !tc || !table || !cell || !balloon || !host || !pan.rxMessage) {
        RXSwipeCancelRecognizer(pan);
        return;
    }
    RXSwipeSession *session = [[RXSwipeSession alloc] init];
    session.pan = pan;
    session.controller = tc;
    session.table = table;
    session.message = pan.rxMessage;
    session.partKey = pan.rxPartKey;
    session.outgoing = [balloon respondsToSelector:@selector(orientation)] && [balloon orientation] != 0;
    session.body = RXReplyBodyRect(balloon.frame, session.outgoing);
    session.wallpaper = RXTableIsWallpapered(table);

    // What moves: the balloon, our badge/quote views beside it, and the red "!" (DESIGN §9).
    NSMutableArray *views = [NSMutableArray arrayWithObject:balloon];
    for (UIView *view in host.subviews) {
        if ([view isKindOfClass:[RXReactionBalloonView class]] || [view isKindOfClass:[RXQuoteBalloonView class]]) {
            [views addObject:view];
        }
    }
    UIView *failed = RXIvar(cell, "_failedButton");
    if ([failed isKindOfClass:[UIView class]]) {
        [views addObject:failed];
    }
    session.views = views;

    if ([balloon respondsToSelector:@selector(hideCopyCallout)]) {
        [balloon hideCopyCallout];
    }
    if (RXPickerIsOpen(tc)) {
        RXPickerDismiss(tc, YES);
    }
    if (RXResponds(tc, @selector(_beginHoldingUpdatesToTranscriptWithKey:))) {
        [tc _beginHoldingUpdatesToTranscriptWithKey:RX_HOLD_KEY];
        session.holding = YES;
    }

    UIImage *image = RXReplyArrowImage(NO, session.wallpaper, 1.0f);
    RXReplyArrowView *arrow = [[RXReplyArrowView alloc] initWithImage:image];
    arrow.userInteractionEnabled = NO;
    arrow.alpha = 0.0f;
    [host insertSubview:arrow belowSubview:balloon];
    session.arrow = arrow;
    session.arrowY = RXSwipeArrowY(table, host, session.body);

    gSwipeSession = session;
    RXLog(@"swipe: begin (%@, %lu layers, hold %d)", session.outgoing ? @"out" : @"in", (unsigned long)views.count,
          session.holding ? 1 : 0);
}

static void RXSwipeTrack(RXReplyPanGestureRecognizer *pan) {
    RXSwipeSession *session = gSwipeSession;
    if (!session || session.pan != pan || session.released) {
        return;
    }
    CGFloat t = MAX(0.0f, [pan translationInView:pan.view].x);
    CGFloat d = MIN(RX_SWIPE_CAP, RX_SWIPE_R * (1.0f - expf(-t / RX_SWIPE_R)));
    session.d = d;
    BOOL wasArmed = session.armed;
    if (!session.armed && d >= RX_SWIPE_ARM) {
        session.armed = YES;
    } else if (session.armed && d < RX_SWIPE_DISARM) {
        session.armed = NO;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *view in session.views) {
        RXSwipeHold(view.layer, d);
    }
    RXSwipeUpdateArrow(session, wasArmed);
    [CATransaction commit];
    if (session.armed && !wasArmed) {
        if (RXOn(RXGetPrefs().haptic)) {
            RXTick();
        }
        if (!session.everArmed) {
            session.everArmed = YES;
            RXLog(@"swipe: armed");
        }
    }
}

static void RXSwipeRelease(RXReplyPanGestureRecognizer *pan, BOOL ended) {
    RXSwipeSession *session = gSwipeSession;
    if (!session || session.pan != pan || session.released) {
        return;
    }
    session.released = YES;
    BOOL reply = ended && session.armed;
    CGFloat d = session.d;
    [CATransaction begin];
    for (UIView *view in session.views) {
        RXSwipeSpringBack(view.layer, d);
    }
    [CATransaction commit];
    UIView *arrow = session.arrow;
    [UIView animateWithDuration:RX_ARROW_FADE
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         arrow.alpha = 0.0f;
                     }
                     completion:nil];
    if (reply) {
        CKTranscriptController *tc = session.controller;
        if (tc && session.message) {
            RXReplyBegin(tc, session.message, session.partKey);
        }
    }
    RXLog(@"swipe: %@ at d %.1f", reply ? @"reply" : (ended ? @"released" : @"cancelled"), (double)d);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RX_SESSION_END_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RXSwipeFinish(session);
    });
}

@implementation RXReplySwipeController

+ (RXReplySwipeController *)shared {
    static RXReplySwipeController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[RXReplySwipeController alloc] init];
    });
    return shared;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (![recognizer isKindOfClass:[RXReplyPanGestureRecognizer class]]) {
        return NO;
    }
    RXReplyPanGestureRecognizer *pan = (RXReplyPanGestureRecognizer *)recognizer;
    if (pan.numberOfTouches > 0) {
        return YES;     // a second finger: failsPastMaxTouches fails the swipe
    }
    UITableView *table = [recognizer.view isKindOfClass:[UITableView class]] ? (UITableView *)recognizer.view : nil;
    if (!table || table.isEditing || table.isDecelerating) {
        return NO;
    }
    if (!RXOn(RXGetPrefs().swipe) || UIAccessibilityIsVoiceOverRunning() || gSwipeSession) {
        return NO;
    }
    CKTranscriptController *tc = (CKTranscriptController *)RXControllerForView(table);
    if (!tc || RXPickerIsOpen(tc)) {
        return NO;
    }
    // SwipeBack owns the outer 10 pt of the navigation view (R4 §2.2): same space, same constants.
    UIView *nav = tc.navigationController.view ?: table.window;
    if (nav) {
        CGFloat x = [touch locationInView:nav].x;
        if (x < RX_SWIPE_EDGE || x > nav.bounds.size.width - RX_SWIPE_EDGE) {
            return NO;
        }
    }
    NSIndexPath *path = [table indexPathForRowAtPoint:[touch locationInView:table]];
    if (!path || path.section != 0) {
        return NO;
    }
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (!cell || cell.hidden || ![cell respondsToSelector:@selector(balloonView)]) {
        return NO;
    }
    CKBalloonView *balloon = [(CKMessageCell *)cell balloonView];
    UIView *host = balloon.superview;
    if (!balloon || !host || balloon.hidden || balloon.alpha < 0.01f) {
        return NO;
    }
    BOOL outgoing = [balloon respondsToSelector:@selector(orientation)] && [balloon orientation] != 0;
    CGRect body = CGRectInset(RXReplyBodyRect(balloon.frame, outgoing), RX_SWIPE_HIT_INSET, RX_SWIPE_HIT_INSET);
    if (!CGRectContainsPoint(body, [touch locationInView:host])) {
        return NO;
    }
    CKIMMessage *message = RXSwipeMessageForBalloon(tc, balloon, path.row);
    if (!message) {
        return NO;
    }
    // -[CKIMMessage pending] is YES for every received message (no sent count), so only outgoing ones count.
    if (([message respondsToSelector:@selector(isFromMe)] && [message isFromMe] &&
         [message respondsToSelector:@selector(pending)] && [message pending])
        || ([message respondsToSelector:@selector(isTypingIndicator)] && [message isTypingIndicator])
        || ([message respondsToSelector:@selector(isPlaceholder)] && [message isPlaceholder])) {
        return NO;
    }
    NSString *guid = [message guid];
    if (!guid.length) {
        return NO;
    }
    pan.rxController = tc;
    pan.rxCell = cell;
    pan.rxBalloon = balloon;
    pan.rxPath = path;
    pan.rxMessage = message;
    pan.rxGUID = guid;
    pan.rxPartKey = RXSwipePartKey(tc, balloon, message, path.row);
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (![recognizer isKindOfClass:[RXReplyPanGestureRecognizer class]]) {
        return NO;
    }
    RXReplyPanGestureRecognizer *pan = (RXReplyPanGestureRecognizer *)recognizer;
    // Raw deltas, not -translationInView: (UIKit has already removed the hysteresis there, R4 U7).
    CGFloat dx = pan.rxLast.x - pan.rxStart.x;
    CGFloat dy = pan.rxLast.y - pan.rxStart.y;
    CGPoint velocity = [pan velocityInView:pan.view];
    if (dx < RX_SWIPE_SLOP || fabsf(dy) > dx * RX_SWIPE_CONE || velocity.x < 0.0f) {
        return NO;      // v.x < 0 belongs to MessageTimes
    }
    return RXSwipeCandidateValid(pan);
}

- (void)rxPan:(RXReplyPanGestureRecognizer *)pan {
    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        RXSwipeBegin(pan);
        RXSwipeTrack(pan);
    } else if (state == UIGestureRecognizerStateChanged) {
        RXSwipeTrack(pan);
    } else if (state == UIGestureRecognizerStateEnded) {
        RXSwipeRelease(pan, YES);
    } else if (state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
        RXSwipeRelease(pan, NO);
    }
}

@end

#pragma mark - Swipe API

void RXReplyInstallPan(CKTranscriptController *tc) {
    UITableView *table = RXResponds(tc, @selector(transcriptTable)) ? [tc transcriptTable] : nil;
    if (!table || objc_getAssociatedObject(table, &kRXPanKey)) {
        return;
    }
    RXReplySwipeController *handler = [RXReplySwipeController shared];
    RXReplyPanGestureRecognizer *pan = [[RXReplyPanGestureRecognizer alloc] initWithTarget:handler action:@selector(rxPan:)];
    pan.delegate = handler;
    pan.maximumNumberOfTouches = 1;
    if ([pan respondsToSelector:@selector(setFailsPastMaxTouches:)]) {
        [pan setFailsPastMaxTouches:YES];
    }
    pan.cancelsTouchesInView = YES;
    pan.delaysTouchesBegan = NO;
    [table addGestureRecognizer:pan];
    // The only failure edge: the table's scrolling waits for us (as for MessageTimes). Ours waits for nothing.
    [table.panGestureRecognizer requireGestureRecognizerToFail:pan];
    objc_setAssociatedObject(table, &kRXPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RXLog(@"swipe: recognizer installed");
}

BOOL RXSwipeSessionActive(void) {
    return gSwipeSession != nil;
}

void RXSwipeTeardown(CKTranscriptController *tc) {
    RXSwipeSession *session = gSwipeSession;
    if (session && (!tc || !session.controller || session.controller == tc)) {
        gSwipeSession = nil;
        session.released = YES;
        session.finished = YES;
        for (UIView *view in session.views) {
            [view.layer removeAnimationForKey:RX_SWIPE_KEY];
        }
        [session.arrow.layer removeAllAnimations];
        [session.arrow removeFromSuperview];
        session.arrow = nil;
        RXSwipeEndHold(session);
        session.views = nil;
        RXReplyPanGestureRecognizer *pan = session.pan;
        if (pan && (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged)) {
            RXSwipeCancelRecognizer(pan);
        }
        RXLog(@"swipe: torn down");
    }
    // Leftovers: spring-backs still running, arrows on cells that went elsewhere.
    UITableView *table = (tc && [tc respondsToSelector:@selector(transcriptTable)]) ? [tc transcriptTable] : nil;
    for (UITableViewCell *cell in table.visibleCells) {
        RXSwipeStripCell(cell);
    }
}
