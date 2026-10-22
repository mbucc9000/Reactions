// Reactions 2.0 - RXCore.m
//
// Owns these sections of RXShared.h: "Helpers & safety" (log, selector/ivar safety, controller lookup,
// chat keys, truncation, first names), prefs, artwork (kit/ChatKit images, balloon dot), the tint
// pipeline, glyphs, the reply arrow, the haptic tick and the MessageWallpapers detection helpers.
//
// Threading: main thread only, except RXLog / RXLogOnce / RXGUIDTail (any thread; the log file and the
// once-set are behind a mutex) and RXTick (called on main, plays on its own serial queue).
//
// DESIGN.md section 2 rules kept here: colours are raw CGFloat components (never UIColor getters),
// translucent fills use CGContextFillRect (never UIRectFill), monochrome glyphs are vector paths or
// Helvetica text (no heart characters anywhere), private classes only via NSClassFromString, and the
// log never contains message text, names or numbers.

#import "RXShared.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <notify.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define RX_LOG_CAP_BYTES        (256 * 1024)
#define RX_VIBRATE_SOUND_ID     0x00000FFFu     // kSystemSoundID_Vibrate (AudioToolbox is not linked)
#define RX_MISS_TABLE_MAX       64
#define RX_HEX(v)               ((CGFloat)(v) / 255.0f)

#pragma mark - Small shared statics

static CGFloat RXScreenScale(void) {
    static CGFloat scale;
    if (scale <= 0.0f) {
        scale = [[UIScreen mainScreen] scale];
        if (scale <= 0.0f) {
            scale = 1.0f;
        }
    }
    return scale;
}

// Rounds a length UP to whole screen pixels (so image contexts get exact pixel sizes).
static CGFloat RXCeilPx(CGFloat v) {
    double s = (double)RXScreenScale();
    return (CGFloat)(ceil((double)v * s - 0.01) / s);
}

// Snaps a user-space point to the nearest device pixel of the given context (crisp 1:1 image blits,
// also correct under a scaled or flipped CTM).
static CGPoint RXSnap(CGContextRef ctx, CGPoint p) {
    if (!ctx) {
        return p;
    }
    CGPoint d = CGContextConvertPointToDeviceSpace(ctx, p);
    d.x = (CGFloat)round((double)d.x);
    d.y = (CGFloat)round((double)d.y);
    return CGContextConvertPointToUserSpace(ctx, d);
}

static CGColorSpaceRef RXRGBSpace(void) {
    static CGColorSpaceRef space;
    if (!space) {
        space = CGColorSpaceCreateDeviceRGB();   // kept for the life of the process
    }
    return space;
}

static Class RXTranscriptClass(void) {
    static Class cls;
    if (!cls) {
        cls = NSClassFromString(@"CKTranscriptController");
    }
    return cls;
}

#pragma mark - Log

static pthread_mutex_t gRXLogLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gRXOnceLock = PTHREAD_MUTEX_INITIALIZER;

static void RXWriteLogLine(NSString *msg) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t secs = (time_t)tv.tv_sec;
    struct tm local;
    localtime_r(&secs, &local);
    char stamp[32];
    if (strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local) == 0) {
        stamp[0] = '\0';
    }
    NSString *line __attribute__((objc_precise_lifetime)) =
        [NSString stringWithFormat:@"%s.%03d [%d] %@\n", stamp, (int)(tv.tv_usec / 1000), (int)getpid(), msg ?: @""];
    const char *bytes = [line UTF8String];
    if (!bytes) {
        return;
    }
    size_t len = strlen(bytes);
    pthread_mutex_lock(&gRXLogLock);
    int fd = open(RX_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size + (off_t)len > (off_t)RX_LOG_CAP_BYTES) {
            if (ftruncate(fd, 0) == 0) {
                const char *note = "--- Reactions.log reset (256 KB cap) ---\n";
                ssize_t wrote = write(fd, note, strlen(note));
                (void)wrote;
            }
        }
        ssize_t written = write(fd, bytes, len);
        (void)written;
        close(fd);
    }
    pthread_mutex_unlock(&gRXLogLock);
}

void RXLog(NSString *format, ...) {
    if (![format isKindOfClass:[NSString class]]) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RXWriteLogLine(msg);
}

static NSMutableSet *gRXOnceKeys;

void RXLogOnce(NSString *key, NSString *message) {
    if (![key isKindOfClass:[NSString class]]) {
        return;
    }
    BOOL first = NO;
    pthread_mutex_lock(&gRXOnceLock);
    if (!gRXOnceKeys) {
        gRXOnceKeys = [[NSMutableSet alloc] init];
    }
    if (![gRXOnceKeys containsObject:key]) {
        NSString *stored = [key copy];
        if (stored) {
            [gRXOnceKeys addObject:stored];
        }
        first = YES;
    }
    pthread_mutex_unlock(&gRXOnceLock);
    if (first) {
        RXWriteLogLine([message isKindOfClass:[NSString class]] ? message : key);
    }
}

NSString *RXGUIDTail(NSString *guid) {
    if (![guid isKindOfClass:[NSString class]] || [guid length] == 0) {
        return @"-";
    }
    NSUInteger len = [guid length];
    if (len <= 6) {
        return guid;
    }
    return [guid substringFromIndex:len - 6];
}

#pragma mark - Selector / ivar safety

typedef struct {
    uintptr_t cls;
    SEL sel;
} RXMissEntry;

static RXMissEntry gRXMisses[RX_MISS_TABLE_MAX];
static int gRXMissCount;

