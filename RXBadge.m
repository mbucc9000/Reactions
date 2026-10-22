// Reactions 2.0 — RXBadge.m: the tapback badge (RXReactionBalloonView) and the sent-reply quote
// (RXQuoteBalloonView). DESIGN.md §6 and §11; R6-visual §2-§4 and §7; mockups v2 (src_v2/badges.py,
// src_v2/transcript.py are the geometry reference).
//
// Both views live in balloon.superview (set up by RXTranscript), draw everything in drawRect: (no
// subviews, no UILabel), are non-opaque, and never touch the balloon, the cell layer or any frame
// other than their own. "Balloon" is in both class names so MessageWallpapers' background hold
// skips them. Colours are raw components (never -[UIColor getRed:...]); no UIRectFill.

#import "RXShared.h"
#import <math.h>

#pragma mark - Shared helpers

#define RXB_POP_KEY      @"RXBadgePop"
#define RXB_OUT_KEY      @"RXBadgeOut"
#define RXB_STEP         0.74f     // glyph pitch in a pill, x D (R6 §3)
#define RXB_GLYPH        0.64f     // glyph box, x D (R6 §2.4)
#define RXB_OVERLAP      0.35f     // my blue dot overlaps the grey pill by 0.35 D (DESIGN §6)
#define RXB_STACK_PAD    0.25f     // grey pill's extra inner padding under my dot, x D
#define RXB_MAX_GLYPHS   3         // multi-kind pills show up to 3 glyphs, then "+N"
#define RXB_HIT          44.0f     // minimum touch target (pt)

static CGFloat RXScreenScale(void) {
    CGFloat s = [UIScreen mainScreen].scale;
    return s > 0 ? s : 1.0f;
}

static CGFloat RXAlignToPixel(CGFloat v, CGFloat scale) {
    return roundf(v * scale) / scale;
}

static CGRect RXCircleRect(CGFloat cx, CGFloat cy, CGFloat d) {
    return CGRectMake(cx - d / 2.0f, cy - d / 2.0f, d, d);
}

static CGRect RXUnionRect(CGRect acc, CGRect r) {
    if (CGRectIsEmpty(r)) {
        return acc;
    }
    return CGRectIsNull(acc) ? r : CGRectUnion(acc, r);
}

// R6 §2.3: the visible body of a (tailed or untailed) stock balloon frame — the frame minus the art's
// halo, drop shadow and tail. outgoing: (+2, +1.5) .. (-9.5, -4.5); incoming: (+9.5, +1.5) .. (-2, -4.5).
static CGRect RXBalloonBody(CGRect b, BOOL outgoing) {
    CGFloat left = outgoing ? 2.0f : 9.5f;
    CGFloat right = outgoing ? 9.5f : 2.0f;
    CGFloat w = b.size.width - left - right;
    CGFloat h = b.size.height - 1.5f - 4.5f;
    if (w < 1.0f) {
        w = 1.0f;
    }
    if (h < 1.0f) {
        h = 1.0f;
    }
    return CGRectMake(b.origin.x + left, b.origin.y + 1.5f, w, h);
}

// The drawn extent of a balloon dot whose BODY is `body` (R6 §2.2: 26x26 body at (2,1.5) of the 30x32 art).
static CGRect RXDotArtForBody(CGRect body) {
    CGFloat f = body.size.height / 26.0f;
    return CGRectMake(body.origin.x - 2.0f * f, body.origin.y - 1.5f * f, body.size.width + 4.0f * f, 32.0f * f);
}

// Hard 1 pt "engraved" copy, then the text (UILabel shadowOffset look; never CGContextSetShadow).
static void RXDrawEngravedText(NSString *s, CGPoint p, UIFont *font, const CGFloat fill[4],
                               const CGFloat shadow[4], CGFloat dy) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx || !s.length || !font) {
        return;
    }
    CGContextSaveGState(ctx);
    CGContextSetRGBFillColor(ctx, shadow[0], shadow[1], shadow[2], shadow[3]);
    [s drawAtPoint:CGPointMake(p.x, p.y + dy) withFont:font];
    CGContextSetRGBFillColor(ctx, fill[0], fill[1], fill[2], fill[3]);
    [s drawAtPoint:p withFont:font];
    CGContextRestoreGState(ctx);
}

// Vector stand-in for a missing balloon-dot artwork (keeps the badge readable instead of floating glyphs).
static void RXDrawFallbackDot(CGRect body, BOOL blue) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx || CGRectIsEmpty(body)) {
        return;
    }
    CGFloat r = MIN(body.size.height, body.size.width) / 2.0f;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:r];
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    if (blue) {
        RXFillGradient(ctx, body, RXGrad(0.482f, 0.694f, 1.0f, 1.0f, 0.282f, 0.580f, 1.0f, 1.0f));    // #7BB1FF -> #4894FF
    } else {
        RXFillGradient(ctx, body, RXGrad(0.965f, 0.965f, 0.965f, 1.0f, 0.851f, 0.851f, 0.851f, 1.0f)); // #F6F6F6 -> #D9D9D9
    }
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(body, 0.5f, 0.5f)
                                                    cornerRadius:MAX(0.0f, r - 0.5f)];
    CGContextAddPath(ctx, edge.CGPath);
    CGContextSetLineWidth(ctx, 1.0f);
    if (blue) {
        CGContextSetRGBStrokeColor(ctx, 0.110f, 0.204f, 0.439f, 1.0f);   // #1C3470
    } else {
        CGContextSetRGBStrokeColor(ctx, 0.447f, 0.447f, 0.447f, 1.0f);   // #727272
    }
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

#pragma mark - Badge content

static BOOL RXBadgeModelHasContent(RXBadgeModel *m) {
    if (!m || m.isEmpty) {
        return NO;
    }
    return m.others.count > 0 || m.mine != nil;
}

static BOOL RXReactionDrawable(id obj) {
    if (![obj isKindOfClass:[RXReaction class]]) {
        return NO;
    }
    RXReaction *r = obj;
    if (r.kind == RXKindEmoji) {
        return r.emoji.length > 0;
    }
    return RXKindKey(r.kind).length > 0;
}

static void RXDrawReactionGlyph(RXReaction *r, CGRect box, RXGlyphStyle style) {
    if (!r) {
        return;
    }
    if (r.kind == RXKindEmoji) {
        if (r.emoji.length) {
            RXDrawGlyph(nil, r.emoji, box, style);
        }
        return;
    }
    NSString *key = RXKindKey(r.kind);
    if (key.length) {
        RXDrawGlyph(key, nil, box, style);
    }
}

static UIFont *RXBadgeCountFont(void) {
    static UIFont *font;
    if (!font) {
        font = [UIFont boldSystemFontOfSize:0.46f * RX_BADGE_D];    // R6 §2.4: Helvetica Bold 0.46 D
    }
    return font;
}

static void RXBadgeDrawDot(UIImage *dot, BOOL blue, CGRect body) {
    if (CGRectIsEmpty(body)) {
        return;
    }
    if (dot) {
        RXDrawBalloonDot(dot, body, 1.0f);
        return;
    }
    RXLogOnce(@"badge.dotart", @"badge: balloon-dot art missing, drawing the vector fallback");
    RXDrawFallbackDot(body, blue);
}

// A scale about point p (p relative to the layer's anchor = bounds centre). Row-vector convention:
// translate(-p), then scale, then translate(+p).
static CATransform3D RXScaleAbout(CGPoint p, CGFloat s) {
    CATransform3D t = CATransform3DMakeTranslation(-p.x, -p.y, 0);
    t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1));
    return CATransform3DConcat(t, CATransform3DMakeTranslation(p.x, p.y, 0));
}

#pragma mark - Badge geometry

