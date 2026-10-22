// RXPicker.m - Reactions 2.0: the reaction picker (DESIGN.md section 7; R6 sections 1.6 and 8;
// mockups research/mockups/v2/v2-picker-group.png and v2-picker-emoji7.png, geometry from src_v2/extras.py).
//
// The picker is the stock iOS 6 callout bar rebuilt from UIKit's own UICalloutBar* artwork (an iOS 6
// UIMenuItem cannot carry an image, R6 1.6). It lives in the transcript controller's view inside a
// full-size pass-through "catcher": a touch on the bar goes to the bar; any other touch schedules a
// dismissal and falls through to whatever is underneath (the first drag scrolls, a tap on a link works).
//
// Owned API (RXShared.h): RXPickerToggle, RXPickerPresentForBadge, RXPickerDismiss, RXPickerIsOpen.
//
// Rules kept here:
//  * Prefs are never checked (the hook layer gates opening; closing must always work).
//  * RXPickerDismiss is teardown-safe: it never forms a weak reference to the controller and never
//    touches tc.view, so it may run from -[CKTranscriptController dealloc].
//  * Colours only as raw components; translucent fills with CGContextFillRect; no UILabel; logs carry
//    kinds, counts and GUID tails only.

#import "RXShared.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Metrics (R6 1.5 / 1.6 / 8, extras.py)

#define RXP_BAR_H             38.0f   // callout body height (76 px art)
#define RXP_ITEM_W            46.0f   // six segments = 276 pt
#define RXP_ITEM_W_EMOJI      40.0f   // seven segments (my emoji reaction shown) = 280 pt
#define RXP_TRAY_H            22.0f   // group-chat "who reacted" caption tray
#define RXP_TIP               10.5f   // arrow tip distance from the bar (or tray) edge
#define RXP_TARGET_GAP        0.5f    // the tip stops 0.5 pt short of the target rect
#define RXP_EDGE              6.0f    // bar x is clamped to [6, W - 6 - width]
#define RXP_ARROW_END         11.0f   // the arrow stays 11 pt from both bar ends
#define RXP_ARROW_W           24.0f   // fallback arrow width when the art is missing
#define RXP_SHADOW_H          17.0f   // UICalloutBarShadow* / ArrowBottom height
#define RXP_GLYPH_BOX         22.0f   // segment glyph box
#define RXP_GLYPH_CY          19.5f   // glyph centre below the bar top
#define RXP_SQUARE_REF        27.5f   // last art row (pt) above the rounded bottom corners
#define RXP_TRAY_UPPER_Y      20.0f   // tray source rows in the plain bar: straight lower gradient...
#define RXP_TRAY_UPPER_H      11.0f
#define RXP_TRAY_CORNER_Y     31.0f   // ...and the rounded bottom corners
#define RXP_TRAY_CORNER_H     7.0f
#define RXP_CAP_FONT          12.0f   // caption: bold 12, white, black a0.5 at (0,-1)
#define RXP_CAP_GLYPH         13.0f   // caption glyph box
#define RXP_CAP_PAD           10.0f   // caption side padding inside the tray
#define RXP_PIN_TOP           4.0f    // gap under the visible top when pinned
#define RXP_POP_UP            0.16    // stock pop: 0.5 -> 1.05 ...
#define RXP_POP_SETTLE        0.08    // ... -> 1.0
#define RXP_FADE              0.1     // close fade
#define RXP_FADE_SLACK        0.15    // the closing gate expires this long after the fade even without its completion
#define RXP_SUPPRESS_S        0.6     // a touch that closed the picker on its own bubble eats the
                                      // double-tap / badge tap that follows (toggle semantics)
#define RXP_KIND_COUNT        6
#define RXP_VALIDATE_ROWS     64      // rows scanned after the message's first row on pick

typedef enum {
    RXPPlaceAbove = 0,     // bar above the target, UICalloutBarArrowBottom
    RXPPlaceBelow,         // bar below the target, UICalloutBarArrowTop
    RXPPlacePinned,        // no room either way: pinned to the top of the visible area
} RXPPlacement;

static const RXKind kRXPKinds[RXP_KIND_COUNT] = {
    RXKindLove, RXKindLike, RXKindDislike, RXKindLaugh, RXKindEmph, RXKindQuestion
};

static char kRXPickerKey;                       // associated object on the controller: the open session
static char kRXPickerClosingKey;                // ... and the session whose close fade is running (gate stays closed)

// Toggle bookkeeping: the bubble whose own tap just closed the picker (DESIGN 7: "close, if this
// bubble's picker is already open" - the catcher sees the double-tap's first touch before ChatKit).
static NSString *gRXPSuppressGUID;
static NSInteger gRXPSuppressPart;
static CFTimeInterval gRXPSuppressTime;

@class RXPickerSession;

#pragma mark - Forward declarations

static UIImage *RXPArt(NSString *base, BOOL hi);
static UIImage *RXPSegmentArt(NSString *base, BOOL hi, BOOL squared);
static UIImage *RXPTrayImage(CGFloat width, CGFloat height);
static CGFloat RXPCaptionLayout(NSArray *entries, NSUInteger shown, NSUInteger more, UIFont *font,
                                BOOL draw, CGFloat x, CGFloat textY, CGFloat glyphCentreY);
static NSString *RXPAccessibilityLabel(RXKind kind, NSString *emoji);
static RXPickerSession *RXPSession(CKTranscriptController *tc);
static void RXPPick(RXPickerSession *s, NSInteger index);
static void RXPOutsideTouch(RXPickerSession *s, CGPoint point);
static void RXPDismissSession(RXPickerSession *s, BOOL animated);
static void RXPClose(RXPickerSession *s, BOOL animated);

#pragma mark - Art (exact UICalloutBar* names, DESIGN 7)

// UICalloutBar<base>[Hi].png via RXKitImage (cached, misses logged once by RXCore). A missing Hi
// variant falls back to the plain art.
static UIImage *RXPArt(NSString *base, BOOL hi) {
    UIImage *img = nil;
    if (hi) {
        img = RXKitImage([NSString stringWithFormat:@"UICalloutBar%@Hi.png", base]);
    }
    if (!img) {
        img = RXKitImage([NSString stringWithFormat:@"UICalloutBar%@.png", base]);
    }
    return img;
}

