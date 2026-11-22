#import "RXNativeBridge.h"
#include <notify.h>
#include <signal.h>
#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

BOOL RXNativeIsGUID(NSString *guid) {
    return [guid isKindOfClass:[NSString class]] &&
           RXNativeGUIDIsValid(guid.UTF8String) &&
           [[guid uppercaseString] hasPrefix:RX_NATIVE_PREFIX];
}

BOOL RXNativeAvailable(void) {
    int token = 0;
    uint64_t state = 0;
    if (notify_register_check(RX_NATIVE_READY, &token) != NOTIFY_STATUS_OK) return NO;
    uint32_t result = notify_get_state(token, &state);
    notify_cancel(token);
    if (result != NOTIFY_STATUS_OK || (state >> 32) != RX_NATIVE_PROTOCOL) return NO;
    pid_t pid = (pid_t)(state & 0xffffffffULL);
    return pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
}

NSString *RXNativeNewGUID(void) {
    NSString *random = [[NSUUID UUID] UUIDString];
    return [RX_NATIVE_PREFIX stringByAppendingString:[random substringFromIndex:9]];
}

static NSString *RXNativePath(NSString *guid) {
    return RXNativeIsGUID(guid) ? [RX_NATIVE_DIRECTORY stringByAppendingPathComponent:
                                  [[guid uppercaseString] stringByAppendingString:@".plist"]] : nil;
}

