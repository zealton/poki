// SPDX-License-Identifier: AGPL-3.0-only
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol PKWBroker
- (void)registerRole:(NSString *)role
             process:(int)pid
            endpoint:(NSXPCListenerEndpoint *)endpoint
               reply:(void (^)(BOOL accepted))reply;
@end
@protocol PKWGuest
- (void)observe:(void (^)(NSDictionary *observation, NSData *jpeg))reply;
- (void)web:(NSDictionary *)action run:(NSString *)run observation:(NSString *)observation
      reply:(void (^)(NSDictionary *result))reply;
- (void)authorizeWorker:(int)pid run:(NSString *)run reply:(void (^)(BOOL))reply;
- (void)setRun:(NSString *)run enabled:(BOOL)enabled reply:(void (^)(BOOL))reply;
- (void)perform:(NSDictionary *)action
            run:(NSString *)run
    observation:(NSString *)observation
       approval:(BOOL)approved
          reply:(void (^)(NSDictionary *result))reply;
@end
@protocol PKWGuestEvents
- (void)userTookControl;
- (void)isolationBlocked:(NSString *)reason;
@end
@protocol PKWWorker
- (void)start:(NSDictionary *)configuration
         guest:(NSXPCListenerEndpoint *)endpoint
    credential:(NSString *)credential
         reply:(void (^)(NSDictionary *))reply;
- (void)control:(NSString *)command reply:(void (^)(NSDictionary *))reply;
- (void)status:(void (^)(NSDictionary *state, NSData *jpeg))reply;
@end
@interface NSObject (PKWPrivate)
+ (NSDictionary *)retrievedAppInfo;
- (int)processIdentifier;
@end

FOUNDATION_EXPORT NSXPCInterface *PKWInterface(Protocol *protocol);
FOUNDATION_EXPORT NSError *PKWError(NSString *code);
FOUNDATION_EXPORT NSDictionary *PKWLaunchOptions(NSString *dataID);
FOUNDATION_EXPORT void PKWSetLaunchOptions(NSString *dataID, NSDictionary *options);
FOUNDATION_EXPORT void PKWConnectBroker(NSString *role, NSXPCListenerEndpoint *endpoint);