BOOL RXResponds(id obj, SEL sel) {
    if (!obj || !sel) {
        return NO;
    }
    if ([obj respondsToSelector:sel]) {
        return YES;
    }
    // Missing selector: log once per (class, selector) without allocating on the repeat path.
    Class cls = object_getClass(obj);
    uintptr_t clsKey = (uintptr_t)(__bridge void *)cls;
    BOOL seen = NO;
    pthread_mutex_lock(&gRXOnceLock);
    for (int i = 0; i < gRXMissCount; i++) {
        if (gRXMisses[i].cls == clsKey && gRXMisses[i].sel == sel) {
            seen = YES;
            break;
        }
    }
    if (!seen) {
        if (gRXMissCount < RX_MISS_TABLE_MAX) {
            gRXMisses[gRXMissCount].cls = clsKey;
            gRXMisses[gRXMissCount].sel = sel;
            gRXMissCount++;
        } else {
            seen = YES;   // table full: stay quiet rather than spam
        }
    }
    pthread_mutex_unlock(&gRXOnceLock);
    if (!seen) {
        BOOL meta = class_isMetaClass(cls) ? YES : NO;
        NSString *name = NSStringFromClass(meta ? (Class)obj : cls);
        RXLog(@"missing selector %c[%@ %@]", meta ? '+' : '-', name ?: @"?", NSStringFromSelector(sel));
    }
    return NO;
}

id RXIvar(id obj, const char *name) {
    if (!obj || !name || !name[0]) {
        return nil;
    }
    Class cls = object_getClass(obj);
    Ivar iv = class_getInstanceVariable(cls, name);
    if (!iv) {
        NSString *clsName = NSStringFromClass(cls) ?: @"?";
        RXLogOnce([NSString stringWithFormat:@"ivar|%@|%s", clsName, name],
                  [NSString stringWithFormat:@"missing ivar %@.%s", clsName, name]);
        return nil;
    }
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') {
        NSString *clsName = NSStringFromClass(cls) ?: @"?";
        RXLogOnce([NSString stringWithFormat:@"ivartype|%@|%s", clsName, name],
                  [NSString stringWithFormat:@"ivar %@.%s is not an object", clsName, name]);
        return nil;
    }
    return object_getIvar(obj, iv);
}

#pragma mark - Controllers

UIViewController *RXControllerForView(UIView *view) {
    Class tcClass = RXTranscriptClass();
    if (!view || !tcClass) {
        return nil;
    }
    int hops = 0;
    for (UIResponder *r = view; r && hops < 64; r = [r nextResponder], hops++) {
        if ([r isKindOfClass:tcClass]) {
            return (UIViewController *)r;
        }
    }
    return nil;
}

BOOL RXIsTranscriptController(id obj) {
    Class tcClass = RXTranscriptClass();
    if (!obj || !tcClass) {
        return NO;
    }
    return [obj isKindOfClass:tcClass] ? YES : NO;
}

#pragma mark - Chat keys, strings, names

NSString *RXChatKeyForConversation(CKConversation *conv) {
    if (!conv || !RXResponds(conv, @selector(chat))) {
        return nil;
    }
    IMChat *chat = [conv chat];
    if (!chat || !RXResponds(chat, @selector(chatIdentifier))) {
        return nil;
    }
    id key = [chat chatIdentifier];
    if (![key isKindOfClass:[NSString class]] || [(NSString *)key length] == 0) {
        return nil;
    }
    return [(NSString *)key copy];
}

NSString *RXChatKeyForMessage(id ckMessage) {
    if (!ckMessage || !RXResponds(ckMessage, @selector(conversation))) {
        return nil;
    }
    CKConversation *conv = [(CKIMMessage *)ckMessage conversation];
    return RXChatKeyForConversation(conv);
}

NSString *RXSafeTruncate(NSString *s, NSUInteger maxUnits) {
    if (![s isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSUInteger len = [s length];
    if (len <= maxUnits) {
        return s;
    }
    if (maxUnits == 0) {
        return @"";
    }
    // The sequence containing index maxUnits starts at or before it; cutting there never splits a
    // surrogate pair or a combining sequence, and the result is never longer than maxUnits.
    NSRange seq = [s rangeOfComposedCharacterSequenceAtIndex:maxUnits];
    NSUInteger cut = seq.location;
    if (cut > maxUnits) {
        cut = maxUnits;
    }
    return [s substringToIndex:cut];
}

static NSString *RXNonEmptyTrimmed(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *t = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t length] ? t : nil;
}

NSString *RXFirstNameForEntity(CKEntity *entity) {
    if (!entity) {
        return @"";
    }
    NSString *name = nil;
    if (RXResponds(entity, @selector(defaultIMHandle))) {
        IMHandle *handle = [entity defaultIMHandle];
        if (handle && RXResponds(handle, @selector(firstName))) {
            name = RXNonEmptyTrimmed([handle firstName]);
        }
    }
    if (!name && RXResponds(entity, @selector(name))) {
        name = RXNonEmptyTrimmed([entity name]);
    }
    return name ?: @"";
}

#pragma mark - Prefs

// Keys: the RX_PREF_* names from RXShared.h (what the Settings pane plist writes) come first; the
// lowerCamel / TitleCase forms of the Settings labels are accepted as aliases.
static RXPrefs gRXPrefs;
static BOOL gRXPrefsLoaded;
static void (^gRXPrefsOnChange)(void);

static BOOL RXPrefBool(NSDictionary *d, NSArray *keys, BOOL fallback) {
    if (!d) {
        return fallback;
    }
    for (NSString *key in keys) {
        id v = [d objectForKey:key];
        if ([v isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)v boolValue] ? YES : NO;
        }
        if ([v isKindOfClass:[NSString class]]) {
            return [(NSString *)v boolValue] ? YES : NO;
        }
    }
    return fallback;
}