// Callout end-cap art with its bottom corners squared off, so the caption tray joins under the bar
// without notches (extras.py square_bottom): below the last straight row, the edge columns (halo and
// the 1 pt border) repeat that row and every other column takes the body colour of its own row.
static UIImage *RXPSquareBottom(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) {
        return img;
    }
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    CGFloat scale = img.scale > 0.0f ? img.scale : 1.0f;
    size_t ref = (size_t)floorf(RXP_SQUARE_REF * scale);
    if (w < 3 || h < 2 || ref + 1 >= h) {
        return img;
    }
    size_t bpr = w * 4;
    unsigned char *buf = (unsigned char *)calloc(h, bpr);
    unsigned char *edge = (unsigned char *)calloc(w, 1);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = NULL;
    if (buf && edge && rgb) {
        bc = CGBitmapContextCreate(buf, w, h, 8, bpr, rgb,
                                   (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    }
    if (rgb) {
        CGColorSpaceRelease(rgb);
    }
    if (!bc) {
        free(buf);
        free(edge);
        return img;
    }
    CGContextDrawImage(bc, CGRectMake(0.0f, 0.0f, (CGFloat)w, (CGFloat)h), cg);
    const unsigned char *refRow = buf + ref * bpr;
    const unsigned char *mid = refRow + (w / 2) * 4;
    for (size_t x = 0; x < w; x++) {
        int d = 0;
        for (size_t c = 0; c < 4; c++) {
            int diff = abs((int)refRow[x * 4 + c] - (int)mid[c]);
            if (diff > d) {
                d = diff;
            }
        }
        edge[x] = (unsigned char)(d > 6 ? 1 : 0);
    }
    for (size_t y = ref + 1; y < h; y++) {
        unsigned char *row = buf + y * bpr;
        size_t m = (w / 2) * 4;
        unsigned char body[4] = { row[m], row[m + 1], row[m + 2], 255 };
        for (size_t x = 0; x < w; x++) {
            const unsigned char *src = edge[x] ? refRow + x * 4 : body;
            memcpy(row + x * 4, src, 4);
        }
    }
    CGImageRef outCG = CGBitmapContextCreateImage(bc);
    CGContextRelease(bc);
    free(buf);
    free(edge);
    if (!outCG) {
        return img;
    }
    UIImage *out = [UIImage imageWithCGImage:outCG scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(outCG);
    return out ? out : img;
}

// Segment art as UICalloutBarButton uses it (R6 1.6): Left/Right(+Hi) stretchable with a 10 pt cap,
// Single(+Hi) 11, Middle(+Hi) stretched as is. `squared` = bottom corners squared for the tray.
static UIImage *RXPSegmentArt(NSString *base, BOOL hi, BOOL squared) {
    static NSMutableDictionary *cache;
    NSString *key = [NSString stringWithFormat:@"%@.%d.%d", base, (int)hi, (int)squared];
    UIImage *img = [cache objectForKey:key];
    if (img) {
        return img;
    }
    UIImage *raw = RXPArt(base, hi);
    if (!raw) {
        return nil;
    }
    CGFloat cap = 10.0f;
    if ([base isEqualToString:@"Single"]) {
        cap = 11.0f;
    } else if ([base isEqualToString:@"Middle"]) {
        cap = 0.0f;
    }
    if (cap > 0.0f) {
        if (squared) {
            raw = RXPSquareBottom(raw);
        }
        // stretchableImageWithLeftCapWidth:cap topCapHeight:0 == a 1 pt stretched column after the cap.
        CGFloat right = raw.size.width - cap - 1.0f;
        UIEdgeInsets caps = UIEdgeInsetsMake(0.0f, cap, 0.0f, right > 0.0f ? right : 0.0f);
        if ([raw respondsToSelector:@selector(resizableImageWithCapInsets:resizingMode:)]) {
            img = [raw resizableImageWithCapInsets:caps resizingMode:UIImageResizingModeStretch];
        } else {
            img = [raw resizableImageWithCapInsets:caps];
        }
    } else {
        img = raw;
    }
    if (!img) {
        return nil;
    }
    if (!cache) {
        cache = [[NSMutableDictionary alloc] init];
    }
    [cache setObject:img forKey:key];
    return img;
}

// The caption tray (extras.py tray_img): the plain bar's own lower half - rows 20-31 pt (straight-sided
// #3B3B3B -> #151515 gradient) stretched, then rows 31-38 pt (rounded bottom corners) - with a dark 1 pt
// etched line on top and a faint highlight under it.
static UIImage *RXPTrayImage(CGFloat width, CGFloat height) {
    UIImage *left = RXPSegmentArt(@"Left", NO, NO);
    UIImage *right = RXPSegmentArt(@"Right", NO, NO);
    if (!left || !right || width < 2.0f * RXP_EDGE || height <= RXP_TRAY_CORNER_H) {
        return nil;
    }
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0.0f) {
        scale = 1.0f;
    }
    CGFloat half = floorf(width / 2.0f);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, RXP_BAR_H), NO, scale);
    [left drawInRect:CGRectMake(0.0f, 0.0f, half, RXP_BAR_H)];
    [right drawInRect:CGRectMake(half, 0.0f, width - half, RXP_BAR_H)];
    UIImage *plain = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRef cg = plain.CGImage;
    if (!cg) {
        return nil;
    }
    CGFloat pw = (CGFloat)CGImageGetWidth(cg);
    CGImageRef upper = CGImageCreateWithImageInRect(cg, CGRectMake(0.0f, RXP_TRAY_UPPER_Y * scale, pw, RXP_TRAY_UPPER_H * scale));
    CGImageRef corners = CGImageCreateWithImageInRect(cg, CGRectMake(0.0f, RXP_TRAY_CORNER_Y * scale, pw, RXP_TRAY_CORNER_H * scale));
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (upper) {
        UIImage *u = [UIImage imageWithCGImage:upper scale:scale orientation:UIImageOrientationUp];
        [u drawInRect:CGRectMake(0.0f, 0.0f, width, height - RXP_TRAY_CORNER_H)];
        CGImageRelease(upper);
    }
    if (corners) {
        UIImage *c = [UIImage imageWithCGImage:corners scale:scale orientation:UIImageOrientationUp];
        [c drawInRect:CGRectMake(0.0f, height - RXP_TRAY_CORNER_H, width, RXP_TRAY_CORNER_H)];
        CGImageRelease(corners);
    }
    if (ctx) {
        CGContextSetRGBFillColor(ctx, 0.0f, 0.0f, 0.0f, 110.0f / 255.0f);     // dark etch, 1 pt
        CGContextFillRect(ctx, CGRectMake(3.0f, 0.0f, width - 6.0f, 1.0f));
        CGContextSetRGBFillColor(ctx, 1.0f, 1.0f, 1.0f, 22.0f / 255.0f);      // faint highlight under it
        CGContextFillRect(ctx, CGRectMake(3.0f, 1.0f, width - 6.0f, 0.5f));
    }
    UIImage *tray = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return tray;
}

#pragma mark - Caption ("You [heart] . Alex [like] . Jordan [!!]", DESIGN 7)

static NSString *RXPEntryName(RXReaction *r) {
    if (r.isMine) {
        return @"You";
    }
    NSArray *names = r.names;
    id name = [names count] ? [names objectAtIndex:0] : nil;
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) {
        return name;
    }
    return @"Someone";
}

// One text run in the callout label style: white, black a0.5 copy at (0, -1). Returns its width.
static CGFloat RXPCaptionText(NSString *s, UIFont *font, BOOL draw, CGFloat x, CGFloat y) {
    if ([s length] == 0) {
        return 0.0f;
    }
    if (draw) {
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx) {
            CGContextSetRGBFillColor(ctx, 0.0f, 0.0f, 0.0f, 0.5f);
            [s drawAtPoint:CGPointMake(x, y - 1.0f) withFont:font];
            CGContextSetRGBFillColor(ctx, 1.0f, 1.0f, 1.0f, 1.0f);
            [s drawAtPoint:CGPointMake(x, y) withFont:font];
        }
    }
    return [s sizeWithFont:font].width;
}

// Measures (draw == NO) or draws the caption runs: "Name " + glyph image, joined with " . ", then
// " . +N more" when entries were dropped. Glyphs are images (RXDrawGlyph), never glyph characters.
static CGFloat RXPCaptionLayout(NSArray *entries, NSUInteger shown, NSUInteger more, UIFont *font,
                                BOOL draw, CGFloat x, CGFloat textY, CGFloat glyphCentreY) {
    NSString *separator = [NSString stringWithFormat:@"  %C  ", (unichar)0x00B7];   // "  U+00B7  "
    CGFloat start = x;
    BOOL first = YES;
    for (NSUInteger i = 0; i < shown && i < [entries count]; i++) {
        RXReaction *r = [entries objectAtIndex:i];
        if (![r isKindOfClass:[RXReaction class]]) {
            continue;
        }
        if (!first) {
            x += RXPCaptionText(separator, font, draw, x, textY);
        }
        first = NO;
        x += RXPCaptionText([RXPEntryName(r) stringByAppendingString:@" "], font, draw, x, textY);
        NSString *key = RXKindKey(r.kind);
        NSString *emoji = (r.kind == RXKindEmoji && [r.emoji length] > 0) ? r.emoji : nil;
        if (!key && !emoji) {
            continue;
        }
        CGFloat gw = emoji ? RXP_CAP_GLYPH * 1.02f : RXP_CAP_GLYPH;
        if (draw) {
            RXDrawGlyph(key, emoji, CGRectMake(x, glyphCentreY - gw / 2.0f, gw, gw), RXGlyphOnCallout);
        }
        x += gw;
    }
    if (more > 0) {
        NSString *tail = [NSString stringWithFormat:@"%@+%lu more", first ? @"" : separator, (unsigned long)more];
        x += RXPCaptionText(tail, font, draw, x, textY);
    }
    return x - start;
}

