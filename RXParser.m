// Reactions 2.0 - RXParser.m
//
// Tapback-text parser (R5 section 5), normaliser N(x) (R5 section 6.2), Apple's US-English send strings
// (R5 section 7) and the parser self-test (R5 section 8 vectors + compose round-trips).
//
// A faithful port of research/R5-data/parser_check.py to NSRegularExpression:
//  * pre-normalisation strips only U+FEFF, U+200E, U+200F, U+2066-2069 at both ends (never spaces);
//  * Google Messages SMS markers, then edit compat rows, then the reply prefix, then the verb heads;
//  * heads in R5 order: removals (R1-R8) before adds (A1-A8); fixed phrases before the generic emoji forms;
//  * en-US plus en-GB/AU/IN ("Emphasised", "Removed an exclamation mark from");
//  * an emoji token must contain no ASCII letter (so "Reacted with ..." / "Removed a heart ..." never read as emoji);
//  * quoted tails are greedy to the LAST U+201D (inner curly quotes survive); straight quotes for third parties;
//  * exact noun table; "1 <App> Message", the three special balloons, unquoted generic tails ("Loved it!")
//    and empty or U+FFFC/whitespace-only quotes are all RXTargetUnknown (unmatchable, the row stays visible);
//  * a quote ending in U+2026 sets truncated + prefix (quote minus the ellipsis minus trailing whitespace).
// Every pattern is compiled once (dispatch_once) with NSRegularExpressionDotMatchesLineSeparators and matched
// with NSMatchingAnchored. Thread-safe after setup (immutable statics). Logs never contain message text.
//
// Deliberate differences from parser_check.py (all conservative):
//  * "Replied to a message: ..." returns nil: RXEvent has no reply-prefix shape and R5 5.5 keeps such rows
//    visible, which is exactly what nil means.
//  * Google-marker events go through the same quote rules as quoted tails (an empty quote is unmatchable,
//    a trailing U+2026 marks truncation) and need a non-empty, letter-free emoji token.
//  * Edit rows set editText only (RXShared.h: "editText set; nothing else").

#import "RXShared.h"

#define RX_QUOTE_MAX_UNITS      50   // R5 7.3: quotes longer than this are cut (INFERENCE; tunable)
#define RX_QUOTE_MIN_WORD_CUT   25   // a word-boundary cut must keep at least this many units, else hard cut,
                                     // so our own echo keeps a long, specific prefix (matcher needs >= 8)

#pragma mark - RXEvent

@implementation RXEvent

// Safe for logs: kinds, flags and lengths only - never the quote, emoji or edit text.
- (NSString *)description
{
    return [NSString stringWithFormat:@"<RXEvent edit=%d removal=%d kind=%d target=%d qlen=%lu trunc=%d elen=%lu>",
            (int)self.isEdit, (int)self.isRemoval, (int)self.kind, (int)self.target,
            (unsigned long)[self.quote length], (int)self.truncated, (unsigned long)[self.editText length]];
}

@end

#pragma mark - Pattern tables (R5 5.2)

typedef struct {
    char lead;              // first literal character after ^ (cheap exact pre-filter)
    const char *pattern;    // ICU, ASCII only
    BOOL removal;
    RXKind kind;
} RXHeadSpec;

// Order is normative: removals first, fixed phrases before the generic emoji forms.
static const RXHeadSpec kRXHeads[] = {
    { 'R', "^Removed a heart from ",                  YES, RXKindLove },      // R1
    { 'R', "^Removed a like from ",                   YES, RXKindLike },      // R2
    { 'R', "^Removed a dislike from ",                YES, RXKindDislike },   // R3
    { 'R', "^Removed a laugh from ",                  YES, RXKindLaugh },     // R4
    { 'R', "^Removed an exclamation(?: mark)? from ", YES, RXKindEmph },      // R5 (US / GB+IN)
    { 'R', "^Removed a question mark from ",          YES, RXKindQuestion },  // R6
    { 'R', "^Removed a sticker from ",                YES, RXKindSticker },   // R7
    { 'R', "^Removed (?:a )?(\\S+) from ",            YES, RXKindEmoji },     // R8 ("a " = rustpush)
    { 'L', "^Loved ",                                 NO,  RXKindLove },      // A1
    { 'L', "^Liked ",                                 NO,  RXKindLike },      // A2
    { 'D', "^Disliked ",                              NO,  RXKindDislike },   // A3
    { 'L', "^Laughed at ",                            NO,  RXKindLaugh },     // A4
    { 'E', "^Emphasi[sz]ed ",                         NO,  RXKindEmph },      // A5 (US / GB+AU+IN)
    { 'Q', "^Questioned ",                            NO,  RXKindQuestion },  // A6
    { 'R', "^Reacted with a sticker to {1,2}",        NO,  RXKindSticker },   // A7
    { 'R', "^Reacted (\\S+) to {1,2}",                NO,  RXKindEmoji },     // A8 (double space = rustpush)
};
#define RX_HEAD_COUNT (sizeof(kRXHeads) / sizeof(kRXHeads[0]))

// Name-first forms ("Taylor loved <q>X<q>", "Mom removed a heart from <q>X<q>"): newer iPhones send these to
// iOS 6 as well (seen on device 2026-10-08). Tried only when no plain head matched and the text contains one
// of the verbs. The pattern is ^(name) <verb>, where name is 1-64 characters with no line break or quote;
// the name itself is unused (the reactor's identity comes from the message's sender). Emoji forms carry the
// emoji in $2. Order mirrors kRXHeads: removals first, fixed phrases before the generic emoji forms.
typedef struct {
    const char *verb;       // ICU, ASCII only; appended after "^(name) "
    BOOL removal;
    RXKind kind;
} RXNamedSpec;

