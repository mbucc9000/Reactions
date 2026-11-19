// Reactions 2.0 - RXStore.m: per-chat reaction state and matcher (DESIGN.md 4, R5 6), the persisted
// matched-GUID list (Matched.plist) and reply links (Replies.plist).
//
// Threading: everything here runs on the main thread, except the plist serialisation and file writes,
// which run on one private serial queue from an immutable deep copy (RXShared.h RULES).
//
// Model notes (read with DESIGN 4.2):
//  * Records are kept in APPEND order for one bubble-data build. Dates (calendarDate) are only used for
//    R5's 60 s skew window, the 15 min edit-alias window and the 2 s own-number duplicate window.
//  * "Candidates" are records that are neither reactions nor edit rows (R5 6.1). A record whose parse
//    target is RXTargetUnknown ("Loved it!", an empty quote, app balloons) is an ordinary message, and so is
//    a name-first edit row that was not applied (it may be an ordinary sentence, DESIGN 4.5).
//  * Matching is stage-major (R5 6.3): every candidate in the 500-candidate window is tried for stage 1
//    before any is tried for stage 2, and within a stage the newest candidate wins. Stages 1-4 and 6 use
//    hash indexes, stage 5 (truncated prefix) and attachments scan backwards.
//  * Votes are derived state: every matched reaction is filed under its target, and the per-part vote
//    table is rebuilt by replaying those reactions in append order (add replaces, any removal clears).
//    That makes failures, own-handle remapping and out-of-order (pending) matches exact.
//  * isHiddenGUID: answers "has this message's append been suppressed in the current bubble data", so it
//    stays YES after -messageFailed: until the next build (the rows are still absent; DESIGN 5.2 reload).
//  * The matched list also keeps, for my own reactions only, the target GUID/part the reaction was
//    applied to ("g"/"k"), so a pick on an older duplicate text ("ok", "lol") keeps its bubble across
//    rebuilds instead of jumping to the newest identical text.
//  * Edits (2.2.0, DESIGN 4.5): an applied edit row is hidden and its target's new text goes into the
//    shown-edit map (target GUID -> { partKey: text }), which survives builds; the transcript pins it on
//    the part at append. The store itself reads every part's RAW text (the _text ivar), never the pin.
//
// Logs: counts, kinds, lengths and GUID tails only (DESIGN 2). Chats are logged as a 16-bit hash.

#import "RXShared.h"

// Selectors used by the attachment-kind fallback that RXShared.h does not declare (CK.dump:L1197).
@interface CKMediaObject (RXStoreLocal)
- (NSString *)mimeType;
- (NSString *)exportedFilename;
@end

// The Load Earlier flag (CK@0x33f0ee50 _refreshMoreToLoadFlag: limitToLoad <= messages count); NO = the whole
// history is loaded. Edit fallback coverage only (DESIGN 4.5).
@interface CKConversation (RXStoreLocal)
- (BOOL)moreMessagesToLoad;
@end

#pragma mark - Tunables

#define RXST_WINDOW             500       // candidates looked back (R5 6.1)
#define RXST_SKEW               60.0      // late-match / pending re-match window, seconds (R5 6.1)
#define RXST_SKEW_PRUNE         120.0     // unmatched/pending entries older than this can never match again
#define RXST_EDIT_WINDOW        900.0     // edit aliases: author's messages in the preceding 15 min (R5 6.5)
#define RXST_EDIT_SLACK         2.0       // tolerate an edit row stamped a moment before its original
#define RXST_DUP_WINDOW         2.0       // own-number chat: sent/received copies within 2 s (R5 6.1)
#define RXST_OWN_PAIRS          2         // duplicate pairs needed before a handle is treated as "me"
#define RXST_RECENT             12        // records remembered for duplicate detection
#define RXST_MIN_PREFIX         8         // truncated-prefix stage: minimum prefix length (R5 6.3)
#define RXST_MAX_STORES         5         // on-screen chat + 4 most recently used (DESIGN 4.2)
#define RXST_MAX_OPTIMISTIC     32
#define RXST_MAX_UNMATCHED      200
#define RXST_SNIPPET_MAX        120       // reply snippet, UTF-16 units (DESIGN 4.3)
#define RXST_REPLIES_PER_CHAT   500       // DESIGN 4.3
#define RXST_REPLIES_TOTAL      5000
#define RXST_MATCHED_PER_CHAT   1000      // matched list: same rules, roomier caps (one entry per reaction)
#define RXST_MATCHED_TOTAL      8000
#define RXST_WRITE_DELAY        1.0       // coalesced writes (DESIGN 4.3)
#define RXST_EDIT_MIN_SIM       0.5       // shown edit: a candidate needs this similarity to win (DESIGN 4.5)
#define RXST_EDIT_STRONG_SIM    0.8       // name-first row whose name is not the sender's: close rewrites only
#define RXST_EDIT_INSERT_SIM    0.6       // similarity floor for a pure insert/delete (shorter text >= 4 code points)
#define RXST_EDIT_MAX           5         // edits per message (Apple's limit)
#define RXST_EDIT_LEV_MAX       64        // full Levenshtein on the stack up to this many differing code points
#define RXST_EDIT_LEV_BAND      64        // longer middles: banded Levenshtein, first band (doubled while needed)
#define RXST_EDIT_LEV_BAND_MAX  256       // band cap: time O(n * (2k + 1)), memory O(n); past it = all differ
#define RXST_EDIT_CP_STACK      512       // both texts' code points on the stack up to this, else heap
#define RXST_EDIT_CANDS         32        // candidates scored per edit row
#define RXST_EDITS_PER_CHAT     200       // shown edits kept per chat (oldest dropped)
#define RXST_LOCAL_SENDS        64        // rows typed on this iPhone remembered (never treated as edits)

#pragma mark - Small helpers

static unsigned long RXStChatTag(NSString *chatKey) {
    return (unsigned long)([chatKey hash] & 0xffff);
}