static NSString *RXPAccessibilityLabel(RXKind kind, NSString *emoji) {
    switch (kind) {
        case RXKindLove:
            return @"Heart";
        case RXKindLike:
            return @"Thumbs Up";
        case RXKindDislike:
            return @"Thumbs Down";
        case RXKindLaugh:
            return @"Ha Ha";
        case RXKindEmph:
            return @"Exclamation Marks";
        case RXKindQuestion:
            return @"Question Mark";
        case RXKindEmoji:
            return [emoji length] ? emoji : @"Emoji";
        default:
            return @"Reaction";
    }
}

#pragma mark - RXPickerView (the callout bar, drawn from the stock art)

@interface RXPickerView : UIView
@property (nonatomic, assign) NSUInteger itemCount;
@property (nonatomic, assign) CGFloat itemWidth;
@property (nonatomic, copy) NSString *emoji;              // the 7th segment: my current emoji reaction
@property (nonatomic, assign) NSInteger mineIndex;        // -1 = none
@property (nonatomic, assign) NSInteger pressedIndex;     // -1 = none
@property (nonatomic, assign) BOOL arrowUp;               // bar below the target (ArrowTop)
@property (nonatomic, assign) CGFloat arrowX;             // arrow art left edge (view coords)
@property (nonatomic, assign) CGFloat barTop;             // bar top (view coords)
@property (nonatomic, assign) CGFloat trayHeight;         // 0 or RXP_TRAY_H
@property (nonatomic, strong) NSArray *caption;           // RXReaction entries (captionEntries)
@property (nonatomic, copy) NSString *captionAccessibility;
@property (nonatomic, assign) BOOL finished;              // a segment was picked: ignore further touches
@property (nonatomic, copy) void (^onPick)(NSInteger index);
- (void)setKind:(RXKind)kind atIndex:(NSUInteger)index;
@end

@implementation RXPickerView {
    RXKind _kinds[RXP_KIND_COUNT + 1];
    UIImage *_trayImage;
    NSMutableArray *_axElements;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clearsContextBeforeDrawing = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.multipleTouchEnabled = NO;
        _itemWidth = RXP_ITEM_W;
        _mineIndex = -1;
        _pressedIndex = -1;
    }
    return self;
}

- (void)setKind:(RXKind)kind atIndex:(NSUInteger)index {
    if (index < RXP_KIND_COUNT + 1) {
        _kinds[index] = kind;
    }
}

- (CGFloat)rx_barWidth {
    return (CGFloat)self.itemCount * self.itemWidth;
}

- (NSInteger)rx_litIndex {
    return self.pressedIndex >= 0 ? self.pressedIndex : self.mineIndex;
}

- (CGRect)rx_unitRect {
    return CGRectMake(0.0f, self.barTop, [self rx_barWidth], RXP_BAR_H + self.trayHeight);
}

- (NSInteger)rx_indexAtPoint:(CGPoint)p {
    CGFloat bw = [self rx_barWidth];
    if (self.itemCount == 0 || self.itemWidth <= 0.0f || p.x < 0.0f || p.x >= bw) {
        return -1;
    }
    CGFloat top = self.barTop - 10.0f;
    CGFloat bottom = self.barTop + RXP_BAR_H + (self.trayHeight > 0.0f ? 0.0f : 10.0f);
    if (p.y < top || p.y > bottom) {
        return -1;
    }
    NSInteger i = (NSInteger)floorf(p.x / self.itemWidth);
    if (i < 0) {
        i = 0;
    }
    if (i >= (NSInteger)self.itemCount) {
        i = (NSInteger)self.itemCount - 1;
    }
    return i;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset([self rx_unitRect], -2.0f, -6.0f), point);
}

#pragma mark Touches (one lit segment: the pressed one while a finger is down, else mine)

- (void)rx_setPressed:(NSInteger)index {
    if (index != self.pressedIndex) {
        self.pressedIndex = index;
        [self setNeedsDisplay];
    }
}

- (void)rx_track:(NSSet *)touches {
    if (self.finished) {
        return;
    }
    UITouch *touch = [touches anyObject];
    [self rx_setPressed:touch ? [self rx_indexAtPoint:[touch locationInView:self]] : -1];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self rx_track:touches];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [self rx_track:touches];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (self.finished) {
        return;
    }
    UITouch *touch = [touches anyObject];
    NSInteger index = touch ? [self rx_indexAtPoint:[touch locationInView:self]] : -1;
    void (^pick)(NSInteger) = self.onPick;
    if (index >= 0 && pick) {
        self.finished = YES;
        [self rx_setPressed:index];          // stays lit while the bar fades, like the stock callout
        pick(index);
    } else {
        [self rx_setPressed:-1];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!self.finished) {
        [self rx_setPressed:-1];
    }
}

#pragma mark Drawing (stock UICalloutBarOverlay order: segments, dividers, shadow, arrow; then labels)

- (void)rx_drawShadowAtY:(CGFloat)y width:(CGFloat)bw gapFrom:(CGFloat)g0 to:(CGFloat)g1 {
    UIImage *sl = RXKitImage(@"UICalloutBarShadowLeft.png");
    UIImage *sm = RXKitImage(@"UICalloutBarShadowMiddle.png");
    UIImage *sr = RXKitImage(@"UICalloutBarShadowRight.png");
    CGFloat lw = sl ? sl.size.width : 0.0f;
    CGFloat rw = sr ? sr.size.width : 0.0f;
    if (sl) {
        [sl drawAtPoint:CGPointMake(0.0f, y)];
    }
    if (sr) {
        [sr drawAtPoint:CGPointMake(bw - rw, y)];
    }
    if (!sm) {
        return;
    }
    CGFloat h = sm.size.height;
    CGFloat m0 = lw;
    CGFloat m1 = bw - rw;
    if (g1 > g0) {
        // A bottom arrow: the middle strip runs on both sides of it (UIK@0x182690).
        if (g0 > m0) {
            [sm drawInRect:CGRectMake(m0, y, g0 - m0, h)];
        }
        if (m1 > g1) {
            [sm drawInRect:CGRectMake(g1, y, m1 - g1, h)];
        }
    } else if (m1 > m0) {
        [sm drawInRect:CGRectMake(m0, y, m1 - m0, h)];
    }
}