// All rects in the badge view's own coordinates once laid out (superview coordinates while computing).
typedef struct {
    BOOL valid;
    BOOL hasGrey;
    BOOL hasMine;
    BOOL mineDots;        // my dot stands alone -> it carries the tail dots
    CGFloat cy;           // centre line of the badge bodies
    CGFloat glyphX0;      // centre x of the first grey glyph
    CGFloat textX;        // left x of the count / "+N" text
    CGRect greyBody;
    CGRect greyDot1;
    CGRect greyDot2;
    CGRect mineBody;
    CGRect mineDot1;
    CGRect mineDot2;
    CGRect art;           // union of everything drawn (dot art incl. halo/shadow)
    CGRect bodies;        // union of the pill + my dot bodies (pop centre)
    CGRect balloonBody;   // the bubble's body (keeps its touches)
} RXBadgeGeometry;

static void RXBadgeGeometryOffset(RXBadgeGeometry *g, CGFloat dx, CGFloat dy) {
    g->cy += dy;
    g->glyphX0 += dx;
    g->textX += dx;
    g->greyBody = CGRectOffset(g->greyBody, dx, dy);
    g->greyDot1 = CGRectOffset(g->greyDot1, dx, dy);
    g->greyDot2 = CGRectOffset(g->greyDot2, dx, dy);
    g->mineBody = CGRectOffset(g->mineBody, dx, dy);
    g->mineDot1 = CGRectOffset(g->mineDot1, dx, dy);
    g->mineDot2 = CGRectOffset(g->mineDot2, dx, dy);
    g->art = CGRectOffset(g->art, dx, dy);
    g->bodies = CGRectOffset(g->bodies, dx, dy);
    g->balloonBody = CGRectOffset(g->balloonBody, dx, dy);
}

static BOOL RXBadgeGeometryEqual(const RXBadgeGeometry *a, const RXBadgeGeometry *b) {
    return a->valid == b->valid && a->hasGrey == b->hasGrey && a->hasMine == b->hasMine &&
           a->mineDots == b->mineDots && a->cy == b->cy && a->glyphX0 == b->glyphX0 && a->textX == b->textX &&
           CGRectEqualToRect(a->greyBody, b->greyBody) && CGRectEqualToRect(a->greyDot1, b->greyDot1) &&
           CGRectEqualToRect(a->greyDot2, b->greyDot2) && CGRectEqualToRect(a->mineBody, b->mineBody) &&
           CGRectEqualToRect(a->mineDot1, b->mineDot1) && CGRectEqualToRect(a->mineDot2, b->mineDot2) &&
           CGRectEqualToRect(a->art, b->art) && CGRectEqualToRect(a->bodies, b->bodies) &&
           CGRectEqualToRect(a->balloonBody, b->balloonBody);
}

static void RXExtendRange(CGFloat x, CGFloat *lo, CGFloat *hi) {
    if (x < *lo) {
        *lo = x;
    }
    if (x > *hi) {
        *hi = x;
    }
}

// Mockup draw_reactions() (src_v2/badges.py), in superview coordinates.
//   nGrey     glyphs shown in the grey pill (0 = no grey pill), textW = width of the count / "+N" (0 = none)
static RXBadgeGeometry RXBadgeComputeGeometry(NSUInteger nGrey, CGFloat textW, BOOL hasMine,
                                              CGRect balloonFrame, BOOL outgoing, CGRect bounds) {
    RXBadgeGeometry g;
    memset(&g, 0, sizeof(g));
    BOOL hasGrey = nGrey > 0;
    if ((!hasGrey && !hasMine) || CGRectIsEmpty(balloonFrame)) {
        return g;
    }
    const CGFloat D = RX_BADGE_D;
    CGRect B = RXBalloonBody(balloonFrame, outgoing);
    CGFloat out = outgoing ? -1.0f : 1.0f;
    // Anchor = centre of the single-badge position (R6 §2.3).
    CGFloat ax = outgoing ? CGRectGetMinX(B) - 1.0f : CGRectGetMaxX(B) + 1.0f;
    CGFloat ay = CGRectGetMinY(B) - 5.0f;
    BOOL stacked = hasGrey && hasMine;
    CGFloat pad = stacked ? RXB_STACK_PAD * D : 0.0f;
    CGFloat gcx = stacked ? ax + out * (1.0f - RXB_OVERLAP) * D : ax;    // grey pill's inner cap centre
    CGFloat w = 0.0f;
    if (hasGrey) {
        if (nGrey == 1 && textW <= 0.0f) {
            w = D + pad;
        } else {
            w = D + (CGFloat)(nGrey - 1) * RXB_STEP * D + (textW > 0.0f ? textW + 0.22f * D : 0.0f) + 0.10f * D + pad;
        }
    }
    // Horizontal extent (bodies + 2 pt halo + tail dots); slide toward the bubble to stay inside the bounds.
    CGFloat dotReach = (0.64f + 0.075f) * D;
    CGFloat lo = CGFLOAT_MAX, hi = -CGFLOAT_MAX;
    if (hasGrey) {
        CGFloat p0 = out > 0 ? gcx - D / 2.0f : gcx + D / 2.0f - w;
        RXExtendRange(p0, &lo, &hi);
        RXExtendRange(p0 + w, &lo, &hi);
        CGFloat ocx = gcx + out * (w - D);
        RXExtendRange(ocx + out * dotReach, &lo, &hi);
    }
    if (hasMine) {
        RXExtendRange(ax - D / 2.0f, &lo, &hi);
        RXExtendRange(ax + D / 2.0f, &lo, &hi);
        if (!hasGrey) {
            RXExtendRange(ax + out * dotReach, &lo, &hi);
        }
    }
    lo -= 2.0f;
    hi += 2.0f;
    if (!CGRectIsEmpty(bounds)) {
        CGFloat minX = CGRectGetMinX(bounds) + 2.0f;
        CGFloat maxX = CGRectGetMaxX(bounds) - 2.0f;
        CGFloat shift = 0.0f;
        if (hi > maxX) {
            shift = maxX - hi;
        }
        if (lo + shift < minX) {
            shift = minX - lo;
        }
        ax += shift;
        gcx += shift;
        // Vertical: keep the dot art's top inside the bounds.
        CGFloat artTop = ay - D / 2.0f - 1.5f * (D / 26.0f);
        if (artTop < CGRectGetMinY(bounds)) {
            ay += CGRectGetMinY(bounds) - artTop;
        }
    }

    g.valid = YES;
    g.hasGrey = hasGrey;
    g.hasMine = hasMine;
    g.mineDots = hasMine && !hasGrey;
    g.cy = ay;
    g.art = CGRectNull;
    g.bodies = CGRectNull;
    if (hasGrey) {
        CGFloat x0 = out > 0 ? gcx - D / 2.0f : gcx + D / 2.0f - w;
        g.greyBody = CGRectMake(x0, ay - D / 2.0f, w, D);
        // Tail dots trail outward and down from the OUTER end cap (R6 §2.3 / §3).
        CGFloat ocx = gcx + out * (w - D);
        g.greyDot1 = RXCircleRect(ocx + out * 0.44f * D, ay + 0.46f * D, 0.30f * D);
        g.greyDot2 = RXCircleRect(ocx + out * 0.64f * D, ay + 0.76f * D, 0.15f * D);
        g.glyphX0 = x0 + D / 2.0f + (out > 0 ? pad : 0.0f);
        g.textX = g.glyphX0 + (CGFloat)(nGrey - 1) * RXB_STEP * D + 0.46f * D;
        g.art = RXUnionRect(g.art, RXDotArtForBody(g.greyBody));
        g.art = RXUnionRect(g.art, RXDotArtForBody(g.greyDot1));
        g.art = RXUnionRect(g.art, RXDotArtForBody(g.greyDot2));
        g.bodies = RXUnionRect(g.bodies, g.greyBody);
    }
    if (hasMine) {
        g.mineBody = RXCircleRect(ax, ay, D);
        g.art = RXUnionRect(g.art, RXDotArtForBody(g.mineBody));
        g.bodies = RXUnionRect(g.bodies, g.mineBody);
        if (g.mineDots) {
            g.mineDot1 = RXCircleRect(ax + out * 0.44f * D, ay + 0.46f * D, 0.30f * D);
            g.mineDot2 = RXCircleRect(ax + out * 0.64f * D, ay + 0.76f * D, 0.15f * D);
            g.art = RXUnionRect(g.art, RXDotArtForBody(g.mineDot1));
            g.art = RXUnionRect(g.art, RXDotArtForBody(g.mineDot2));
        }
    }
    g.balloonBody = B;
    return g;
}