static id RXStObject(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static BOOL RXStBool(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

// An NSString (or an NSAttributedString's plain string) from a getter; nil otherwise. Always a copy.
static NSString *RXStString(id obj, SEL sel) {
    id value = RXStObject(obj, sel);
    if ([value isKindOfClass:[NSAttributedString class]]) {
        return [[(NSAttributedString *)value string] copy];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value copy];
    }
    return nil;
}

// U+FFFC (object replacement character), built from its code point so this file stays ASCII.
static NSString *RXStObjectChar(void) {
    static NSString *s;
    if (!s) {
        unichar c = 0xFFFC;
        s = [NSString stringWithCharacters:&c length:1];
    }
    return s;
}

static NSString *RXStStripFFFC(NSString *s) {
    if (![s length]) {
        return @"";
    }
    NSString *obj = RXStObjectChar();
    if ([s rangeOfString:obj].location == NSNotFound) {
        return s;
    }
    return [s stringByReplacingOccurrencesOfString:obj withString:@""];
}

// R5 6.2 N(x); never nil.
static NSString *RXStNorm(NSString *s) {
    if (![s length]) {
        return @"";
    }
    NSString *n = RXNormalize(s);
    return n ? n : @"";
}

static NSString *RXStTrim(NSString *s) {
    if (![s length]) {
        return @"";
    }
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// R5 6.3 stage 6: runs of whitespace/newlines -> one space, trimmed.
static NSString *RXStCollapse(NSString *s) {
    NSUInteger n = [s length];
    if (!n) {
        return @"";
    }
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableData *inData = [NSMutableData dataWithLength:n * sizeof(unichar)];
    NSMutableData *outData = [NSMutableData dataWithLength:n * sizeof(unichar)];
    unichar *src = (unichar *)[inData mutableBytes];
    unichar *dst = (unichar *)[outData mutableBytes];
    if (!src || !dst) {
        return RXStTrim(s);
    }
    [s getCharacters:src range:NSMakeRange(0, n)];
    NSUInteger len = 0;
    BOOL gap = NO;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = src[i];
        if ([ws characterIsMember:c]) {
            if (len) {
                gap = YES;
            }
            continue;
        }
        if (gap) {
            dst[len++] = ' ';
            gap = NO;
        }
        dst[len++] = c;
    }
    return [NSString stringWithCharacters:dst length:len];
}

// YES when s.length > 0 and contains needle (a nil string never "contains" anything).
static BOOL RXStHas(NSString *s, NSString *needle) {
    return [s length] && [needle length] && [s rangeOfString:needle].location != NSNotFound;
}

static BOOL RXStExtIn(NSString *ext, NSString *spaceList) {
    return [ext length] && [[spaceList componentsSeparatedByString:@" "] containsObject:ext];
}

static BOOL RXStHasLongerPrefix(NSString *s, NSString *prefix) {
    return [prefix length] && [s length] > [prefix length] && [s hasPrefix:prefix];
}

// Reactor key normalisation, same rules as GroupChatNameFix HideBar.xm:59-80:
// "tel:+1 (555) 010-0199" -> "5550100199"; "mailto:A@B.com" -> "a@b.com". nil when nothing usable.
static NSString *RXStHandleKey(NSString *address) {
    if (![address isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *a = RXStTrim(address);
    if (![a length]) {
        return nil;
    }
    NSString *lower = [a lowercaseString];
    if ([lower hasPrefix:@"tel:"]) {
        a = [a substringFromIndex:4];
    } else if ([lower hasPrefix:@"mailto:"]) {
        a = [a substringFromIndex:7];
    }
    if ([a rangeOfString:@"@"].location != NSNotFound) {
        NSString *mail = [[a stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
        return [mail length] ? mail : nil;
    }
    NSMutableString *digits = [NSMutableString string];
    NSUInteger n = [a length];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [a characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            [digits appendFormat:@"%C", c];
        }
    }
    if ([digits length] > 10) {
        return [digits substringFromIndex:[digits length] - 10];
    }
    if ([digits length]) {
        return [digits copy];
    }
    NSString *other = [[a stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
    return [other length] ? other : nil;
}

// Composed-sequence-safe cut to <= maxUnits UTF-16 units (no ellipsis).
static NSString *RXStCut(NSString *s, NSUInteger maxUnits) {
    if (![s isKindOfClass:[NSString class]]) {
        return @"";
    }
    if ([s length] <= maxUnits) {
        return s;
    }
    NSString *cut = RXSafeTruncate(s, maxUnits);
    if (![cut isKindOfClass:[NSString class]] || [cut length] > maxUnits) {
        NSRange seq = [s rangeOfComposedCharacterSequenceAtIndex:maxUnits];
        cut = [s substringToIndex:MIN(seq.location, maxUnits)];
    }
    return cut;
}

static NSString *RXStKindName(RXTarget kind) {
    switch (kind) {
        case RXTargetText:      return @"text";
        case RXTargetUnknown:   return @"text";
        case RXTargetImage:     return @"image";
        case RXTargetMovie:     return @"movie";
        case RXTargetAudio:     return @"audio";
        case RXTargetLocation:  return @"location";
        case RXTargetContact:   return @"contact";
        default:                return @"attachment";
    }
}

static RXTarget RXStKindFromName(NSString *name) {
    if ([name isEqualToString:@"text"]) {
        return RXTargetText;
    }
    if ([name isEqualToString:@"image"]) {
        return RXTargetImage;
    }
    if ([name isEqualToString:@"movie"]) {
        return RXTargetMovie;
    }
    if ([name isEqualToString:@"audio"]) {
        return RXTargetAudio;
    }
    if ([name isEqualToString:@"location"]) {
        return RXTargetLocation;
    }
    if ([name isEqualToString:@"contact"]) {
        return RXTargetContact;
    }
    if ([name isEqualToString:@"event"]) {
        return RXTargetEvent;
    }
    if ([name isEqualToString:@"pass"]) {
        return RXTargetPass;
    }
    return RXTargetAnyAttachment;
}

#pragma mark - Part classification (RXShared.h)

// Media object class name -> kind (CK.dump: CKCompressibleImage/AnimatedImage/FixedImage/WBMPImage,
// CKVideo, CKAudio, CKLocation (a card; checked before VCard), CKVCard, CKVCal, CKPassbook).
static RXTarget RXStKindForMediaClassName(NSString *name) {
    if (RXStHas(name, @"Location")) {
        return RXTargetLocation;
    }
    if (RXStHas(name, @"VCard")) {
        return RXTargetContact;
    }
    if (RXStHas(name, @"VCal")) {
        return RXTargetEvent;
    }
    if (RXStHas(name, @"Passbook")) {
        return RXTargetPass;
    }
    if (RXStHas(name, @"Video")) {
        return RXTargetMovie;
    }
    if (RXStHas(name, @"Audio")) {
        return RXTargetAudio;
    }
    if (RXStHas(name, @"Image") || RXStHas(name, @"AnimatedImage") || RXStHas(name, @"FixedImage") ||
        RXStHas(name, @"WBMP") || RXStHas(name, @"Compressible")) {
        return RXTargetImage;
    }
    return RXTargetUnknown;
}

static NSString *RXStMediaFilename(CKMediaObject *media) {
    NSString *file = [RXStString(media, @selector(filename)) lowercaseString];
    if (![file length]) {
        file = [RXStString(media, @selector(exportedFilename)) lowercaseString];
    }
    return file;
}

// UTI / MIME / file extension fallback (R5 3.2, 6.4). MobileCoreServices is not linked, so no UTType calls.
static RXTarget RXStKindForMediaFallback(CKMediaObject *media) {
    NSString *uti = [RXStString(media, @selector(UTIType)) lowercaseString];
    NSString *mime = [RXStString(media, @selector(mimeType)) lowercaseString];
    NSString *file = RXStMediaFilename(media);
    NSString *ext = [file length] ? [file pathExtension] : @"";
    if ([file hasSuffix:@".loc.vcf"] || RXStHas(mime, @"vlocation")) {
        return RXTargetLocation;
    }
    if (RXStHas(uti, @"vcard") || RXStHas(mime, @"vcard") || RXStHas(mime, @"directory") ||
        [ext isEqualToString:@"vcf"]) {
        return RXTargetContact;
    }
    if (RXStHas(uti, @"calendar") || RXStHas(uti, @"ical") || RXStHas(mime, @"calendar") ||
        [ext isEqualToString:@"ics"]) {
        return RXTargetEvent;
    }
    if (RXStHas(uti, @"pkpass") || RXStHas(mime, @"pkpass") || [ext isEqualToString:@"pkpass"]) {
        return RXTargetPass;
    }
    if (RXStHas(mime, @"vnd.apple.finance.order") || [ext isEqualToString:@"order"]) {
        return RXTargetOrder;
    }
    if ([mime hasPrefix:@"audio/"] || RXStHas(uti, @"audio") ||
        RXStExtIn(ext, @"caf amr m4a mp3 aac wav aif aiff")) {
        return RXTargetAudio;
    }
    if ([mime hasPrefix:@"image/"] || RXStHas(uti, @"image") || RXStHas(uti, @"jpeg") || RXStHas(uti, @"png") ||
        RXStHas(uti, @"gif") || RXStHas(uti, @"tiff") || RXStHas(uti, @"heic") || RXStHas(uti, @"heif") ||
        RXStHas(uti, @"bmp") || RXStExtIn(ext, @"jpg jpeg png gif tif tiff heic heif bmp")) {
        return RXTargetImage;
    }
    if ([mime hasPrefix:@"video/"] || RXStHas(uti, @"movie") || RXStHas(uti, @"video") ||
        RXStHas(uti, @"mpeg-4") || RXStHas(uti, @"3gpp") || RXStExtIn(ext, @"mov mp4 m4v 3gp")) {
        return RXTargetMovie;
    }
    return RXTargetUnknown;
}

RXTarget RXTargetForPart(CKMessagePart *part) {
    if (!part) {
        return RXTargetUnknown;
    }
    int type = -1;
    if ([part respondsToSelector:@selector(type)]) {
        type = [part type];
    } else {
        NSString *cls = NSStringFromClass(object_getClass(part));
        if (RXStHas(cls, @"TextMessagePart")) {
            type = 0;
        } else if (RXStHas(cls, @"MediaObjectMessagePart")) {
            type = 1;
        }
    }
    if (type == 0) {
        return RXTargetText;
    }
    if (type != 1) {
        return RXTargetUnknown;            // deleted / unknown parts
    }
    CKMediaObject *media = [part respondsToSelector:@selector(mediaObject)] ? [part mediaObject] : nil;
    if (!media) {
        return RXTargetAnyAttachment;
    }
    RXTarget kind = RXTargetUnknown;
    for (Class c = object_getClass(media); c; c = class_getSuperclass(c)) {
        NSString *name = NSStringFromClass(c);
        if (![name length] || [name isEqualToString:@"CKMediaObject"] || [name isEqualToString:@"NSObject"]) {
            break;
        }
        kind = RXStKindForMediaClassName(name);
        if (kind != RXTargetUnknown) {
            break;
        }
    }
    if (kind == RXTargetContact && [RXStMediaFilename(media) hasSuffix:@".loc.vcf"]) {
        kind = RXTargetLocation;
    }
    if (kind == RXTargetUnknown) {
        kind = RXStKindForMediaFallback(media);
    }
    return kind == RXTargetUnknown ? RXTargetAnyAttachment : kind;
}

// The text the bubble shows: -text goes through the edit hook, so an edited part answers its new text (what
// RXSend / RXReply / RXPicker quote). The store never calls this (RXStRawTextForPart).
NSString *RXTextForPart(CKMessagePart *part) {
    if (!part) {
        return nil;
    }
    if ([part respondsToSelector:@selector(type)] && [part type] != 0) {
        return nil;
    }
    NSString *s = RXStString(part, @selector(text));
    if (!s) {
        return nil;
    }
    return RXStStripFFFC(s);
}

// CKTextMessagePart and its _text ivar (@"NSAttributedString", CK.dump L1085), resolved once; NULL when absent.
static Class gRXStTextClass;
static Ivar gRXStTextIvar;

static void RXStTextIvarSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRXStTextClass = NSClassFromString(@"CKTextMessagePart");
        Ivar iv = gRXStTextClass ? class_getInstanceVariable(gRXStTextClass, "_text") : NULL;
        const char *type = iv ? ivar_getTypeEncoding(iv) : NULL;
        gRXStTextIvar = (type && type[0] == '@') ? iv : NULL;
        if (!gRXStTextIvar) {
            RXLogOnce(@"store.textivar", @"store: CKTextMessagePart _text ivar missing; Show Edits unavailable");
        }
    });
}

// Show Edits needs the raw text: without the ivar no edit is ever applied, so nothing is pinned.
static BOOL RXStRawTextAvailable(void) {
    RXStTextIvarSetup();
    return gRXStTextIvar != NULL;
}

// A text part's stored text exactly as the stock getter returns it (CK@0x31480 just loads _text), read
// directly so the edit hook's pin never reaches the store (DESIGN 4.5). FFFC removed; nil for other parts.
static NSString *RXStRawTextForPart(CKMessagePart *part) {
    if (!part) {
        return nil;
    }
    if ([part respondsToSelector:@selector(type)] && [part type] != 0) {
        return nil;
    }
    RXStTextIvarSetup();
    id value = nil;
    if (gRXStTextIvar && gRXStTextClass && [part isKindOfClass:gRXStTextClass]) {
        value = object_getIvar(part, gRXStTextIvar);
    } else {
        value = RXStObject(part, @selector(text));     // no pins exist then (RXStRawTextAvailable)
    }
    NSString *str = nil;
    if ([value isKindOfClass:[NSAttributedString class]]) {
        str = [[(NSAttributedString *)value string] copy];
    } else if ([value isKindOfClass:[NSString class]]) {
        str = [(NSString *)value copy];
    }
    return str ? RXStStripFFFC(str) : nil;
}

// s as code points (a surrogate pair is one value, a lone half stays as is); out holds >= [s length] entries.
static NSUInteger RXStCodePoints(NSString *s, uint32_t *out) {
    if (![s length]) {
        return 0;
    }
    CFStringRef cf = (__bridge CFStringRef)s;
    CFIndex n = CFStringGetLength(cf);
    CFStringInlineBuffer buf;
    CFStringInitInlineBuffer(cf, &buf, CFRangeMake(0, n));
    NSUInteger k = 0;
    for (CFIndex i = 0; i < n; i++) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buf, i);
        if (CFStringIsSurrogateHighCharacter(c) && i + 1 < n) {
            UniChar d = CFStringGetCharacterFromInlineBuffer(&buf, i + 1);
            if (CFStringIsSurrogateLowCharacter(d)) {
                out[k++] = (uint32_t)CFStringGetLongCharacterForSurrogatePair(c, d);
                i++;
                continue;
            }
        }
        out[k++] = c;
    }
    return k;
}

// Banded Levenshtein for long middles (two fixes far apart): exact up to k edits, k + 1 beyond that (also when
// the lengths differ by more than k). Cells outside |i - j| <= k count as k + 1; stops early once a whole row is
// past k. Allocates only one row; NSNotFound if out of memory.
static NSUInteger RXStLevBanded(const uint32_t *ca, NSUInteger ma, const uint32_t *cb, NSUInteger mb, NSUInteger k) {
    NSUInteger beyond = k + 1;
    if ((ma > mb ? ma - mb : mb - ma) > k) {
        return beyond;                                // the band misses the corner (and row[jlo - 1] would overrun)
    }
    NSUInteger *row = malloc((mb + 1) * sizeof(NSUInteger));
    NSUInteger dist = NSNotFound;
    if (row) {
        for (NSUInteger j = 0; j <= mb; j++) {
            row[j] = j <= k ? j : beyond;
        }
        dist = beyond;
        BOOL done = NO;
        for (NSUInteger i = 1; i <= ma && !done; i++) {
            NSUInteger jlo = i > k ? i - k : 1;
            NSUInteger jhi = MIN(mb, i + k);
            NSUInteger diag = row[jlo - 1];
            row[jlo - 1] = (jlo == 1) ? MIN(i, beyond) : beyond;
            NSUInteger rowMin = row[jlo - 1];
            for (NSUInteger j = jlo; j <= jhi; j++) {
                NSUInteger up = row[j];
                NSUInteger best = MIN(up + 1, row[j - 1] + 1);
                best = MIN(best, diag + (ca[i - 1] == cb[j - 1] ? 0 : 1));
                row[j] = MIN(best, beyond);
                rowMin = MIN(rowMin, row[j]);
                diag = up;
            }
            if (rowMin > k) {
                done = YES;                           // every path is already past k
            }
        }
        if (!done) {
            dist = row[mb];
        }
    }
    free(row);
    return dist;
}

// Edit similarity (DESIGN 4.5) on lowercased N(x) texts, in code points (a surrogate pair is one symbol, so two
// different emoji share nothing): the shared start and end are stripped, the middles compared with an exact
// Levenshtein (stack) when both are <= RXST_EDIT_LEV_MAX, else a banded one that starts at RXST_EDIT_LEV_BAND and
// doubles up to k = the most edits that can still score RXST_EDIT_MIN_SIM, capped at RXST_EDIT_LEV_BAND_MAX (a
// middle past k counts as entirely different); score = 1 - distance / longer length. A pure insert or delete
// (one text is the other's start plus end, the shorter >= 4) scores at least RXST_EDIT_INSERT_SIM.
static double RXStEditSim(NSString *a, NSString *b) {
    NSUInteger ua = [a length];
    NSUInteger ub = [b length];
    if (ua + ub == 0) {
        return 1.0;
    }
    uint32_t stackBuf[RXST_EDIT_CP_STACK];
    uint32_t *buf = (ua + ub <= RXST_EDIT_CP_STACK) ? stackBuf : malloc((ua + ub) * sizeof(uint32_t));
    if (!buf) {
        return 0.0;
    }
    const uint32_t *ca = buf;
    const uint32_t *cb = buf + ua;
    NSUInteger la = RXStCodePoints(a, buf);
    NSUInteger lb = RXStCodePoints(b, buf + ua);
    NSUInteger longer = MAX(la, lb);
    NSUInteger shorter = MIN(la, lb);
    NSUInteger pre = 0;
    while (pre < shorter && ca[pre] == cb[pre]) {
        pre++;
    }
    NSUInteger suf = 0;
    while (suf < shorter - pre && ca[la - 1 - suf] == cb[lb - 1 - suf]) {
        suf++;
    }
    NSUInteger ma = la - pre - suf;
    NSUInteger mb = lb - pre - suf;
    const uint32_t *xa = ca + pre;
    const uint32_t *xb = cb + pre;
    NSUInteger dist = MAX(ma, mb);
    if (ma > 0 && mb > 0 && dist <= RXST_EDIT_LEV_MAX) {
        NSUInteger row[RXST_EDIT_LEV_MAX + 1];
        for (NSUInteger j = 0; j <= mb; j++) {
            row[j] = j;
        }
        for (NSUInteger i = 1; i <= ma; i++) {
            NSUInteger diag = row[0];
            row[0] = i;
            for (NSUInteger j = 1; j <= mb; j++) {
                NSUInteger up = row[j];
                NSUInteger best = MIN(up + 1, row[j - 1] + 1);
                best = MIN(best, diag + (xa[i - 1] == xb[j - 1] ? 0 : 1));
                row[j] = best;
                diag = up;
            }
        }
        dist = row[mb];
    } else if (ma > 0 && mb > 0) {
        // Only distances that can still score RXST_EDIT_MIN_SIM need to be exact (below it only the newest
        // candidate can win, whatever its score). A small band first: a result within the band is exact.
        NSUInteger k = (NSUInteger)floor((1.0 - RXST_EDIT_MIN_SIM) * (double)longer);
        k = MIN(k, (NSUInteger)RXST_EDIT_LEV_BAND_MAX);
        NSUInteger gap = ma > mb ? ma - mb : mb - ma;
        if (gap <= k) {
            NSUInteger kk = MIN(k, MAX(gap, (NSUInteger)RXST_EDIT_LEV_BAND));   // never below the gap
            for (;;) {
                NSUInteger banded = RXStLevBanded(xa, ma, xb, mb, kk);
                if (banded == NSNotFound) {
                    break;                            // out of memory: dist stays MAX(ma, mb)
                }
                if (banded <= kk) {
                    dist = banded;                    // exact
                    break;
                }
                if (kk >= k) {
                    break;                            // past k: never used (a capped k + 1 could score >= 0.5)
                }
                kk = MIN(k, kk * 2);
            }
        }
    }
    double sim = 1.0 - (double)dist / (double)longer;
    if (shorter >= 4 && pre + suf >= shorter && sim < RXST_EDIT_INSERT_SIM) {
        sim = RXST_EDIT_INSERT_SIM;
    }
    if (buf != stackBuf) {
        free(buf);
    }
    return sim;
}

// A name-first edit row's name vs the sender's first name: equal, or the first name plus exactly one more word
// ("Taylor Brooks" / "Taylor"; never "Will you check what I" / "Will"), ignoring case and accents. Only the
// flag is kept, never a name.
static BOOL RXStNameMatches(NSString *rowName, NSString *firstName) {
    NSString *a = RXStTrim(RXStNorm(rowName));
    NSString *b = RXStTrim(RXStNorm(firstName));
    NSUInteger lb = [b length];
    if (![a length] || !lb || [a length] < lb) {
        return NO;
    }
    NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    if ([a compare:b options:opts range:NSMakeRange(0, lb)] != NSOrderedSame) {
        return NO;
    }
    if ([a length] == lb) {
        return YES;
    }
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    if (![ws characterIsMember:[a characterAtIndex:lb]]) {
        return NO;
    }
    NSString *rest = [a substringFromIndex:lb + 1];
    return [rest length] && [rest rangeOfCharacterFromSet:ws].location == NSNotFound;
}

// Store vectors for the parser self-test (S1-S6, 2.2.0): edit similarity and the name check. Fake names only.
void RXStoreSelfTest(NSUInteger *pass, NSUInteger *total, NSMutableArray *fails) {
    NSString *typo = @"hey so i was thinkng we could go to the beach on saturday and then get dinner after, let me knw";
    NSString *fixed = @"hey so i was thinking we could go to the beach on saturday and then get dinner after, let me know";
    NSString *other = @"no worries at all, we can just pick a different weekend once everyone has looked at their plans";
    NSMutableString *body = [NSMutableString string];
    while ([body length] < 2100) {
        [body appendString:@" the quick brown fox jumps over the lazy dog"];
    }
    NSString *cry = [NSString stringWithFormat:@"%C%C", (unichar)0xD83D, (unichar)0xDE2D];    // U+1F62D
    NSString *joy = [NSString stringWithFormat:@"%C%C", (unichar)0xD83D, (unichar)0xDE02];    // U+1F602
    BOOL ok[6];
    ok[0] = RXStEditSim(typo, fixed) >= 0.9;                       // two fixes ~80 units apart (distance 2)
    ok[1] = RXStEditSim(typo, other) < RXST_EDIT_MIN_SIM;          // a long unrelated text stays below 0.5
    ok[2] = RXStNameMatches(@"Taylor Brooks", @"Taylor");
    ok[3] = !RXStNameMatches(@"Taylor will check what I", @"Taylor");
    ok[4] = RXStEditSim([@"helo" stringByAppendingFormat:@"%@ byee", body],
                        [@"hello" stringByAppendingFormat:@"%@ bye", body]) >= 0.9;   // > 2,100 apart (capped band)
    ok[5] = RXStEditSim(cry, joy) < RXST_EDIT_MIN_SIM;             // two emoji: one code point each, no shared half
    for (int i = 0; i < 6; i++) {
        (*total)++;
        if (ok[i]) {
            (*pass)++;
        } else {
            [fails addObject:[NSString stringWithFormat:@"S%d", i + 1]];
        }
    }
}

#pragma mark - Public model classes

@implementation RXReaction
@end

static NSString *RXStGroupKey(RXKind kind, NSString *emoji) {
    return [NSString stringWithFormat:@"%d|%@", (int)kind, (kind == RXKindEmoji && emoji) ? emoji : @""];
}

static BOOL RXStSameKind(RXReaction *a, RXReaction *b) {
    if (!a || !b || a.kind != b.kind) {
        return NO;
    }
    if (a.kind != RXKindEmoji) {
        return YES;
    }
    return (a.emoji == nil && b.emoji == nil) || [a.emoji isEqualToString:b.emoji];
}

static NSString *RXStJoinNames(NSArray *names) {
    NSUInteger n = [names count];
    if (n == 0) {
        return @"someone";
    }
    if (n == 1) {
        return [names objectAtIndex:0];
    }
    if (n == 2) {
        return [NSString stringWithFormat:@"%@ and %@", [names objectAtIndex:0], [names objectAtIndex:1]];
    }
    NSArray *head = [names subarrayWithRange:NSMakeRange(0, n - 1)];
    return [NSString stringWithFormat:@"%@, and %@", [head componentsJoinedByString:@", "], [names lastObject]];
}

// Words only (VoiceOver reads an emoji by its name).
static NSString *RXStPhrase(RXKind kind, NSString *emoji, NSArray *names) {
    NSString *verb = nil;
    switch (kind) {
        case RXKindLove:     verb = @"Loved"; break;
        case RXKindLike:     verb = @"Liked"; break;
        case RXKindDislike:  verb = @"Disliked"; break;
        case RXKindLaugh:    verb = @"Laughed at"; break;
        case RXKindEmph:     verb = @"Emphasized"; break;
        case RXKindQuestion: verb = @"Questioned"; break;
        case RXKindSticker:  verb = @"Reacted with a sticker"; break;
        case RXKindEmoji:    verb = [emoji length] ? [NSString stringWithFormat:@"Reacted %@", emoji] : @"Reacted"; break;
        default:             verb = @"Reacted"; break;
    }
    return [NSString stringWithFormat:@"%@ by %@", verb, RXStJoinNames(names)];
}

@implementation RXBadgeModel

- (BOOL)isEmpty {
    return [self.others count] == 0 && self.mine == nil;
}

- (NSArray *)captionEntries {
    NSMutableArray *out = [NSMutableArray array];
    RXReaction *mine = self.mine;
    if (mine) {
        RXReaction *e = [[RXReaction alloc] init];
        e.kind = mine.kind;
        e.emoji = mine.emoji;
        e.count = 1;
        e.isMine = YES;
        e.names = [NSArray arrayWithObject:@"You"];
        [out addObject:e];
    }
    for (RXReaction *g in self.others) {
        for (id name in g.names) {
            NSString *shown = ([name isKindOfClass:[NSString class]] && [(NSString *)name length]) ? name : @"Someone";
            RXReaction *e = [[RXReaction alloc] init];
            e.kind = g.kind;
            e.emoji = g.emoji;
            e.count = 1;
            e.isMine = NO;
            e.names = [NSArray arrayWithObject:shown];
            [out addObject:e];
        }
    }
    return out;
}

- (NSString *)accessibilityString {
    NSMutableArray *phrases = [NSMutableArray array];
    RXReaction *mine = self.mine;
    BOOL mineUsed = NO;
    for (RXReaction *g in self.others) {
        NSMutableArray *who = [NSMutableArray array];
        for (id name in g.names) {
            BOOL ok = [name isKindOfClass:[NSString class]] && [(NSString *)name length];
            [who addObject:ok ? name : @"someone"];
        }
        if (mine && !mineUsed && RXStSameKind(mine, g)) {
            [who addObject:@"you"];
            mineUsed = YES;
        }
        [phrases addObject:RXStPhrase(g.kind, g.emoji, who)];
    }
    if (mine && !mineUsed) {
        [phrases addObject:RXStPhrase(mine.kind, mine.emoji, [NSArray arrayWithObject:@"you"])];
    }
    return [phrases componentsJoinedByString:@". "];
}

@end

@implementation RXReplyLink

- (id)init {
    if ((self = [super init])) {
        _kind = RXTargetText;
    }
    return self;
}

@end

#pragma mark - Persistence (Replies.plist / Matched.plist)

typedef enum {
    RXStFileReplies = 0,
    RXStFileMatched
} RXStFileKind;

static dispatch_queue_t RXStQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.mbucc9000.reactions.store", NULL);
    });
    return queue;
}