- (void)rx_drawCaptionInRect:(CGRect)tray context:(CGContextRef)ctx {
    NSArray *entries = self.caption;
    if ([entries count] == 0) {
        return;
    }
    UIFont *font = [UIFont boldSystemFontOfSize:RXP_CAP_FONT];
    CGFloat maxWidth = tray.size.width - 2.0f * RXP_CAP_PAD;
    NSUInteger shown = [entries count];
    NSUInteger more = 0;
    CGFloat width = RXPCaptionLayout(entries, shown, more, font, NO, 0.0f, 0.0f, 0.0f);
    while (width > maxWidth && shown > 1) {
        shown--;
        more++;
        width = RXPCaptionLayout(entries, shown, more, font, NO, 0.0f, 0.0f, 0.0f);
    }
    CGFloat baseline = CGRectGetMinY(tray) + tray.size.height / 2.0f + 4.6f;
    CGFloat x = roundf(CGRectGetMidX(tray) - width / 2.0f);
    CGContextSaveGState(ctx);
    if (width > maxWidth) {
        // One very long name: left-align and clip to the tray rather than spill over the art.
        x = CGRectGetMinX(tray) + RXP_CAP_PAD;
        CGContextClipToRect(ctx, CGRectInset(tray, RXP_CAP_PAD - 2.0f, 0.0f));
    }
    RXPCaptionLayout(entries, shown, more, font, YES, x, baseline - font.ascender, baseline - 4.4f);
    CGContextRestoreGState(ctx);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    NSUInteger n = self.itemCount;
    if (!ctx || n == 0) {
        return;
    }
    CGFloat w = self.itemWidth;
    CGFloat bw = [self rx_barWidth];
    CGFloat barTop = self.barTop;
    CGFloat barBottom = barTop + RXP_BAR_H;
    BOOL tray = self.trayHeight > 0.0f;
    CGFloat unitBottom = barBottom + self.trayHeight;
    NSInteger lit = [self rx_litIndex];
    BOOL down = !self.arrowUp;

    // Arrow: ...Hi only when the lit segment touches it directly (never through the tray).
    NSString *arrowBase = down ? @"ArrowBottom" : @"ArrowTop";
    UIImage *arrow = RXPArt(arrowBase, NO);
    CGFloat aw = arrow ? arrow.size.width : RXP_ARROW_W;
    NSInteger under = (NSInteger)floorf((self.arrowX + aw / 2.0f) / w);
    if (lit >= 0 && under == lit && !(down && tray)) {
        UIImage *hi = RXPArt(arrowBase, YES);
        if (hi) {
            arrow = hi;
        }
    }

    // 1. Tray under the bar (group chats).
    if (tray) {
        if (!_trayImage) {
            _trayImage = RXPTrayImage(bw, self.trayHeight);
        }
        [_trayImage drawInRect:CGRectMake(0.0f, barBottom, bw, self.trayHeight)];
    }

    // 2. Segments: Left / Middle... / Right (Single for one), exactly one lit.
    for (NSUInteger i = 0; i < n; i++) {
        NSString *base = @"Middle";
        if (n == 1) {
            base = @"Single";
        } else if (i == 0) {
            base = @"Left";
        } else if (i == n - 1) {
            base = @"Right";
        }
        UIImage *seg = RXPSegmentArt(base, (NSInteger)i == lit, tray);
        [seg drawInRect:CGRectMake((CGFloat)i * w, barTop, w, RXP_BAR_H)];
    }

    // 3. Etched dividers centred on each boundary.
    UIImage *cut = RXKitImage(@"UICalloutBarCut.png");
    if (cut) {
        CGFloat cw = cut.size.width;
        for (NSUInteger i = 1; i < n; i++) {
            [cut drawInRect:CGRectMake((CGFloat)i * w - cw / 2.0f, barTop, cw, RXP_BAR_H)];
        }
    }

    // 4. Shadow strip (its first 1 pt is the #333 bottom border) under the bar or bar + tray.
    if (down) {
        [self rx_drawShadowAtY:unitBottom width:bw gapFrom:self.arrowX to:self.arrowX + aw];
    } else {
        [self rx_drawShadowAtY:unitBottom width:bw gapFrom:0.0f to:0.0f];
    }

    // 5. Arrow: hangs from the bar/tray bottom, or (picker below the bubble) sits on the bar top with
    //    its tip RXP_TIP above it (UIK calculateControlFrameForCalloutSize:below: uses +/-16 both ways,
    //    so the up arrow mirrors the down one; tune on device).
    if (arrow) {
        CGFloat ay = down ? unitBottom : barTop - RXP_TIP;
        [arrow drawAtPoint:CGPointMake(self.arrowX, ay)];
    }

    // 6. Glyphs: white, callout label shadow; the emoji segment in colour.
    for (NSUInteger i = 0; i < n && i < RXP_KIND_COUNT + 1; i++) {
        RXKind kind = _kinds[i];
        NSString *key = RXKindKey(kind);
        NSString *emoji = (kind == RXKindEmoji) ? self.emoji : nil;
        if (!key && [emoji length] == 0) {
            continue;
        }
        CGFloat cx = (CGFloat)i * w + w / 2.0f;
        CGFloat cy = barTop + RXP_GLYPH_CY;
        CGRect box = CGRectMake(cx - RXP_GLYPH_BOX / 2.0f, cy - RXP_GLYPH_BOX / 2.0f, RXP_GLYPH_BOX, RXP_GLYPH_BOX);
        RXDrawGlyph(key, emoji, box, RXGlyphOnCallout);
    }

    // 7. Who reacted.
    if (tray) {
        [self rx_drawCaptionInRect:CGRectMake(0.0f, barBottom, bw, self.trayHeight) context:ctx];
    }
}

#pragma mark Accessibility (segments as buttons, the caption as text)

- (BOOL)isAccessibilityElement {
    return NO;
}

- (NSArray *)rx_accessibilityElements {
    if (_axElements) {
        return _axElements;
    }
    _axElements = [[NSMutableArray alloc] init];
    for (NSUInteger i = 0; i < self.itemCount && i < RXP_KIND_COUNT + 1; i++) {
        UIAccessibilityElement *e = [[UIAccessibilityElement alloc] initWithAccessibilityContainer:self];
        RXKind kind = _kinds[i];
        e.accessibilityLabel = RXPAccessibilityLabel(kind, kind == RXKindEmoji ? self.emoji : nil);
        UIAccessibilityTraits traits = UIAccessibilityTraitButton;
        if ((NSInteger)i == self.mineIndex) {
            traits |= UIAccessibilityTraitSelected;
        }
        e.accessibilityTraits = traits;
        [_axElements addObject:e];
    }
    if (self.trayHeight > 0.0f && [self.captionAccessibility length] > 0) {
        UIAccessibilityElement *e = [[UIAccessibilityElement alloc] initWithAccessibilityContainer:self];
        e.accessibilityLabel = self.captionAccessibility;
        e.accessibilityTraits = UIAccessibilityTraitStaticText;
        [_axElements addObject:e];
    }
    return _axElements;
}

- (CGRect)rx_screenRect:(CGRect)r {
    UIWindow *window = self.window;
    if (!window) {
        return CGRectZero;
    }
    return [window convertRect:[self convertRect:r toView:nil] toWindow:nil];
}

- (NSInteger)accessibilityElementCount {
    return (NSInteger)[[self rx_accessibilityElements] count];
}

- (id)accessibilityElementAtIndex:(NSInteger)index {
    NSArray *elements = [self rx_accessibilityElements];
    if (index < 0 || index >= (NSInteger)[elements count]) {
        return nil;
    }
    UIAccessibilityElement *e = [elements objectAtIndex:(NSUInteger)index];
    CGRect r;
    if (index < (NSInteger)self.itemCount) {
        r = CGRectMake((CGFloat)index * self.itemWidth, self.barTop, self.itemWidth, RXP_BAR_H);
    } else {
        r = CGRectMake(0.0f, self.barTop + RXP_BAR_H, [self rx_barWidth], self.trayHeight);
    }
    e.accessibilityFrame = [self rx_screenRect:r];
    return e;
}

- (NSInteger)indexOfAccessibilityElement:(id)element {
    NSUInteger i = [[self rx_accessibilityElements] indexOfObject:element];
    return i == NSNotFound ? NSNotFound : (NSInteger)i;
}

@end

#pragma mark - RXPickerCatcher (pass-through, DESIGN 7)

// Full-size, transparent, on top of the controller's view. hitTest returns the bar for points inside
// it; anything else schedules a dismissal and returns nil, so the touch reaches the table, a link, a
// badge or another bubble exactly as if the picker were not there. No gesture recognizers (SwipeBack,
// MessageWallpapers and MessageTimes are untouched).
@interface RXPickerCatcher : UIView
@property (nonatomic, weak) RXPickerView *bar;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, copy) void (^onOutsideTouch)(CGPoint point);
@end