#pragma mark - RXReactionBalloonView

@implementation RXReactionBalloonView {
    RXBadgeModel *_shown;        // what is drawn (lags _model only while the removal animation runs)
    NSArray *_greyKinds;         // RXReaction, <= 3, in the grey pill (others' kinds)
    RXReaction *_mineKind;       // my kind (blue dot) or nil
    NSString *_countText;        // count on a single-kind grey badge, or "+N"; nil otherwise
    NSString *_signature;        // visible content, to tell a real change from a re-apply
    BOOL _hasLayout;
    CGRect _balloonFrame;
    CGRect _clampBounds;
    NSInteger _pendingPop;       // 0 none, 1 change pop, 2 full pop (waiting for the first layout)
    NSUInteger _generation;
    BOOL _removing;              // the shrink+fade is running (old content still drawn)
    BOOL _tracking;
    RXBadgeGeometry _g;          // local coordinates
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = nil;
        self.clearsContextBeforeDrawing = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.clipsToBounds = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = NO;
        memset(&_g, 0, sizeof(_g));
    }
    return self;
}

#pragma mark Model

- (void)rxRebuildContent {
    NSMutableArray *grey = [NSMutableArray array];
    NSUInteger total = 0;
    RXReaction *first = nil;
    RXReaction *mine = nil;
    if (RXBadgeModelHasContent(_shown)) {
        for (id obj in _shown.others) {
            if (!RXReactionDrawable(obj)) {
                continue;
            }
            RXReaction *r = obj;
            total++;
            if (!first) {
                first = r;
            }
            if (grey.count < RXB_MAX_GLYPHS) {
                [grey addObject:r];
            }
        }
        if (RXReactionDrawable(_shown.mine)) {
            mine = _shown.mine;
        }
    }
    _greyKinds = grey;
    _mineKind = mine;
    _countText = nil;
    if (total == 1 && first.count > 1) {
        _countText = [NSString stringWithFormat:@"%ld", (long)first.count];
    } else if (total > RXB_MAX_GLYPHS) {
        _countText = [NSString stringWithFormat:@"+%lu", (unsigned long)(total - RXB_MAX_GLYPHS)];
    }
    NSMutableString *sig = [NSMutableString string];
    for (RXReaction *r in grey) {
        [sig appendFormat:@"%d:%@,", (int)r.kind, r.emoji ?: @""];
    }
    [sig appendFormat:@"|%@|", _countText ?: @""];
    if (mine) {
        [sig appendFormat:@"%d:%@", (int)mine.kind, mine.emoji ?: @""];
    }
    _signature = sig;
}

- (void)setModel:(RXBadgeModel *)model {
    [self setModel:model animated:NO];
}

- (void)setModel:(RXBadgeModel *)model animated:(BOOL)animated {
    if (_removing && animated && !RXBadgeModelHasContent(model)) {
        // Still empty while the removal runs (a re-apply): let it finish instead of restarting it.
        _model = model;
        return;
    }
    BOOL had = _greyKinds.count > 0 || _mineKind != nil;
    NSString *oldSignature = _signature;
    _model = model;
    _generation++;
    _pendingPop = 0;
    _removing = NO;
    [self.layer removeAnimationForKey:RXB_POP_KEY];
    [self.layer removeAnimationForKey:RXB_OUT_KEY];

    BOOL live = animated && self.window != nil && !self.hidden;
    if (live && had && !RXBadgeModelHasContent(model) && _g.valid) {
        // Disappear: keep drawing the old content while it shrinks and fades (0.15 s).
        [self rxAnimateRemoval];
        return;
    }

    _shown = model;
    [self rxRebuildContent];
    BOOL has = _greyKinds.count > 0 || _mineKind != nil;
    [self rxUpdateGeometryForce:YES];
    // A brand-new badge view is configured before RXTranscript inserts it into the cell (no window, no
    // layout yet): its pop waits for the first -layoutForBalloonFrame:..., which runs right after the
    // insertion (DESIGN 6: the first reaction on a bubble pops too).
    BOOL waiting = animated && !self.hidden && (self.window == nil || !_g.valid);
    if (!has || (!live && !waiting)) {
        return;
    }
    NSInteger pop = 0;
    if (!had) {
        pop = 2;
    } else if (![oldSignature isEqualToString:_signature]) {
        pop = 1;
    }
    if (pop == 0) {
        return;
    }
    if (live && _g.valid) {
        [self rxAnimatePop:(pop == 2)];
    } else {
        _pendingPop = pop;
    }
}

- (void)setOutgoing:(BOOL)outgoing {
    if (_outgoing == outgoing) {
        return;
    }
    _outgoing = outgoing;
    if (_hasLayout) {
        [self rxUpdateGeometryForce:NO];
    }
}

- (void)setWallpaper:(BOOL)wallpaper {
    // The badge material reads the same on wallpapers (mockup v2-transcript-wallpaper); kept for restyles.
    if (_wallpaper == wallpaper) {
        return;
    }
    _wallpaper = wallpaper;
    [self setNeedsDisplay];
}

#pragma mark Layout

- (void)layoutForBalloonFrame:(CGRect)balloonFrame outgoing:(BOOL)outgoing inBounds:(CGRect)bounds {
    _balloonFrame = balloonFrame;
    _outgoing = outgoing;
    _clampBounds = bounds;
    _hasLayout = YES;
    [self rxUpdateGeometryForce:NO];
    if (_pendingPop && _g.valid && self.window != nil && !self.hidden) {
        [self rxAnimatePop:(_pendingPop == 2)];
    }
    _pendingPop = 0;
}

- (void)rxUpdateGeometryForce:(BOOL)force {
    RXBadgeGeometry g;
    memset(&g, 0, sizeof(g));
    if (_hasLayout && (_greyKinds.count > 0 || _mineKind != nil)) {
        CGFloat textW = _countText.length ? ceilf([_countText sizeWithFont:RXBadgeCountFont()].width) : 0.0f;
        g = RXBadgeComputeGeometry(_greyKinds.count, textW, _mineKind != nil, _balloonFrame, _outgoing, _clampBounds);
    }
    if (g.valid) {
        CGRect frame = CGRectIntegral(g.art);
        RXBadgeGeometryOffset(&g, -frame.origin.x, -frame.origin.y);
        if (!CGRectEqualToRect(self.frame, frame)) {
            self.frame = frame;
        }
    }
    if (force || !RXBadgeGeometryEqual(&g, &_g)) {
        _g = g;
        [self setNeedsDisplay];
    }
}

- (CGRect)artRectInSuperview {
    if (!_g.valid || self.hidden || !RXBadgeModelHasContent(_model)) {
        return CGRectNull;
    }
    CGRect f = self.frame;
    return CGRectOffset(_g.art, f.origin.x, f.origin.y);
}

#pragma mark Animation (DESIGN §6 motion)

- (CGPoint)rxPopCentre {
    CGSize sz = self.bounds.size;
    CGRect b = CGRectIsNull(_g.bodies) ? self.bounds : _g.bodies;
    return CGPointMake(CGRectGetMidX(b) - sz.width / 2.0f, CGRectGetMidY(b) - sz.height / 2.0f);
}