static RXPrefs RXReadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RX_PREFS_PATH];
    if (![d isKindOfClass:[NSDictionary class]]) {
        d = nil;
    }
    RXPrefs p;
    p.enabled = RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_ENABLED, @"Enabled", nil], YES);
    p.badges = RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_BADGES, @"showReactions", @"ShowReactions", nil], YES);
    // React & Reply is off by default. It gates both sending features, so every existing picker/swipe
    // check (RXOn(...picker) / RXOn(...swipe)) sees NO while it is off, whatever their own switches say.
    p.sending = RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_SENDING, @"reactAndReply", @"ReactAndReply", nil], NO);
    p.picker = (p.sending && RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_PICKER, @"doubleTapToReact", @"DoubleTapToReact", nil], YES)) ? YES : NO;
    p.swipe = (p.sending && RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_SWIPE, @"swipeToReply", @"SwipeToReply", nil], YES)) ? YES : NO;
    p.quotes = RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_QUOTES, @"replyQuotes", @"ReplyQuotes", nil], YES);
    p.haptic = RXPrefBool(d, [NSArray arrayWithObjects:RX_PREF_HAPTIC, @"Haptic", nil], YES);
    return p;
}

static BOOL RXPrefsEqual(RXPrefs a, RXPrefs b) {
    return (a.enabled == b.enabled && a.badges == b.badges && a.sending == b.sending && a.picker == b.picker &&
            a.swipe == b.swipe && a.quotes == b.quotes && a.haptic == b.haptic) ? YES : NO;
}

static void RXLogPrefs(NSString *why, RXPrefs p) {
    RXLog(@"prefs %@: enabled=%d badges=%d sending=%d picker=%d swipe=%d quotes=%d haptic=%d", why,
          (int)p.enabled, (int)p.badges, (int)p.sending, (int)p.picker, (int)p.swipe, (int)p.quotes, (int)p.haptic);
}

RXPrefs RXGetPrefs(void) {
    if (!gRXPrefsLoaded) {
        gRXPrefs = RXReadPrefs();
        gRXPrefsLoaded = YES;
        RXLogPrefs(@"loaded", gRXPrefs);
    }
    return gRXPrefs;
}

BOOL RXOn(BOOL feature) {
    RXPrefs p = RXGetPrefs();
    return (p.enabled && feature) ? YES : NO;
}

// Main queue. Settings writes the plist before posting; if the file still reads the same, look once
// more 0.5 s later in case the write landed after the notification.
static void RXPrefsNotified(BOOL isRetry) {
    RXPrefs fresh = RXReadPrefs();
    if (gRXPrefsLoaded && RXPrefsEqual(fresh, gRXPrefs)) {
        if (!isRetry) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RXPrefsNotified(YES);
            });
        }
        return;
    }
    gRXPrefs = fresh;
    gRXPrefsLoaded = YES;
    RXLogPrefs(@"changed", fresh);
    void (^callback)(void) = gRXPrefsOnChange;
    if (callback) {
        callback();
    }
}

void RXPrefsStart(void (^onChange)(void)) {
    static BOOL started;
    if (onChange) {
        gRXPrefsOnChange = [onChange copy];
    }
    if (started) {
        return;
    }
    started = YES;
    (void)RXGetPrefs();
    int token = 0;
    uint32_t status = notify_register_dispatch(RX_PREFS_NOTIFY, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        RXPrefsNotified(NO);
    });
    if (status != NOTIFY_STATUS_OK) {
        RXLog(@"prefs: notify_register_dispatch failed (%u)", (unsigned)status);
    }
}

#pragma mark - Artwork

static UIImage *RXCachedArt(NSMutableDictionary *cache, NSString *name, BOOL kit) {
    id hit = [cache objectForKey:name];
    if (hit) {
        return [hit isKindOfClass:[UIImage class]] ? (UIImage *)hit : nil;
    }
    UIImage *img = nil;
    if (kit) {
        if (RXResponds([UIImage class], @selector(kitImageNamed:))) {
            img = [UIImage kitImageNamed:name];
        }
    } else {
        if (RXResponds([UIImage class], @selector(ckImageNamed:))) {
            img = [UIImage ckImageNamed:name];
        }
    }
    if (![img isKindOfClass:[UIImage class]] || img.size.width <= 0.0f || img.size.height <= 0.0f) {
        img = nil;
        RXLogOnce([NSString stringWithFormat:@"art|%d|%@", (int)kit, name],
                  [NSString stringWithFormat:@"art missing: %@ %@", kit ? @"kit" : @"ck", name]);
    }
    [cache setObject:(img ?: (id)[NSNull null]) forKey:name];
    return img;
}

UIImage *RXKitImage(NSString *exactName) {
    static NSMutableDictionary *cache;
    if (![exactName isKindOfClass:[NSString class]] || [exactName length] == 0) {
        return nil;
    }
    if (!cache) {
        cache = [[NSMutableDictionary alloc] init];
    }
    return RXCachedArt(cache, exactName, YES);
}

UIImage *RXCKImage(NSString *name) {
    static NSMutableDictionary *cache;
    if (![name isKindOfClass:[NSString class]] || [name length] == 0) {
        return nil;
    }
    if (!cache) {
        cache = [[NSMutableDictionary alloc] init];
    }
    return RXCachedArt(cache, name, NO);
}