@implementation RXPickerCatcher

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.closing || self.hidden || !self.userInteractionEnabled) {
        return nil;
    }
    RXPickerView *bar = self.bar;
    if (bar && bar.superview == self && !bar.finished) {
        CGPoint p = [self convertPoint:point toView:bar];
        if ([bar pointInside:p withEvent:event]) {
            return bar;
        }
    }
    // Only real touches dismiss (other code, e.g. MessageWallpapers, hit-tests with a nil event).
    if (event && event.type == UIEventTypeTouches) {
        void (^outside)(CGPoint) = self.onOutsideTouch;
        if (outside) {
            outside(point);
        }
    }
    return nil;
}

@end

#pragma mark - Session (one open picker per controller)

@interface RXPickerSession : NSObject
@property (nonatomic, weak) CKTranscriptController *tc;
@property (nonatomic, strong) RXPickerCatcher *catcher;
@property (nonatomic, strong) RXPickerView *bar;
@property (nonatomic, weak) CKBalloonView *balloon;
@property (nonatomic, strong) CKMessagePart *part;        // what the balloon showed when opened
// Snapshot (DESIGN 7 "Pick"): re-validated against the current bubble data before sending.
@property (nonatomic, copy) NSString *chatKey;
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) RXTarget target;
@property (nonatomic, copy) NSString *quote;
@property (nonatomic, assign) RXKind mineKind;
@property (nonatomic, copy) NSString *mineEmoji;
@property (nonatomic, assign) NSInteger mineIndex;
@property (nonatomic, assign) CGRect touchTarget;           // catcher coords: bubble + badge (toggle)
@property (nonatomic, strong) NSMutableArray *observers;
@property (nonatomic, assign) BOOL highlighted;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, assign) BOOL dismissScheduled;
@property (nonatomic, assign) CFTimeInterval fadeUntil;     // close fade deadline (RXPickerIsOpen)
@end

@implementation RXPickerSession

- (void)dealloc {
    // Normally emptied by RXPClose; this only matters if the controller vanished without a teardown.
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (id token in _observers) {
        [nc removeObserver:token];
    }
}

@end

// What a double-tapped / badge-tapped bubble resolves to.
@interface RXPickerTarget : NSObject
@property (nonatomic, strong) UITableViewCell *cell;
@property (nonatomic, strong) CKMessagePart *part;
@property (nonatomic, copy) NSString *chatKey;
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) RXTarget target;
@property (nonatomic, copy) NSString *quote;
@end

@implementation RXPickerTarget
@end

#pragma mark - Helpers

static RXPickerSession *RXPSession(CKTranscriptController *tc) {
    if (!tc) {
        return nil;
    }
    id s = objc_getAssociatedObject(tc, &kRXPickerKey);
    return [s isKindOfClass:[RXPickerSession class]] ? (RXPickerSession *)s : nil;
}

static CGFloat RXPSnap(CGFloat v) {
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0.0f) {
        scale = 1.0f;
    }
    return roundf(v * scale) / scale;
}

static BOOL RXPRectValid(CGRect r) {
    return !CGRectIsNull(r) && !CGRectIsEmpty(r) &&
           isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height);
}

static UITableViewCell *RXPCellForView(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *v = view.superview; v && depth < 12; v = v.superview, depth++) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            return (UITableViewCell *)v;
        }
    }
    return nil;
}

// Not opened (and a pick aborts) for pending / failed / placeholder / typing messages (DESIGN 7).
static BOOL RXPMessageBlocked(CKIMMessage *msg) {
    if ([msg respondsToSelector:@selector(isPlaceholder)] && [msg isPlaceholder]) {
        return YES;
    }
    if ([msg respondsToSelector:@selector(isTypingIndicator)] && [msg isTypingIndicator]) {
        return YES;
    }
    // -[CKIMMessage pending] is (total - sent - failed) > 0, so it is YES for every RECEIVED message:
    // only an outgoing message can really be "still sending".
    if ([msg respondsToSelector:@selector(isFromMe)] && [msg isFromMe] &&
        [msg respondsToSelector:@selector(pending)] && [msg pending]) {
        return YES;
    }
    if ([msg respondsToSelector:@selector(failedSend)] && [msg failedSend]) {
        return YES;
    }
    if ([msg respondsToSelector:@selector(partiallyFailedSend)] && [msg partiallyFailedSend]) {
        return YES;
    }
    return NO;
}

// The visible transcript area in host coords: the table's frame minus contentInset.top and minus
// [tc _bottomInset] (entry view + keyboard, R2 3.4), clipped to the host bounds.
static CGRect RXPVisibleArea(CKTranscriptController *tc, UIView *host, UITableView *table) {
    CGRect bounds = host.bounds;
    if (!table || !table.superview) {
        return bounds;
    }
    CGRect tf = [table.superview convertRect:table.frame toView:host];
    if (!RXPRectValid(tf)) {
        return bounds;
    }
    CGFloat top = table.contentInset.top;
    CGFloat bottom = RXResponds(tc, @selector(_bottomInset)) ? (CGFloat)[tc _bottomInset] : table.contentInset.bottom;
    if (!(top >= 0.0f) || top > tf.size.height) {
        top = 0.0f;
    }
    if (!(bottom >= 0.0f) || bottom > tf.size.height) {
        bottom = 0.0f;
    }
    CGFloat minY = MAX(CGRectGetMinY(bounds), CGRectGetMinY(tf) + top);
    CGFloat maxY = MIN(CGRectGetMaxY(bounds), CGRectGetMaxY(tf) - bottom);
    if (!(maxY > minY)) {
        return CGRectNull;
    }
    return CGRectMake(CGRectGetMinX(bounds), minY, bounds.size.width, maxY - minY);
}

// The bubble body (R6 2.3: the balloon frame minus halo, tail and shadow) clipped by ChatKit's own
// -clippedTargetRectForBalloon: (balloon coords: bounds intersected with the table minus its insets,
// CK@0x1839c), in host coords.
static CGRect RXPBodyInHost(CKTranscriptController *tc, CKBalloonView *balloon, UIView *host) {
    CGRect b = balloon.bounds;
    CGRect body = b;
    if (b.size.width > 12.0f && b.size.height > 7.0f) {
        BOOL incoming = [balloon respondsToSelector:@selector(orientation)] ? ([balloon orientation] == 0) : YES;
        CGFloat left = incoming ? 9.5f : 2.0f;
        body = CGRectMake(b.origin.x + left, b.origin.y + 1.5f, b.size.width - 11.5f, b.size.height - 6.0f);
    }
    if (RXResponds(tc, @selector(clippedTargetRectForBalloon:))) {
        CGRect clip = [tc clippedTargetRectForBalloon:balloon];
        if (RXPRectValid(clip)) {
            CGRect inter = CGRectIntersection(body, clip);
            body = RXPRectValid(inter) ? inter : clip;
        }
    }
    return [balloon convertRect:body toView:host];
}

static RXReactionBalloonView *RXPBadgeIn(UIView *parent) {
    for (UIView *v in parent.subviews) {
        if (![v isKindOfClass:[RXReactionBalloonView class]] || v.hidden || v.alpha < 0.01f) {
            continue;
        }
        RXBadgeModel *model = [(RXReactionBalloonView *)v model];
        if (model && !model.isEmpty) {
            return (RXReactionBalloonView *)v;
        }
    }
    return nil;
}

// The bubble's badge view (a sibling of the balloon, DESIGN 5.5), if it shows anything.
static RXReactionBalloonView *RXPBadgeView(CKBalloonView *balloon, UITableViewCell *cell) {
    RXReactionBalloonView *badge = RXPBadgeIn(balloon.superview);
    if (!badge && cell && cell.contentView != balloon.superview) {
        badge = RXPBadgeIn(cell.contentView);
    }
    return badge;
}