// Appear: scale 0.5 -> 1.08 -> 1.0 over 0.2 s from the badge centre (a content change pops from 0.85).
- (void)rxAnimatePop:(BOOL)full {
    CGPoint p = [self rxPopCentre];
    CFTimeInterval duration = 0.2;
    CAKeyframeAnimation *scale = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    scale.values = @[[NSValue valueWithCATransform3D:RXScaleAbout(p, full ? 0.5f : 0.85f)],
                     [NSValue valueWithCATransform3D:RXScaleAbout(p, 1.08f)],
                     [NSValue valueWithCATransform3D:CATransform3DIdentity]];
    scale.keyTimes = @[@0.0f, @0.6f, @1.0f];
    scale.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                              [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    scale.duration = duration;
    NSMutableArray *animations = [NSMutableArray arrayWithObject:scale];
    if (full) {
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0.0f, @1.0f, @1.0f];
        fade.keyTimes = @[@0.0f, @0.4f, @1.0f];
        fade.duration = duration;
        [animations addObject:fade];
    }
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = animations;
    group.duration = duration;
    [self.layer addAnimation:group forKey:RXB_POP_KEY];
}

// Disappear: shrink + fade over 0.15 s, then drop the old content (the forward-filled animation keeps
// the layer invisible until the next setModel: removes it, so the old art never flashes back).
- (void)rxAnimateRemoval {
    CGPoint p = [self rxPopCentre];
    CFTimeInterval duration = 0.15;
    CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform"];
    shrink.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    shrink.toValue = [NSValue valueWithCATransform3D:RXScaleAbout(p, 0.5f)];
    shrink.duration = duration;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0f;
    fade.toValue = @0.0f;
    fade.duration = duration;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[shrink, fade];
    group.duration = duration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;

    NSUInteger generation = _generation;
    __weak RXReactionBalloonView *weakSelf = self;
    _removing = YES;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        RXReactionBalloonView *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_generation != generation) {
            return;
        }
        [strongSelf rxFinishRemoval];
    }];
    [self.layer addAnimation:group forKey:RXB_OUT_KEY];
    [CATransaction commit];
}

- (void)rxFinishRemoval {
    _removing = NO;
    _shown = _model;
    [self rxRebuildContent];
    [self rxUpdateGeometryForce:YES];
}

#pragma mark Drawing

- (void)drawRect:(CGRect)rect {
    if (!_g.valid) {
        return;
    }
    const CGFloat D = RX_BADGE_D;
    CGFloat gl = RXB_GLYPH * D;
    CGFloat scale = RXScreenScale();
    if (_g.hasGrey) {
        UIImage *dot = RXBalloonDot(NO);
        // z-order: dot 2 < dot 1 < pill < glyphs (R6 §2.3)
        RXBadgeDrawDot(dot, NO, _g.greyDot2);
        RXBadgeDrawDot(dot, NO, _g.greyDot1);
        RXBadgeDrawDot(dot, NO, _g.greyBody);
        NSUInteger i = 0;
        for (RXReaction *r in _greyKinds) {
            CGFloat gx = _g.glyphX0 + (CGFloat)i * RXB_STEP * D;
            CGRect box = CGRectMake(RXAlignToPixel(gx - gl / 2.0f, scale), RXAlignToPixel(_g.cy - gl / 2.0f, scale), gl, gl);
            RXDrawReactionGlyph(r, box, RXGlyphOnGrey);
            i++;
        }
        if (_countText.length) {
            // Count / "+N": Helvetica Bold 0.46 D, the grey glyph's top colour + white a0.80 at +1, baseline cy + 0.17 D.
            static const CGFloat fill[4] = {0.490f, 0.514f, 0.565f, 1.0f};      // #7D8390
            static const CGFloat shadow[4] = {1.0f, 1.0f, 1.0f, 0.80f};
            UIFont *font = RXBadgeCountFont();
            CGFloat baseline = _g.cy + 0.17f * D;
            CGPoint p = CGPointMake(RXAlignToPixel(_g.textX, scale), RXAlignToPixel(baseline - font.ascender, scale));
            RXDrawEngravedText(_countText, p, font, fill, shadow, 1.0f);
        }
    }
    if (_g.hasMine) {
        UIImage *dot = RXBalloonDot(YES);
        if (_g.mineDots) {
            RXBadgeDrawDot(dot, YES, _g.mineDot2);
            RXBadgeDrawDot(dot, YES, _g.mineDot1);
        }
        RXBadgeDrawDot(dot, YES, _g.mineBody);
        CGFloat cx = CGRectGetMidX(_g.mineBody);
        CGRect box = CGRectMake(RXAlignToPixel(cx - gl / 2.0f, scale), RXAlignToPixel(_g.cy - gl / 2.0f, scale), gl, gl);
        RXDrawReactionGlyph(_mineKind, box, RXGlyphOnBlue);
    }
}

#pragma mark Touches (>= 44x44 target, no recognizer)

- (BOOL)rxHitsPoint:(CGPoint)point {
    if (!_g.valid || self.hidden || !RXBadgeModelHasContent(_model)) {
        return NO;
    }
    // Without onTap (React & Reply off, the 2.1.0 default) the badge still takes touches on its own art,
    // so MessageWallpapers' long-press skips it as before; only a tappable badge gets the 44 pt target.
    CGRect hit = _g.art;
    if (self.onTap && hit.size.width < RXB_HIT) {
        hit = CGRectInset(hit, (hit.size.width - RXB_HIT) / 2.0f, 0);
    }
    if (self.onTap && hit.size.height < RXB_HIT) {
        hit = CGRectInset(hit, 0, (hit.size.height - RXB_HIT) / 2.0f);
    }
    // UIKit never hit-tests a point above the cell's top (our superview's bounds), so the part of the
    // 44 pt square that would sit there moves below the art instead (DESIGN 6: >= 44 pt reachable); over
    // the bubble's body only the art counts (below).
    UIView *host = self.superview;
    if (host) {
        CGFloat top = CGRectGetMinY(host.bounds) - self.frame.origin.y;
        if (CGRectGetMinY(hit) < top) {
            hit.origin.y = top;
        }
    }
    if (!CGRectContainsPoint(hit, point)) {
        return NO;
    }
    // Over the bubble's own body only the badge art itself counts (the text keeps its double-tap/Copy).
    if (CGRectContainsPoint(_g.balloonBody, point)) {
        CGRect own = CGRectIsNull(_g.bodies) ? CGRectZero : CGRectInset(_g.bodies, -2.0f, -2.0f);
        return CGRectContainsPoint(own, point);
    }
    return YES;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [self rxHitsPoint:point];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    _tracking = YES;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    BOOL wasTracking = _tracking;
    _tracking = NO;
    UITouch *touch = [touches anyObject];
    if (!wasTracking || !touch) {
        return;
    }
    if (![self rxHitsPoint:[touch locationInView:self]]) {
        return;
    }
    void (^tap)(void) = self.onTap;
    if (tap) {
        tap();
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    _tracking = NO;
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement {
    return !self.hidden && _g.valid && RXBadgeModelHasContent(_model);
}

- (NSString *)accessibilityLabel {
    if (!RXBadgeModelHasContent(_model)) {
        return nil;
    }
    NSString *s = [_model accessibilityString];
    return s.length ? s : nil;
}

- (UIAccessibilityTraits)accessibilityTraits {
    return self.onTap ? UIAccessibilityTraitButton : UIAccessibilityTraitNone;
}

@end

#pragma mark - Quote: metrics and text layout

#define RXQ_SCALE        0.80f     // the quote is the original drawn at 80 % (R6 §7)
#define RXQ_INSET_X      12.0f     // untailed balloon text inset, both sides
#define RXQ_INSET_TOP    4.0f
#define RXQ_INSET_BOTTOM 8.0f
#define RXQ_MAX_TEXT     186.0f    // balloonWidth 217 - insets 31 (transcript.py MAXTEXT)
#define RXQ_EDGE         9.5f      // quote body edge = stock body edge (R6 §7 placement)
#define RXQ_MAX_UNITS    300
#define RXQ_BOUNDS_CAP   320

typedef enum {
    RXQuoteModeNone = 0,
    RXQuoteModeText,     // up to 2 lines of the parent's text
    RXQuoteModeNoun,     // media without thumbnail: "Photo", "Video", ...
    RXQuoteModeThumb,    // image/movie with a thumbnail in the untailed image-bubble mask
} RXQuoteMode;

typedef struct {
    RXQuoteMode mode;
    CGSize size;         // unscaled art size (the 0.80 CTM scale is applied when drawing)
    CGFloat textTop;     // unscaled y of the first line box
    CGFloat lineHeight;
} RXQuoteMetrics;

@interface RXQuoteTextLines : NSObject
@property (nonatomic, copy) NSString *line1;
@property (nonatomic, copy) NSString *line2;       // nil = one line
@property (nonatomic, assign) CGFloat textWidth;
@end

@implementation RXQuoteTextLines
@end

// The balloon text font and line height, exactly as ChatKit computes them (Large Text aware):
// -[CKUIBehavior balloonTextFont] = systemFontOfSize:_UIAccessibilityLargeTextFontSize(16),
// -balloonTextLineHeight = _CKBalloonLineHeightFromFont (20 at the default size). Fallback 16 / 20.
static void RXQuoteTextStyle(UIFont **outFont, CGFloat *outLineHeight) {
    UIFont *font = nil;
    CGFloat lineHeight = 0.0f;
    Class cls = NSClassFromString(@"CKUIBehavior");
    SEL sharedSel = NSSelectorFromString(@"sharedBehaviors");
    SEL fontSel = NSSelectorFromString(@"balloonTextFont");
    SEL lineSel = NSSelectorFromString(@"balloonTextLineHeight");
    if (cls && [cls respondsToSelector:sharedSel]) {
        id behaviors = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
        if (behaviors && [behaviors respondsToSelector:fontSel] && [behaviors respondsToSelector:lineSel]) {
            id f = ((id (*)(id, SEL))objc_msgSend)(behaviors, fontSel);
            if ([f isKindOfClass:[UIFont class]]) {
                font = f;
                lineHeight = ((float (*)(id, SEL))objc_msgSend)(behaviors, lineSel);
            }
        }
    }
    if (!font) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            RXLogOnce(@"quote.textstyle", @"quote: CKUIBehavior balloon text style unavailable, using 16/20");
        }
        font = [UIFont systemFontOfSize:16.0f];
        lineHeight = 20.0f;
    }
    if (!(lineHeight >= 10.0f && lineHeight <= 120.0f)) {
        lineHeight = MAX(20.0f, ceilf(font.pointSize * 1.25f));
    }
    *outFont = font;
    *outLineHeight = lineHeight;
}