// R6 section 2.2 / 10: the left 15 pt of the 43x32 pt balloon art (the side without the tail) plus its
// mirror -> 30x32 pt, body 26x26 at (2, 1.5); resizable with caps {14, 14.5, 17, 14.5}, leaving a 1 pt
// centre column (the mirror seam) and a 1 pt row at the gloss break, so the same image makes pills.
UIImage *RXBalloonDotNamed(NSString *ckArtName) {
    static NSMutableDictionary *cache;
    if (![ckArtName isKindOfClass:[NSString class]] || [ckArtName length] == 0) {
        return nil;
    }
    if (!cache) {
        cache = [[NSMutableDictionary alloc] init];
    }
    id hit = [cache objectForKey:ckArtName];
    if (hit) {
        return [hit isKindOfClass:[UIImage class]] ? (UIImage *)hit : nil;
    }
    UIImage *dot = nil;
    UIImage *src = RXCKImage(ckArtName);
    if (src && src.size.width >= 15.0f && src.size.height >= 32.0f) {
        CGSize size = CGSizeMake(30.0f, src.size.height);
        CGFloat scale = src.scale > 0.0f ? src.scale : RXScreenScale();
        UIGraphicsBeginImageContextWithOptions(size, NO, scale);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx) {
            for (int side = 0; side < 2; side++) {
                CGContextSaveGState(ctx);
                if (side) {
                    CGContextTranslateCTM(ctx, 30.0f, 0.0f);
                    CGContextScaleCTM(ctx, -1.0f, 1.0f);
                }
                CGContextClipToRect(ctx, CGRectMake(0.0f, 0.0f, 15.0f, size.height));
                [src drawAtPoint:CGPointZero];
                CGContextRestoreGState(ctx);
            }
            UIImage *flat = UIGraphicsGetImageFromCurrentImageContext();
            dot = [flat resizableImageWithCapInsets:UIEdgeInsetsMake(14.0f, 14.5f, 17.0f, 14.5f)
                                       resizingMode:UIImageResizingModeStretch];
        }
        UIGraphicsEndImageContext();
    } else if (src) {
        RXLogOnce([@"dotsize|" stringByAppendingString:ckArtName],
                  [NSString stringWithFormat:@"art %@ has unexpected size %.1fx%.1f", ckArtName,
                   (double)src.size.width, (double)src.size.height]);
    }
    [cache setObject:(dot ?: (id)[NSNull null]) forKey:ckArtName];
    return dot;
}

UIImage *RXBalloonDot(BOOL mine) {
    return RXBalloonDotNamed(mine ? @"select-text-bubble" : @"Balloon_2");
}

// The dot's 26 pt body is scaled with the CTM (f = height / 26) so the resizable image is never drawn
// smaller than its caps; a body narrower than tall is drawn as a circle centred on the rect.
void RXDrawBalloonDot(UIImage *dot, CGRect body, CGFloat alpha) {
    if (!dot || body.size.width <= 0.0f || body.size.height <= 0.0f || alpha <= 0.0f) {
        return;
    }
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }
    CGFloat f = body.size.height / 26.0f;
    CGFloat artW = body.size.width / f + 4.0f;
    if (artW < 30.0f) {
        artW = 30.0f;
    }
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, CGRectGetMidX(body) - (artW / 2.0f) * f, body.origin.y - 1.5f * f);
    CGContextScaleCTM(ctx, f, f);
    [dot drawInRect:CGRectMake(0.0f, 0.0f, artW, 32.0f) blendMode:kCGBlendModeNormal alpha:(alpha > 1.0f ? 1.0f : alpha)];
    CGContextRestoreGState(ctx);
}

#pragma mark - Tint pipeline

RXGradient RXGrad(CGFloat r1, CGFloat g1, CGFloat b1, CGFloat a1, CGFloat r2, CGFloat g2, CGFloat b2, CGFloat a2) {
    RXGradient g;
    g.c[0] = r1;
    g.c[1] = g1;
    g.c[2] = b1;
    g.c[3] = a1;
    g.c[4] = r2;
    g.c[5] = g2;
    g.c[6] = b2;
    g.c[7] = a2;
    return g;
}

RXGradient RXSolid(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return RXGrad(r, g, b, a, r, g, b, a);
}

static BOOL RXGradIsSolid(RXGradient g) {
    for (int i = 0; i < 4; i++) {
        if (g.c[i] != g.c[i + 4]) {
            return NO;
        }
    }
    return YES;
}