static BOOL RXPSessionShows(RXPickerSession *s, CKBalloonView *balloon) {
    if (!s || !balloon || s.balloon != balloon) {
        return NO;
    }
    CKMessagePart *part = [balloon respondsToSelector:@selector(messagePart)] ? [balloon messagePart] : nil;
    return part && part == s.part;
}

static BOOL RXPSuppressed(NSString *guid, NSInteger partKey) {
    NSString *g = gRXPSuppressGUID;
    gRXPSuppressGUID = nil;
    if (!g) {
        return NO;
    }
    return [g isEqualToString:guid] && gRXPSuppressPart == partKey &&
           (CACurrentMediaTime() - gRXPSuppressTime) < RXP_SUPPRESS_S;
}

// The close fade is over: the transcript gate may open again (RXPickerIsOpen).
static void RXPClearClosing(RXPickerSession *s) {
    CKTranscriptController *tc = s.tc;        // nil once the controller is gone / deallocating
    if (tc && objc_getAssociatedObject(tc, &kRXPickerClosingKey) == s) {
        objc_setAssociatedObject(tc, &kRXPickerClosingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void RXPPokeLater(RXPickerSession *s) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CKTranscriptController *tc = s.tc;    // nil once the controller is gone / deallocating
        if (tc) {
            RXTranscriptPoke(tc);              // DESIGN 5.6: picker close retries deferred refreshes
        }
    });
}

#pragma mark - Resolve (row -> message -> part, DESIGN 5.3)

static RXPickerTarget *RXPResolve(CKTranscriptController *tc, CKBalloonView *balloon, UITableViewCell *cellHint) {
    if (!tc || !balloon || ![tc isViewLoaded] || !tc.view.window || !balloon.window || tc.isEditing) {
        return nil;
    }
    if (!RXResponds(tc, @selector(transcriptTable)) || !RXResponds(tc, @selector(bubbleData)) ||
        !RXResponds(tc, @selector(conversation))) {
        return nil;
    }
    UITableView *table = [tc transcriptTable];
    if (!table || table.isEditing) {
        return nil;
    }
    UITableViewCell *cell = cellHint;
    if (!cell || ![balloon isDescendantOfView:cell]) {
        cell = RXPCellForView(balloon);
    }
    NSIndexPath *path = cell ? [table indexPathForCell:cell] : nil;
    if (!path || path.section != 0) {
        return nil;
    }
    CKTranscriptBubbleData *data = [tc bubbleData];
    NSInteger row = path.row;
    if (!data || !RXResponds(data, @selector(count)) || !RXResponds(data, @selector(messageAtIndex:)) ||
        !RXResponds(data, @selector(partAtIndex:)) || row < 0 || row >= (NSInteger)[data count]) {
        return nil;
    }
    CKIMMessage *msg = [data messageAtIndex:(int)row];
    CKMessagePart *part = [data partAtIndex:(int)row];
    if (!msg || !part) {
        return nil;
    }
    if ([balloon respondsToSelector:@selector(messagePart)]) {
        CKMessagePart *shown = [balloon messagePart];
        if (shown && shown != part) {
            RXLog(@"picker: balloon part differs from row %ld, not opening", (long)row);
            return nil;
        }
    }
    NSString *guid = RXResponds(msg, @selector(guid)) ? [msg guid] : nil;
    if (![guid isKindOfClass:[NSString class]] || [guid length] == 0 || RXPMessageBlocked(msg)) {
        return nil;
    }
    NSString *chatKey = RXChatKeyForConversation([tc conversation]);
    NSString *msgKey = RXChatKeyForMessage(msg);
    if ([chatKey length] == 0 || (msgKey && ![msgKey isEqualToString:chatKey])) {
        return nil;
    }
    NSInteger partKey = RXTranscriptPartKeyForRow(data, row);
    if (partKey == NSNotFound) {
        return nil;
    }
    RXTarget target = RXTargetForPart(part);
    NSString *quote = RXTextForPart(part);
    if (target == RXTargetUnknown || (target == RXTargetText && [quote length] == 0)) {
        return nil;
    }
    RXPickerTarget *t = [[RXPickerTarget alloc] init];
    t.cell = cell;
    t.part = part;
    t.chatKey = chatKey;
    t.guid = guid;
    t.partKey = partKey;
    t.target = target;
    t.quote = quote;
    return t;
}

// On pick: the snapshot must still describe a row of the current bubble data (same chat, same GUID,
// same partKey, same target kind and text), else the pick is dropped (DESIGN 7).
static BOOL RXPValidate(RXPickerSession *s, CKTranscriptController *tc) {
    if (!RXResponds(tc, @selector(conversation)) || !RXResponds(tc, @selector(bubbleData))) {
        return NO;
    }
    NSString *chatKey = RXChatKeyForConversation([tc conversation]);
    if (!chatKey || !s.chatKey || ![chatKey isEqualToString:s.chatKey]) {
        return NO;
    }
    CKTranscriptBubbleData *data = [tc bubbleData];
    if (!data || !RXResponds(data, @selector(indexForMessageWithGUID:)) || !RXResponds(data, @selector(count)) ||
        !RXResponds(data, @selector(messageAtIndex:)) || !RXResponds(data, @selector(partAtIndex:))) {
        return NO;
    }
    NSInteger count = (NSInteger)[data count];
    NSUInteger first = [data indexForMessageWithGUID:s.guid];
    if (first == NSNotFound || (NSInteger)first >= count) {
        return NO;
    }
    NSInteger end = MIN(count, (NSInteger)first + RXP_VALIDATE_ROWS);
    for (NSInteger r = (NSInteger)first; r < end; r++) {
        CKIMMessage *msg = [data messageAtIndex:(int)r];
        NSString *g = [msg respondsToSelector:@selector(guid)] ? [msg guid] : nil;
        if (![g isKindOfClass:[NSString class]] || ![g isEqualToString:s.guid]) {
            continue;
        }
        if (RXTranscriptPartKeyForRow(data, r) != s.partKey) {
            continue;
        }
        CKMessagePart *part = [data partAtIndex:(int)r];
        if (!part) {
            continue;
        }
        if (RXPMessageBlocked(msg) || RXTargetForPart(part) != s.target) {
            return NO;
        }
        if (s.target == RXTargetText) {
            NSString *text = RXTextForPart(part);
            if (!text || !s.quote || ![text isEqualToString:s.quote]) {
                return NO;
            }
        }
        return YES;
    }
    return NO;
}

#pragma mark - Open