static CGFloat RXQuoteWidth(NSString *s, UIFont *font) {
    return s.length ? [s sizeWithFont:font].width : 0.0f;
}

static NSString *RXQuoteTrimTrailing(NSString *s) {
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger end = s.length;
    while (end > 0 && [ws characterIsMember:[s characterAtIndex:end - 1]]) {
        end--;
    }
    return end == s.length ? s : [s substringToIndex:end];
}

static NSString *RXQuoteClean(NSString *s) {
    if (!s.length) {
        return @"";
    }
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"\uFFFC" withString:@"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\u2028" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\u2029" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    NSString *t = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length > RXQ_MAX_UNITS) {
        NSRange r = [t rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, RXQ_MAX_UNITS)];
        t = [t substringWithRange:r];
    }
    return t;
}

// Composed-character boundaries of s: out[0] = 0 ... out[n-1] = end (or the cap). Returns n.
static NSUInteger RXQuoteBoundaries(NSString *s, NSUInteger *out, NSUInteger cap) {
    NSUInteger n = 0, i = 0, len = s.length;
    out[n++] = 0;
    while (i < len && n < cap) {
        NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:i];
        NSUInteger next = NSMaxRange(r);
        if (next <= i) {
            next = i + 1;
        }
        i = next;
        out[n++] = i;
    }
    return n;
}

// Largest k in [1, n-1] whose prefix (+ suffix, after trimming trailing whitespace) fits maxW; 1 if none.
static NSUInteger RXQuoteFitIndex(NSString *s, const NSUInteger *b, NSUInteger n, UIFont *font,
                                  CGFloat maxW, NSString *suffix) {
    NSUInteger lo = 1, hi = n - 1, best = 1;
    while (lo <= hi) {
        NSUInteger mid = (lo + hi) / 2;
        NSString *p = [s substringToIndex:b[mid]];
        if (suffix) {
            p = [RXQuoteTrimTrailing(p) stringByAppendingString:suffix];
        }
        if (RXQuoteWidth(p, font) <= maxW + 0.01f) {
            best = mid;
            lo = mid + 1;
        } else {
            if (mid <= 1) {
                break;
            }
            hi = mid - 1;
        }
    }
    return best;
}

static NSString *RXQuoteTruncate(NSString *s, UIFont *font, CGFloat maxW) {
    if (RXQuoteWidth(s, font) <= maxW + 0.01f) {
        return s;
    }
    NSUInteger b[RXQ_BOUNDS_CAP];
    NSUInteger n = RXQuoteBoundaries(s, b, RXQ_BOUNDS_CAP);
    if (n < 2) {
        return @"\u2026";
    }
    NSUInteger k = RXQuoteFitIndex(s, b, n, font, maxW, @"\u2026");
    return [RXQuoteTrimTrailing([s substringToIndex:b[k]]) stringByAppendingString:@"\u2026"];
}

// Greedy word wrap into at most 2 lines; the 2nd line carries the rest, tail-truncated with "…"
// (transcript.py quote_size()). Hard line breaks are honoured for line 1.
static RXQuoteTextLines *RXQuoteWrap(NSString *raw, UIFont *font, CGFloat maxW) {
    RXQuoteTextLines *out = [RXQuoteTextLines new];
    NSString *text = RXQuoteClean(raw);
    if (!text.length) {
        out.line1 = @"\u2026";
        out.textWidth = RXQuoteWidth(out.line1, font);
        return out;
    }
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSRange nl = [text rangeOfCharacterFromSet:newlines];
    NSString *para = nl.location == NSNotFound ? text : [text substringToIndex:nl.location];
    NSString *after = nl.location == NSNotFound ? @"" : [text substringFromIndex:NSMaxRange(nl)];
    NSString *line1 = para;
    NSString *rest = after;
    if (RXQuoteWidth(para, font) > maxW + 0.01f) {
        NSUInteger b[RXQ_BOUNDS_CAP];
        NSUInteger n = RXQuoteBoundaries(para, b, RXQ_BOUNDS_CAP);
        NSUInteger cut = para.length;
        if (n >= 2) {
            cut = b[RXQuoteFitIndex(para, b, n, font, maxW, nil)];
            // Prefer the last space at or before the cut (the first character that didn't fit may be it).
            NSUInteger searchEnd = MIN(cut + 1, para.length);
            NSRange ws = [para rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]
                                               options:NSBackwardsSearch
                                                 range:NSMakeRange(0, searchEnd)];
            if (ws.location != NSNotFound && ws.location > 0) {
                cut = ws.location;
            }
        }
        line1 = [para substringToIndex:cut];
        NSString *tail = [para substringFromIndex:cut];
        rest = after.length ? [NSString stringWithFormat:@"%@\n%@", tail, after] : tail;
    }
    line1 = RXQuoteTrimTrailing(line1);
    if (!line1.length) {
        line1 = @"\u2026";
    }
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (rest.length) {
        rest = [[rest componentsSeparatedByCharactersInSet:newlines] componentsJoinedByString:@" "];
        out.line2 = RXQuoteTruncate(rest, font, maxW);
    }
    out.line1 = line1;
    out.textWidth = MAX(RXQuoteWidth(line1, font), RXQuoteWidth(out.line2, font));
    return out;
}