static NSDate *RXStEntryDate(id entry) {
    id t = [entry isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)entry objectForKey:@"t"] : nil;
    return [t isKindOfClass:[NSDate class]] ? t : [NSDate distantPast];
}

// Validates one loaded entry; returns an immutable, nil-free dictionary or nil (entry dropped).
static NSDictionary *RXStSanitize(RXStFileKind kind, id raw) {
    if (kind == RXStFileMatched && [raw isKindOfClass:[NSDate class]]) {
        return [NSDictionary dictionaryWithObject:raw forKey:@"t"];        // lenient: bare date
    }
    if (![raw isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *d = raw;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [out setObject:RXStEntryDate(d) forKey:@"t"];
    if (kind == RXStFileReplies) {
        id p = [d objectForKey:@"p"];
        if (![p isKindOfClass:[NSString class]] || ![(NSString *)p length]) {
            return nil;
        }
        [out setObject:p forKey:@"p"];
        id i = [d objectForKey:@"i"];
        [out setObject:([i isKindOfClass:[NSNumber class]] ? i : [NSNumber numberWithInt:0]) forKey:@"i"];
        id k = [d objectForKey:@"k"];
        [out setObject:([k isKindOfClass:[NSString class]] ? k : @"text") forKey:@"k"];
        id s = [d objectForKey:@"s"];
        [out setObject:([s isKindOfClass:[NSString class]] ? RXStCut(s, RXST_SNIPPET_MAX) : @"") forKey:@"s"];
        id m = [d objectForKey:@"m"];
        [out setObject:([m isKindOfClass:[NSNumber class]] ? m : [NSNumber numberWithBool:NO]) forKey:@"m"];
        id n = [d objectForKey:@"n"];
        [out setObject:([n isKindOfClass:[NSString class]] ? n : @"") forKey:@"n"];
    } else {
        id g = [d objectForKey:@"g"];
        if ([g isKindOfClass:[NSString class]] && [(NSString *)g length]) {
            [out setObject:g forKey:@"g"];
            id k = [d objectForKey:@"k"];
            if ([k isKindOfClass:[NSNumber class]]) {
                [out setObject:k forKey:@"k"];
            }
        }
        id eg = [d objectForKey:@"eg"];                 // edit rows: the bubble the edit went to (DESIGN 4.5)
        if ([eg isKindOfClass:[NSString class]] && [(NSString *)eg length]) {
            [out setObject:eg forKey:@"eg"];
        }
    }
    return [out copy];
}

// { chatKey: { key: entry } } with LRU caps, coalesced binary writes and .bad quarantine.
@interface RXStFile : NSObject
- (id)initWithPath:(NSString *)path label:(NSString *)label kind:(RXStFileKind)kind
           perChat:(NSUInteger)perChat total:(NSUInteger)total;
- (NSDictionary *)entryForChat:(NSString *)chat key:(NSString *)key;
- (void)setEntry:(NSDictionary *)entry forChat:(NSString *)chat key:(NSString *)key;
- (void)removeEntryForChat:(NSString *)chat key:(NSString *)key;
@end

@implementation RXStFile {
    NSString *_path;
    NSString *_label;
    RXStFileKind _kind;
    NSUInteger _perChat;
    NSUInteger _total;
    NSMutableDictionary *_root;
    BOOL _loaded;
    BOOL _writable;        // NO after a failed load: never overwrite until a load succeeds (DESIGN 4.3)
    BOOL _changed;
    BOOL _scheduled;
}

- (id)initWithPath:(NSString *)path label:(NSString *)label kind:(RXStFileKind)kind
           perChat:(NSUInteger)perChat total:(NSUInteger)total {
    if ((self = [super init])) {
        _path = [path copy];
        _label = [label copy];
        _kind = kind;
        _perChat = perChat ? perChat : 1;
        _total = total ? total : 1;
        _root = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)quarantine:(NSUInteger)bytes {
    _writable = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bad = [_path stringByAppendingString:@".bad"];
    if ([fm fileExistsAtPath:bad]) {
        bad = [NSString stringWithFormat:@"%@.bad-%lu", _path, (unsigned long)[[NSDate date] timeIntervalSince1970]];
    }
    NSError *error = nil;
    BOOL moved = [fm moveItemAtPath:_path toPath:bad error:&error];
    RXLog(@"%@: parse failure (%lu bytes), %@; running in memory, file not overwritten this session",
          _label, (unsigned long)bytes, moved ? @"moved to .bad" : @"rename failed");
}

- (void)ensureLoaded {
    if (_loaded) {
        return;
    }
    _loaded = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_path]) {
        _writable = YES;
        RXLog(@"%@: no file yet", _label);
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (!data) {
        _writable = NO;
        RXLog(@"%@: unreadable; running in memory, file not overwritten this session", _label);
        return;
    }
    id plist = nil;
    if ([data length]) {
        NSError *error = nil;
        plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
    }
    if (![plist isKindOfClass:[NSDictionary class]]) {
        [self quarantine:[data length]];
        return;
    }
    NSDictionary *root = plist;
    NSUInteger chats = 0, entries = 0, dropped = 0;
    for (id chat in root) {
        id value = [root objectForKey:chat];
        if (![chat isKindOfClass:[NSString class]] || ![(NSString *)chat length] ||
            ![value isKindOfClass:[NSDictionary class]]) {
            dropped++;
            continue;
        }
        NSDictionary *src = value;
        NSMutableDictionary *dst = [NSMutableDictionary dictionaryWithCapacity:[src count]];
        for (id key in src) {
            NSDictionary *entry = nil;
            if ([key isKindOfClass:[NSString class]] && [(NSString *)key length]) {
                entry = RXStSanitize(_kind, [src objectForKey:key]);
            }
            if (entry) {
                [dst setObject:entry forKey:key];
            } else {
                dropped++;
            }
        }
        if ([dst count]) {
            [_root setObject:dst forKey:chat];
            chats++;
            entries += [dst count];
        }
    }
    _writable = YES;
    RXLog(@"%@: loaded %lu entries in %lu chats (%lu dropped)", _label, (unsigned long)entries,
          (unsigned long)chats, (unsigned long)dropped);
}

- (NSUInteger)totalCount {
    NSUInteger n = 0;
    for (NSString *chat in _root) {
        n += [(NSDictionary *)[_root objectForKey:chat] count];
    }
    return n;
}

- (void)trimChat:(NSString *)chat to:(NSUInteger)target {
    NSMutableDictionary *d = [_root objectForKey:chat];
    if ([d count] <= target) {
        return;
    }
    NSArray *keys = [d keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
        return [RXStEntryDate(a) compare:RXStEntryDate(b)];
    }];
    NSUInteger drop = [d count] - target;
    for (NSUInteger i = 0; i < drop && i < [keys count]; i++) {
        [d removeObjectForKey:[keys objectAtIndex:i]];
    }
}

- (void)trimAllTo:(NSUInteger)target {
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *chat in _root) {
        NSDictionary *d = [_root objectForKey:chat];
        for (NSString *key in d) {
            [all addObject:[NSArray arrayWithObjects:RXStEntryDate([d objectForKey:key]), chat, key, nil]];
        }
    }
    if ([all count] <= target) {
        return;
    }
    [all sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [(NSDate *)[(NSArray *)a objectAtIndex:0] compare:(NSDate *)[(NSArray *)b objectAtIndex:0]];
    }];
    NSUInteger drop = [all count] - target;
    for (NSUInteger i = 0; i < drop; i++) {
        NSArray *item = [all objectAtIndex:i];
        NSString *chat = [item objectAtIndex:1];
        NSMutableDictionary *d = [_root objectForKey:chat];
        [d removeObjectForKey:[item objectAtIndex:2]];
        if (d && ![d count]) {
            [_root removeObjectForKey:chat];
        }
    }
}