static void RXPOpen(CKTranscriptController *tc, CKBalloonView *balloon, UITableViewCell *cellHint) {
    if (RXSwipeSessionActive()) {
        return;
    }
    RXPickerTarget *t = RXPResolve(tc, balloon, cellHint);
    if (!t) {
        return;
    }
    if (RXPSuppressed(t.guid, t.partKey)) {
        return;                                  // this bubble's own tap just closed it: toggle
    }
    if (!RXPSegmentArt(@"Left", NO, NO) || !RXPSegmentArt(@"Middle", NO, NO) || !RXPSegmentArt(@"Right", NO, NO)) {
        RXLogOnce(@"picker.art", @"picker: UICalloutBar art missing, picker disabled");
        return;
    }
    UIView *host = tc.view;
    UITableView *table = [tc transcriptTable];

    // My current reaction (lit) and, in group chats, who reacted.
    RXStore *store = [RXStore storeForChatKey:t.chatKey create:NO];
    RXReaction *mine = [store myReactionForGUID:t.guid partKey:t.partKey];
    NSInteger mineIndex = -1;
    RXKind mineKind = RXKindNone;
    NSString *mineEmoji = nil;
    if (mine) {
        mineKind = mine.kind;
        if (mineKind == RXKindEmoji) {
            if ([mine.emoji length] > 0) {
                mineEmoji = mine.emoji;
                mineIndex = RXP_KIND_COUNT;          // the 7th segment shows it in colour
            } else {
                mineKind = RXKindNone;
            }
        } else {
            for (NSInteger i = 0; i < RXP_KIND_COUNT; i++) {
                if (kRXPKinds[i] == mineKind) {
                    mineIndex = i;
                    break;
                }
            }
        }
    }
    NSUInteger n = mineEmoji ? RXP_KIND_COUNT + 1 : RXP_KIND_COUNT;
    CGFloat itemW = mineEmoji ? RXP_ITEM_W_EMOJI : RXP_ITEM_W;
    CGFloat bw = (CGFloat)n * itemW;

    NSArray *caption = nil;
    NSString *captionAX = nil;
    CKConversation *conv = [tc conversation];
    NSArray *recipients = RXResponds(conv, @selector(recipients)) ? [conv recipients] : nil;
    if ([recipients count] > 1) {
        RXBadgeModel *model = [store badgeForGUID:t.guid partKey:t.partKey];
        if (model && !model.isEmpty) {
            caption = [model captionEntries];
            captionAX = [model accessibilityString];
        }
    }
    CGFloat trayH = [caption count] > 0 ? RXP_TRAY_H : 0.0f;

    // Target = bubble body U badge art, inside the visible area (DESIGN 7 "Placement").
    CGRect visible = RXPVisibleArea(tc, host, table);
    if (!RXPRectValid(visible)) {
        return;
    }
    CGRect body = RXPBodyInHost(tc, balloon, host);
    if (!RXPRectValid(body)) {
        return;
    }
    RXReactionBalloonView *badge = RXPBadgeView(balloon, t.cell);
    CGRect target = body;
    if (badge && badge.superview) {
        CGRect art = [badge.superview convertRect:[badge artRectInSuperview] toView:host];
        if (RXPRectValid(art)) {
            target = CGRectUnion(target, art);
        }
    }
    target = CGRectIntersection(target, visible);
    if (!RXPRectValid(target)) {
        RXLog(@"picker: target not visible, not opening (guid %@)", RXGUIDTail(t.guid));
        return;
    }
    CGFloat targetX = CGRectGetMidX(body);

    // Above if there is room for bar (+ tray) + tip, else below, else pinned to the visible top.
    CGFloat need = RXP_BAR_H + trayH + RXP_TIP + RXP_TARGET_GAP;     // 49 (+22)
    RXPPlacement place;
    CGFloat barTop;
    if (CGRectGetMinY(target) - CGRectGetMinY(visible) >= need) {
        place = RXPPlaceAbove;
        barTop = CGRectGetMinY(target) - need;
    } else if (CGRectGetMaxY(visible) - CGRectGetMaxY(target) >= need) {
        place = RXPPlaceBelow;
        barTop = CGRectGetMaxY(target) + RXP_TARGET_GAP + RXP_TIP;
    } else {
        place = RXPPlacePinned;
        barTop = CGRectGetMinY(visible) + RXP_PIN_TOP;
    }
    BOOL arrowUp = (place == RXPPlaceBelow);

    // Bar x in [6, W - 6 - width]; arrow centred on the bubble, 11 pt from both ends.
    CGRect hb = host.bounds;
    CGFloat x0 = targetX - bw / 2.0f;
    x0 = MIN(x0, CGRectGetMaxX(hb) - RXP_EDGE - bw);
    x0 = MAX(x0, CGRectGetMinX(hb) + RXP_EDGE);
    x0 = RXPSnap(x0);
    UIImage *arrowArt = RXPArt(arrowUp ? @"ArrowTop" : @"ArrowBottom", NO);
    CGFloat aw = arrowArt ? arrowArt.size.width : RXP_ARROW_W;
    CGFloat ax = RXPSnap(targetX - aw / 2.0f);
    ax = MIN(ax, x0 + bw - RXP_ARROW_END - aw);
    ax = MAX(ax, x0 + RXP_ARROW_END);

    CGFloat localBarTop = arrowUp ? RXP_TIP : 0.0f;
    CGFloat viewTop = RXPSnap(barTop - localBarTop);
    CGFloat viewH = localBarTop + RXP_BAR_H + trayH + RXP_SHADOW_H;
    CGRect frame = CGRectMake(x0, viewTop, bw, viewH);
    CGPoint tip = CGPointMake(ax - x0 + aw / 2.0f, arrowUp ? 0.0f : localBarTop + RXP_BAR_H + trayH + RXP_TIP);

    RXPickerView *bar = [[RXPickerView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, bw, viewH)];
    bar.itemCount = n;
    bar.itemWidth = itemW;
    for (NSUInteger i = 0; i < RXP_KIND_COUNT; i++) {
        [bar setKind:kRXPKinds[i] atIndex:i];
    }
    if (mineEmoji) {
        [bar setKind:RXKindEmoji atIndex:RXP_KIND_COUNT];
        bar.emoji = mineEmoji;
    }
    bar.mineIndex = mineIndex;
    bar.arrowUp = arrowUp;
    bar.arrowX = ax - x0;
    bar.barTop = localBarTop;
    bar.trayHeight = trayH;
    bar.caption = caption;
    bar.captionAccessibility = captionAX;

    RXPickerCatcher *catcher = [[RXPickerCatcher alloc] initWithFrame:hb];
    catcher.bar = bar;
    [catcher addSubview:bar];

    RXPickerSession *s = [[RXPickerSession alloc] init];
    s.tc = tc;
    s.catcher = catcher;
    s.bar = bar;
    s.balloon = balloon;
    s.part = t.part;
    s.chatKey = t.chatKey;
    s.guid = t.guid;
    s.partKey = t.partKey;
    s.target = t.target;
    s.quote = t.quote;
    s.mineKind = mineKind;
    s.mineEmoji = mineEmoji;
    s.mineIndex = mineIndex;
    s.observers = [[NSMutableArray alloc] init];

    __weak RXPickerSession *weakSession = s;
    bar.onPick = ^(NSInteger index) {
        RXPPick(weakSession, index);
    };
    catcher.onOutsideTouch = ^(CGPoint point) {
        RXPOutsideTouch(weakSession, point);
    };

    // Only one callout at a time: a Copy menu still up (another bubble) goes away first.
    UIMenuController *menu = [UIMenuController sharedMenuController];
    if (menu.menuVisible) {
        [menu setMenuVisible:NO animated:NO];
    }
    RXPickerDismiss(tc, NO);                     // a stale session, if any
    objc_setAssociatedObject(tc, &kRXPickerKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addSubview:catcher];

    CGRect touch = [balloon convertRect:balloon.bounds toView:catcher];
    if (badge && badge.superview) {
        touch = CGRectUnion(touch, [badge.superview convertRect:badge.frame toView:catcher]);
    }
    s.touchTarget = CGRectInset(touch, -6.0f, -6.0f);

    // Stock behaviour: the bubble shows its highlighted art while the callout is up.
    if ([balloon respondsToSelector:@selector(setHighlighted:)]) {
        [balloon setHighlighted:YES];
        s.highlighted = YES;
    }

    // Dismissal triggers owned here (the hook layer covers rows changing, reloads, rotation, editing,
    // viewWillDisappear:, setConversation:, swipes). The scroll notification is posted by ChatKit's
    // own -scrollViewWillBeginDragging: (CK@0xe24c).
    NSArray *names = @[ UIKeyboardWillShowNotification, UIKeyboardWillHideNotification,
                        UIKeyboardWillChangeFrameNotification, UIMenuControllerWillShowMenuNotification,
                        UIApplicationWillResignActiveNotification, @"SMSMessageTranscriptLayerDidScroll" ];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *name in names) {
        // queue:nil = delivered synchronously, so e.g. a Copy menu's WillShow closes us (and drops our
        // highlight) before ChatKit highlights its balloon (CK@0x55e2 -> 0x55f6).
        id token = [nc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            if ([NSThread isMainThread]) {
                RXPDismissSession(weakSession, YES);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    RXPDismissSession(weakSession, YES);
                });
            }
        }];
        if (token) {
            [s.observers addObject:token];
        }
    }

    // Pop in like the stock callout: 0.5 -> 1.05 (0.16 s) -> 1.0 (0.08 s) from the arrow tip.
    bar.layer.anchorPoint = CGPointMake(bw > 0.0f ? tip.x / bw : 0.5f, viewH > 0.0f ? tip.y / viewH : 1.0f);
    bar.frame = [host convertRect:frame toView:catcher];
    bar.transform = CGAffineTransformMakeScale(0.5f, 0.5f);
    bar.alpha = 0.0f;
    [UIView animateWithDuration:RXP_POP_UP
                          delay:0.0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        bar.transform = CGAffineTransformMakeScale(1.05f, 1.05f);
        bar.alpha = 1.0f;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:RXP_POP_SETTLE
                              delay:0.0
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            bar.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);

    RXLog(@"picker: open items=%lu mine=%ld tray=%d place=%d guid=%@",
          (unsigned long)n, (long)mineIndex, (int)(trayH > 0.0f), (int)place, RXGUIDTail(t.guid));
}