// Top colour at r.minY, bottom at r.maxY (UIKit coordinates). Respects the context's blend mode.
void RXFillGradient(CGContextRef ctx, CGRect r, RXGradient g) {
    if (!ctx || CGRectIsEmpty(r)) {
        return;
    }
    CGContextSaveGState(ctx);
    if (RXGradIsSolid(g)) {
        CGContextSetRGBFillColor(ctx, g.c[0], g.c[1], g.c[2], g.c[3]);
        CGContextFillRect(ctx, r);
    } else {
        CGFloat locations[2] = { 0.0f, 1.0f };
        CGGradientRef grad = CGGradientCreateWithColorComponents(RXRGBSpace(), g.c, locations, 2);
        if (grad) {
            CGContextClipToRect(ctx, r);
            CGContextDrawLinearGradient(ctx, grad,
                                        CGPointMake(r.origin.x, CGRectGetMinY(r)),
                                        CGPointMake(r.origin.x, CGRectGetMaxY(r)),
                                        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
            CGGradientRelease(grad);
        }
    }
    CGContextRestoreGState(ctx);
}

static char kRXTintCacheKey;

// Coverage alpha x gradient, off-screen with kCGBlendModeSourceIn. The result is cached on the coverage
// image itself (associated dictionary keyed by the raw components), so it lives exactly as long as the
// coverage image does.
UIImage *RXTint(UIImage *coverage, RXGradient g) {
    if (!coverage) {
        return nil;
    }
    CGSize s = coverage.size;
    if (s.width <= 0.0f || s.height <= 0.0f) {
        return nil;
    }
    NSData *key = [NSData dataWithBytes:g.c length:sizeof(g.c)];
    NSMutableDictionary *cache = objc_getAssociatedObject(coverage, &kRXTintCacheKey);
    UIImage *hit = key ? [cache objectForKey:key] : nil;
    if (hit) {
        return hit;
    }
    CGFloat scale = coverage.scale > 0.0f ? coverage.scale : RXScreenScale();
    UIImage *out = nil;
    UIGraphicsBeginImageContextWithOptions(s, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        [coverage drawAtPoint:CGPointZero];
        CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
        RXFillGradient(ctx, CGRectMake(0.0f, 0.0f, s.width, s.height), g);
        out = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();
    if (out && key) {
        if (!cache) {
            cache = [[NSMutableDictionary alloc] init];
            objc_setAssociatedObject(coverage, &kRXTintCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if ([cache count] >= 24) {
            [cache removeAllObjects];
        }
        [cache setObject:out forKey:key];
    }
    return out;
}

#pragma mark - Glyph shapes (R6 section 4.2; 100 x 100 design box)

static UIBezierPath *RXHeartPath(CGRect r) {
    CGFloat sx = r.size.width / 100.0f, sy = r.size.height / 100.0f;
#define PT(px, py) CGPointMake(r.origin.x + (px) * sx, r.origin.y + (py) * sy)
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:PT(50, 90)];
    [p addCurveToPoint:PT(6, 33) controlPoint1:PT(50, 90) controlPoint2:PT(6, 64)];
    [p addCurveToPoint:PT(31, 7) controlPoint1:PT(6, 17) controlPoint2:PT(18, 7)];
    [p addCurveToPoint:PT(50, 20) controlPoint1:PT(41, 7) controlPoint2:PT(47, 13)];
    [p addCurveToPoint:PT(69, 7) controlPoint1:PT(53, 13) controlPoint2:PT(59, 7)];
    [p addCurveToPoint:PT(94, 33) controlPoint1:PT(82, 7) controlPoint2:PT(94, 17)];
    [p addCurveToPoint:PT(50, 90) controlPoint1:PT(94, 64) controlPoint2:PT(50, 90)];
    [p closePath];
#undef PT
    return p;
}

static UIBezierPath *RXThumbPath(CGRect r) {
    CGFloat sx = r.size.width / 100.0f, sy = r.size.height / 100.0f;
#define PT(px, py) CGPointMake(r.origin.x + (px) * sx, r.origin.y + (py) * sy)
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:PT(16, 50)];
    [p addLineToPoint:PT(34, 40)];
    [p addCurveToPoint:PT(45, 10) controlPoint1:PT(38, 33) controlPoint2:PT(42, 20)];
    [p addCurveToPoint:PT(59, 10) controlPoint1:PT(47, 3) controlPoint2:PT(57, 3)];
    [p addCurveToPoint:PT(56, 37) controlPoint1:PT(61, 18) controlPoint2:PT(58, 28)];
    [p addLineToPoint:PT(80, 37)];
    [p addCurveToPoint:PT(80, 51) controlPoint1:PT(89, 37) controlPoint2:PT(89, 51)];
    [p addLineToPoint:PT(81, 51)];
    [p addCurveToPoint:PT(81, 64) controlPoint1:PT(89, 51) controlPoint2:PT(89, 64)];
    [p addLineToPoint:PT(79, 64)];
    [p addCurveToPoint:PT(79, 77) controlPoint1:PT(87, 64) controlPoint2:PT(87, 77)];
    [p addLineToPoint:PT(76, 77)];
    [p addCurveToPoint:PT(76, 90) controlPoint1:PT(83, 77) controlPoint2:PT(83, 90)];
    [p addLineToPoint:PT(33, 92)];
    [p addCurveToPoint:PT(16, 78) controlPoint1:PT(22, 92) controlPoint2:PT(16, 86)];
    [p addLineToPoint:PT(16, 50)];
    [p closePath];
#undef PT
    return p;
}

// love: heart in a 0.80 g square, centred, 0.5 pt down.
static void RXDrawHeartCoverage(CGFloat side, CGFloat g) {
    CGFloat t = g * 0.80f;
    CGRect r = CGRectMake((side - t) / 2.0f, (side - t) / 2.0f + 0.5f, t, t);
    [RXHeartPath(r) fill];
}

// like / dislike: thumb in a 0.86 g square, centred; three finger gaps cleared; dislike = vertical flip.
static void RXDrawThumbCoverage(CGContextRef ctx, CGFloat side, CGFloat g, BOOL flip) {
    static const CGFloat gaps[3][4] = {
        { 58.0f, 50.2f, 86.0f, 51.8f },
        { 58.0f, 63.2f, 85.0f, 64.8f },
        { 58.0f, 76.2f, 82.0f, 77.8f },
    };
    CGFloat t = g * 0.86f;
    CGFloat u = t / 100.0f;
    CGRect r = CGRectMake((side - t) / 2.0f, (side - t) / 2.0f, t, t);
    CGContextSaveGState(ctx);
    if (flip) {
        CGContextTranslateCTM(ctx, 0.0f, side);
        CGContextScaleCTM(ctx, 1.0f, -1.0f);
    }
    [RXThumbPath(r) fill];
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    for (int i = 0; i < 3; i++) {
        CGRect gap = CGRectMake(r.origin.x + gaps[i][0] * u, r.origin.y + gaps[i][1] * u,
                                (gaps[i][2] - gaps[i][0]) * u, (gaps[i][3] - gaps[i][1]) * u);
        CGContextFillRect(ctx, gap);
    }
    CGContextRestoreGState(ctx);
}

// Draws one line of text whose ascender/descender middle sits on `centre` (the anchor the mockups use).
static void RXDrawTextCentred(NSString *text, UIFont *font, CGPoint centre) {
    if (!text || !font) {
        return;
    }
    CGSize size = [text sizeWithFont:font];
    CGFloat lineBox = font.ascender - font.descender;   // descender is negative
    [text drawAtPoint:CGPointMake(centre.x - size.width / 2.0f, centre.y - lineBox / 2.0f) withFont:font];
}

// laugh: "HA" over "HA", bold 0.58 g, line step 0.80 x font size, rotated -12 degrees (up to the right)
// about the centre of a 1.34 g image so the corners never clip.
static void RXDrawLaughCoverage(CGContextRef ctx, CGFloat side, CGFloat g) {
    UIFont *font = [UIFont boldSystemFontOfSize:g * 0.58f];
    CGFloat step = font.pointSize * 0.80f;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, side / 2.0f, side / 2.0f);
    CGContextRotateCTM(ctx, (CGFloat)(-12.0 * M_PI / 180.0));
    RXDrawTextCentred(@"HA", font, CGPointMake(0.0f, -step / 2.0f));
    RXDrawTextCentred(@"HA", font, CGPointMake(0.0f, step / 2.0f));
    CGContextRestoreGState(ctx);
}

// sticker: a rounded square (0.80 g design box, square 10..90, radius 18) whose bottom-right corner is
// cut along x + y = 150 and folded back over the face as a flap (the cut corner reflected over the fold
// line), separated from the face by a 5-unit L-shaped gap cleared with kCGBlendModeClear.
static void RXDrawStickerCoverage(CGContextRef ctx, CGFloat side, CGFloat g) {
    CGFloat t = g * 0.80f;
    CGFloat ox = (side - t) / 2.0f, oy = (side - t) / 2.0f;
    CGFloat u = t / 100.0f;
#define SP(x, y) CGPointMake(ox + (x) * u, oy + (y) * u)
    UIBezierPath *face = [UIBezierPath bezierPath];
    [face moveToPoint:SP(28, 10)];
    [face addLineToPoint:SP(72, 10)];
    [face addArcWithCenter:SP(72, 28) radius:18.0f * u startAngle:(CGFloat)(-M_PI_2) endAngle:0.0f clockwise:YES];
    [face addLineToPoint:SP(90, 60)];
    [face addLineToPoint:SP(60, 90)];
    [face addLineToPoint:SP(28, 90)];
    [face addArcWithCenter:SP(28, 72) radius:18.0f * u startAngle:(CGFloat)M_PI_2 endAngle:(CGFloat)M_PI clockwise:YES];
    [face addLineToPoint:SP(10, 28)];
    [face addArcWithCenter:SP(28, 28) radius:18.0f * u startAngle:(CGFloat)M_PI endAngle:(CGFloat)(1.5 * M_PI) clockwise:YES];
    [face closePath];
    [face fill];

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    CGContextFillRect(ctx, CGRectMake(ox + 55.0f * u, oy + 55.0f * u, 45.0f * u, 45.0f * u));
    CGContextRestoreGState(ctx);

    UIBezierPath *flap = [UIBezierPath bezierPath];
    [flap moveToPoint:SP(90, 60)];
    [flap addLineToPoint:SP(66, 60)];
    [flap addQuadCurveToPoint:SP(60, 66) controlPoint:SP(60, 60)];
    [flap addLineToPoint:SP(60, 90)];
    [flap closePath];
    [flap fill];
#undef SP
}

static BOOL RXIsGlyphKey(NSString *key) {
    static NSSet *keys;
    if (!keys) {
        keys = [NSSet setWithObjects:@"love", @"like", @"dislike", @"laugh", @"emph", @"question", @"sticker", nil];
    }
    return [keys containsObject:key] ? YES : NO;
}

static UIImage *RXRenderCoverage(NSString *key, CGFloat g) {
    BOOL laugh = [key isEqualToString:@"laugh"];
    CGFloat side = RXCeilPx(laugh ? g * 1.34f : g);
    if (side <= 0.0f) {
        return nil;
    }
    UIImage *img = nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, RXScreenScale());
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextSetRGBFillColor(ctx, 0.0f, 0.0f, 0.0f, 1.0f);   // any opaque colour: alpha = coverage
        if ([key isEqualToString:@"love"]) {
            RXDrawHeartCoverage(side, g);
        } else if ([key isEqualToString:@"like"]) {
            RXDrawThumbCoverage(ctx, side, g, NO);
        } else if ([key isEqualToString:@"dislike"]) {
            RXDrawThumbCoverage(ctx, side, g, YES);
        } else if (laugh) {
            RXDrawLaughCoverage(ctx, side, g);
        } else if ([key isEqualToString:@"emph"]) {
            RXDrawTextCentred(@"!!", [UIFont boldSystemFontOfSize:g * 0.92f], CGPointMake(side / 2.0f, side / 2.0f));
        } else if ([key isEqualToString:@"question"]) {
            RXDrawTextCentred(@"?", [UIFont boldSystemFontOfSize:g * 0.92f], CGPointMake(side / 2.0f, side / 2.0f));
        } else if ([key isEqualToString:@"sticker"]) {
            RXDrawStickerCoverage(ctx, side, g);
        }
        img = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();
    return img;
}