- (void)flush {
    _scheduled = NO;
    if (!_changed) {
        return;
    }
    _changed = NO;
    if (!_writable) {
        RXLogOnce([_label stringByAppendingString:@".nowrite"],
                  [NSString stringWithFormat:@"%@: changes kept in memory only (file did not load)", _label]);
        return;
    }
    // Immutable deep copy: chat dictionaries are copied; entries are already immutable.
    NSMutableDictionary *snap = [NSMutableDictionary dictionaryWithCapacity:[_root count]];
    NSUInteger entries = 0;
    for (NSString *chat in _root) {
        NSDictionary *d = [(NSDictionary *)[_root objectForKey:chat] copy];
        if ([d count]) {
            [snap setObject:d forKey:chat];
            entries += [d count];
        }
    }
    NSDictionary *plist = [snap copy];
    NSString *path = [_path copy];
    NSString *label = [_label copy];
    dispatch_async(RXStQueue(), ^{
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:&error];
        BOOL ok = NO;
        if (data) {
            NSFileManager *fm = [[NSFileManager alloc] init];
            [fm createDirectoryAtPath:RX_DATA_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
            ok = [data writeToFile:path options:NSDataWritingAtomic error:&error];
        }
        NSUInteger bytes = [data length];
        long code = error ? (long)[error code] : 0;
        BOOL serialized = data != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                RXLog(@"%@: wrote %lu entries (%lu bytes)", label, (unsigned long)entries, (unsigned long)bytes);
            } else {
                RXLog(@"%@: %@ failed (error %ld)", label, serialized ? @"write" : @"serialize", code);
            }
        });
    });
}

- (void)scheduleWrite {
    _changed = YES;
    if (_scheduled) {
        return;
    }
    _scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RXST_WRITE_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self flush];
    });
}

- (NSDictionary *)entryForChat:(NSString *)chat key:(NSString *)key {
    if (![chat length] || ![key length]) {
        return nil;
    }
    [self ensureLoaded];
    return [(NSDictionary *)[_root objectForKey:chat] objectForKey:key];
}

- (void)setEntry:(NSDictionary *)entry forChat:(NSString *)chat key:(NSString *)key {
    if (![entry isKindOfClass:[NSDictionary class]] || ![chat length] || ![key length]) {
        return;
    }
    [self ensureLoaded];
    NSMutableDictionary *d = [_root objectForKey:chat];
    if (!d) {
        d = [NSMutableDictionary dictionary];
        [_root setObject:d forKey:chat];
    }
    [d setObject:[entry copy] forKey:key];
    // Replies trim exactly to the cap (rare inserts); the matched list keeps 2% slack so a large first
    // build does not re-sort thousands of entries on every new match.
    BOOL slack = (_kind == RXStFileMatched);
    if ([d count] > _perChat) {
        [self trimChat:chat to:_perChat - (slack ? _perChat / 50 : 0)];
    }
    if ([self totalCount] > _total) {
        [self trimAllTo:_total - (slack ? _total / 50 : 0)];
    }
    [self scheduleWrite];
}

- (void)removeEntryForChat:(NSString *)chat key:(NSString *)key {
    if (![chat length] || ![key length]) {
        return;
    }
    [self ensureLoaded];
    NSMutableDictionary *d = [_root objectForKey:chat];
    if (![d objectForKey:key]) {
        return;
    }
    [d removeObjectForKey:key];
    if (![d count]) {
        [_root removeObjectForKey:chat];
    }
    [self scheduleWrite];
}

@end

static RXStFile *RXStReplies(void) {
    static RXStFile *file;
    if (!file) {
        file = [[RXStFile alloc] initWithPath:RX_REPLIES_PATH label:@"replies" kind:RXStFileReplies
                                      perChat:RXST_REPLIES_PER_CHAT total:RXST_REPLIES_TOTAL];
    }
    return file;
}

static RXStFile *RXStMatched(void) {
    static RXStFile *file;
    if (!file) {
        file = [[RXStFile alloc] initWithPath:RX_MATCHED_PATH label:@"matched" kind:RXStFileMatched
                                      perChat:RXST_MATCHED_PER_CHAT total:RXST_MATCHED_TOTAL];
    }
    return file;
}

static RXReplyLink *RXStLinkFromEntry(NSDictionary *e) {
    id p = [e objectForKey:@"p"];
    if (![p isKindOfClass:[NSString class]] || ![(NSString *)p length]) {
        return nil;
    }
    RXReplyLink *link = [[RXReplyLink alloc] init];
    link.parentGUID = p;
    id i = [e objectForKey:@"i"];
    link.partKey = [i isKindOfClass:[NSNumber class]] ? [(NSNumber *)i integerValue] : 0;
    id k = [e objectForKey:@"k"];
    link.kind = [k isKindOfClass:[NSString class]] ? RXStKindFromName(k) : RXTargetText;
    id s = [e objectForKey:@"s"];
    link.snippet = [s isKindOfClass:[NSString class]] ? s : @"";
    id m = [e objectForKey:@"m"];
    link.parentIsMine = [m isKindOfClass:[NSNumber class]] ? [(NSNumber *)m boolValue] : NO;
    id n = [e objectForKey:@"n"];
    NSString *name = [n isKindOfClass:[NSString class]] ? n : @"";
    if (![name length] && link.parentIsMine) {
        name = @"You";
    }
    link.parentName = name;
    id t = [e objectForKey:@"t"];
    link.date = [t isKindOfClass:[NSDate class]] ? t : nil;
    return link;
}

#pragma mark - Store internals

@interface RXStSeg : NSObject
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, copy) NSString *norm;
@property (nonatomic, copy) NSString *trim;
@property (nonatomic, copy) NSString *coll;
@property (nonatomic, assign) BOOL fromPart;          // a real text part (NO: the _rawPreviewText fallback)
@property (nonatomic, copy) NSString *cur;            // N(current text) after applied edits; nil = unedited
@property (nonatomic, copy) NSString *shown;          // the latest edit's text as received (FFFC removed)
@end

@implementation RXStSeg
@end

@interface RXStAtt : NSObject
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) RXTarget kind;
@end

@implementation RXStAtt
@end

@interface RXStRecord : NSObject
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, copy) NSString *reactor;        // "me", a normalised handle, or "?" (own handles mapped at use)
@property (nonatomic, copy) NSString *name;           // first name (others' reactions only)
@property (nonatomic, assign) BOOL fromMe;
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, assign) BOOL hasDate;
@property (nonatomic, assign) NSTimeInterval t;
@property (nonatomic, assign) NSInteger seq;          // append order (store clock)
@property (nonatomic, copy) NSString *fullNorm;       // N(text parts joined)
@property (nonatomic, copy) NSString *fullTrim;       // candidates only
@property (nonatomic, copy) NSString *fullColl;       // candidates only
@property (nonatomic, strong) NSArray *segs;          // RXStSeg, one per text part
@property (nonatomic, strong) NSArray *atts;          // RXStAtt, one per attachment part
@property (nonatomic, strong) NSMutableArray *aliases;// normalised edit texts (R5 6.5)
@property (nonatomic, assign) NSInteger firstTextKey; // partKey for whole-text matches
@property (nonatomic, strong) RXEvent *event;
@property (nonatomic, assign) BOOL isReaction;
@property (nonatomic, assign) BOOL isEdit;
@property (nonatomic, assign) BOOL isCandidate;
@property (nonatomic, assign) NSInteger candOrdinal;
@property (nonatomic, copy) NSString *qNorm;          // reaction quote forms
@property (nonatomic, copy) NSString *qTrim;
@property (nonatomic, copy) NSString *qColl;
@property (nonatomic, copy) NSString *qPrefix;        // truncated quotes with >= 8 units only
@property (nonatomic, assign) BOOL hidden;            // append suppressed in the current bubble data
@property (nonatomic, assign) BOOL matched;           // counted (vote applied)
@property (nonatomic, assign) BOOL pending;           // matched-list hidden, no target yet
@property (nonatomic, copy) NSString *targetGUID;
@property (nonatomic, assign) NSInteger targetPart;
@property (nonatomic, copy) NSString *hintGUID;       // my pick (optimistic entry or matched list "g")
@property (nonatomic, assign) NSInteger hintPart;
@property (nonatomic, assign) NSInteger editCount;    // candidates: edits applied (<= RXST_EDIT_MAX)
@property (nonatomic, copy) NSString *editRule;       // candidates: how the last edit chose it (log only)
@property (nonatomic, assign) double editSim;         // candidates: that edit's similarity (log only)
@property (nonatomic, assign) NSUInteger editCands;   // candidates: candidates scored for that edit (log only)
@property (nonatomic, assign) BOOL editNameMatch;     // name-first edit rows: name == sender's first name
@property (nonatomic, assign) BOOL editApplied;       // edit rows: applied to a loaded target (=> hidden)
@end

@implementation RXStRecord
@end

@interface RXStRef : NSObject
@property (nonatomic, strong) RXStRecord *rec;
@property (nonatomic, assign) NSInteger partKey;
@end

@implementation RXStRef
@end

static RXStRef *RXStMakeRef(RXStRecord *rec, NSInteger partKey) {
    RXStRef *ref = [[RXStRef alloc] init];
    ref.rec = rec;
    ref.partKey = partKey;
    return ref;
}

static void RXStIndex(NSMutableDictionary *idx, NSString *key, RXStRecord *rec, NSInteger partKey) {
    if (![key length] || !rec) {
        return;
    }
    NSMutableArray *list = [idx objectForKey:key];
    if (!list) {
        list = [NSMutableArray array];
        [idx setObject:list forKey:key];
    }
    [list addObject:RXStMakeRef(rec, partKey)];
}

static NSArray *RXStLookup(NSDictionary *idx, NSString *key) {
    return [key length] ? [idx objectForKey:key] : nil;
}

@interface RXStVote : NSObject
@property (nonatomic, assign) RXKind kind;
@property (nonatomic, copy) NSString *emoji;
@property (nonatomic, assign) NSInteger seq;
@property (nonatomic, copy) NSString *name;
@end

@implementation RXStVote
@end

// Reactions filed under one target message, in append order; `cache` = { partKey: { reactor: RXStVote } }.
@interface RXStTarget : NSObject
@property (nonatomic, strong) NSMutableArray *apps;
@property (nonatomic, strong) NSDictionary *cache;
@end

@implementation RXStTarget
@end

@interface RXStOptimistic : NSObject
@property (nonatomic, copy) NSString *sentGUID;
@property (nonatomic, copy) NSString *targetGUID;
@property (nonatomic, assign) NSInteger partKey;
@property (nonatomic, assign) RXKind kind;
@property (nonatomic, copy) NSString *emoji;
@property (nonatomic, assign) BOOL removal;
@property (nonatomic, assign) NSInteger seq;
@end

@implementation RXStOptimistic
@end

typedef struct {
    NSUInteger messages;
    NSUInteger reactions;
    NSUInteger matched;
    NSUInteger late;
    NSUInteger hidden;
    NSUInteger pending;
    NSUInteger edits;
    NSUInteger editsApplied;
    NSUInteger editsKept;
    NSUInteger failed;
} RXStStats;

#pragma mark - RXStore

@interface RXStore ()
- (id)initWithChatKey:(NSString *)chatKey;
- (NSUInteger)clearEdits;
@end

static NSMutableArray *gRXStores;     // MRU first

void RXStoreClearEdits(void) {
    NSUInteger n = 0;
    for (RXStore *store in gRXStores) {
        n += [store clearEdits];
    }
    if (n) {
        RXLog(@"edits: cleared %lu (prefs)", (unsigned long)n);
    }
}

@implementation RXStore {
    // Per build (reset by -restartBuild)
    NSMutableDictionary *_byGUID;     // guid -> RXStRecord
    NSMutableArray *_cands;           // candidate records, append order
    NSMutableDictionary *_idxFull;
    NSMutableDictionary *_idxFullTrim;
    NSMutableDictionary *_idxSeg;
    NSMutableDictionary *_idxSegTrim;
    NSMutableDictionary *_idxAlias;
    NSMutableDictionary *_idxAliasTrim;
    NSMutableDictionary *_idxColl;
    NSMutableDictionary *_idxEdited;  // applied edits: N(new text) -> the target part that shows it
    NSMutableDictionary *_idxEditedTrim;
    NSTimeInterval _buildFirstT;      // oldest dated row ingested this build (edit fallback coverage)
    BOOL _buildHasFirstT;
    NSMutableDictionary *_targets;    // target guid -> RXStTarget
    NSMutableArray *_pending;         // list-hidden reactions without a target yet
    NSMutableArray *_unmatched;       // visible unmatched reactions (late-match candidates)
    NSMutableArray *_recent;          // last few records (own-number duplicate detection)
    int _oneToOne;                    // -1 unknown, 0 group, 1 one-to-one
    RXStStats _stats;
    // Kept across builds
    NSMutableSet *_dirty;
    BOOL _needsReload;
    NSMutableSet *_reloadRequested;   // GUIDs that already triggered a late-match reload
    NSMutableArray *_optimistic;      // RXStOptimistic
    NSMutableSet *_ownHandles;        // handles learned to be the user's own (own-number chat)
    NSMutableDictionary *_ownPairs;   // handle -> set of received-copy GUIDs
    NSMutableDictionary *_linkCache;  // replyGUID -> RXReplyLink
    NSInteger _clock;
    NSMutableDictionary *_editShown;  // target GUID -> { @(partKey): text } (DESIGN 4.5; what the pins show)
    NSMutableArray *_editOrder;       // _editShown keys, oldest first (cap)
    NSDictionary *_editStart;         // _editShown at the last restart / take (change detection)
    BOOL _editsTouched;               // _editShown written since then
    NSMutableDictionary *_editKept;   // edit row GUID -> last "kept visible" reason (log once per change)
    NSMutableDictionary *_editTarget; // edit row GUID -> target GUID it was applied to (never moves while gone)
    NSMutableArray *_editTargetOrder; // _editTarget keys, oldest first (cap)
    NSMutableArray *_localSends;      // GUIDs typed on this iPhone (own Send path): never edits
}