#pragma mark - Close

static void RXPClose(RXPickerSession *s, BOOL animated) {
    if (!s || s.closing) {
        return;
    }
    s.closing = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (id token in s.observers) {
        [nc removeObserver:token];
    }
    [s.observers removeAllObjects];

    // Un-highlight only if the balloon still shows the part we highlighted (cells are reused).
    CKBalloonView *balloon = s.balloon;
    if (s.highlighted && balloon) {
        CKMessagePart *now = [balloon respondsToSelector:@selector(messagePart)] ? [balloon messagePart] : nil;
        if (now && now == s.part && [balloon respondsToSelector:@selector(setHighlighted:)]) {
            [balloon setHighlighted:NO];
        }
    }
    s.highlighted = NO;

    RXPickerCatcher *catcher = s.catcher;
    catcher.closing = YES;
    catcher.onOutsideTouch = nil;
    s.bar.onPick = nil;
    if (animated && catcher.window) {
        // DESIGN 6 "after the picker fades": the transcript gate (RXPickerIsOpen) stays closed until the
        // fade is over, so the refresh a pick queued (badge pop) runs from the completion's poke.
        CKTranscriptController *owner = s.tc;
        if (owner) {
            s.fadeUntil = CACurrentMediaTime() + RXP_FADE + RXP_FADE_SLACK;
            objc_setAssociatedObject(owner, &kRXPickerClosingKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [UIView animateWithDuration:RXP_FADE
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            catcher.alpha = 0.0f;
        } completion:^(BOOL finished) {
            [catcher removeFromSuperview];
            RXPClearClosing(s);
            RXPPokeLater(s);
        }];
    } else {
        [catcher removeFromSuperview];
        RXPPokeLater(s);
    }
}

static void RXPDismissSession(RXPickerSession *s, BOOL animated) {
    if (!s || s.closing) {
        return;
    }
    CKTranscriptController *tc = s.tc;
    if (tc && RXPSession(tc) == s) {
        RXPickerDismiss(tc, animated);
    } else {
        RXPClose(s, animated);
    }
}

// A touch outside the bar: dismiss on the next turn (never inside hit-testing). If it landed on this
// bubble or its badge, remember it so the double-tap / badge tap it starts closes instead of reopening.
static void RXPOutsideTouch(RXPickerSession *s, CGPoint point) {
    if (!s || s.closing || s.dismissScheduled) {
        return;
    }
    s.dismissScheduled = YES;
    if (CGRectContainsPoint(s.touchTarget, point)) {
        gRXPSuppressGUID = s.guid;
        gRXPSuppressPart = s.partKey;
        gRXPSuppressTime = CACurrentMediaTime();
    } else {
        gRXPSuppressGUID = nil;
    }
    __weak RXPickerSession *weakSession = s;
    dispatch_async(dispatch_get_main_queue(), ^{
        RXPDismissSession(weakSession, YES);
    });
}

#pragma mark - Pick

static void RXPPick(RXPickerSession *s, NSInteger index) {
    if (!s || s.closing) {
        return;
    }
    CKTranscriptController *tc = s.tc;
    if (!tc || RXPSession(tc) != s) {
        RXPClose(s, YES);
        return;
    }
    BOOL removal = (index == s.mineIndex);
    RXKind kind = RXKindNone;
    NSString *emoji = nil;
    if (removal) {
        kind = s.mineKind;                       // tapping my lit kind removes it
        emoji = s.mineEmoji;
    } else if (index >= 0 && index < RXP_KIND_COUNT) {
        kind = kRXPKinds[index];                 // a different kind replaces mine
    }
    if (kind == RXKindNone || (kind == RXKindEmoji && [emoji length] == 0)) {
        RXPickerDismiss(tc, YES);
        return;
    }
    if (!RXPValidate(s, tc)) {
        RXLog(@"picker: pick dropped, target changed (guid %@)", RXGUIDTail(s.guid));
        RXPickerDismiss(tc, YES);
        return;
    }
    // Sent while the bar is still up; the optimistic badge refresh it queues waits for the close fade
    // (RXPickerIsOpen stays YES until the fade's completion, which pokes the transcript; DESIGN 6).
    BOOL sent = RXSendReaction(tc, s.guid, s.partKey, kind, emoji, removal);
    RXLog(@"picker: pick kind=%d removal=%d sent=%d guid=%@", (int)kind, (int)removal, (int)sent, RXGUIDTail(s.guid));
    RXPickerDismiss(tc, YES);
}

#pragma mark - API (RXShared.h)

void RXPickerToggle(CKTranscriptController *tc, CKBalloonView *balloon) {
    if (!tc || !balloon) {
        return;
    }
    RXPickerSession *s = RXPSession(tc);
    if (s) {
        BOOL same = RXPSessionShows(s, balloon);
        RXPickerDismiss(tc, YES);
        if (same) {
            return;
        }
    }
    RXPOpen(tc, balloon, nil);
}

void RXPickerPresentForBadge(CKTranscriptController *tc, UITableViewCell *cell) {
    if (!tc || !cell || ![cell respondsToSelector:@selector(balloonView)]) {
        return;
    }
    CKBalloonView *balloon = [(CKMessageCell *)cell balloonView];
    if (!balloon) {
        return;
    }
    RXPickerSession *s = RXPSession(tc);
    if (s) {
        if (RXPSessionShows(s, balloon)) {
            return;
        }
        RXPickerDismiss(tc, YES);
    }
    RXPOpen(tc, balloon, cell);
}

// Teardown-safe: no prefs, no weak reference to tc formed, tc.view never touched.
void RXPickerDismiss(CKTranscriptController *tc, BOOL animated) {
    RXPickerSession *s = RXPSession(tc);
    if (!s) {
        return;
    }
    objc_setAssociatedObject(tc, &kRXPickerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RXPClose(s, animated);
}

// YES while a picker is open and while its animated close fade runs (so the transcript gate opens only
// after the bar has gone, DESIGN 6). RXPickerDismiss / RXPickerToggle act on the open session only.
BOOL RXPickerIsOpen(CKTranscriptController *tc) {
    if (RXPSession(tc)) {
        return YES;
    }
    if (!tc) {
        return NO;
    }
    id closing = objc_getAssociatedObject(tc, &kRXPickerClosingKey);
    if (![closing isKindOfClass:[RXPickerSession class]]) {
        return NO;
    }
    return CACurrentMediaTime() < [(RXPickerSession *)closing fadeUntil];
}