static BOOL RXNativeFieldsValid(id fields) {
    if (![fields isKindOfClass:[NSDictionary class]]) return NO;
    if ([fields count] == 1 && [[fields objectForKey:@"tg"] isKindOfClass:[NSString class]]) {
        NSArray *items = [[fields objectForKey:@"tg"] componentsSeparatedByString:@":"];
        if (items.count != 5 || ![[items objectAtIndex:0] isEqual:@"r"]) return NO;
        for (NSUInteger i = 1; i < 4; i++) {
            NSString *number = [items objectAtIndex:i];
            if (!number.length || number.length > 10 || [number rangeOfCharacterFromSet:
                [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound ||
                [number longLongValue] > 2147483647LL) return NO;
        }
        return [[items objectAtIndex:2] longLongValue] + [[items objectAtIndex:3] longLongValue] <= 2147483647LL &&
               RXNativeGUIDIsValid([[items objectAtIndex:4] UTF8String]);
    }
    NSSet *expected = [NSSet setWithObjects:@"amk", @"amt", @"amrlc", @"amrln", @"msi", nil];
    if (![[NSSet setWithArray:[fields allKeys]] isEqual:expected]) return NO;
    id target = [fields objectForKey:@"amk"];
    if (![target isKindOfClass:[NSString class]] || ![target hasPrefix:@"p:"]) return NO;
    NSRange slash = [target rangeOfString:@"/"];
    if (slash.location == NSNotFound || slash.location <= 2) return NO;
    NSString *part = [target substringWithRange:NSMakeRange(2, slash.location - 2)];
    if ([part length] > 10 || [part rangeOfCharacterFromSet:
            [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return NO;
    NSString *guid = [target substringFromIndex:slash.location + 1];
    if (!RXNativeGUIDIsValid([guid UTF8String])) return NO;
    for (NSString *key in @[@"amt", @"amrlc", @"amrln"])
        if (![[fields objectForKey:key] isKindOfClass:[NSNumber class]]) return NO;
    long long type = [[fields objectForKey:@"amt"] longLongValue];
    if (!((type >= 2000 && type <= 2005) || (type >= 3000 && type <= 3005))) return NO;
    if ([[fields objectForKey:@"amrlc"] longLongValue] < 0 ||
        [[fields objectForKey:@"amrln"] longLongValue] < 0) return NO;
    NSData *msi = [fields objectForKey:@"msi"];
    if (![msi isKindOfClass:[NSData class]] || msi.length > 32768) return NO;
    id summary = [NSPropertyListSerialization propertyListWithData:msi options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    return [summary isKindOfClass:[NSDictionary class]] &&
           [[summary objectForKey:@"ams"] isKindOfClass:[NSString class]] &&
           ([[summary objectForKey:@"amc"] isEqual:@1] || [[summary objectForKey:@"amc"] isEqual:@9]);
}

BOOL RXNativeStage(NSString *guid, NSString *fallback, NSDictionary *fields) {
    NSString *path = RXNativePath(guid);
    if (!path || ![fallback isKindOfClass:[NSString class]] || !fallback.length ||
        !RXNativeFieldsValid(fields)) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:RX_NATIVE_DIRECTORY withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return NO;
    struct stat st;
    if (lstat(RX_NATIVE_DIRECTORY.fileSystemRepresentation, &st) != 0 ||
        !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0077)) return NO;
    // Keep a month of retry metadata; never remove a still-valid pending send.
    static dispatch_once_t cleanup;
    dispatch_once(&cleanup, ^{
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-30 * 86400];
        for (NSString *name in [fm contentsOfDirectoryAtPath:RX_NATIVE_DIRECTORY error:NULL]) {
            if (![name.pathExtension isEqual:@"plist"] || !RXNativeIsGUID(name.stringByDeletingPathExtension)) continue;
            NSString *oldPath = [RX_NATIVE_DIRECTORY stringByAppendingPathComponent:name];
            NSDictionary *attributes = [fm attributesOfItemAtPath:oldPath error:NULL];
            NSDate *modified = [attributes objectForKey:NSFileModificationDate];
            if ([modified isKindOfClass:[NSDate class]] && [modified compare:cutoff] == NSOrderedAscending)
                [fm removeItemAtPath:oldPath error:NULL];
        }
    });
    NSArray *names = [fm contentsOfDirectoryAtPath:RX_NATIVE_DIRECTORY error:NULL];
    if (!names || names.count >= 4096) return NO;
    NSDictionary *request = @{@"version":@1, @"guid":[guid uppercaseString],
        @"created":@([[NSDate date] timeIntervalSince1970]), @"fallback":fallback, @"fields":fields};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:request
                       format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data || data.length > 65536) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:NULL];
}

NSDictionary *RXNativeRead(NSString *guid) {
    NSString *path = RXNativePath(guid);
    if (!path) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != 501 ||
        st.st_size <= 0 || st.st_size > 65536) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger done = 0;
    while (done < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (NSUInteger)n;
    }
    close(fd);
    if (done != data.length) return nil;
    id r = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                    format:NULL error:NULL];
    if (![r isKindOfClass:[NSDictionary class]] || ![[r objectForKey:@"version"] isEqual:@1] ||
        ![[r objectForKey:@"guid"] isEqual:[guid uppercaseString]] ||
        ![[r objectForKey:@"created"] isKindOfClass:[NSNumber class]] ||
        ![[r objectForKey:@"fallback"] isKindOfClass:[NSString class]] ||
        !RXNativeFieldsValid([r objectForKey:@"fields"])) return nil;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - [[r objectForKey:@"created"] doubleValue];
    return age >= -60 && age <= 30 * 86400 ? r : nil;
}

void RXNativeDiscard(NSString *guid) {
    NSString *path = RXNativePath(guid);
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

NSDictionary *RXNativeDecorate(NSDictionary *original, NSDictionary *request) {
    if (![original isKindOfClass:[NSDictionary class]] || ![request isKindOfClass:[NSDictionary class]] ||
        ![[original objectForKey:@"t"] isEqual:[request objectForKey:@"fallback"]] ||
        !RXNativeFieldsValid([request objectForKey:@"fields"])) return nil;
    NSMutableDictionary *out = [original mutableCopy];
    [out addEntriesFromDictionary:[request objectForKey:@"fields"]];
    [out setObject:@0 forKey:@"pv"];
    [out setObject:@"8" forKey:@"gv"];
    [out setObject:@"1" forKey:@"v"];
    // A tapback carries fallback text, not a second independently rendered HTML body.
    if (![[request objectForKey:@"fields"] objectForKey:@"tg"]) [out removeObjectForKey:@"x"];
    return out;
}
