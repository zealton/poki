// SPDX-License-Identifier: AGPL-3.0-only
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
/// LiveContainer scene transport for the ORIGINAL Poki chat. Holds no model credential or loop.
@interface PKContainedWorkspace : UIViewController
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) int guestPID;
@property(nonatomic, readonly) NSString *statusText;
- (void)observe:(void (^)(NSDictionary *, NSData * _Nullable))completion;
- (void)perform:(NSDictionary *)action completion:(void (^)(NSDictionary *))completion;
- (void)stop;
- (void)toggleFloatingPreview;
@end
NS_ASSUME_NONNULL_END