// Image size: box x box pt (pixel-rounded up), except "laugh", which is 1.34 x box so the rotated text
// never clips. Either way the glyph is centred in the image: always draw it centred on the box centre.
UIImage *RXGlyphCoverage(NSString *key, CGFloat box) {
    static NSMutableDictionary *cache;
    if (![key isKindOfClass:[NSString class]] || box < 1.0f) {
        return nil;
    }
    if (!RXIsGlyphKey(key)) {
        RXLogOnce([@"glyphkey|" stringByAppendingString:key],
                  [NSString stringWithFormat:@"glyph: unknown key (length %lu)", (unsigned long)[key length]]);
        return nil;
    }
    if (!cache) {
        cache = [[NSMutableDictionary alloc] init];
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.2f", key, (double)box];
    UIImage *hit = [cache objectForKey:cacheKey];
    if (hit) {
        return hit;
    }
    UIImage *img = RXRenderCoverage(key, box);
    if (!img) {
        RXLogOnce([@"glyphfail|" stringByAppendingString:key], [NSString stringWithFormat:@"glyph: render failed for %@", key]);
        return nil;
    }
    if ([cache count] >= 128) {
        [cache removeAllObjects];
    }
    [cache setObject:img forKey:cacheKey];
    return img;
}

#pragma mark - Glyph drawing (engraved)

typedef struct {
    RXGradient fill;
    RXGradient shadow;
    CGFloat dy;
} RXGlyphPaint;

static RXGlyphPaint RXPaintForGlyph(NSString *key, RXGlyphStyle style) {
    RXGlyphPaint p;
    switch (style) {
        case RXGlyphOnBlue:      // mine on select-text-bubble: white -> #E6EEFF, black a0.30 at -1
            p.fill = RXGrad(1.0f, 1.0f, 1.0f, 1.0f, RX_HEX(0xE6), RX_HEX(0xEE), 1.0f, 1.0f);
            p.shadow = RXSolid(0.0f, 0.0f, 0.0f, 0.30f);
            p.dy = -1.0f;
            break;
        case RXGlyphOnCallout:   // stock callout label: white, black a0.5 at -1
            p.fill = RXSolid(1.0f, 1.0f, 1.0f, 1.0f);
            p.shadow = RXSolid(0.0f, 0.0f, 0.0f, 0.5f);
            p.dy = -1.0f;
            break;
        case RXGlyphOnGrey:
        default:                 // others on Balloon_2: #7D8390 -> #4F5562 (heart #FF5C7A -> #D9173D), white a0.80 at +1
            if ([key isEqualToString:@"love"]) {
                p.fill = RXGrad(1.0f, RX_HEX(0x5C), RX_HEX(0x7A), 1.0f, RX_HEX(0xD9), RX_HEX(0x17), RX_HEX(0x3D), 1.0f);
            } else {
                p.fill = RXGrad(RX_HEX(0x7D), RX_HEX(0x83), RX_HEX(0x90), 1.0f, RX_HEX(0x4F), RX_HEX(0x55), RX_HEX(0x62), 1.0f);
            }
            p.shadow = RXSolid(1.0f, 1.0f, 1.0f, 0.80f);
            p.dy = 1.0f;
            break;
    }
    return p;
}

// Colour emoji (Apple Color Emoji via UIKit string drawing), first composed sequence only, centred.
static void RXDrawEmojiGlyph(CGContextRef ctx, NSString *emoji, CGFloat g, CGPoint centre) {
    NSString *one = emoji;
    NSRange first = [emoji rangeOfComposedCharacterSequenceAtIndex:0];
    if (first.location == 0 && first.length > 0 && first.length < [emoji length]) {
        one = [emoji substringWithRange:first];
    }
    UIFont *font = [UIFont systemFontOfSize:g * 1.02f];
    CGSize size = [one sizeWithFont:font];
    CGContextSaveGState(ctx);
    CGContextSetRGBFillColor(ctx, 0.0f, 0.0f, 0.0f, 1.0f);
    CGPoint p = RXSnap(ctx, CGPointMake(centre.x - size.width / 2.0f, centre.y - size.height / 2.0f));
    [one drawAtPoint:p withFont:font];
    CGContextRestoreGState(ctx);
}

// `box` is the glyph box (g = its shorter side), centred where the glyph goes. Engraving = a hard 1 pt
// tinted copy offset by dy, then the gradient fill on top (no CGContextSetShadow).
void RXDrawGlyph(NSString *key, NSString *emoji, CGRect box, RXGlyphStyle style) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx || CGRectIsEmpty(box)) {
        return;
    }
    CGFloat g = MIN(box.size.width, box.size.height);
    CGPoint centre = CGPointMake(CGRectGetMidX(box), CGRectGetMidY(box));
    if ([emoji isKindOfClass:[NSString class]] && [emoji length] > 0) {
        RXDrawEmojiGlyph(ctx, emoji, g, centre);
        return;
    }
    UIImage *coverage = RXGlyphCoverage(key, g);
    if (!coverage) {
        return;
    }
    RXGlyphPaint paint = RXPaintForGlyph(key, style);
    UIImage *fill = RXTint(coverage, paint.fill);
    UIImage *shadow = RXTint(coverage, paint.shadow);
    CGPoint p = RXSnap(ctx, CGPointMake(centre.x - coverage.size.width / 2.0f, centre.y - coverage.size.height / 2.0f));
    if (shadow) {
        [shadow drawAtPoint:CGPointMake(p.x, p.y + paint.dy)];
    }
    if (fill) {
        [fill drawAtPoint:p];
    }
}