static const RXNamedSpec kRXNamedHeads[] = {
    { "removed a heart from ",                  YES, RXKindLove },
    { "removed a like from ",                   YES, RXKindLike },
    { "removed a dislike from ",                YES, RXKindDislike },
    { "removed a laugh from ",                  YES, RXKindLaugh },
    { "removed an exclamation(?: mark)? from ", YES, RXKindEmph },
    { "removed a question mark from ",          YES, RXKindQuestion },
    { "removed a sticker from ",                YES, RXKindSticker },
    { "removed (?:a )?(\\S+) from ",            YES, RXKindEmoji },
    { "loved ",                                 NO,  RXKindLove },
    { "liked ",                                 NO,  RXKindLike },
    { "disliked ",                              NO,  RXKindDislike },
    { "laughed at ",                            NO,  RXKindLaugh },
    { "emphasi[sz]ed ",                         NO,  RXKindEmph },
    { "questioned ",                            NO,  RXKindQuestion },
    { "reacted with a sticker to {1,2}",        NO,  RXKindSticker },
    { "reacted (\\S+) to {1,2}",                NO,  RXKindEmoji },
};
#define RX_NAMED_COUNT (sizeof(kRXNamedHeads) / sizeof(kRXNamedHeads[0]))

static NSRegularExpression *sNamedRegex[RX_NAMED_COUNT];
static NSArray *sNamedNeedles;                // " loved ", " removed ", ... (cheap pre-filter)

static NSRegularExpression *sHeadRegex[RX_HEAD_COUNT];
static NSRegularExpression *sQuoteCurly;      // ^U+201C(.*)U+201D$  greedy: to the last U+201D
static NSRegularExpression *sQuoteStraight;   // ^"(.*)"$
static NSRegularExpression *sEditCurly;       // Apple
static NSRegularExpression *sEditStraight;    // mautrix via BlueBubbles
static NSRegularExpression *sEditColon;       // BlueBubbles app
static NSRegularExpression *sGoogleAdd;       // R5 5.6
static NSRegularExpression *sGoogleRemove;
static NSDictionary *sNouns;                  // exact noun phrase -> @(RXTarget)
static NSCharacterSet *sEdgeSet;              // U+FEFF, U+200E, U+200F, U+2066-2069 (pre-normalisation, ends only)
static NSCharacterSet *sInvisibleSet;         // the above plus U+FFFC (N(x), everywhere)
static NSCharacterSet *sASCIILetters;         // [A-Za-z]

static NSString *RXNounForTarget(RXTarget target);

static NSRegularExpression *RXCompile(NSString *pattern, NSUInteger *failures)
{
    NSError *error = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:NSRegularExpressionDotMatchesLineSeparators
                                                                          error:&error];
    if (!re) {
        (*failures)++;
        RXLog(@"parser: pattern %lu chars failed to compile (error %ld)",
              (unsigned long)[pattern length], (long)[error code]);
    }
    return re;
}

static void RXParserSetup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUInteger failures = 0;
        for (size_t i = 0; i < RX_HEAD_COUNT; i++) {
            NSString *pattern = [NSString stringWithUTF8String:kRXHeads[i].pattern];
            sHeadRegex[i] = pattern ? RXCompile(pattern, &failures) : nil;
        }
        // Name group: 1-64 characters, none of LF, CR, U+201C, U+201D or a straight quote (built with %C so the
        // source stays ASCII without \u escapes). Lazy, so the first matching verb wins.
        NSString *nameGroup = [NSString stringWithFormat:@"^([^%C%C%C%C\"]{1,64}?) ",
                               (unichar)0x000A, (unichar)0x000D, (unichar)0x201C, (unichar)0x201D];
        for (size_t i = 0; i < RX_NAMED_COUNT; i++) {
            NSString *verb = [NSString stringWithUTF8String:kRXNamedHeads[i].verb];
            sNamedRegex[i] = verb ? RXCompile([nameGroup stringByAppendingString:verb], &failures) : nil;
        }
        sNamedNeedles = [NSArray arrayWithObjects:@" loved ", @" liked ", @" disliked ", @" laughed at ",
                         @" emphasized ", @" emphasised ", @" questioned ", @" removed ", @" reacted ", nil];
        sQuoteCurly    = RXCompile(@"^\\u201C(.*)\\u201D$", &failures);
        sQuoteStraight = RXCompile(@"^\"(.*)\"$", &failures);
        sEditCurly     = RXCompile(@"^Edited to \\u201C(.*)\\u201D$", &failures);
        sEditStraight  = RXCompile(@"^Edited to \"(.*)\"$", &failures);
        sEditColon     = RXCompile(@"^Edited to: '(.*)'$", &failures);
        sGoogleAdd     = RXCompile(@"^\\u200A[^\\u200B\\u200A]*\\u200B([^\\u200B]*)\\u200B[^\\u200B\\u200A]*\\u200A(.*)\\u200A[^\\u200B\\u200A]*\\u200A$", &failures);
        sGoogleRemove  = RXCompile(@"^\\u200A[^\\u200C\\u200A]*\\u200C([^\\u200C]*)\\u200C[^\\u200C\\u200A]*\\u200A(.*)\\u200A[^\\u200C\\u200A]*\\u200A$", &failures);
        if (failures > 0) {
            RXLogOnce(@"parser.compile", [NSString stringWithFormat:@"parser: %lu pattern(s) unavailable; those forms stay visible text",
                                          (unsigned long)failures]);
        }

        // Exact noun table (R5 5.3), built from the send table so both directions agree.
        // "a Photo Message" / "a Handwritten Message" / "a Digital Touch Message" and "1 <App> Message"
        // are deliberately absent: they fall through to RXTargetUnknown (unmatchable on iOS 6).
        NSMutableDictionary *nouns = [NSMutableDictionary dictionary];
        for (int t = (int)RXTargetImage; t <= (int)RXTargetOrder; t++) {
            NSString *noun = RXNounForTarget((RXTarget)t);
            if (noun) {
                [nouns setObject:[NSNumber numberWithInt:t] forKey:noun];
            }
        }
        sNouns = [nouns copy];

        NSMutableCharacterSet *edge = [[NSMutableCharacterSet alloc] init];
        [edge addCharactersInRange:NSMakeRange(0xFEFF, 1)];     // BOM / ZWNBSP
        [edge addCharactersInRange:NSMakeRange(0x200E, 2)];     // LRM, RLM
        [edge addCharactersInRange:NSMakeRange(0x2066, 4)];     // LRI, RLI, FSI, PDI
        sEdgeSet = [edge copy];
        [edge addCharactersInRange:NSMakeRange(0xFFFC, 1)];     // object replacement character
        sInvisibleSet = [edge copy];

        NSMutableCharacterSet *letters = [[NSMutableCharacterSet alloc] init];
        [letters addCharactersInRange:NSMakeRange('A', 26)];
        [letters addCharactersInRange:NSMakeRange('a', 26)];
        sASCIILetters = [letters copy];
    });
}