static RXQuoteTextLines *RXQuoteLinesFor(NSString *snippet, UIFont *font, CGFloat maxW) {
    static NSMutableDictionary *cache;
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
    }
    NSString *text = snippet ?: @"";
    NSString *key = [NSString stringWithFormat:@"%d|%d|%@", (int)roundf(maxW * 2.0f),
                     (int)roundf(font.pointSize * 10.0f), text];
    RXQuoteTextLines *hit = [cache objectForKey:key];
    if (hit) {
        return hit;
    }
    RXQuoteTextLines *lines = RXQuoteWrap(text, font, maxW);
    if (cache.count >= 128) {
        [cache removeAllObjects];
    }
    [cache setObject:lines forKey:key];
    return lines;
}

// Unscaled text width so the 80 % quote body fits between the 9.5 pt body edges of `width`.
static CGFloat RXQuoteMaxTextWidth(CGFloat width) {
    if (width < 1.0f) {
        return RXQ_MAX_TEXT;
    }
    CGFloat m = (width - 2.0f * RXQ_EDGE) / RXQ_SCALE - 2.0f * RXQ_INSET_X - 8.0f;
    return MAX(40.0f, MIN(RXQ_MAX_TEXT, m));
}

static BOOL RXQuoteIsText(RXReplyLink *link) {
    return link.kind == RXTargetText || (link.kind == RXTargetUnknown && link.snippet.length > 0);
}

static BOOL RXQuoteIsPhotoLike(RXTarget kind) {
    return kind == RXTargetImage || kind == RXTargetMovie;
}

static NSString *RXQuoteNoun(RXTarget kind) {
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

// The single source of truth for the quote's size: heightForLink:width: and the layout both use it.
// The height never depends on the thumbnail (image/movie quotes are 2-line tall with or without one).
static RXQuoteMetrics RXQuoteMetricsFor(RXReplyLink *link, UIImage *thumb, CGFloat width,
                                        NSString **outLine1, NSString **outLine2) {
    RXQuoteMetrics m;
    memset(&m, 0, sizeof(m));
    *outLine1 = nil;
    *outLine2 = nil;
    if (!link) {
        return m;
    }
    UIFont *font = nil;
    CGFloat L = 20.0f;
    RXQuoteTextStyle(&font, &L);
    m.lineHeight = L;
    CGFloat oneLine = MAX(32.0f, ceilf(L + RXQ_INSET_TOP + RXQ_INSET_BOTTOM));          // 32 at 16/20
    CGFloat twoLines = MAX(32.0f, ceilf(2.0f * L + RXQ_INSET_TOP + RXQ_INSET_BOTTOM));  // 52 at 16/20
    if (RXQuoteIsText(link)) {
        RXQuoteTextLines *lines = RXQuoteLinesFor(link.snippet, font, RXQuoteMaxTextWidth(width));
        *outLine1 = lines.line1;
        *outLine2 = lines.line2;
        m.mode = RXQuoteModeText;
        m.size = CGSizeMake(MAX(30.0f, ceilf(lines.textWidth) + 2.0f * RXQ_INSET_X), lines.line2 ? twoLines : oneLine);
        m.textTop = RXQ_INSET_TOP;
        return m;
    }
    BOOL photo = RXQuoteIsPhotoLike(link.kind);
    NSString *noun = RXQuoteNoun(link.kind);
    CGFloat h = photo ? twoLines : oneLine;
    *outLine1 = noun;                                  // the thumbnail mode only draws it if the thumb fails
    m.textTop = (h - oneLine) / 2.0f + RXQ_INSET_TOP;  // one line, vertically centred
    if (photo && thumb && thumb.size.width > 0.0f && thumb.size.height > 0.0f) {
        CGFloat bodyH = h - 6.0f;
        CGFloat bodyW = roundf(bodyH * thumb.size.width / thumb.size.height);
        bodyW = MAX(roundf(bodyH * 0.75f), MIN(roundf(bodyH * 2.0f), bodyW));
        m.mode = RXQuoteModeThumb;
        m.size = CGSizeMake(bodyW + 4.0f, h);
        return m;
    }
    m.mode = RXQuoteModeNoun;
    m.size = CGSizeMake(MAX(30.0f, ceilf(RXQuoteWidth(noun, font)) + 2.0f * RXQ_INSET_X), h);
    return m;
}

// Row space for the quote: the 80 % art height rounded up to whole points so rows stay on the pixel grid.
static CGFloat RXQuoteSlotHeight(RXQuoteMetrics m) {
    return m.mode == RXQuoteModeNone ? 0.0f : ceilf(m.size.height * RXQ_SCALE);
}

#pragma mark - Quote: artwork

// Untailed "balloon dots" (left 15 pt of the stock art + its mirror, caps {14, 14.5, 17, 14.5}; R6 §2.2 /
// §10) come from RXCore's RXBalloonDotNamed (cached; a missing art name is logged once and returns nil).

// Renders the resizable dot at its unscaled size (every slice boundary lands on a whole pixel, so no
// seams) into one image that is then drawn under the 0.80 CTM.
static UIImage *RXQuoteRenderDot(UIImage *dot, CGSize size, CGFloat scale) {
    if (!dot || size.width < 1.0f || size.height < 1.0f) {
        return nil;
    }
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    [dot drawInRect:CGRectMake(0.0f, 0.0f, size.width, size.height)];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Media parent: the thumbnail aspect-filled into the untailed image-bubble mask + its glass.
static UIImage *RXQuoteRenderThumb(UIImage *thumb, CGSize size, CGFloat scale) {
    if (!thumb || size.width < 1.0f || size.height < 1.0f || thumb.size.width <= 0.0f || thumb.size.height <= 0.0f) {
        return nil;
    }
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    CGRect full = CGRectMake(0.0f, 0.0f, size.width, size.height);
    CGRect body = CGRectMake(2.0f, 1.5f, size.width - 4.0f, size.height - 6.0f);
    UIImage *mask = RXBalloonDotNamed(@"ImageBubbleMaskUntailed");
    CGContextSaveGState(ctx);
    if (!mask) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:MIN(13.0f, body.size.height / 2.0f)];
        CGContextAddPath(ctx, clip.CGPath);
        CGContextClip(ctx);
    }
    CGFloat k = MAX(body.size.width / thumb.size.width, body.size.height / thumb.size.height);
    CGSize ts = CGSizeMake(thumb.size.width * k, thumb.size.height * k);
    [thumb drawInRect:CGRectMake(CGRectGetMidX(body) - ts.width / 2.0f, CGRectGetMidY(body) - ts.height / 2.0f,
                                 ts.width, ts.height)];
    CGContextRestoreGState(ctx);
    if (mask) {
        [mask drawInRect:full blendMode:kCGBlendModeDestinationIn alpha:1.0f];
    }
    UIImage *glass = RXBalloonDotNamed(@"ImageBubbleUntailed");
    if (glass) {
        [glass drawInRect:full];
    } else {
        UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(body, 0.5f, 0.5f)
                                                        cornerRadius:MIN(12.5f, body.size.height / 2.0f)];
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, edge.CGPath);
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextSetRGBStrokeColor(ctx, 0.0f, 0.0f, 0.0f, 0.30f);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - Quote geometry

typedef struct {
    BOOL valid;
    BOOL cross;          // connector type: corner into the reply (cross side) or a straight stem
    CGRect art;          // 80 % art rect (local)
    CGRect hit;          // touch area (local)
    CGPoint c0;          // connector start (below the quote)
    CGPoint c1;          // cross: the corner point; stem: the end
    CGPoint c2;          // cross: the end beside the reply
    CGFloat radius;
} RXQuoteGeometry;

static BOOL RXQuoteGeometryEqual(const RXQuoteGeometry *a, const RXQuoteGeometry *b) {
    return a->valid == b->valid && a->cross == b->cross && a->radius == b->radius &&
           CGRectEqualToRect(a->art, b->art) && CGRectEqualToRect(a->hit, b->hit) &&
           CGPointEqualToPoint(a->c0, b->c0) && CGPointEqualToPoint(a->c1, b->c1) && CGPointEqualToPoint(a->c2, b->c2);
}

