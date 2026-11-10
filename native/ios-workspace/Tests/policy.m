// SPDX-License-Identifier: AGPL-3.0-only
#import <Foundation/Foundation.h>
#import "WorkspacePolicy.h"
static NSDictionary *parse(NSString *s) {
    return PKWParseAction([s dataUsingEncoding:NSUTF8StringEncoding], NULL);
}
int main(void) {
    @autoreleasepool {
        NSCAssert(parse(@"{\"action\":\"tap\",\"x\":12,\"y\":40}"), @"ordinary tap");
        for (NSString *s in @[
                 @"[]", @"null", @"{", @"{\"action\":\"open_app\"}",
                 @"{\"action\":\"tap\",\"x\":true,\"y\":5}",
                 @"{\"action\":\"tap\",\"x\":-1,\"y\":5}",
                 @"{\"action\":\"tap\",\"x\":\"5\",\"y\":5}",
                 @"{\"action\":\"set_text\",\"x\":1,\"y\":2}",
                 @"{\"action\":\"scroll\",\"x\":1,\"y\":2,\"dy\":2001}"
             ]) {
            NSCAssert(!parse(s), @"reject invalid model output: %@", s);
        }
        NSCAssert(PKWNeedsApproval(@"确认支付", @[]), @"payment approval");
        NSCAssert(PKWNeedsApproval(@"Delete account", @[]), @"destructive approval");
        NSCAssert(!PKWNeedsApproval(@"Increment", @[]), @"ordinary control");
        NSCAssert(PKWAllowedModel(@"deepseek/deepseek-v4.1-flash-1017"), @"DeepSeek");
        NSCAssert(!PKWAllowedModel(@"http://other/model"), @"no arbitrary endpoint");
        NSCAssert(!PKWAllowedModel(@"deepseek/model\nAuthorization"), @"model injection");
        puts("Workspace policy: 16 checks passed");
        return 0;
    }
}
