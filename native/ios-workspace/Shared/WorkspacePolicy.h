// SPDX-License-Identifier: AGPL-3.0-only
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSDictionary *PKWParseAction(NSData *json, NSError **error);
FOUNDATION_EXPORT BOOL PKWNeedsApproval(NSString *label, NSArray<NSString *> *context);
FOUNDATION_EXPORT BOOL PKWAllowedModel(NSString *model);