static BOOL RXSameString(NSString *a, NSString *b) {
    if (a == b) {
        return YES;
    }
    return a && b && [a isEqualToString:b];
}

// Centre a 1.5 pt (3 px) line on a pixel centre so both edges are crisp.
static CGFloat RXQuoteAlignLine(CGFloat v, CGFloat scale) {
    return (floorf(v * scale) + 0.5f) / scale;
}

#pragma mark - RXQuoteBalloonView

@implementation RXQuoteBalloonView {
    BOOL _hasLayout;
    CGRect _replyFrame;
    BOOL _replyOutgoing;
    BOOL _withBadge;
    CGRect _clampBounds;
    BOOL _tracking;
    BOOL _pressed;
    RXQuoteMetrics _m;
    NSString *_line1;
    NSString *_line2;
    RXQuoteGeometry _g;     // local coordinates
}

+ (CGFloat)heightForLink:(RXReplyLink *)link width:(CGFloat)width {
    NSString *line1 = nil, *line2 = nil;
    RXQuoteMetrics m = RXQuoteMetricsFor(link, nil, width, &line1, &line2);
    return RXQuoteSlotHeight(m);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = nil;
        self.clearsContextBeforeDrawing = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.clipsToBounds = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = NO;
        memset(&_m, 0, sizeof(_m));
        memset(&_g, 0, sizeof(_g));
    }
    return self;
}

#pragma mark Properties

- (void)setLink:(RXReplyLink *)link {
    _link = link;
    [self rxUpdate];
    [self setNeedsDisplay];
}

- (void)setThumbnail:(UIImage *)thumbnail {
    if (_thumbnail == thumbnail) {
        return;
    }
    _thumbnail = thumbnail;
    [self rxUpdate];
    [self setNeedsDisplay];
}

- (void)setWallpaper:(BOOL)wallpaper {
    if (_wallpaper == wallpaper) {
        return;
    }
    _wallpaper = wallpaper;
    [self setNeedsDisplay];
}

- (void)setOnTap:(void (^)(void))onTap {
    _onTap = [onTap copy];
    if (!_onTap && (_pressed || _tracking)) {
        _tracking = NO;
        _pressed = NO;
        [self setNeedsDisplay];
    }
}

#pragma mark Layout

- (void)layoutForReplyBalloonFrame:(CGRect)replyFrame replyOutgoing:(BOOL)replyOutgoing
                         withBadge:(BOOL)withBadge inBounds:(CGRect)bounds {
    _replyFrame = replyFrame;
    _replyOutgoing = replyOutgoing;
    _withBadge = withBadge;
    _clampBounds = bounds;
    _hasLayout = YES;
    if ([self rxUpdate]) {
        [self setNeedsDisplay];
    }
}

// Recomputes metrics + geometry (transcript.py draw_quote()) and frames the view. Returns YES if
// anything that is drawn changed.
- (BOOL)rxUpdate {
    NSString *line1 = nil, *line2 = nil;
    CGFloat width = _hasLayout ? _clampBounds.size.width : 0.0f;
    RXQuoteMetrics m = RXQuoteMetricsFor(_link, _thumbnail, width, &line1, &line2);
    RXQuoteGeometry g;
    memset(&g, 0, sizeof(g));
    if (_hasLayout && m.mode != RXQuoteModeNone && !CGRectIsEmpty(_replyFrame) && !CGRectIsEmpty(_clampBounds)) {
        CGFloat qw = m.size.width * RXQ_SCALE;
        CGFloat qh = m.size.height * RXQ_SCALE;
        CGFloat slotH = RXQuoteSlotHeight(m);
        BOOL parentRight = _link.parentIsMine;
        // Bottom of the quote art: 2 pt above the reply's balloon, or above the 15 pt badge band.
        CGFloat bottom = CGRectGetMinY(_replyFrame) - RX_QUOTE_GAP - (_withBadge ? RX_BADGE_ROW_EXTRA : 0.0f);
        // On the parent's side: body edge 9.5 pt from the cell edge, like stock bodies.
        CGFloat x = parentRight ? CGRectGetMaxX(_clampBounds) - RXQ_EDGE + 2.0f * RXQ_SCALE - qw
                                : CGRectGetMinX(_clampBounds) + RXQ_EDGE - 2.0f * RXQ_SCALE;
        CGRect art = CGRectMake(x, bottom - qh, qw, qh);
        CGRect slot = CGRectMake(x, bottom - slotH, qw, slotH);
        CGRect qb = CGRectMake(art.origin.x + 2.0f * RXQ_SCALE, art.origin.y + 1.5f * RXQ_SCALE,
                               qw - 4.0f * RXQ_SCALE, qh - 6.0f * RXQ_SCALE);
        CGRect rb = RXBalloonBody(_replyFrame, _replyOutgoing);
        CGRect lineBox;
        g.cross = parentRight != _replyOutgoing;
        if (g.cross) {
            // Down from the quote, a 7 pt corner, then across to 3 pt short of the reply's body; with a
            // badge on the reply the leg runs low (replyBody.maxY - 8) so it never meets the badge dots.
            CGFloat sx = parentRight ? CGRectGetMaxX(qb) - 14.0f : CGRectGetMinX(qb) + 14.0f;
            CGFloat sy = CGRectGetMaxY(qb) + 1.5f;
            CGFloat ex = _replyOutgoing ? CGRectGetMinX(rb) - 3.0f : CGRectGetMaxX(rb) + 3.0f;
            CGFloat ey = _withBadge ? CGRectGetMaxY(rb) - 8.0f : CGRectGetMidY(rb);
            if (ey < sy) {
                ey = sy;
            }
            CGFloat r = MIN(7.0f, MIN(ey - sy, fabsf(ex - sx)));
            g.c0 = CGPointMake(sx, sy);
            g.c1 = CGPointMake(sx, ey);
            g.c2 = CGPointMake(ex, ey);
            g.radius = MAX(0.0f, r);
            lineBox = CGRectMake(MIN(sx, ex) - 1.0f, sy - 1.0f, fabsf(ex - sx) + 2.0f, ey - sy + 3.0f);
        } else {
            // Same side: a short stem from the quote down into the reply's top edge.
            CGFloat sx = parentRight ? CGRectGetMaxX(qb) - 16.0f : CGRectGetMinX(qb) + 16.0f;
            CGFloat sy = CGRectGetMaxY(qb) + 1.0f;
            CGFloat ey = MAX(sy, CGRectGetMinY(rb) + 0.5f);
            g.c0 = CGPointMake(sx, sy);
            g.c1 = CGPointMake(sx, ey);
            g.c2 = g.c1;
            g.radius = 0.0f;
            lineBox = CGRectMake(sx - 1.0f, sy - 1.0f, 2.0f, ey - sy + 3.0f);
        }
        // Touch area (DESIGN 11, >= 44 pt): the quote art grown down first, to the reply's body top (never
        // over the reply bubble; a badge in the band is above us in z-order and keeps its touches), then up,
        // but not above the cell's top - UIKit never delivers a touch there. RXTranscriptExtraHeight pads
        // the row so the 44 pt fit.
        CGRect hit = art;
        if (hit.size.width < RXB_HIT) {
            hit = CGRectInset(hit, (hit.size.width - RXB_HIT) / 2.0f, 0.0f);
        }
        if (hit.size.height < RXB_HIT) {
            CGFloat need = RXB_HIT - hit.size.height;
            CGFloat below = MAX(0.0f, MIN(need, CGRectGetMinY(rb) - CGRectGetMaxY(hit)));
            hit.size.height += below;
            need -= below;
            CGFloat above = MAX(0.0f, MIN(need, CGRectGetMinY(hit) - CGRectGetMinY(_clampBounds)));
            hit.origin.y -= above;
            hit.size.height += above;
        }
        CGRect frame = CGRectIntegral(CGRectUnion(CGRectUnion(slot, art), lineBox));
        CGFloat dx = -frame.origin.x, dy = -frame.origin.y;
        CGFloat scale = RXScreenScale();
        g.art = CGRectOffset(art, dx, dy);
        g.hit = CGRectOffset(hit, dx, dy);
        g.c0 = CGPointMake(RXQuoteAlignLine(g.c0.x + dx, scale), g.c0.y + dy);
        g.c1 = CGPointMake(g.c0.x, g.cross ? RXQuoteAlignLine(g.c1.y + dy, scale) : g.c1.y + dy);
        g.c2 = g.cross ? CGPointMake(g.c2.x + dx, g.c1.y) : g.c1;
        g.valid = YES;
        if (!CGRectEqualToRect(self.frame, frame)) {
            self.frame = frame;
        }
    }
    BOOL changed = !RXQuoteGeometryEqual(&g, &_g) || m.mode != _m.mode || !CGSizeEqualToSize(m.size, _m.size) ||
                   m.textTop != _m.textTop || m.lineHeight != _m.lineHeight ||
                   !RXSameString(line1, _line1) || !RXSameString(line2, _line2);
    _g = g;
    _m = m;
    _line1 = line1;
    _line2 = line2;
    return changed;
}