#pragma mark - Small helpers

static NSString *RXPlainString(id obj)
{
    if ([obj isKindOfClass:[NSString class]]) {
        return obj;
    }
    if ([obj isKindOfClass:[NSAttributedString class]]) {
        return [(NSAttributedString *)obj string];
    }
    return nil;
}

static NSTextCheckingResult *RXMatch(NSRegularExpression *re, NSString *s)
{
    if (!re || !s) {
        return nil;
    }
    return [re firstMatchInString:s options:NSMatchingAnchored range:NSMakeRange(0, [s length])];
}

static NSString *RXGroup(NSTextCheckingResult *m, NSString *s, NSUInteger idx)
{
    if (!m || idx >= [m numberOfRanges]) {
        return nil;
    }
    NSRange r = [m rangeAtIndex:idx];
    if (r.location == NSNotFound || NSMaxRange(r) > [s length]) {
        return nil;
    }
    return [s substringWithRange:r];
}

static NSString *RXTrimTrailingWhitespace(NSString *s)
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger end = [s length];
    while (end > 0 && [ws characterIsMember:[s characterAtIndex:end - 1]]) {
        end--;
    }
    return end == [s length] ? s : [s substringToIndex:end];
}

static BOOL RXIsBlankQuote(NSString *q)
{
    NSString *visible = [q stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    visible = [visible stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [visible length] == 0;
}

// R5 5.2: the emoji token ($1 of R8/A8) must contain no ASCII letter.
static BOOL RXEmojiTokenOK(NSString *token)
{
    return [token length] > 0 && [token rangeOfCharacterFromSet:sASCIILetters].location == NSNotFound;
}

#pragma mark - Parser (R5 5)

// R5 5.3 quoted special cases.
static void RXApplyQuote(RXEvent *ev, NSString *q)
{
    ev.target = RXTargetUnknown;
    if (!q || RXIsBlankQuote(q)) {
        return;                                     // Loved "" / only U+FFFC: unmatchable, keep visible
    }
    ev.target = RXTargetText;
    ev.quote = q;
    if ([q hasSuffix:@"\u2026"]) {
        ev.truncated = YES;                         // keep quote too: the original may really end in U+2026
        ev.prefix = RXTrimTrailingWhitespace([q substringToIndex:[q length] - 1]);
    }
}

// R5 5.3 tail: quoted (Apple) -> quoted (straight) -> exact noun -> unknown.
static void RXApplyTail(RXEvent *ev, NSString *tail)
{
    ev.target = RXTargetUnknown;
    if ([tail length] == 0) {
        return;
    }
    NSTextCheckingResult *m = RXMatch(sQuoteCurly, tail);
    if (!m) {
        m = RXMatch(sQuoteStraight, tail);
    }
    if (m) {
        RXApplyQuote(ev, RXGroup(m, tail, 1));
        return;
    }
    NSNumber *noun = [sNouns objectForKey:tail];
    if (noun) {
        ev.target = (RXTarget)[noun intValue];
    }
    // "1 <App> Message", the special balloons, "Loved it!" and anything else: RXTargetUnknown.
}

// R5 5.6 Google Messages SMS markers: $1 = emoji, $2 = quoted text.
static RXEvent *RXParseGoogle(NSString *s, NSRegularExpression *re, BOOL removal)
{
    NSTextCheckingResult *m = RXMatch(re, s);
    if (!m) {
        return nil;
    }
    NSString *emoji = [RXGroup(m, s, 1) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!RXEmojiTokenOK(emoji)) {
        return nil;
    }
    RXEvent *ev = [[RXEvent alloc] init];
    ev.isRemoval = removal;
    ev.kind = RXKindEmoji;
    ev.emoji = emoji;
    RXApplyQuote(ev, RXGroup(m, s, 2));
    return ev;
}

// R5 5.4 edit compat rows; nil when s is not one.
static NSString *RXEditText(NSString *s)
{
    NSTextCheckingResult *m = RXMatch(sEditCurly, s);
    if (!m) {
        m = RXMatch(sEditStraight, s);
    }
    if (!m) {
        m = RXMatch(sEditColon, s);
    }
    return m ? RXGroup(m, s, 1) : nil;
}

// Name-first forms (kRXNamedHeads); nil when s is not one.
static RXEvent *RXParseNamed(NSString *s)
{
    BOOL hasVerb = NO;
    for (NSString *needle in sNamedNeedles) {
        if ([s rangeOfString:needle].location != NSNotFound) {
            hasVerb = YES;
            break;
        }
    }
    if (!hasVerb) {
        return nil;
    }
    for (size_t i = 0; i < RX_NAMED_COUNT; i++) {
        NSTextCheckingResult *m = RXMatch(sNamedRegex[i], s);
        if (!m) {
            continue;
        }
        NSString *emoji = nil;
        if (kRXNamedHeads[i].kind == RXKindEmoji) {
            emoji = RXGroup(m, s, 2);
            if (!RXEmojiTokenOK(emoji)) {
                continue;                           // "removed a cat from": a word, not an emoji
            }
        }
        RXEvent *ev = [[RXEvent alloc] init];
        ev.isRemoval = kRXNamedHeads[i].removal;
        ev.kind = kRXNamedHeads[i].kind;
        ev.emoji = emoji;
        RXApplyTail(ev, [s substringFromIndex:NSMaxRange([m range])]);
        return ev;
    }
    return nil;
}

RXEvent *RXParse(NSString *text)
{
    NSString *s = RXPlainString(text);
    if ([s length] == 0) {
        return nil;
    }
    RXParserSetup();

    // 5.1: strip the invisible direction/BOM marks at both ends only. Spaces are never trimmed, and U+200A
    // (needed by 5.6) is not in the set.
    s = [s stringByTrimmingCharactersInSet:sEdgeSet];
    if ([s length] == 0) {
        return nil;
    }

    // Every plain pattern below is anchored and begins with one of these literal characters; anything else
    // can only be a name-first form.
    unichar c0 = [s characterAtIndex:0];
    if (c0 != 'R' && c0 != 'L' && c0 != 'D' && c0 != 'E' && c0 != 'Q' && c0 != 0x200A) {
        return RXParseNamed(s);
    }

    // 5.6 Google SMS markers (removal first). Nothing else can start with U+200A.
    if (c0 == 0x200A) {
        RXEvent *g = RXParseGoogle(s, sGoogleRemove, YES);
        return g ? g : RXParseGoogle(s, sGoogleAdd, NO);
    }

    // 5.4 edit compat rows.
    if (c0 == 'E') {
        NSString *edited = RXEditText(s);
        if (edited) {
            RXEvent *ev = [[RXEvent alloc] init];
            ev.isEdit = YES;
            ev.editText = edited;
            return ev;
        }
    }

    // 5.5 reply prefix: an ordinary, visible message.
    if (c0 == 'R' && [s hasPrefix:@"Replied to a message:"]) {
        return nil;
    }

    // 5.2 heads in normative order, then 5.3 tail.
    for (size_t i = 0; i < RX_HEAD_COUNT; i++) {
        if ((unichar)kRXHeads[i].lead != c0) {
            continue;
        }
        NSTextCheckingResult *m = RXMatch(sHeadRegex[i], s);
        if (!m) {
            continue;
        }
        NSString *emoji = nil;
        if (kRXHeads[i].kind == RXKindEmoji) {
            emoji = RXGroup(m, s, 1);
            if (!RXEmojiTokenOK(emoji)) {
                continue;                           // a word ("with", "cat"), not an emoji: try the next head
            }
        }
        RXEvent *ev = [[RXEvent alloc] init];
        ev.isRemoval = kRXHeads[i].removal;
        ev.kind = kRXHeads[i].kind;
        ev.emoji = emoji;
        RXApplyTail(ev, [s substringFromIndex:NSMaxRange([m range])]);
        return ev;
    }
    return RXParseNamed(s);                         // e.g. "Laura loved ..." / "Dad reacted ..."
}

#pragma mark - Normalisation (R5 6.2)

NSString *RXNormalize(NSString *s)
{
    NSString *str = RXPlainString(s);
    if (!str) {
        return @"";
    }
    RXParserSetup();
    if ([str rangeOfCharacterFromSet:sInvisibleSet].location != NSNotFound) {
        str = [[str componentsSeparatedByCharactersInSet:sInvisibleSet] componentsJoinedByString:@""];
    }
    NSString *nfc = [str precomposedStringWithCanonicalMapping];
    return nfc ? nfc : str;
}

#pragma mark - Glyph keys

NSString *RXKindKey(RXKind kind)
{
    switch (kind) {
        case RXKindLove:     return @"love";
        case RXKindLike:     return @"like";
        case RXKindDislike:  return @"dislike";
        case RXKindLaugh:    return @"laugh";
        case RXKindEmph:     return @"emph";
        case RXKindQuestion: return @"question";
        case RXKindSticker:  return @"sticker";
        case RXKindEmoji:
        case RXKindNone:
        default:             return nil;
    }
}

#pragma mark - Sending strings (R5 7)

static NSString *RXNounForTarget(RXTarget target)
{
    switch (target) {
        case RXTargetImage:         return @"an image";
        case RXTargetMovie:         return @"a movie";
        case RXTargetAudio:         return @"an audio message";
        case RXTargetAnyAttachment: return @"an attachment";
        case RXTargetContact:       return @"a contact";
        case RXTargetLocation:      return @"a location";
        case RXTargetEvent:         return @"an event";
        case RXTargetPass:          return @"a Wallet pass";
        case RXTargetOrder:         return @"a Wallet order";
        case RXTargetUnknown:
        case RXTargetText:
        default:                    return nil;
    }
}

// An emoji we can send AND read back: non-empty, no whitespace (the parser's token is \S+), no ASCII letter.
static BOOL RXEmojiSendable(NSString *emoji)
{
    return RXEmojiTokenOK(emoji) &&
           [emoji rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound;
}

// The verb phrase without its trailing space ("Loved", "Removed a heart from", "Reacted X to").
static NSString *RXComposeHead(RXKind kind, NSString *emoji, BOOL removal)
{
    switch (kind) {
        case RXKindLove:     return removal ? @"Removed a heart from"          : @"Loved";
        case RXKindLike:     return removal ? @"Removed a like from"           : @"Liked";
        case RXKindDislike:  return removal ? @"Removed a dislike from"        : @"Disliked";
        case RXKindLaugh:    return removal ? @"Removed a laugh from"          : @"Laughed at";
        case RXKindEmph:     return removal ? @"Removed an exclamation from"   : @"Emphasized";
        case RXKindQuestion: return removal ? @"Removed a question mark from"  : @"Questioned";
        case RXKindSticker:  return removal ? @"Removed a sticker from"        : @"Reacted with a sticker to";
        case RXKindEmoji:
            if (!RXEmojiSendable(emoji)) {
                return nil;
            }
            return removal ? [NSString stringWithFormat:@"Removed %@ from", emoji]
                           : [NSString stringWithFormat:@"Reacted %@ to", emoji];
        case RXKindNone:
        default:
            return nil;
    }
}

// Q per R5 7.2/7.3: U+FFFC removed, no trimming; when longer than 50 UTF-16 units, cut at the last space at
// or before unit 50 (or, when that keeps too little, at the composed-sequence boundary at or before unit 50)
// and append " " U+2026. Never splits a surrogate pair or a base + combining-mark sequence.
// nil when the quote is empty or blank (it would parse back as unmatchable).
static NSString *RXComposeQuote(NSString *quoteText)
{
    NSString *q = RXPlainString(quoteText);
    if (!q) {
        return nil;
    }
    q = [q stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    if (RXIsBlankQuote(q)) {
        return nil;
    }
    NSUInteger len = [q length];
    if (len <= RX_QUOTE_MAX_UNITS) {
        return q;
    }

    NSString *kept = nil;
    NSRange space = [q rangeOfString:@" " options:NSBackwardsSearch range:NSMakeRange(0, RX_QUOTE_MAX_UNITS + 1)];
    if (space.location != NSNotFound) {
        NSString *wordCut = RXTrimTrailingWhitespace([q substringToIndex:space.location]);
        if ([wordCut length] >= RX_QUOTE_MIN_WORD_CUT) {
            kept = wordCut;
        }
    }
    if (!kept) {
        NSRange seq = [q rangeOfComposedCharacterSequenceAtIndex:RX_QUOTE_MAX_UNITS];
        NSUInteger cut = seq.location;
        if (cut == 0) {
            cut = NSMaxRange(seq);                  // one giant sequence: keep it whole rather than nothing
        }
        if (cut == 0 || cut >= len) {
            return q;
        }
        kept = RXTrimTrailingWhitespace([q substringToIndex:cut]);
    }
    if ([kept length] == 0) {
        return q;                                   // nothing sensible to keep: send it whole (always matchable)
    }
    return [kept stringByAppendingString:@" \u2026"];
}

NSString *RXComposeReaction(RXKind kind, NSString *emoji, BOOL removal, RXTarget target, NSString *quoteText)
{
    RXParserSetup();
    NSString *head = RXComposeHead(kind, emoji, removal);
    if (!head) {
        return nil;
    }
    if (target == RXTargetText) {
        NSString *q = RXComposeQuote(quoteText);
        if (!q) {
            return nil;
        }
        return [NSString stringWithFormat:@"%@ \u201C%@\u201D", head, q];
    }
    NSString *noun = RXNounForTarget(target);
    if (!noun) {
        return nil;                                 // RXTargetUnknown: nothing Apple would send
    }
    return [NSString stringWithFormat:@"%@ %@", head, noun];
}

#pragma mark - Self-test (R5 8)

enum { RXShapeNil = 0, RXShapeReaction = 1, RXShapeEdit = 2 };

typedef struct {
    const char *ident;                          // vector number for the log (never the text)
    __unsafe_unretained NSString *input;
    int shape;
    BOOL removal;
    RXKind kind;
    __unsafe_unretained NSString *emoji;
    RXTarget target;
    __unsafe_unretained NSString *quote;
    BOOL truncated;
    __unsafe_unretained NSString *text;         // prefix (reaction) or editText (edit)
} RXParseVector;

#define RXV_NIL(n, s)                       { n, s, RXShapeNil, NO, RXKindNone, nil, RXTargetUnknown, nil, NO, nil }
#define RXV_EDIT(n, s, e)                   { n, s, RXShapeEdit, NO, RXKindNone, nil, RXTargetUnknown, nil, NO, e }
#define RXV(n, s, rem, k, emo, tgt, q, tr, p) { n, s, RXShapeReaction, rem, k, emo, tgt, q, tr, p }

static BOOL RXSameString(NSString *a, NSString *b)
{
    if (!a || !b) {
        return a == b;
    }
    return [a isEqualToString:b];
}

static BOOL RXCheckParseVector(const RXParseVector *v)
{
    RXEvent *ev = RXParse(v->input);
    switch (v->shape) {
        case RXShapeNil:
            return ev == nil;
        case RXShapeEdit:
            return ev && ev.isEdit && !ev.isRemoval && ev.kind == RXKindNone && ev.target == RXTargetUnknown &&
                   RXSameString(ev.editText, v->text);
        default:
            return ev && !ev.isEdit && ev.isRemoval == v->removal && ev.kind == v->kind &&
                   RXSameString(ev.emoji, v->emoji) && ev.target == v->target &&
                   RXSameString(ev.quote, v->quote) && ev.truncated == v->truncated &&
                   RXSameString(ev.prefix, v->text) && ev.editText == nil;
    }
}

// compose -> exact string (when `expect` is given) -> parse gives the same kind/removal/emoji/target and,
// for text, the same quote (or, when truncated, a strict prefix of the original).
static BOOL RXCheckCompose(RXKind kind, NSString *emoji, BOOL removal, RXTarget target, NSString *quote,
                           NSString *expect, BOOL expectNil)
{
    NSString *sent = RXComposeReaction(kind, emoji, removal, target, quote);
    if (expectNil) {
        return sent == nil;
    }
    if (!sent || (expect && ![sent isEqualToString:expect])) {
        return NO;
    }
    RXEvent *ev = RXParse(sent);
    if (!ev || ev.isEdit || ev.isRemoval != removal || ev.kind != kind || ev.target != target) {
        return NO;
    }
    if (kind == RXKindEmoji && !RXSameString(ev.emoji, emoji)) {
        return NO;
    }
    if (target != RXTargetText) {
        return ev.quote == nil;
    }
    NSString *original = [quote stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    if (RXSameString(ev.quote, original)) {
        return YES;
    }
    return ev.truncated && [ev.prefix length] >= 8 && [original length] > [ev.prefix length] &&
           [original hasPrefix:ev.prefix];
}

// Name-first vectors: kind RXKindNone means "must not parse".
static BOOL RXCheckNamed(NSString *input, BOOL removal, RXKind kind, NSString *emoji, RXTarget target, NSString *quote)
{
    RXEvent *ev = RXParse(input);
    if (kind == RXKindNone) {
        return ev == nil;
    }
    return ev && !ev.isEdit && ev.isRemoval == removal && ev.kind == kind && RXSameString(ev.emoji, emoji) &&
           ev.target == target && RXSameString(ev.quote, quote);
}

static void RXTally(BOOL ok, NSString *ident, NSUInteger *pass, NSUInteger *total, NSMutableArray *fails)
{
    (*total)++;
    if (ok) {
        (*pass)++;
    } else if (ident) {
        [fails addObject:ident];
    }
}

void RXParserSelfTest(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RXParserSetup();
        NSUInteger pass = 0, total = 0;
        NSMutableArray *fails = [NSMutableArray array];

        // R5 section 8 (1-25, with 21 as a/b), then parser_check.py's two extras (26-27), then edge cases.
        RXParseVector vectors[] = {
            RXV("1", @"Loved \u201Csee you at 6\u201D", NO, RXKindLove, nil, RXTargetText, @"see you at 6", NO, nil),
            RXV("2", @"Laughed at \u201Clol\u201D", NO, RXKindLaugh, nil, RXTargetText, @"lol", NO, nil),
            RXV("3", @"Emphasised \u201CWOW\u201D", NO, RXKindEmph, nil, RXTargetText, @"WOW", NO, nil),
            RXV("4", @"Removed an exclamation mark from \u201CWOW\u201D", YES, RXKindEmph, nil, RXTargetText, @"WOW", NO, nil),
            RXV("5", @"Removed a question mark from \u201Cwhy?\u201D", YES, RXKindQuestion, nil, RXTargetText, @"why?", NO, nil),
            RXV("6", @"Reacted \U0001F3B6 to \u201CX\u201D", NO, RXKindEmoji, @"\U0001F3B6", RXTargetText, @"X", NO, nil),
            RXV("7", @"Reacted \U0001F44D\U0001F3FD to  \u201CX\u201D", NO, RXKindEmoji, @"\U0001F44D\U0001F3FD", RXTargetText, @"X", NO, nil),
            RXV("8", @"Removed \U0001F468\u200D\U0001F469\u200D\U0001F467 from \u201CX\u201D", YES, RXKindEmoji,
                @"\U0001F468\u200D\U0001F469\u200D\U0001F467", RXTargetText, @"X", NO, nil),
            RXV("9", @"Removed a \U0001F600 from \u201CX\u201D", YES, RXKindEmoji, @"\U0001F600", RXTargetText, @"X", NO, nil),
            RXV("10", @"Reacted with a sticker to \u201CX\u201D", NO, RXKindSticker, nil, RXTargetText, @"X", NO, nil),
            RXV("11", @"Removed a sticker from an image", YES, RXKindSticker, nil, RXTargetImage, nil, NO, nil),
            RXV("12", @"Loved an image", NO, RXKindLove, nil, RXTargetImage, nil, NO, nil),
            RXV("13", @"Liked a movie", NO, RXKindLike, nil, RXTargetMovie, nil, NO, nil),
            RXV("14", @"Loved an attachment", NO, RXKindLove, nil, RXTargetAnyAttachment, nil, NO, nil),
            RXV("15", @"Questioned 1 GamePigeon Message", NO, RXKindQuestion, nil, RXTargetUnknown, nil, NO, nil),
            RXV("16", @"Loved \u201C\u201D", NO, RXKindLove, nil, RXTargetUnknown, nil, NO, nil),
            RXV("17", @"Liked \u201Cthere\u2019s a protest for the faculty lecturers union \u2026\u201D", NO, RXKindLike, nil,
                RXTargetText, @"there\u2019s a protest for the faculty lecturers union \u2026", YES,
                @"there\u2019s a protest for the faculty lecturers union"),
            RXV("18", @"Loved \u201CHe said \u201Chi\u201D to me\u201D", NO, RXKindLove, nil, RXTargetText,
                @"He said \u201Chi\u201D to me", NO, nil),
            RXV("19", @"Loved \u201Cline1\nline2 \u201D", NO, RXKindLove, nil, RXTargetText, @"line1\nline2 ", NO, nil),
            RXV_EDIT("20", @"Edited to \u201Con the dryer\u201D", @"on the dryer"),
            RXV_EDIT("21a", @"Edited to \"on the dryer\"", @"on the dryer"),
            RXV_EDIT("21b", @"Edited to: 'on the dryer'", @"on the dryer"),
            RXV_NIL("22", @"Replied to a message: ok"),
            RXV("23", @"Loved it!", NO, RXKindLove, nil, RXTargetUnknown, nil, NO, nil),
            RXV("24", @"\u200A\u200B\U0001F602\u200B to \"\u200Ahello\u200A\"\u200A", NO, RXKindEmoji, @"\U0001F602",
                RXTargetText, @"hello", NO, nil),
            RXV("25", @"Removed a heart from a location", YES, RXKindLove, nil, RXTargetLocation, nil, NO, nil),
            RXV("26", @"Reacted \u2764\uFE0F to \u201CX\u201D", NO, RXKindEmoji, @"\u2764\uFE0F", RXTargetText, @"X", NO, nil),
            RXV("27", @"Removed \u2764\uFE0F from \u201CX\u201D", YES, RXKindEmoji, @"\u2764\uFE0F", RXTargetText, @"X", NO, nil),
            RXV("28", @"\uFEFF\u200ELoved \u201CX\u201D\u200F", NO, RXKindLove, nil, RXTargetText, @"X", NO, nil),
            RXV("29", @"Loved \u201C\uFFFC\u201D", NO, RXKindLove, nil, RXTargetUnknown, nil, NO, nil),
            RXV("30", @"Liked \"ok\"", NO, RXKindLike, nil, RXTargetText, @"ok", NO, nil),
            RXV_NIL("31", @"Removed a cat from \u201CX\u201D"),
            RXV("32", @"Reacted with a sticker to  \u201CX\u201D", NO, RXKindSticker, nil, RXTargetText, @"X", NO, nil),
            RXV("33", @"Removed an exclamation from \u201CWOW\u201D", YES, RXKindEmph, nil, RXTargetText, @"WOW", NO, nil),
            RXV("34", @"Emphasized a Wallet pass", NO, RXKindEmph, nil, RXTargetPass, nil, NO, nil),
            RXV("35", @"Loved a Digital Touch Message", NO, RXKindLove, nil, RXTargetUnknown, nil, NO, nil),
            RXV_NIL("36", @"Hello there"),
            RXV("37", @"Loved \u201CAre you\u2026\u201D", NO, RXKindLove, nil, RXTargetText, @"Are you\u2026", YES, @"Are you"),
            RXV("38", @"Reacted \U0001F3B6 to an image", NO, RXKindEmoji, @"\U0001F3B6", RXTargetImage, nil, NO, nil),
            RXV("39", @"\u200ARemoved \u200C\U0001F602\u200C from \"\u200Ahello\u200A\"\u200A", YES, RXKindEmoji, @"\U0001F602",
                RXTargetText, @"hello", NO, nil),
            RXV_NIL("40", @"Reacted with to \u201CX\u201D"),
            RXV("41", @"Removed a like from \u201C\u201D", YES, RXKindLike, nil, RXTargetUnknown, nil, NO, nil),
            RXV_NIL("42", @"Loved\u201CX\u201D"),
        };
        size_t count = sizeof(vectors) / sizeof(vectors[0]);
        for (size_t i = 0; i < count; i++) {
            RXTally(RXCheckParseVector(&vectors[i]), [NSString stringWithUTF8String:vectors[i].ident], &pass, &total, fails);
        }

        // Name-first forms (P1-P10). Curly quotes are built at runtime (lq/rq).
        {
            NSString *lq = [NSString stringWithFormat:@"%C", (unichar)0x201C];
            NSString *rq = [NSString stringWithFormat:@"%C", (unichar)0x201D];
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Taylor loved %@this is a test%@", lq, rq],
                                 NO, RXKindLove, nil, RXTargetText, @"this is a test"), @"P1", &pass, &total, fails);
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Taylor Brooks liked %@ok%@", lq, rq],
                                 NO, RXKindLike, nil, RXTargetText, @"ok"), @"P2", &pass, &total, fails);
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Mom removed a heart from %@ok%@", lq, rq],
                                 YES, RXKindLove, nil, RXTargetText, @"ok"), @"P3", &pass, &total, fails);
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Alex reacted \U0001F602 to %@lol%@", lq, rq],
                                 NO, RXKindEmoji, @"\U0001F602", RXTargetText, @"lol"), @"P4", &pass, &total, fails);
            RXTally(RXCheckNamed(@"Jordan laughed at an image", NO, RXKindLaugh, nil, RXTargetImage, nil),
                    @"P5", &pass, &total, fails);
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Sam removed an exclamation mark from %@WOW%@", lq, rq],
                                 YES, RXKindEmph, nil, RXTargetText, @"WOW"), @"P6", &pass, &total, fails);
            RXTally(RXCheckNamed(@"I loved it", NO, RXKindLove, nil, RXTargetUnknown, nil), @"P7", &pass, &total, fails);
            RXTally(RXCheckNamed(@"Taylor said hi", NO, RXKindNone, nil, RXTargetUnknown, nil), @"P8", &pass, &total, fails);
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Alex removed \U0001F602 from %@lol%@", lq, rq],
                                 YES, RXKindEmoji, @"\U0001F602", RXTargetText, @"lol"), @"P9", &pass, &total, fails);
            RXTally(RXCheckNamed([NSString stringWithFormat:@"Alex removed a cat from %@X%@", lq, rq],
                                 NO, RXKindNone, nil, RXTargetUnknown, nil), @"P10", &pass, &total, fails);
        }

        // Normaliser (R5 6.2).
        RXTally([RXNormalize(@"\uFFFCAre\u200E you\u2026") isEqualToString:@"Are you\u2026"], @"N1", &pass, &total, fails);
        RXTally([RXNormalize(@"Cafe\u0301") isEqualToString:@"Caf\u00E9"], @"N2", &pass, &total, fails);
        RXTally([RXNormalize(nil) isEqualToString:@""], @"N3", &pass, &total, fails);

        // Compose (R5 7) exact strings and round-trips.
        RXTally(RXCheckCompose(RXKindLove, nil, NO, RXTargetText, @"see you at 6",
                               @"Loved \u201Csee you at 6\u201D", NO), @"C1", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindEmph, nil, YES, RXTargetText, @"WOW",
                               @"Removed an exclamation from \u201CWOW\u201D", NO), @"C2", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindEmoji, @"\U0001F602", NO, RXTargetText, @"hi",
                               @"Reacted \U0001F602 to \u201Chi\u201D", NO), @"C3", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindEmoji, @"\U0001F602", YES, RXTargetText, @"hi",
                               @"Removed \U0001F602 from \u201Chi\u201D", NO), @"C4", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindLike, nil, NO, RXTargetImage, nil, @"Liked an image", NO), @"C5", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindQuestion, nil, YES, RXTargetMovie, nil,
                               @"Removed a question mark from a movie", NO), @"C6", &pass, &total, fails);
        // Apple's observed truncation (FINDINGS row 462): 49 units + " " U+2026.
        RXTally(RXCheckCompose(RXKindLike, nil, NO, RXTargetText,
                               @"there\u2019s a protest for the faculty lecturers union meeting tomorrow at noon",
                               @"Liked \u201Cthere\u2019s a protest for the faculty lecturers union \u2026\u201D", NO),
                @"C7", &pass, &total, fails);
        {
            // No space: hard cut that never splits a surrogate pair ("a" + 30 x U+1F600 -> "a" + 24 x U+1F600).
            NSMutableString *longText = [NSMutableString stringWithString:@"a"];
            NSMutableString *cutText = [NSMutableString stringWithString:@"a"];
            for (int i = 0; i < 30; i++) {
                [longText appendString:@"\U0001F600"];
                if (i < 24) {
                    [cutText appendString:@"\U0001F600"];
                }
            }
            NSString *want = [NSString stringWithFormat:@"Loved \u201C%@ \u2026\u201D", cutText];
            RXTally(RXCheckCompose(RXKindLove, nil, NO, RXTargetText, longText, want, NO), @"C8", &pass, &total, fails);
        }
        RXTally(RXCheckCompose(RXKindLove, nil, NO, RXTargetText, @"\uFFFCAre you coming tonight?",
                               @"Loved \u201CAre you coming tonight?\u201D", NO), @"C9", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindSticker, nil, NO, RXTargetText, @"X",
                               @"Reacted with a sticker to \u201CX\u201D", NO), @"C10", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindLove, nil, NO, RXTargetUnknown, @"X", nil, YES), @"C11", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindEmoji, @"abc", NO, RXTargetText, @"X", nil, YES), @"C12", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindLove, nil, NO, RXTargetText, @" \uFFFC ", nil, YES), @"C13", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindNone, nil, NO, RXTargetText, @"X", nil, YES), @"C14", &pass, &total, fails);
        // A word cut that would keep too little falls back to the hard cut (round-trip only).
        RXTally(RXCheckCompose(RXKindLove, nil, NO, RXTargetText,
                               @"Hi https://example.com/a/very/long/path/that/goes/on/and/on/forever", nil, NO),
                @"C15", &pass, &total, fails);
        RXTally(RXCheckCompose(RXKindLaugh, nil, NO, RXTargetText, @"He said \u201Chi\u201D",
                               @"Laughed at \u201CHe said \u201Chi\u201D\u201D", NO), @"C16", &pass, &total, fails);

        // Every kind x add/remove on text, and every media noun, must read back as itself.
        for (int k = (int)RXKindLove; k <= (int)RXKindEmoji; k++) {
            for (int r = 0; r < 2; r++) {
                NSString *emoji = (k == (int)RXKindEmoji) ? @"\U0001F3B6" : nil;
                BOOL ok = RXCheckCompose((RXKind)k, emoji, (BOOL)r, RXTargetText, @"ok", nil, NO);
                RXTally(ok, [NSString stringWithFormat:@"K%d%c", k, r ? 'r' : 'a'], &pass, &total, fails);
            }
        }
        for (int t = (int)RXTargetImage; t <= (int)RXTargetOrder; t++) {
            BOOL ok = RXCheckCompose(RXKindLove, nil, NO, (RXTarget)t, nil, nil, NO) &&
                      RXCheckCompose(RXKindLike, nil, YES, (RXTarget)t, nil, nil, NO);
            RXTally(ok, [NSString stringWithFormat:@"M%d", t], &pass, &total, fails);
        }

        if ([fails count] > 0) {
            RXLog(@"parser self-test %lu/%lu failed: %@", (unsigned long)pass, (unsigned long)total,
                  [fails componentsJoinedByString:@","]);
        } else {
            RXLog(@"parser self-test %lu/%lu", (unsigned long)pass, (unsigned long)total);
        }
    });
}

#undef RXV
#undef RXV_EDIT
#undef RXV_NIL