+ (RXStore *)storeForChatKey:(NSString *)chatKey create:(BOOL)create {
    if (![chatKey isKindOfClass:[NSString class]] || ![chatKey length]) {
        return nil;
    }
    if (!gRXStores) {
        gRXStores = [NSMutableArray array];
    }
    NSUInteger count = [gRXStores count];
    for (NSUInteger i = 0; i < count; i++) {
        RXStore *found = [gRXStores objectAtIndex:i];
        if ([found.chatKey isEqualToString:chatKey]) {
            if (i) {
                [gRXStores removeObjectAtIndex:i];
                [gRXStores insertObject:found atIndex:0];
            }
            return found;
        }
    }
    if (!create) {
        return nil;
    }
    RXStore *store = [[RXStore alloc] initWithChatKey:chatKey];
    [gRXStores insertObject:store atIndex:0];
    while ([gRXStores count] > RXST_MAX_STORES) {
        RXStore *old = [gRXStores lastObject];
        RXLog(@"store: chat #%04lx released from memory", RXStChatTag(old.chatKey));
        [gRXStores removeLastObject];
    }
    RXLog(@"store: chat #%04lx opened (%lu in memory)", RXStChatTag(chatKey), (unsigned long)[gRXStores count]);
    return store;
}

- (id)initWithChatKey:(NSString *)chatKey {
    if ((self = [super init])) {
        _chatKey = [chatKey copy];
        _dirty = [NSMutableSet set];
        _reloadRequested = [NSMutableSet set];
        _optimistic = [NSMutableArray array];
        _ownHandles = [NSMutableSet set];
        _ownPairs = [NSMutableDictionary dictionary];
        _linkCache = [NSMutableDictionary dictionary];
        _editShown = [NSMutableDictionary dictionary];
        _editOrder = [NSMutableArray array];
        _editKept = [NSMutableDictionary dictionary];
        _editTarget = [NSMutableDictionary dictionary];
        _editTargetOrder = [NSMutableArray array];
        _localSends = [NSMutableArray array];
        [self resetBuildState];
    }
    return self;
}

- (void)resetBuildState {
    _byGUID = [NSMutableDictionary dictionary];
    _cands = [NSMutableArray array];
    _idxFull = [NSMutableDictionary dictionary];
    _idxFullTrim = [NSMutableDictionary dictionary];
    _idxSeg = [NSMutableDictionary dictionary];
    _idxSegTrim = [NSMutableDictionary dictionary];
    _idxAlias = [NSMutableDictionary dictionary];
    _idxAliasTrim = [NSMutableDictionary dictionary];
    _idxColl = [NSMutableDictionary dictionary];
    _idxEdited = [NSMutableDictionary dictionary];
    _idxEditedTrim = [NSMutableDictionary dictionary];
    _buildFirstT = 0;
    _buildHasFirstT = NO;
    _targets = [NSMutableDictionary dictionary];
    _pending = [NSMutableArray array];
    _unmatched = [NSMutableArray array];
    _recent = [NSMutableArray array];
    _oneToOne = -1;
    memset(&_stats, 0, sizeof(_stats));
}

- (void)logBuildSummary {
    if (!_stats.messages) {
        return;
    }
    RXLog(@"store #%04lx build: %lu messages, %lu reactions, %lu matched (%lu late), %lu hidden (%lu pending), "
          @"%lu edits (%lu applied, %lu kept), %lu failed, %lu targets, %lu own handles",
          RXStChatTag(_chatKey), (unsigned long)_stats.messages, (unsigned long)_stats.reactions,
          (unsigned long)_stats.matched, (unsigned long)_stats.late, (unsigned long)_stats.hidden,
          (unsigned long)_stats.pending, (unsigned long)_stats.edits, (unsigned long)_stats.editsApplied,
          (unsigned long)_stats.editsKept, (unsigned long)_stats.failed,
          (unsigned long)[_targets count], (unsigned long)[_ownHandles count]);
}

- (void)restartBuild {
    [self logBuildSummary];
    [self resetBuildState];
    [_dirty removeAllObjects];     // the build reloads every row
    _needsReload = NO;             // a rebuild is the reload
    _editStart = [_editShown copy];   // the pins this build's appends will use (never cleared here)
    _editsTouched = NO;
}

#pragma mark Identity

- (NSString *)who:(NSString *)reactor {
    if (![reactor length]) {
        return @"?";
    }
    return [_ownHandles containsObject:reactor] ? @"me" : reactor;
}

#pragma mark Matched list

- (NSDictionary *)listedEntry:(NSString *)guid {
    return [guid length] ? [RXStMatched() entryForChat:_chatKey key:guid] : nil;
}

- (void)rememberMatch:(RXStRecord *)r {
    if (![r.guid length] || [self listedEntry:r.guid]) {
        return;
    }
    NSMutableDictionary *e = [NSMutableDictionary dictionaryWithObject:[NSDate date] forKey:@"t"];
    if (r.fromMe && [r.targetGUID length]) {
        [e setObject:r.targetGUID forKey:@"g"];
        [e setObject:[NSNumber numberWithInteger:r.targetPart] forKey:@"k"];
    }
    [RXStMatched() setEntry:e forChat:_chatKey key:r.guid];
}

- (void)forgetMatch:(NSString *)guid {
    if ([guid length]) {
        [RXStMatched() removeEntryForChat:_chatKey key:guid];
    }
}

- (void)requestReload:(NSString *)guid {
    if (![guid length] || [_reloadRequested containsObject:guid]) {
        return;
    }
    [_reloadRequested addObject:guid];
    _needsReload = YES;
}

#pragma mark Votes

- (RXStTarget *)targetFor:(NSString *)guid create:(BOOL)create {
    if (![guid length]) {
        return nil;
    }
    RXStTarget *ts = [_targets objectForKey:guid];
    if (!ts && create) {
        ts = [[RXStTarget alloc] init];
        ts.apps = [NSMutableArray array];
        [_targets setObject:ts forKey:guid];
    }
    return ts;
}

- (void)invalidateTarget:(NSString *)guid {
    RXStTarget *ts = [self targetFor:guid create:NO];
    ts.cache = nil;
    if ([guid length]) {
        [_dirty addObject:guid];
    }
}

- (void)invalidateAllTargets {
    for (NSString *guid in _targets) {
        RXStTarget *ts = [_targets objectForKey:guid];
        ts.cache = nil;
        [_dirty addObject:guid];
    }
}

- (void)apply:(RXStRecord *)r to:(RXStRecord *)c part:(NSInteger)partKey {
    if (!r || ![c.guid length]) {
        return;
    }
    r.matched = YES;
    r.pending = NO;
    r.targetGUID = c.guid;
    r.targetPart = partKey;
    RXStTarget *ts = [self targetFor:c.guid create:YES];
    NSUInteger i = [ts.apps count];
    while (i > 0 && [(RXStRecord *)[ts.apps objectAtIndex:i - 1] seq] > r.seq) {
        i--;
    }
    [ts.apps insertObject:r atIndex:i];
    [self invalidateTarget:c.guid];
}

// { partKey(NSNumber): { reactor: RXStVote } } by replaying the target's reactions in append order.
- (NSDictionary *)votesFor:(NSString *)guid {
    RXStTarget *ts = [self targetFor:guid create:NO];
    if (!ts) {
        return nil;
    }
    if (!ts.cache) {
        NSMutableDictionary *byPart = [NSMutableDictionary dictionary];
        for (RXStRecord *r in ts.apps) {
            if (!r.matched || r.failed || !r.event) {
                continue;
            }
            NSNumber *pk = [NSNumber numberWithInteger:r.targetPart];
            NSMutableDictionary *votes = [byPart objectForKey:pk];
            if (!votes) {
                votes = [NSMutableDictionary dictionary];
                [byPart setObject:votes forKey:pk];
            }
            NSString *who = [self who:r.reactor];
            if (r.event.isRemoval) {
                [votes removeObjectForKey:who];            // any removal clears (R5 6.6)
            } else if (r.event.kind != RXKindNone) {
                RXStVote *v = [[RXStVote alloc] init];     // add replaces (R5 4.1)
                v.kind = r.event.kind;
                v.emoji = r.event.emoji;
                v.seq = r.seq;
                v.name = r.name ? r.name : @"";
                [votes setObject:v forKey:who];
            }
        }
        ts.cache = byPart;
    }
    return ts.cache;
}