#pragma mark - Reply arrow

// UIButtonBarReply.png (25x20 pt white mask) scaled by `scale`, tinted per DESIGN section 9:
//   idle      #97A1B4 -> #7C879B, shadow #F3F7FF at (0, +1)
//   armed     #6FA3FF -> #2A63E0, shadow #F3F7FF at (0, +1)
//   wallpaper white, shadow black a0.6 at (0, +1)   (armed looks the same; it only grows)
// The image is (art width x scale) by (art height x scale + 2 pt): 1 pt of padding above and below, the
// fill at y = 1 and its engraving at y = 2, so the fill is centred in the image.
// Scale is quantised to 0.01; the cache is bounded.
UIImage *RXReplyArrowImage(BOOL armed, BOOL wallpaper, CGFloat scale) {
    static NSMutableDictionary *cache;
    if (scale <= 0.0f) {
        return nil;
    }
    CGFloat q = (CGFloat)(round((double)scale * 100.0) / 100.0);
    if (q < 0.05f) {
        q = 0.05f;
    }
    BOOL lit = (armed && !wallpaper) ? YES : NO;
    NSString *cacheKey = [NSString stringWithFormat:@"%d%d|%.2f", (int)lit, (int)wallpaper, (double)q];
    if (!cache) {
        cache = [[NSMutableDictionary alloc] init];
    }
    UIImage *hit = [cache objectForKey:cacheKey];
    if (hit) {
        return hit;
    }
    UIImage *art = RXKitImage(@"UIButtonBarReply.png");
    if (!art) {
        return nil;
    }
    CGFloat sc = RXScreenScale();
    CGSize gs = CGSizeMake(RXCeilPx(art.size.width * q), RXCeilPx(art.size.height * q));
    if (gs.width <= 0.0f || gs.height <= 0.0f) {
        return nil;
    }

    UIImage *coverage = nil;
    UIGraphicsBeginImageContextWithOptions(gs, NO, sc);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        [art drawInRect:CGRectMake(0.0f, 0.0f, gs.width, gs.height)];
        coverage = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();
    if (!coverage) {
        return nil;
    }

    RXGradient fillGrad;
    RXGradient shadowGrad;
    if (wallpaper) {
        fillGrad = RXSolid(1.0f, 1.0f, 1.0f, 1.0f);
        shadowGrad = RXSolid(0.0f, 0.0f, 0.0f, 0.6f);
    } else if (lit) {
        fillGrad = RXGrad(RX_HEX(0x6F), RX_HEX(0xA3), 1.0f, 1.0f, RX_HEX(0x2A), RX_HEX(0x63), RX_HEX(0xE0), 1.0f);
        shadowGrad = RXSolid(RX_HEX(0xF3), RX_HEX(0xF7), 1.0f, 1.0f);
    } else {
        fillGrad = RXGrad(RX_HEX(0x97), RX_HEX(0xA1), RX_HEX(0xB4), 1.0f, RX_HEX(0x7C), RX_HEX(0x87), RX_HEX(0x9B), 1.0f);
        shadowGrad = RXSolid(RX_HEX(0xF3), RX_HEX(0xF7), 1.0f, 1.0f);
    }
    UIImage *fill = RXTint(coverage, fillGrad);
    UIImage *shadow = RXTint(coverage, shadowGrad);
    if (!fill) {
        return nil;
    }

    UIImage *out = nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(gs.width, gs.height + 2.0f), NO, sc);
    if (UIGraphicsGetCurrentContext()) {
        if (shadow) {
            [shadow drawAtPoint:CGPointMake(0.0f, 2.0f)];
        }
        [fill drawAtPoint:CGPointMake(0.0f, 1.0f)];
        out = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();
    if (out) {
        if ([cache count] >= 96) {
            [cache removeAllObjects];
        }
        [cache setObject:out forKey:cacheKey];
    }
    return out;
}

