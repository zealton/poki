// SPDX-License-Identifier: AGPL-3.0-only
#import "WorkspacePolicy.h"
#import <math.h>
static BOOL ValidNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
           isfinite([value doubleValue]);
}
NSDictionary *PKWParseAction(NSData *json, NSError **error) {
    if (json.length > 32768)
        return nil;
    id object = [NSJSONSerialization JSONObjectWithData:json options:0 error:error];
    if (![object isKindOfClass:NSDictionary.class])
        return nil;
    NSString *kind = object[@"action"];
    NSArray *allowed = @[ @"tap", @"set_text", @"scroll", @"wait", @"finish", @"ask_user" ];
    if (![kind isKindOfClass:NSString.class] || ![allowed containsObject:kind])
        goto invalid;
    if ([@[ @"tap", @"set_text", @"scroll" ] containsObject:kind]) {
        for (NSString *key in @[ @"x", @"y" ]) {
            id v = object[key];
            if (!ValidNumber(v) || [v doubleValue] < 0 || [v doubleValue] > 10000)
                goto invalid;
        }
    }
    if ([kind isEqual:@"set_text"] &&
        (![object[@"text"] isKindOfClass:NSString.class] || [object[@"text"] length] > 4000))
        goto invalid;
    if ([kind isEqual:@"scroll"]) {
        id dy = object[@"dy"];
        if (!ValidNumber(dy) || fabs([dy doubleValue]) > 2000)
            goto invalid;
    }
    return object;
invalid:
    if (error)
        *error = [NSError
            errorWithDomain:@"PokiWorkspace"
                       code:2
                   userInfo:@{NSLocalizedDescriptionKey : @"unsupported_or_invalid_action"}];
    return nil;
}
BOOL PKWNeedsApproval(NSString *label, NSArray<NSString *> *context) {
    NSString *text = [[label
        stringByAppendingFormat:@" %@", [context componentsJoinedByString:@" "]] lowercaseString];
    NSArray *words = @[
        @"pay", @"purchase", @"buy now", @"transfer", @"send", @"delete", @"remove account",
        @"submit order", @"付款", @"支付", @"转账", @"购买", @"发送", @"发布", @"删除", @"注销"
    ];
    for (NSString *word in words)
        if ([text containsString:word])
            return YES;
    return NO;
}
BOOL PKWAllowedModel(NSString *model) {
    return
        [model hasPrefix:@"deepseek/"] && model.length < 160 &&
        [model rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location ==
            NSNotFound;
}