#pragma mark Drawing

- (UIImage *)rxArtImageIsThumb:(BOOL *)isThumb {
    CGFloat scale = RXScreenScale();
    *isThumb = NO;
    if (_m.mode == RXQuoteModeThumb) {
        UIImage *img = RXQuoteRenderThumb(_thumbnail, _m.size, scale);
        if (img) {
            *isThumb = YES;
            return img;
        }
    }
    // The parent's material: theirs = Balloon_2 (grey), mine = Balloon_Blue (R6 §7).
    UIImage *dot = RXBalloonDotNamed(_link.parentIsMine ? @"Balloon_Blue" : @"Balloon_2");
    if (!dot) {
        dot = RXBalloonDot(_link.parentIsMine);
    }
    return RXQuoteRenderDot(dot, _m.size, scale);
}

- (void)rxDrawLinesInArtSize:(CGSize)size context:(CGContextRef)ctx {
    if (!_line1.length) {
        return;
    }
    UIFont *font = nil;
    CGFloat L = 20.0f;
    RXQuoteTextStyle(&font, &L);
    // Baseline = line top + half-leading + ascent (R6 §11.6), black with the balloon's white shadow at (0,+1).
    CGFloat lineBox = font.ascender - font.descender;
    CGFloat lead = (L - lineBox) / 2.0f;
    CGFloat shadowAlpha = _link.parentIsMine ? 0.5f : 0.8f;
    static const CGFloat black[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    CGFloat white[4] = {1.0f, 1.0f, 1.0f, shadowAlpha};
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(2.0f, 0.0f, size.width - 4.0f, size.height));
    RXDrawEngravedText(_line1, CGPointMake(RXQ_INSET_X, _m.textTop + lead), font, black, white, 1.0f);
    if (_line2.length) {
        RXDrawEngravedText(_line2, CGPointMake(RXQ_INSET_X, _m.textTop + L + lead), font, black, white, 1.0f);
    }
    CGContextRestoreGState(ctx);
}

- (void)rxDrawConnector:(CGContextRef)ctx {
    // Engraved like the timestamps: stock #A9B2C1 + white a0.78 copy 1 pt below; wallpaper white a0.75 +
    // black a0.27 copy (R6 §7).
    static const CGFloat stockLine[4] = {0.663f, 0.698f, 0.757f, 1.0f};
    static const CGFloat stockShade[4] = {1.0f, 1.0f, 1.0f, 0.78f};
    static const CGFloat wallLine[4] = {1.0f, 1.0f, 1.0f, 0.75f};
    static const CGFloat wallShade[4] = {0.0f, 0.0f, 0.0f, 0.27f};
    const CGFloat *lineRGBA = _wallpaper ? wallLine : stockLine;
    const CGFloat *shadeRGBA = _wallpaper ? wallShade : stockShade;
    for (int pass = 0; pass < 2; pass++) {
        const CGFloat *c = pass == 0 ? shadeRGBA : lineRGBA;
        CGContextSaveGState(ctx);
        if (pass == 0) {
            CGContextTranslateCTM(ctx, 0.0f, 1.0f);     // engraved copy 1 pt below
        }
        CGContextSetLineWidth(ctx, 1.5f);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextSetLineCap(ctx, kCGLineCapButt);
        CGContextSetRGBStrokeColor(ctx, c[0], c[1], c[2], c[3]);
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, _g.c0.x, _g.c0.y);
        if (_g.cross) {
            if (_g.radius > 0.5f) {
                CGContextAddArcToPoint(ctx, _g.c1.x, _g.c1.y, _g.c2.x, _g.c2.y, _g.radius);
            } else {
                CGContextAddLineToPoint(ctx, _g.c1.x, _g.c1.y);
            }
            CGContextAddLineToPoint(ctx, _g.c2.x, _g.c2.y);
        } else {
            CGContextAddLineToPoint(ctx, _g.c1.x, _g.c1.y);
        }
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }
}

- (void)drawRect:(CGRect)rect {
    if (!_g.valid || !_link) {
        return;
    }
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }
    CGFloat alpha = (_wallpaper ? 0.80f : 0.55f) + (_pressed ? 0.20f : 0.0f);
    if (alpha > 1.0f) {
        alpha = 1.0f;
    }
    CGSize size = _m.size;
    BOOL isThumb = NO;
    UIImage *art = [self rxArtImageIsThumb:&isThumb];
    // The quote (art + text) fades as one group; the connector keeps its own colours.
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, alpha);
    CGContextBeginTransparencyLayer(ctx, NULL);
    CGContextTranslateCTM(ctx, _g.art.origin.x, _g.art.origin.y);
    CGContextScaleCTM(ctx, RXQ_SCALE, RXQ_SCALE);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGRect artRect = CGRectMake(0.0f, 0.0f, size.width, size.height);
    if (art) {
        [art drawInRect:artRect];
    } else {
        RXLogOnce(@"quote.art", @"quote: balloon art missing, drawing the vector fallback");
        RXDrawFallbackDot(CGRectMake(2.0f, 1.5f, size.width - 4.0f, size.height - 6.0f), _link.parentIsMine);
    }
    if (!isThumb) {
        [self rxDrawLinesInArtSize:size context:ctx];
    }
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    [self rxDrawConnector:ctx];
}

#pragma mark Touches (only with onTap; pressed = opacity + 0.2)

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_g.valid || !_link || !self.onTap || self.hidden) {
        return NO;
    }
    return CGRectContainsPoint(_g.hit, point);
}

- (void)rxSetPressed:(BOOL)pressed {
    if (_pressed == pressed) {
        return;
    }
    _pressed = pressed;
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!self.onTap) {
        return;
    }
    _tracking = YES;
    [self rxSetPressed:YES];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    if (!_tracking || !touch) {
        return;
    }
    // UIButton-style slop: stays pressed while the finger is near the quote.
    [self rxSetPressed:CGRectContainsPoint(CGRectInset(_g.hit, -20.0f, -20.0f), [touch locationInView:self])];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    BOOL fire = _tracking && _pressed;
    _tracking = NO;
    [self rxSetPressed:NO];
    void (^tap)(void) = self.onTap;
    if (fire && tap) {
        tap();
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    _tracking = NO;
    [self rxSetPressed:NO];
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement {
    return _link != nil && _g.valid && !self.hidden;
}

- (NSString *)accessibilityLabel {
    if (!_link) {
        return nil;
    }
    NSString *what = RXQuoteIsText(_link) ? RXQuoteClean(_link.snippet) : RXQuoteNoun(_link.kind);
    if (!what.length) {
        what = @"\u2026";
    }
    NSString *name = _link.parentName;
    if (name.length) {
        return [NSString stringWithFormat:@"Reply to %@: %@", name, what];
    }
    return [NSString stringWithFormat:@"Reply: %@", what];
}

- (UIAccessibilityTraits)accessibilityTraits {
    return self.onTap ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
}

@end