#pragma mark - Haptic (R4 section 5.7)

typedef void (*RXVibeFn)(UInt32 soundID, id unknown, NSDictionary *pattern);

// One very light tap (Intensity 0.25, 12 ms) through KeyTick's private call, at most every 250 ms,
// played on a serial queue. Silently skipped when the symbol is missing or the Haptic pref is off.
void RXTick(void) {
    static RXVibeFn fn;
    static dispatch_queue_t queue;
    static NSDictionary *pattern;
    static CFTimeInterval last;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (RXVibeFn)dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSoundWithVibration");
        queue = dispatch_queue_create("com.mbucc9000.reactions.tick", DISPATCH_QUEUE_SERIAL);
        pattern = [NSDictionary dictionaryWithObjectsAndKeys:
                   [NSArray arrayWithObjects:[NSNumber numberWithBool:YES], [NSNumber numberWithInt:12], nil], @"VibePattern",
                   [NSNumber numberWithFloat:0.25f], @"Intensity",
                   nil];
        RXLog(@"haptic: vibration call %@", fn ? @"found" : @"missing");
    });
    if (!fn || !queue || !pattern) {
        return;
    }
    if (!RXOn(RXGetPrefs().haptic)) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (last > 0.0 && now - last < 0.25) {
        return;
    }
    last = now;
    RXVibeFn play = fn;
    NSDictionary *vibe = pattern;
    dispatch_async(queue, ^{
        play(RX_VIBRATE_SOUND_ID, nil, vibe);
    });
}

#pragma mark - MessageWallpapers detection

// MW sets the transcript table's backgroundColor to clearColor (MessageWallpapers/Tweak.x:705).
BOOL RXTableIsWallpapered(UITableView *table) {
    if (!table) {
        return NO;
    }
    UIColor *bg = table.backgroundColor;
    CGColorRef cg = bg ? bg.CGColor : NULL;
    if (!cg) {
        return NO;
    }
    return CGColorGetAlpha(cg) < 0.01f ? YES : NO;
}

// MW removes the entry bar's glass by clearing its layer contents (MessageWallpapers/Tweak.x:320-325).
BOOL RXEntryIsWallpapered(UIView *entry) {
    if (!entry) {
        return NO;
    }
    return entry.layer.contents == nil ? YES : NO;
}
