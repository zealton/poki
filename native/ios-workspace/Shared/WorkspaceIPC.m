// SPDX-License-Identifier: AGPL-3.0-only
#import "WorkspaceIPC.h"
NSXPCInterface *PKWInterface(Protocol *protocol) {
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:protocol];
    NSSet *classes = [NSSet setWithArray:@[
        NSDictionary.class, NSMutableDictionary.class, NSArray.class, NSMutableArray.class,
        NSString.class, NSNumber.class, NSData.class, NSNull.class
    ]];
    if (protocol == @protocol(PKWGuest)) {
        [i setClasses:classes forSelector:@selector(web:run:observation:reply:) argumentIndex:0 ofReply:NO];
        [i setClasses:classes forSelector:@selector(web:run:observation:reply:) argumentIndex:0 ofReply:YES];
        [i setClasses:classes forSelector:@selector(observe:) argumentIndex:0 ofReply:YES];
        [i setClasses:classes
              forSelector:@selector(perform:run:observation:approval:reply:)
            argumentIndex:0
                  ofReply:NO];
        [i setClasses:classes
              forSelector:@selector(perform:run:observation:approval:reply:)
            argumentIndex:0
                  ofReply:YES];
    } else if (protocol == @protocol(PKWWorker)) {
        [i setClasses:classes
              forSelector:@selector(start:guest:credential:reply:)
            argumentIndex:0
                  ofReply:NO];
        [i setClasses:classes
              forSelector:@selector(start:guest:credential:reply:)
            argumentIndex:0
                  ofReply:YES];
        [i setClasses:classes forSelector:@selector(status:) argumentIndex:0 ofReply:YES];
        [i setClasses:classes forSelector:@selector(control:reply:) argumentIndex:0 ofReply:YES];
    }
    return i;
}
NSError *PKWError(NSString *code) {
    return [NSError errorWithDomain:@"PokiWorkspace"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : code}];
}
static NSMutableDictionary *launchOptions;
NSDictionary *PKWLaunchOptions(NSString *dataID) {
    @synchronized(NSObject.class) {
        return launchOptions[dataID];
    }
}
void PKWSetLaunchOptions(NSString *dataID, NSDictionary *options) {
    @synchronized(NSObject.class) {
        if (!launchOptions)
            launchOptions = [NSMutableDictionary new];
        launchOptions[dataID] = options;
    }
}
void PKWConnectBroker(NSString *role, NSXPCListenerEndpoint *endpoint) {
    NSDictionary *bootstrap = [NSClassFromString(@"LiveProcessHandler") retrievedAppInfo];
    NSXPCListenerEndpoint *broker = bootstrap[@"pokiBroker"];
    if (!broker)
        return;
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:broker];
    connection.remoteObjectInterface = PKWInterface(@protocol(PKWBroker));
    [connection resume];
    connection.invalidationHandler = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"PKWHostDisconnected" object:nil];
    };
    // Keep the bootstrap connection alive. It contains no credentials or screenshots.
    static NSMutableArray *connections;
    if (!connections)
        connections = [NSMutableArray new];
    [connections addObject:connection];
    __block void (^attempt)(NSInteger);
    attempt = ^(NSInteger remaining) {
        id<PKWBroker> remote = [connection remoteObjectProxyWithErrorHandler:^(NSError *error){
        }];
        [remote registerRole:role
                     process:NSProcessInfo.processInfo.processIdentifier
                    endpoint:endpoint
                       reply:^(BOOL accepted) {
                           if (!accepted && remaining > 0)
                               dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .3 * NSEC_PER_SEC),
                                              dispatch_get_main_queue(), ^{
                                                  attempt(remaining - 1);
                                              });
                           else
                               attempt = nil;
                       }];
    };
    attempt(20);
}
