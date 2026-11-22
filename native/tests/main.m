#import <Foundation/Foundation.h>
#import "../RXNativeBridge.h"
#include <assert.h>
#include <unistd.h>
#include <dlfcn.h>
#import <objc/runtime.h>

@interface NSObject (RXFactoryCheck)
+ (id)newCompositionForText:(NSString *)text;
- (NSArray *)messageParts;
- (NSString *)textString;
- (id)initWithSender:(id)sender time:(NSDate *)time text:(NSAttributedString *)text
      messageSubject:(id)subject fileTransferGUIDs:(id)transfers flags:(unsigned long long)flags
               error:(id)error guid:(NSString *)guid subject:(id)handle;
- (NSString *)guid;
@end
int main(void) { @autoreleasepool {
 if (getuid()==0) { assert(setgid(501)==0); assert(setuid(501)==0); }
 NSString *guid=@"01234567-89AB-CDEF-0123-456789ABCDEF";
 for (unsigned int k=0;k<6;k++) for (int r=0;r<2;r++) {
  NSDictionary *f=RXNativeReactionFields(guid,2,k,r,@"Hi",NO,0,2);
  assert([[f objectForKey:@"amt"] intValue]==(r?3000:2000)+(int)k);
  assert([[f objectForKey:@"amk"] isEqual:@"p:2/01234567-89AB-CDEF-0123-456789ABCDEF"]);
  NSDictionary *request=@{@"fallback":@"Loved hi",@"fields":f};
  NSDictionary *ordinary=@{@"t":@"Loved hi",@"p":@[@"a",@"b"],@"v":@"1",@"x":@"old html"};
  NSDictionary *decorated=RXNativeDecorate(ordinary,request);
  assert(decorated && ![decorated objectForKey:@"x"]);
  assert([[decorated objectForKey:@"p"] isEqual:[ordinary objectForKey:@"p"]]);
  assert([[ordinary objectForKey:@"x"] isEqual:@"old html"]);
  assert(!RXNativeDecorate(@{@"t":@"unrelated text"},request));
 }
 assert(!RXNativeReactionFields(guid,0,6,NO,@"x",NO,0,1));
 assert(!RXNativeReactionFields(guid,0,0,NO,@"x",NO,1,1));
 assert(!RXNativeReactionFields(@"../bad",0,0,NO,@"x",NO,0,1));
 assert(RXNativeReactionFields(guid,0,0,NO,@"",YES,0,0));
 NSDictionary *reply = RXNativeReplyFields(guid,2,4,7);
 assert([[reply objectForKey:@"tg"] isEqual:@"r:2:4:7:01234567-89AB-CDEF-0123-456789ABCDEF"]);
 assert(!RXNativeReplyFields(@"bad",0,0,1));
 assert(!RXNativeReplyFields(guid,0,2147483647U,1));
 NSDictionary *replyRequest = @{@"fallback":@"Reply text",@"fields":reply};
 NSDictionary *original = @{@"t":@"Reply text",@"x":@"<span>Reply text</span>",@"p":@[@"a",@"b"],@"r":@"routing"};
 NSDictionary *result = RXNativeDecorate(original,replyRequest);
 assert(result && [[result objectForKey:@"tg"] isEqual:[reply objectForKey:@"tg"]]);
 assert([[result objectForKey:@"x"] isEqual:[original objectForKey:@"x"]]);
 assert([[result objectForKey:@"r"] isEqual:@"routing"] && ![original objectForKey:@"tg"]);
 assert(!RXNativeDecorate(@{@"t":@"different"},replyRequest));
 assert(!RXNativeDecorate(original,@{@"fallback":@"Reply text",@"fields":@{@"tg":@"r:0:-1:1:bad"}}));
 NSString *replyGUID = RXNativeNewGUID();
 assert(RXNativeStage(replyGUID,@"Reply text",reply));
 assert([[RXNativeRead(replyGUID) objectForKey:@"fields"] isEqual:reply]);
 RXNativeDiscard(replyGUID);
 assert(RXNativeIsGUID(RXNativeNewGUID()));
 NSString *requestGUID=RXNativeNewGUID();
 NSDictionary *f=RXNativeReactionFields(guid,0,0,NO,@"Hi",NO,0,2);
 assert(RXNativeStage(requestGUID,@"Loved Hi",f));
 NSDictionary *loaded=RXNativeRead(requestGUID);
 assert(loaded && [[loaded objectForKey:@"fields"] isEqual:f]);
 NSString *path=[RX_NATIVE_DIRECTORY stringByAppendingPathComponent:
                  [requestGUID stringByAppendingString:@".plist"]];
 assert([[@"corrupt" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
 assert(!RXNativeRead(requestGUID));
 RXNativeDiscard(requestGUID);
 assert(!RXNativeRead(requestGUID));
 assert(dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore",RTLD_LAZY));
 Class cls=NSClassFromString(@"IMMessage");
 assert(cls);
 id message=[(NSObject *)[cls alloc] initWithSender:nil time:[NSDate date]
          text:[[NSAttributedString alloc] initWithString:@"Loved Hi"]
          messageSubject:nil fileTransferGUIDs:nil flags:0x100005ULL error:nil
          guid:requestGUID subject:nil];
 assert(message && [[message guid] isEqual:requestGUID]);
 id copied=[message copy];
 assert([[copied guid] isEqual:requestGUID]);
 printf("native payload fixture checks passed; helper ready=%d\n", (int)RXNativeAvailable());
 } return 0; }