- (BOOL)guid:(NSString *)guid hasVoteFrom:(NSString *)reactor {
    if (![reactor length]) {
        return NO;
    }
    NSDictionary *byPart = [self votesFor:guid];
    for (NSNumber *pk in byPart) {
        if ([(NSDictionary *)[byPart objectForKey:pk] objectForKey:reactor]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark Records

- (RXStRecord *)recordForMessage:(CKIMMessage *)msg guid:(NSString *)guid fromMe:(BOOL)fromMe failed:(BOOL)failed {
    RXStRecord *r = [[RXStRecord alloc] init];
    r.guid = guid;
    r.fromMe = fromMe;
    r.failed = failed;
    r.candOrdinal = -1;
    r.targetPart = NSNotFound;
    r.hintPart = NSNotFound;

    id date = RXStObject(msg, @selector(calendarDate));
    if ([date isKindOfClass:[NSDate class]]) {
        r.t = [(NSDate *)date timeIntervalSinceReferenceDate];
        r.hasDate = YES;
    }

    CKEntity *sender = nil;
    if (fromMe) {
        r.reactor = @"me";
    } else {
        sender = RXStObject(msg, @selector(sender));        // a new entity every call (R2 4.1)
        NSString *key = RXStHandleKey(RXStString(sender, @selector(rawAddress)));
        if (!key) {
            key = RXStHandleKey(RXStString(msg, @selector(address)));
        }
        r.reactor = key ? key : @"?";
    }

    if (_oneToOne < 0) {
        id conversation = RXStObject(msg, @selector(conversation));
        id recipients = RXStObject(conversation, @selector(recipients));
        _oneToOne = [recipients isKindOfClass:[NSArray class]] ? ([(NSArray *)recipients count] <= 1 ? 1 : 0) : 1;
    }

    // Text parts become segments, attachment parts become kinds; partKey = index in -parts (DESIGN 5.3).
    NSMutableArray *segs = [NSMutableArray array];
    NSMutableArray *atts = [NSMutableArray array];
    NSMutableString *raw = [NSMutableString string];
    id parts = RXStObject(msg, @selector(parts));
    if ([parts isKindOfClass:[NSArray class]]) {
        NSInteger index = 0;
        for (id p in (NSArray *)parts) {
            CKMessagePart *part = p;
            RXTarget kind = RXTargetForPart(part);
            if (kind == RXTargetText) {
                NSString *s = RXStRawTextForPart(part);    // raw, never the edited text pinned for display
                if (!s) {
                    s = @"";
                }
                [raw appendString:s];
                RXStSeg *seg = [[RXStSeg alloc] init];
                seg.partKey = index;
                seg.norm = RXStNorm(s);
                seg.fromPart = YES;
                [segs addObject:seg];
            } else if (kind != RXTargetUnknown) {
                RXStAtt *att = [[RXStAtt alloc] init];
                att.partKey = index;
                att.kind = kind;
                [atts addObject:att];
            }
            index++;
        }
    }
    if (![segs count] && ![atts count]) {
        NSString *s = RXStStripFFFC(RXStString(msg, @selector(_rawPreviewText)));   // never -previewText
        if ([s length]) {
            [raw appendString:s];
            RXStSeg *seg = [[RXStSeg alloc] init];
            seg.partKey = 0;
            seg.norm = RXStNorm(s);
            [segs addObject:seg];
        }
    }
    r.segs = segs;
    r.atts = atts;
    r.fullNorm = RXStNorm(raw);
    r.firstTextKey = [segs count] ? [(RXStSeg *)[segs objectAtIndex:0] partKey] : 0;
    for (RXStSeg *seg in segs) {
        if ([RXStTrim(seg.norm) length]) {
            r.firstTextKey = seg.partKey;
            break;
        }
    }

    // Classification. Only text-only messages can be tapback / edit rows.
    if (![atts count] && [raw length]) {
        RXEvent *ev = RXParse([raw copy]);
        if (ev.isEdit) {
            if ([ev.editText length]) {
                r.isEdit = YES;
                r.event = ev;
            }
        } else if (ev && ev.target != RXTargetUnknown && (ev.isRemoval || ev.kind != RXKindNone)) {
            if (ev.target == RXTargetText) {
                NSString *q = RXStNorm(ev.quote);
                NSString *qt = RXStTrim(q);
                if ([qt length]) {                         // empty / FFFC-only quotes stay visible (R5 4.9)
                    r.isReaction = YES;
                    r.event = ev;
                    r.qNorm = q;
                    r.qTrim = qt;
                    r.qColl = RXStCollapse(q);
                    if (ev.truncated) {
                        NSString *prefix = RXStNorm(ev.prefix);
                        NSUInteger plen = [prefix length];
                        if (plen) {
                            unichar last = [prefix characterAtIndex:plen - 1];
                            if (last >= 0xD800 && last <= 0xDBFF) {
                                prefix = [prefix substringToIndex:plen - 1];   // lone high surrogate
                            }
                        }
                        if ([prefix length] >= RXST_MIN_PREFIX) {
                            r.qPrefix = prefix;
                        }
                    }
                }
            } else {
                r.isReaction = YES;
                r.event = ev;
            }
        }
    }
    if (r.isReaction && !fromMe) {
        NSString *name = sender ? RXFirstNameForEntity(sender) : nil;
        r.name = name ? name : @"";
    }
    if (r.isEdit && !fromMe && [r.event.editName length]) {
        r.editNameMatch = RXStNameMatches(r.event.editName, sender ? RXFirstNameForEntity(sender) : nil);
    }
    return r;
}

- (void)addCandidate:(RXStRecord *)c {
    c.isCandidate = YES;
    c.candOrdinal = (NSInteger)[_cands count];
    [_cands addObject:c];
    c.fullTrim = RXStTrim(c.fullNorm);
    c.fullColl = RXStCollapse(c.fullNorm);
    NSInteger fk = c.firstTextKey;
    RXStIndex(_idxFull, c.fullNorm, c, fk);
    RXStIndex(_idxFullTrim, c.fullTrim, c, fk);
    RXStIndex(_idxColl, c.fullColl, c, fk);
    BOOL multi = [c.segs count] > 1;
    for (RXStSeg *seg in c.segs) {
        seg.trim = RXStTrim(seg.norm);
        seg.coll = RXStCollapse(seg.norm);
        RXStIndex(_idxSeg, seg.norm, c, seg.partKey);
        RXStIndex(_idxSegTrim, seg.trim, c, seg.partKey);
        if (multi) {
            RXStIndex(_idxColl, seg.coll, c, seg.partKey);
        }
    }
}

#pragma mark Matching (R5 6.3 / 6.4)

// Newest in-window candidate across two index lists; for removals, the newest one on which the
// reactor currently has a vote is preferred (so a removal finds the bubble its add went to).
- (RXStRef *)pickFrom:(NSArray *)a also:(NSArray *)b prefer:(NSString *)reactor {
    NSInteger minOrdinal = (NSInteger)[_cands count] - RXST_WINDOW;
    RXStRef *best = nil;
    RXStRef *bestVoted = nil;
    for (int pass = 0; pass < 2; pass++) {
        for (RXStRef *ref in (pass ? b : a)) {
            NSInteger ord = ref.rec.candOrdinal;
            if (ord < minOrdinal || ord < 0) {
                continue;
            }
            if (!best || ord > best.rec.candOrdinal) {
                best = ref;
            }
            if (reactor && (!bestVoted || ord > bestVoted.rec.candOrdinal) &&
                [self guid:ref.rec.guid hasVoteFrom:reactor]) {
                bestVoted = ref;
            }
        }
    }
    return bestVoted ? bestVoted : best;
}

- (NSInteger)prefix:(NSString *)prefix partIn:(RXStRecord *)c {
    if (![prefix length]) {
        return NSNotFound;
    }
    if (RXStHasLongerPrefix(c.fullNorm, prefix)) {
        return c.firstTextKey;
    }
    for (RXStSeg *seg in c.segs) {
        if (RXStHasLongerPrefix(seg.norm, prefix)) {
            return seg.partKey;
        }
    }
    for (NSString *alias in c.aliases) {
        if (RXStHasLongerPrefix(alias, prefix)) {
            return c.firstTextKey;
        }
    }
    return NSNotFound;
}

- (RXStRef *)prefixMatch:(RXStRecord *)r prefer:(NSString *)reactor {
    if (![r.qPrefix length]) {
        return nil;
    }
    NSInteger n = (NSInteger)[_cands count];
    NSInteger lo = MAX((NSInteger)0, n - RXST_WINDOW);
    RXStRef *best = nil;
    for (NSInteger i = n - 1; i >= lo; i--) {
        RXStRecord *c = [_cands objectAtIndex:(NSUInteger)i];
        NSInteger pk = [self prefix:r.qPrefix partIn:c];
        if (pk == NSNotFound) {
            continue;
        }
        RXStRef *ref = RXStMakeRef(c, pk);
        if (!reactor) {
            return ref;
        }
        if (!best) {
            best = ref;
        }
        if ([self guid:c.guid hasVoteFrom:reactor]) {
            return ref;
        }
    }
    return best;
}

- (RXStRef *)matchText:(RXStRecord *)r prefer:(NSString *)reactor {
    RXStRef *ref = nil;
    // 1 exact
    if ((ref = [self pickFrom:RXStLookup(_idxFull, r.qNorm) also:nil prefer:reactor])) {
        return ref;
    }
    // 2 segment (exact, or equal after trimming)
    if ((ref = [self pickFrom:RXStLookup(_idxSeg, r.qNorm) also:RXStLookup(_idxSegTrim, r.qTrim) prefer:reactor])) {
        return ref;
    }
    // 3 trimmed
    if ((ref = [self pickFrom:RXStLookup(_idxFullTrim, r.qTrim) also:nil prefer:reactor])) {
        return ref;
    }
    // 4a applied edit (the bubble and part that now show this text, DESIGN 4.5)
    if ((ref = [self pickFrom:RXStLookup(_idxEdited, r.qNorm) also:RXStLookup(_idxEditedTrim, r.qTrim) prefer:reactor])) {
        return ref;
    }
    // 4 edit alias (stages 1-3 against the alias text)
    if ((ref = [self pickFrom:RXStLookup(_idxAlias, r.qNorm) also:RXStLookup(_idxAliasTrim, r.qTrim) prefer:reactor])) {
        return ref;
    }
    // 5 truncated prefix
    if ((ref = [self prefixMatch:r prefer:reactor])) {
        return ref;
    }
    // 6 whitespace-collapsed
    return [self pickFrom:RXStLookup(_idxColl, r.qColl) also:nil prefer:reactor];
}

// First attachment part of c fitting `target` ("an attachment" = any); for a removal, the fitting part
// that carries the reactor's vote wins.
- (NSInteger)attachmentPartIn:(RXStRecord *)c fitting:(RXTarget)target voter:(NSString *)reactor {
    NSInteger first = NSNotFound;
    NSDictionary *byPart = reactor ? [self votesFor:c.guid] : nil;
    for (RXStAtt *att in c.atts) {
        if (target != RXTargetAnyAttachment && att.kind != target) {
            continue;
        }
        if (first == NSNotFound) {
            first = att.partKey;
        }
        NSDictionary *votes = [byPart objectForKey:[NSNumber numberWithInteger:att.partKey]];
        if (reactor && [votes objectForKey:reactor]) {
            return att.partKey;
        }
    }
    return first;
}

- (RXStRef *)matchMedia:(RXStRecord *)r prefer:(NSString *)reactor {
    RXTarget target = r.event.target;
    NSInteger n = (NSInteger)[_cands count];
    NSInteger lo = MAX((NSInteger)0, n - RXST_WINDOW);
    RXStRef *best = nil;
    for (NSInteger i = n - 1; i >= lo; i--) {
        RXStRecord *c = [_cands objectAtIndex:(NSUInteger)i];
        if (![c.atts count]) {
            continue;
        }
        NSInteger pk = [self attachmentPartIn:c fitting:target voter:reactor];
        if (pk == NSNotFound) {
            continue;
        }
        RXStRef *ref = RXStMakeRef(c, pk);
        if (!reactor) {
            return ref;
        }
        if (!best) {
            best = ref;
        }
        if ([self guid:c.guid hasVoteFrom:reactor]) {
            return ref;
        }
    }
    return best;
}

// Does candidate c satisfy reaction r (any stage)? Returns the part key or NSNotFound. Used for the hinted
// target, pending re-matches and late matches, where only one candidate is in question.
- (NSInteger)partIn:(RXStRecord *)c forReaction:(RXStRecord *)r {
    RXEvent *ev = r.event;
    if (!c || !ev) {
        return NSNotFound;
    }
    BOOL hinted = r.hintPart != NSNotFound && [r.hintGUID length] && [r.hintGUID isEqualToString:c.guid];
    if (ev.target != RXTargetText) {
        if (hinted) {
            for (RXStAtt *att in c.atts) {
                if (att.partKey == r.hintPart && (ev.target == RXTargetAnyAttachment || att.kind == ev.target)) {
                    return att.partKey;
                }
            }
        }
        return [self attachmentPartIn:c fitting:ev.target voter:(ev.isRemoval ? [self who:r.reactor] : nil)];
    }
    NSString *q = r.qNorm;
    NSString *qt = r.qTrim;
    if (![qt length]) {
        return NSNotFound;
    }
    if (hinted) {
        for (RXStSeg *seg in c.segs) {
            if (seg.partKey != r.hintPart) {
                continue;
            }
            if ([seg.norm isEqualToString:q] || [seg.trim isEqualToString:qt] || [seg.cur isEqualToString:q] ||
                RXStHasLongerPrefix(seg.norm, r.qPrefix) ||
                ([r.qColl length] && [seg.coll isEqualToString:r.qColl])) {
                return seg.partKey;
            }
        }
    }
    if ([c.fullNorm isEqualToString:q]) {                                          // 1
        return c.firstTextKey;
    }
    for (RXStSeg *seg in c.segs) {                                                // 2
        if ([seg.norm isEqualToString:q] || [seg.trim isEqualToString:qt]) {
            return seg.partKey;
        }
    }
    if ([c.fullTrim isEqualToString:qt]) {                                        // 3
        return c.firstTextKey;
    }
    for (RXStSeg *seg in c.segs) {                                                // 4a applied edit
        if (seg.cur && ([seg.cur isEqualToString:q] || [RXStTrim(seg.cur) isEqualToString:qt])) {
            return seg.partKey;
        }
    }
    for (NSString *alias in c.aliases) {                                          // 4
        if ([alias isEqualToString:q] || [RXStTrim(alias) isEqualToString:qt]) {
            return c.firstTextKey;
        }
    }
    NSInteger pk = [self prefix:r.qPrefix partIn:c];                              // 5
    if (pk != NSNotFound) {
        return pk;
    }
    if ([r.qColl length]) {                                                       // 6
        if ([c.fullColl isEqualToString:r.qColl]) {
            return c.firstTextKey;
        }
        for (RXStSeg *seg in c.segs) {
            if ([seg.coll isEqualToString:r.qColl]) {
                return seg.partKey;
            }
        }
        for (NSString *alias in c.aliases) {
            if ([RXStCollapse(alias) isEqualToString:r.qColl]) {
                return c.firstTextKey;
            }
        }
    }
    return NSNotFound;
}

- (RXStRef *)findTargetFor:(RXStRecord *)r {
    // My pick (optimistic entry, or the matched list's "g"/"k") is tried first, regardless of the window.
    if ([r.hintGUID length]) {
        RXStRecord *c = [_byGUID objectForKey:r.hintGUID];
        if (c.isCandidate && c.seq < r.seq) {
            NSInteger pk = [self partIn:c forReaction:r];
            if (pk != NSNotFound) {
                return RXStMakeRef(c, pk);
            }
        }
    }
    NSString *prefer = r.event.isRemoval ? [self who:r.reactor] : nil;
    if (r.event.target == RXTargetText) {
        return [self matchText:r prefer:prefer];
    }
    return [self matchMedia:r prefer:prefer];
}

#pragma mark Ingest

- (void)noteOwnPairForHandle:(NSString *)handle guid:(NSString *)guid {
    if (![handle length] || ![guid length] || [handle isEqualToString:@"?"] || [handle isEqualToString:@"me"] ||
        [_ownHandles containsObject:handle]) {
        return;
    }
    NSMutableSet *pairs = [_ownPairs objectForKey:handle];
    if (!pairs) {
        pairs = [NSMutableSet set];
        [_ownPairs setObject:pairs forKey:handle];
    }
    [pairs addObject:guid];
    if ([pairs count] < RXST_OWN_PAIRS) {
        return;
    }
    [_ownHandles addObject:handle];
    [_ownPairs removeObjectForKey:handle];
    [self invalidateAllTargets];       // that handle's votes are "me" from now on
    RXLog(@"store #%04lx: own-number duplicates seen; that handle now counts as me", RXStChatTag(_chatKey));
}

// R5 6.1 own-number chat: a sent copy and a received copy with the same text within 2 s.
- (void)noteDuplicate:(RXStRecord *)r {
    if (r.hasDate && [r.fullNorm length] && _oneToOne != 0) {
        for (RXStRecord *o in _recent) {
            if (o.fromMe == r.fromMe || !o.hasDate) {
                continue;
            }
            NSTimeInterval d = r.t - o.t;
            if (d > RXST_DUP_WINDOW || d < -RXST_DUP_WINDOW || ![o.fullNorm isEqualToString:r.fullNorm]) {
                continue;
            }
            RXStRecord *received = r.fromMe ? o : r;
            [self noteOwnPairForHandle:received.reactor guid:received.guid];
            break;
        }
    }
    [_recent addObject:r];
    if ([_recent count] > RXST_RECENT) {
        [_recent removeObjectAtIndex:0];
    }
}

// The echo of my own send: take the optimistic entry's target as the hint, then drop the entry (DESIGN 4.4).
- (void)takeOptimisticFor:(RXStRecord *)r {
    if (![_optimistic count]) {
        return;
    }
    NSMutableArray *drop = nil;
    for (RXStOptimistic *o in _optimistic) {
        if (![o.sentGUID isEqualToString:r.guid]) {
            continue;
        }
        if (!drop) {
            drop = [NSMutableArray array];
        }
        [drop addObject:o];
        if ([o.targetGUID length]) {
            r.hintGUID = o.targetGUID;
            r.hintPart = o.partKey;
            [_dirty addObject:o.targetGUID];
        }
    }
    if (drop) {
        [_optimistic removeObjectsInArray:drop];
    }
}

// An edit row that stays visible: counted, and logged only when its reason changes (it repeats every build).
- (void)keepEdit:(RXStRecord *)e because:(NSString *)why {
    _stats.editsKept++;
    if (![e.guid length] || [[_editKept objectForKey:e.guid] isEqualToString:why]) {
        return;
    }
    if ([_editKept count] >= RXST_EDITS_PER_CHAT) {
        [_editKept removeAllObjects];
    }
    [_editKept setObject:why forKey:e.guid];
    RXLog(@"store #%04lx: edit %@ kept visible (%@)", RXStChatTag(_chatKey), RXGUIDTail(e.guid), why);
}

// The target's shown text parts into the shown-edit map (what the transcript pins at append).
- (void)publishEditFor:(RXStRecord *)c {
    if (![c.guid length]) {
        return;
    }
    NSMutableDictionary *parts = [NSMutableDictionary dictionary];
    for (RXStSeg *seg in c.segs) {
        if (seg.fromPart && seg.cur && [seg.shown length]) {
            [parts setObject:seg.shown forKey:[NSNumber numberWithInteger:seg.partKey]];
        }
    }
    NSDictionary *entry = [parts count] ? [parts copy] : nil;
    NSDictionary *old = [_editShown objectForKey:c.guid];
    if ((!entry && !old) || [old isEqualToDictionary:entry]) {
        return;
    }
    _editsTouched = YES;
    if (!entry) {
        [_editShown removeObjectForKey:c.guid];
        [_editOrder removeObject:c.guid];
        return;
    }
    if (!old) {
        [_editOrder addObject:c.guid];
    }
    [_editShown setObject:entry forKey:c.guid];
    while ([_editOrder count] > RXST_EDITS_PER_CHAT) {
        NSString *drop = [_editOrder objectAtIndex:0];
        [_editOrder removeObjectAtIndex:0];
        [_editShown removeObjectForKey:drop];
    }
}

// Memory side of the edit row -> target link (capped like the shown edits).
- (void)noteEditTarget:(NSString *)target forRow:(NSString *)row {
    if (![_editTarget objectForKey:row]) {
        [_editTargetOrder addObject:row];
    }
    [_editTarget setObject:target forKey:row];
    while ([_editTargetOrder count] > RXST_EDITS_PER_CHAT) {
        [_editTarget removeObjectForKey:[_editTargetOrder objectAtIndex:0]];
        [_editTargetOrder removeObjectAtIndex:0];
    }
}

// R5 6.5 aliases, unchanged: the new text is an alias of every message from the edit's author in the 15 min
// before it (reaction matching). With `real` (Show Edits on, not typed here) it is also the shown edit
// (DESIGN 4.5): candidates are those messages with a real text part, scored against their CURRENT text
// (after earlier edits); the best wins at >= 0.5, else the newest, but only when the whole 15 min before
// the edit is loaded (`allLoaded`: no Load Earlier). A name-first row whose name is not the sender's first
// name (my own rows included) needs RXST_EDIT_STRONG_SIM, never takes the newest and adds no aliases;
// unapplied, the caller makes it an ordinary candidate ("Ok I edited ..." parses the same). One text part per
// edit (the best scoring one), at most RXST_EDIT_MAX per message, a later edit wins; an edit row never moves to
// another bubble while its first target is not loaded (the link is kept in the matched list as "eg", so it
// survives relaunch, eviction and Show Edits off). Returns YES when applied (the row is then hidden).
- (BOOL)applyEdit:(RXStRecord *)e real:(BOOL)real allLoaded:(BOOL)allLoaded {
    _stats.edits++;
    NSString *alias = RXStNorm(e.event.editText);
    NSString *aliasTrim = RXStTrim(alias);
    if (![aliasTrim length] || !e.hasDate) {
        if (real) {
            [self keepEdit:e because:@"no text"];
        }
        return NO;
    }
    // Name-first rows: the sender's own first name is trusted like "Edited to". Any other name (a contact saved
    // under another name, an unsaved number, or a sentence like "Ok I edited ...", mine too: my own rows are
    // never name-checked) must be a close rewrite of the author's recent message (RXST_EDIT_STRONG_SIM), never
    // takes the newest fallback and adds no aliases.
    BOOL nameFirst = [e.event.editName length] > 0;
    BOOL nameTrusted = !nameFirst || e.editNameMatch;
    if (!nameTrusted && !real) {
        return NO;
    }
    NSString *aliasColl = RXStCollapse(alias);
    NSString *author = [self who:e.reactor];
    NSString *lower = real ? [alias lowercaseString] : nil;
    NSInteger n = (NSInteger)[_cands count];
    NSInteger lo = MAX((NSInteger)0, n - RXST_WINDOW);
    NSUInteger aliased = 0;
    NSUInteger scored = 0;
    RXStRecord *newest = nil;
    NSInteger newestPart = NSNotFound;
    double newestSim = 0;
    RXStRecord *best = nil;
    NSInteger bestPart = NSNotFound;
    double bestSim = -1.0;
    for (NSInteger i = n - 1; i >= lo; i--) {
        RXStRecord *c = [_cands objectAtIndex:(NSUInteger)i];
        if (c.isEdit || !c.hasDate || ![c.segs count]) {
            continue;                                 // an unapplied name-first row: never an alias holder or target
        }
        NSTimeInterval d = e.t - c.t;
        if (d < -RXST_EDIT_SLACK || d > RXST_EDIT_WINDOW) {
            continue;
        }
        if (![[self who:c.reactor] isEqualToString:author]) {
            continue;
        }
        if (nameTrusted) {
            if (!c.aliases) {
                c.aliases = [NSMutableArray array];
            }
            if (![c.aliases containsObject:alias]) {
                [c.aliases addObject:alias];          // aliases accumulate (R5 6.5)
                RXStIndex(_idxAlias, alias, c, c.firstTextKey);
                RXStIndex(_idxAliasTrim, aliasTrim, c, c.firstTextKey);
                RXStIndex(_idxColl, aliasColl, c, c.firstTextKey);
                aliased++;
            }
        }
        if (!real || scored >= RXST_EDIT_CANDS) {
            continue;
        }
        double partSim = -1.0;
        NSInteger part = NSNotFound;
        for (RXStSeg *seg in c.segs) {
            if (!seg.fromPart || ![seg.trim length]) {
                continue;                             // pins live on real text parts only
            }
            double sim = RXStEditSim(lower, [(seg.cur ? seg.cur : seg.norm) lowercaseString]);
            if (sim > partSim) {                      // ties: the lower part key
                partSim = sim;
                part = seg.partKey;
            }
        }
        if (part == NSNotFound) {
            continue;
        }
        scored++;
        if (!newest) {
            newest = c;
            newestPart = part;
            newestSim = partSim;
        }
        if (partSim > bestSim) {                      // ties: the newer candidate
            best = c;
            bestPart = part;
            bestSim = partSim;
        }
    }
    if (!real) {
        if (aliased) {
            RXLog(@"store #%04lx: edit row %@ aliased %lu messages", RXStChatTag(_chatKey), RXGUIDTail(e.guid),
                  (unsigned long)aliased);
        }
        return NO;
    }

    RXStRecord *target = nil;
    NSInteger pk = NSNotFound;
    double sim = 0;
    NSString *rule = nil;
    // The newest fallback needs the whole window loaded: its original may be just above Load Earlier.
    BOOL covered = allLoaded || (_buildHasFirstT && _buildFirstT <= e.t - RXST_EDIT_WINDOW);
    BOOL newestOK = !nameFirst || e.editNameMatch;   // "Edited to", or a name-first row with the sender's name
    if (best && bestSim >= (nameTrusted ? RXST_EDIT_MIN_SIM : RXST_EDIT_STRONG_SIM)) {
        target = best;
        pk = bestPart;
        sim = bestSim;
        rule = @"sim";
    } else if (newest && covered && newestOK) {
        target = newest;
        pk = newestPart;
        sim = newestSim;
        rule = nameFirst ? @"name" : @"newest";
    }
    if (!target) {
        NSString *why = @"no target";
        if (!nameTrusted) {
            why = @"name";
        } else if (newest) {
            why = covered ? @"low sim" : @"not loaded";
        }
        [self keepEdit:e because:why];
        return NO;
    }
    // First applied to another bubble that is not loaded now (deleted, or above Load Earlier): stays visible.
    // The persisted link covers a relaunch, an evicted store and Show Edits off (memory map empty).
    NSString *was = [e.guid length] ? [_editTarget objectForKey:e.guid] : nil;
    if (!was && [e.guid length]) {
        id pg = [[self listedEntry:e.guid] objectForKey:@"eg"];
        if ([pg isKindOfClass:[NSString class]] && [(NSString *)pg length]) {
            was = pg;
            [self noteEditTarget:was forRow:e.guid];
        }
    }
    if (was &&![was isEqualToString:target.guid] && ![(RXStRecord *)[_byGUID objectForKey:was] isCandidate]) {
        [self keepEdit:e because:@"target gone"];
        return NO;
    }
    RXStSeg *seg = nil;
    for (RXStSeg *candidate in target.segs) {
        if (candidate.fromPart && candidate.partKey == pk) {
            seg = candidate;
            break;
        }
    }
    if (!seg) {
        [self keepEdit:e because:@"no target"];
        return NO;
    }
    // The same edit again (the own-number chat's second copy) changes nothing but is still folded.
    if (![seg.cur isEqualToString:alias]) {
        if (target.editCount >= RXST_EDIT_MAX) {
            [self keepEdit:e because:@"max"];          // never falls over to another bubble
            return NO;
        }
        seg.cur = alias;
        seg.shown = RXStStripFFFC(e.event.editText);
        target.editCount = target.editCount + 1;
        RXStIndex(_idxEdited, alias, target, pk);           // a reaction quoting the shown text lands here
        RXStIndex(_idxEditedTrim, aliasTrim, target, pk);
    }
    target.editRule = rule;
    target.editSim = sim;
    target.editCands = scored;
    e.editApplied = YES;
    e.targetGUID = target.guid;
    e.targetPart = pk;
    if ([e.guid length] && ![was isEqualToString:target.guid]) {
        [self noteEditTarget:target.guid forRow:e.guid];
        // Persisted with the matched list (its own "eg" key; edit rows are never looked up as reactions).
        NSMutableDictionary *pe = [NSMutableDictionary dictionaryWithObject:[NSDate date] forKey:@"t"];
        [pe setObject:target.guid forKey:@"eg"];
        [RXStMatched() setEntry:pe forChat:_chatKey key:e.guid];
    }
    _stats.editsApplied++;
    [self publishEditFor:target];
    return YES;
}

- (void)markFailed:(RXStRecord *)r {
    r.failed = YES;
    if (r.matched) {
        r.matched = NO;
        [self invalidateTarget:r.targetGUID];
    }
    if (r.pending) {
        r.pending = NO;
        [_pending removeObject:r];
    }
    [_unmatched removeObject:r];
    [self forgetMatch:r.guid];
}

- (BOOL)ingestReaction:(RXStRecord *)r allowHide:(BOOL)allowHide {
    _stats.reactions++;
    NSDictionary *listed = [self listedEntry:r.guid];
    if (![r.hintGUID length]) {
        id g = [listed objectForKey:@"g"];
        if ([g isKindOfClass:[NSString class]] && [(NSString *)g length]) {
            id k = [listed objectForKey:@"k"];
            r.hintGUID = g;
            r.hintPart = [k isKindOfClass:[NSNumber class]] ? [(NSNumber *)k integerValue] : NSNotFound;
        }
    }
    RXStRef *ref = [self findTargetFor:r];
    if (ref) {
        [self apply:r to:ref.rec part:ref.partKey];
        _stats.matched++;
        [self rememberMatch:r];
        if (allowHide) {
            r.hidden = YES;
            _stats.hidden++;
            return YES;
        }
        [self requestReload:r.guid];   // counted but its rows are being added (own Send path): fold on reload
        return NO;
    }
    if (listed && allowHide) {
        // Matched before (target deleted, outside the loaded history, or appended later in this build).
        r.hidden = YES;
        r.pending = YES;
        [_pending addObject:r];
        _stats.pending++;
        _stats.hidden++;
        return YES;
    }
    if (r.hasDate) {
        [_unmatched addObject:r];
        if ([_unmatched count] > RXST_MAX_UNMATCHED) {
            [_unmatched removeObjectAtIndex:0];
        }
    }
    return NO;
}

// DESIGN 4.2 (v2.1): list-hidden reactions with no target yet, re-matched as later records arrive (no reload).
- (void)rematchPendingWith:(RXStRecord *)c {
    if (![_pending count]) {
        return;
    }
    NSMutableArray *done = [NSMutableArray array];
    for (RXStRecord *r in _pending) {
        BOOL hinted = [r.hintGUID length] && [r.hintGUID isEqualToString:c.guid];
        if (!hinted) {
            if (!r.hasDate || !c.hasDate) {
                continue;
            }
            NSTimeInterval d = c.t - r.t;
            if (d > RXST_SKEW_PRUNE) {
                [done addObject:r];          // can no longer match: stays hidden without a badge
                continue;
            }
            if (d > RXST_SKEW || d < -RXST_SKEW) {
                continue;
            }
        }
        NSInteger pk = [self partIn:c forReaction:r];
        if (pk == NSNotFound) {
            continue;
        }
        [self apply:r to:c part:pk];
        _stats.matched++;
        [done addObject:r];
    }
    if ([done count]) {
        [_pending removeObjectsInArray:done];
    }
}

// DESIGN 4.2 late match: a visible unmatched reaction from the last 60 s now matches -> matched list
// first, then one reload per GUID.
- (void)lateMatchWith:(RXStRecord *)c {
    if (![_unmatched count] || !c.hasDate) {
        return;
    }
    NSMutableArray *done = [NSMutableArray array];
    for (RXStRecord *r in _unmatched) {
        if (r.matched || r.failed || !r.hasDate) {
            [done addObject:r];
            continue;
        }
        NSTimeInterval d = c.t - r.t;
        if (d > RXST_SKEW_PRUNE) {
            [done addObject:r];
            continue;
        }
        if (d > RXST_SKEW || d < -RXST_SKEW) {
            continue;
        }
        NSInteger pk = [self partIn:c forReaction:r];
        if (pk == NSNotFound) {
            continue;
        }
        [self apply:r to:c part:pk];
        [self rememberMatch:r];
        [self requestReload:r.guid];
        _stats.matched++;
        _stats.late++;
        [done addObject:r];
        RXLog(@"store #%04lx: late match %@ (%.1f s)", RXStChatTag(_chatKey), RXGUIDTail(r.guid), (double)d);
    }
    if ([done count]) {
        [_unmatched removeObjectsInArray:done];
    }
}

- (BOOL)reingest:(RXStRecord *)r failed:(BOOL)failed allowHide:(BOOL)allowHide {
    if (r.isEdit) {
        r.hidden = allowHide && r.editApplied;
        return r.hidden;
    }
    if (failed && !r.failed && r.isReaction) {
        [self markFailed:r];
        _stats.failed++;
    }
    BOOL hide = allowHide && r.isReaction && !r.failed && (r.matched || r.pending);
    if (!hide && r.isReaction && r.matched && !r.failed) {
        [self requestReload:r.guid];
    }
    r.hidden = hide;
    return hide;
}

- (BOOL)ingestMessage:(CKIMMessage *)msg allowHide:(BOOL)allowHide badges:(BOOL)badges edits:(BOOL)edits {
    if (!msg) {
        return NO;
    }
    if (RXStBool(msg, @selector(isTypingIndicator)) || RXStBool(msg, @selector(isPlaceholder))) {
        return NO;
    }
    NSString *guid = RXStString(msg, @selector(guid));
    if (![guid length]) {
        return NO;
    }
    BOOL fromMe = RXStBool(msg, @selector(isFromMe));
    // Never hide or count an outgoing reaction whose send failed (DESIGN 4.2).
    BOOL failed = fromMe && (RXStBool(msg, @selector(failedSend)) || RXStBool(msg, @selector(partiallyFailedSend)));

    RXStRecord *known = [_byGUID objectForKey:guid];
    if (known) {
        return [self reingest:known failed:failed allowHide:allowHide];
    }

    RXStRecord *r = [self recordForMessage:msg guid:guid fromMe:fromMe failed:failed];
    r.seq = ++_clock;
    [_byGUID setObject:r forKey:guid];
    _stats.messages++;
    if (r.hasDate && (!_buildHasFirstT || r.t < _buildFirstT)) {
        _buildFirstT = r.t;
        _buildHasFirstT = YES;
    }
    [self noteDuplicate:r];
    [self takeOptimisticFor:r];

    if (r.isEdit) {
        // Hidden only when Show Edits applied it to a loaded message (DESIGN 4.5); a row typed on this iPhone
        // (own Send path, allowHide NO) is remembered and never treated as an edit.
        if (edits && !allowHide && ![_localSends containsObject:guid]) {
            [_localSends addObject:guid];
            if ([_localSends count] > RXST_LOCAL_SENDS) {
                [_localSends removeObjectAtIndex:0];
            }
        }
        BOOL real = edits && allowHide && RXStRawTextAvailable() && ![_localSends containsObject:guid];
        BOOL allLoaded = NO;
        if (real) {
            CKConversation *conv = [msg respondsToSelector:@selector(conversation)] ? [msg conversation] : nil;
            allLoaded = conv && [conv respondsToSelector:@selector(moreMessagesToLoad)] && ![conv moreMessagesToLoad];
        }
        BOOL applied = [self applyEdit:r real:real allLoaded:allLoaded];
        r.hidden = applied;
        if (applied) {
            _stats.hidden++;
            return YES;
        }
        if (!r.event.editName) {
            return NO;                          // "Edited to" rows are never candidates (R5 6.5)
        }
        // An unapplied name-first row may be an ordinary sentence ("I edited ..."): a candidate, as in 2.1.2.
    }
    if (r.isReaction) {
        if (!badges) {
            return NO;                          // Show Reactions off (Show Edits alone ingests): stays text
        }
        if (r.failed) {
            _stats.failed++;
            [self forgetMatch:guid];
            return NO;
        }
        return [self ingestReaction:r allowHide:allowHide];
    }
    [self addCandidate:r];
    [self rematchPendingWith:r];
    [self lateMatchWith:r];
    return NO;
}

- (BOOL)isHiddenGUID:(NSString *)guid {
    if (![guid length]) {
        return NO;
    }
    RXStRecord *r = [_byGUID objectForKey:guid];
    return r.hidden;
}

- (BOOL)isKnownGUID:(NSString *)guid {
    return [guid length] && [_byGUID objectForKey:guid] != nil;
}

#pragma mark Edits (DESIGN 4.5)

- (NSDictionary *)editsForGUID:(NSString *)guid {
    return [guid length] ? [_editShown objectForKey:guid] : nil;
}

// End of a real rebuild: a shown edit whose message was rebuilt without an applied edit (its edit row is
// gone) is dropped; the transcript then re-runs the build once, so the bubble shows its own text again.
- (void)finishBuild {
    if (![_editShown count]) {
        return;
    }
    NSMutableArray *stale = nil;
    for (NSString *guid in _editShown) {
        RXStRecord *rec = [_byGUID objectForKey:guid];
        if (rec.isCandidate && rec.editCount == 0) {
            if (!stale) {
                stale = [NSMutableArray array];
            }
            [stale addObject:guid];
        }
    }
    for (NSString *guid in stale) {
        [_editShown removeObjectForKey:guid];
        [_editOrder removeObject:guid];
        _editsTouched = YES;
    }
}

// YES when the shown-edit map differs from the last restart / take; one log line per changed message.
- (BOOL)takeEditsChanged {
    if (!_editsTouched) {
        return NO;
    }
    _editsTouched = NO;
    NSMutableSet *keys = [NSMutableSet setWithArray:[_editShown allKeys]];
    if (_editStart) {
        [keys addObjectsFromArray:[_editStart allKeys]];
    }
    NSUInteger changed = 0;
    for (NSString *guid in keys) {
        NSDictionary *now = [_editShown objectForKey:guid];
        NSDictionary *was = [_editStart objectForKey:guid];
        if (now == was || [now isEqualToDictionary:was]) {
            continue;
        }
        changed++;
        if (!now) {
            RXLog(@"store #%04lx: edit on %@ dropped", RXStChatTag(_chatKey), RXGUIDTail(guid));
            continue;
        }
        RXStRecord *rec = [_byGUID objectForKey:guid];
        RXLog(@"store #%04lx: edit shown on %@ (%lu part(s), rule %@, sim %d, %lu cands, n%ld)",
              RXStChatTag(_chatKey), RXGUIDTail(guid), (unsigned long)[now count], rec.editRule ? rec.editRule : @"?",
              (int)(rec.editSim * 100.0 + 0.5), (unsigned long)rec.editCands, (long)rec.editCount);
    }
    _editStart = [_editShown copy];
    return changed > 0;
}

- (NSUInteger)clearEdits {
    NSUInteger n = [_editShown count];
    [_editShown removeAllObjects];
    [_editOrder removeAllObjects];
    [_editKept removeAllObjects];
    [_editTarget removeAllObjects];
    [_editTargetOrder removeAllObjects];
    _editStart = nil;
    _editsTouched = NO;
    return n;
}

#pragma mark Badges

- (RXReaction *)mineForGUID:(NSString *)guid partKey:(NSInteger)partKey votes:(NSDictionary *)votes {
    RXStOptimistic *latest = nil;
    for (RXStOptimistic *o in _optimistic) {
        if (o.partKey == partKey && [o.targetGUID isEqualToString:guid] && (!latest || o.seq > latest.seq)) {
            latest = o;
        }
    }
    RXKind kind = RXKindNone;
    NSString *emoji = nil;
    if (latest) {                                  // a pending pick always wins until its echo or failure
        if (!latest.removal) {
            kind = latest.kind;
            emoji = latest.emoji;
        }
    } else {
        RXStVote *v = [votes objectForKey:@"me"];
        if (v) {
            kind = v.kind;
            emoji = v.emoji;
        }
    }
    if (kind == RXKindNone) {
        return nil;
    }
    RXReaction *mine = [[RXReaction alloc] init];
    mine.kind = kind;
    mine.emoji = emoji;
    mine.count = 1;
    mine.names = [NSArray array];
    mine.isMine = YES;
    return mine;
}

- (RXBadgeModel *)badgeForGUID:(NSString *)guid partKey:(NSInteger)partKey {
    if (![guid length]) {
        return nil;
    }
    NSDictionary *votes = [[self votesFor:guid] objectForKey:[NSNumber numberWithInteger:partKey]];
    RXReaction *mine = [self mineForGUID:guid partKey:partKey votes:votes];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *who in votes) {
        if ([who isEqualToString:@"me"]) {
            continue;
        }
        RXStVote *v = [votes objectForKey:who];
        if (v) {
            [list addObject:v];
        }
    }
    if (![list count] && !mine) {
        return nil;
    }
    [list sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger sa = [(RXStVote *)a seq];
        NSInteger sb = [(RXStVote *)b seq];
        if (sa == sb) {
            return NSOrderedSame;
        }
        return sa > sb ? NSOrderedAscending : NSOrderedDescending;    // newest first
    }];
    NSMutableArray *others = [NSMutableArray array];
    NSMutableDictionary *byKind = [NSMutableDictionary dictionary];
    for (RXStVote *v in list) {
        NSString *key = RXStGroupKey(v.kind, v.emoji);
        RXReaction *g = [byKind objectForKey:key];
        if (!g) {
            g = [[RXReaction alloc] init];
            g.kind = v.kind;
            g.emoji = v.emoji;
            g.count = 0;
            g.names = [NSArray array];
            g.isMine = NO;
            [byKind setObject:g forKey:key];
            [others addObject:g];                    // kinds ordered by their newest vote
        }
        g.count = g.count + 1;
        g.names = [g.names arrayByAddingObject:(v.name ? v.name : @"")];
    }
    RXBadgeModel *model = [[RXBadgeModel alloc] init];
    model.others = others;
    model.mine = mine;
    return model;
}

- (RXReaction *)myReactionForGUID:(NSString *)guid partKey:(NSInteger)partKey {
    if (![guid length]) {
        return nil;
    }
    NSDictionary *votes = [[self votesFor:guid] objectForKey:[NSNumber numberWithInteger:partKey]];
    return [self mineForGUID:guid partKey:partKey votes:votes];
}

- (NSSet *)takeDirtyGUIDs {
    NSSet *out = [_dirty copy];
    [_dirty removeAllObjects];
    return out ? out : [NSSet set];
}

- (BOOL)takeNeedsReload {
    BOOL r = _needsReload;
    _needsReload = NO;
    return r;
}

#pragma mark Optimistic votes / failures

- (void)addOptimisticKind:(RXKind)kind emoji:(NSString *)emoji removal:(BOOL)removal
                forGUID:(NSString *)guid partKey:(NSInteger)partKey sentGUID:(NSString *)sentGUID {
    if (![guid length] || ![sentGUID length]) {
        return;                                    // without the sent GUID the echo could never replace it
    }
    if (!removal && kind == RXKindNone) {
        return;
    }
    if ([_byGUID objectForKey:sentGUID]) {
        [_dirty addObject:guid];                   // the echo was already ingested: the real vote is in effect
        return;
    }
    RXStOptimistic *o = [[RXStOptimistic alloc] init];
    o.sentGUID = sentGUID;
    o.targetGUID = guid;
    o.partKey = partKey;
    o.kind = kind;
    o.emoji = emoji;
    o.removal = removal;
    o.seq = ++_clock;
    [_optimistic addObject:o];
    while ([_optimistic count] > RXST_MAX_OPTIMISTIC) {
        RXStOptimistic *old = [_optimistic objectAtIndex:0];
        if ([old.targetGUID length]) {
            [_dirty addObject:old.targetGUID];
        }
        [_optimistic removeObjectAtIndex:0];
    }
    [_dirty addObject:guid];
}

- (void)messageFailed:(CKIMMessage *)msg {
    NSString *guid = RXStString(msg, @selector(guid));
    if (![guid length]) {
        return;
    }
    NSMutableArray *drop = nil;
    for (RXStOptimistic *o in _optimistic) {
        if ([o.sentGUID isEqualToString:guid]) {
            if (!drop) {
                drop = [NSMutableArray array];
            }
            [drop addObject:o];
            if ([o.targetGUID length]) {
                [_dirty addObject:o.targetGUID];
            }
        }
    }
    if (drop) {
        [_optimistic removeObjectsInArray:drop];
    }
    RXStRecord *r = [_byGUID objectForKey:guid];
    if (r.isReaction) {
        BOOL wasHidden = r.hidden;
        if (!r.failed) {
            [self markFailed:r];
            _stats.failed++;
        }
        if (wasHidden) {
            _needsReload = YES;                    // the reload shows the stock Not Delivered row
        }
        RXLog(@"store #%04lx: reaction %@ failed%@", RXStChatTag(_chatKey), RXGUIDTail(guid),
              wasHidden ? @", shown on reload" : @"");
    } else if (!r) {
        [self forgetMatch:guid];
    }
}

#pragma mark Reply links

- (void)setReplyLink:(RXReplyLink *)link forReplyGUID:(NSString *)replyGUID {
    if (!link || ![replyGUID length] || ![link.parentGUID length]) {
        return;
    }
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    [e setObject:link.parentGUID forKey:@"p"];
    [e setObject:[NSNumber numberWithInteger:link.partKey] forKey:@"i"];
    [e setObject:RXStKindName(link.kind) forKey:@"k"];
    [e setObject:RXStCut(link.snippet ? link.snippet : @"", RXST_SNIPPET_MAX) forKey:@"s"];
    [e setObject:[NSNumber numberWithBool:link.parentIsMine] forKey:@"m"];
    [e setObject:(link.parentName ? link.parentName : @"") forKey:@"n"];
    [e setObject:(link.date ? link.date : [NSDate date]) forKey:@"t"];
    NSDictionary *entry = [e copy];
    [RXStReplies() setEntry:entry forChat:_chatKey key:replyGUID];
    RXReplyLink *stored = RXStLinkFromEntry(entry);
    if (stored) {
        [_linkCache setObject:stored forKey:replyGUID];
    }
    RXLog(@"store #%04lx: reply link %@ -> %@ (%@, snippet %lu)", RXStChatTag(_chatKey), RXGUIDTail(replyGUID),
          RXGUIDTail(link.parentGUID), RXStKindName(link.kind), (unsigned long)[(NSString *)[entry objectForKey:@"s"] length]);
}

- (RXReplyLink *)replyLinkForGUID:(NSString *)replyGUID {
    if (![replyGUID length]) {
        return nil;
    }
    RXReplyLink *link = [_linkCache objectForKey:replyGUID];
    if (link) {
        return link;
    }
    NSDictionary *entry = [RXStReplies() entryForChat:_chatKey key:replyGUID];
    link = entry ? RXStLinkFromEntry(entry) : nil;
    if (link) {
        [_linkCache setObject:link forKey:replyGUID];
    }
    return link;
}

@end
