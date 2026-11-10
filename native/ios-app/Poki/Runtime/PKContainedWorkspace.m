// SPDX-License-Identifier: AGPL-3.0-only
#import "PKContainedWorkspace.h"
#import "../../../ios-workspace/Shared/WorkspaceIPC.h"
#import <dlfcn.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

// Minimal declarations keep the ordinary Poki build independent of private LC headers/binaries.
@interface PKLCScene : UIViewController
@property int pid;
@property id presenter;
@property UIView *contentView;
@property BOOL shouldIgnoreSceneUpdates;
@property CGFloat scaleRatio;
- (instancetype)initWithBundleId:(NSString *)bundle dataUUID:(NSString *)data delegate:(id)delegate;
- (void)setBackgroundNotificationEnabled:(BOOL)enabled;
- (void)updateSettingsWithBlock:(void (^)(id settings))block;
- (void)terminate;
- (void)openURLScheme:(NSString *)url;
@end
static NSXPCInterface *Wire(Protocol *protocol) {
    NSXPCInterface *(*fn)(Protocol *) = dlsym(RTLD_DEFAULT, "PKWInterface");
    return fn ? fn(protocol) : nil;
}
static void HostGlobal(const char *symbol, id value) {
    id __strong *slot = (id __strong *)dlsym(RTLD_DEFAULT, symbol);
    if (slot) *slot = value;
}
@interface PKContainedWorkspace () <NSXPCListenerDelegate, PKWBroker, PKWGuestEvents, AVPictureInPictureControllerDelegate>
@property NSXPCListener *listener;
@property NSMutableArray<NSXPCConnection *> *brokers;
@property NSXPCConnection *connection;
@property PKLCScene *guest;
@property UIView *preview;
@property UIImageView *snapshotPreview;
@property UILabel *label;
@property UIButton *floating;
@property AVPictureInPictureController *pip;
@property AVPictureInPictureVideoCallViewController *pipVC;
@property NSString *runID, *observationID;
@property BOOL preparing, authorized;
@property NSMutableArray *waiters;
@property NSInteger generation, runEpoch;
@end
@implementation PKContainedWorkspace
+ (instancetype)shared { static id value; static dispatch_once_t once; dispatch_once(&once, ^{value=[self new];}); return value; }
- (BOOL)available {
    return NSClassFromString(@"AppSceneViewController") && Wire(@protocol(PKWGuest)) &&
      [NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ContainedResources/MobileSafari.app/Info.plist"]];
}
- (int)guestPID { return self.guest.pid; }
- (NSString *)statusText { return self.label.text ?: @"idle"; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.secondarySystemBackgroundColor;
    self.brokers=[NSMutableArray new]; self.waiters=[NSMutableArray new];
    self.label=[[UILabel alloc] initWithFrame:CGRectMake(8,0,360,28)];self.label.font=[UIFont systemFontOfSize:11];self.label.numberOfLines=2;
    self.label.text=@"LiveContainer · Apple MobileSafari";self.label.accessibilityIdentifier=@"poki.contained.status";
    [self.view addSubview:self.label];
    self.floating=[UIButton buttonWithType:UIButtonTypeSystem];[self.floating setTitle:@"Floating preview" forState:UIControlStateNormal];
    self.floating.titleLabel.font=[UIFont systemFontOfSize:11];self.floating.accessibilityIdentifier=@"poki.contained.floating";
    [self.floating addTarget:self action:@selector(toggleFloatingPreview) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.floating];
    self.preview=[UIView new];self.preview.clipsToBounds=YES;[self.view addSubview:self.preview];
    self.snapshotPreview=[UIImageView new];self.snapshotPreview.contentMode=UIViewContentModeScaleAspectFit;
    self.snapshotPreview.backgroundColor=UIColor.secondarySystemBackgroundColor;self.snapshotPreview.hidden=YES;
    self.snapshotPreview.accessibilityLabel=@"Latest real Safari guest screenshot";[self.preview addSubview:self.snapshotPreview];
    self.view.accessibilityIdentifier=@"poki.contained.preview";
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self prepare]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; self.label.frame=CGRectMake(8,0,MAX(1,self.view.bounds.size.width-114),30);self.floating.frame=CGRectMake(self.view.bounds.size.width-106,0,100,30);
    self.preview.frame=CGRectMake(0,30,self.view.bounds.size.width,MAX(1,self.view.bounds.size.height-30));
    self.snapshotPreview.frame=self.preview.bounds;
    if(self.guest && !self.pip.isPictureInPictureActive) {
        self.guest.shouldIgnoreSceneUpdates=YES;
        self.guest.view.transform=CGAffineTransformIdentity;
        self.guest.view.frame=self.preview.bounds;
        CGFloat scale=MIN(self.preview.bounds.size.width/402,self.preview.bounds.size.height/874);
        self.guest.scaleRatio=scale;
        self.guest.contentView.transform=CGAffineTransformMakeScale(scale,scale);
        self.guest.contentView.bounds=CGRectMake(0,0,402,874);
        self.guest.contentView.center=CGPointMake(CGRectGetMidX(self.preview.bounds),CGRectGetMidY(self.preview.bounds));
    }
}
- (void)fail:(NSString *)why {
    self.label.text=why; self.preparing=NO;self.authorized=NO; self.runEpoch++;
    self.observationID=nil;
    if(self.connection){NSXPCConnection *connection=self.connection;self.connection=nil;connection.invalidationHandler=nil;[connection invalidate];}
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PokiContainedUserInterruption" object:self];
    NSArray *pending=self.waiters.copy;[self.waiters removeAllObjects];
    for(void (^done)(BOOL) in pending)done(NO);
}
- (void)prepare {
    [self loadViewIfNeeded]; if(self.preparing || self.guest) return;
    if(!self.available){[self fail:@"Container runtime unavailable; no foreground fallback"];return;}
    self.preparing=YES; self.label.text=@"Starting real Apple MobileSafari guest…";
    setenv("LC_HOME_PATH", NSHomeDirectory().fileSystemRepresentation, 1);
    HostGlobal("lcMainBundle",NSBundle.mainBundle);HostGlobal("lcUserDefaults",NSUserDefaults.standardUserDefaults);
    Class shared=NSClassFromString(@"LCSharedUtils");
    NSString *group=[shared performSelector:NSSelectorFromString(@"appGroupID")];
    HostGlobal("lcSharedDefaults",[[NSUserDefaults alloc] initWithSuiteName:group]);
    HostGlobal("lcAppUrlScheme",@"poki");
    HostGlobal("lcAppGroupPath",[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group].path);
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *docs=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *apps=[docs stringByAppendingPathComponent:@"Applications"],*tweaks=[docs stringByAppendingPathComponent:@"Tweaks"];
    [fm createDirectoryAtPath:apps withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:tweaks withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *resources=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ContainedResources"];
    NSString *dest=[apps stringByAppendingPathComponent:@"MobileSafari.app"];
    // This bundle is an SDK-generated, locally transformed copy, never the user's original app/data.
    if(![fm fileExistsAtPath:dest]) {
        NSError *error=nil;[fm copyItemAtPath:[resources stringByAppendingPathComponent:@"MobileSafari.app"] toPath:dest error:&error];
        if(error){[self fail:@"Safari guest resources could not be copied"];return;}
    }
    NSString *bridge=[tweaks stringByAppendingPathComponent:@"WorkspaceBridge.dylib"];
    [fm removeItemAtPath:bridge error:nil];[fm copyItemAtPath:[resources stringByAppendingPathComponent:@"WorkspaceBridge.dylib"] toPath:bridge error:nil];
    NSString *dataID=@"Poki-Safari-Isolation";
    for(NSString *path in @[@"Documents",@"Library/Preferences",@"tmp"])
        [fm createDirectoryAtPath:[[docs stringByAppendingPathComponent:[@"Data/Application/" stringByAppendingString:dataID]] stringByAppendingPathComponent:path] withIntermediateDirectories:YES attributes:nil error:nil];
    self.listener=[NSXPCListener anonymousListener];self.listener.delegate=self;[self.listener resume];
    void (*options)(NSString *,NSDictionary *)=dlsym(RTLD_DEFAULT,"PKWSetLaunchOptions");
    options(dataID,@{@"pokiRole":@"guest",@"pokiHostPID":@(NSProcessInfo.processInfo.processIdentifier),@"pokiBroker":self.listener.endpoint,@"pokiStrictIsolation":@YES});
    @try {
        self.guest=[(PKLCScene *)[NSClassFromString(@"AppSceneViewController") alloc] initWithBundleId:@"MobileSafari.app" dataUUID:dataID delegate:self];
    } @catch(NSException *exception) {
        [self fail:@"LiveContainer rejected scene initialization; no automatic retry"];return;
    }
    if(!self.guest){[self fail:@"LiveContainer failed to create Safari process"];return;}
    [self addChildViewController:self.guest];[self.preview insertSubview:self.guest.view atIndex:0];[self.guest didMoveToParentViewController:self];[self.view setNeedsLayout];
    NSInteger generation=++self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(generation==self.generation && !self.connection)[self fail:@"Safari bridge did not connect within 30 seconds"];
    });
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    c.exportedInterface=Wire(@protocol(PKWBroker));c.exportedObject=self;[self.brokers addObject:c];[c resume];return YES;
}
- (void)registerRole:(NSString *)role process:(int)pid endpoint:(NSXPCListenerEndpoint *)endpoint reply:(void (^)(BOOL))reply {
    int actual=NSXPCConnection.currentConnection.processIdentifier;
    dispatch_async(dispatch_get_main_queue(),^{
        BOOL valid=[role isEqual:@"guest"] && actual==pid && pid>0 && pid==self.guest.pid;
        reply(valid);if(!valid)return;
        self.connection=[[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        self.connection.remoteObjectInterface=Wire(@protocol(PKWGuest));
        self.connection.exportedInterface=Wire(@protocol(PKWGuestEvents));self.connection.exportedObject=self;
        __weak typeof(self) weak=self;
        self.connection.invalidationHandler=^{dispatch_async(dispatch_get_main_queue(),^{[weak fail:@"Safari guest connection closed"];});};
        [self.connection resume];self.preparing=NO;self.label.text=[NSString stringWithFormat:@"Apple MobileSafari · guest %d · isolated scene",pid];
        NSArray *pending=self.waiters.copy;[self.waiters removeAllObjects];for(void (^done)(BOOL) in pending)done(YES);
    });
}
- (void)ready:(void (^)(BOOL))done {
    [self loadViewIfNeeded];if(self.connection){done(YES);return;}if(self.guest && !self.preparing){done(NO);return;}
    [self.waiters addObject:[done copy]];[self prepare];
}
- (id<PKWGuest>)remote { return [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{[self fail:@"Safari IPC failed"];});}]; }
- (void)authorize:(void (^)(BOOL))done {
    if(self.authorized){done(YES);return;}
    self.runID=NSUUID.UUID.UUIDString;
    NSString *run=self.runID; NSInteger epoch=self.runEpoch;
    [[self remote] authorizeWorker:NSProcessInfo.processInfo.processIdentifier run:run reply:^(BOOL ok){dispatch_async(dispatch_get_main_queue(),^{
        if(epoch!=self.runEpoch){[[self remote] setRun:run enabled:NO reply:^(BOOL stopped){}];done(NO);return;}
        self.authorized=ok;done(ok);
    });}];
}
- (void)observe:(void (^)(NSDictionary *,NSData *))completion {
    NSInteger epoch=self.runEpoch;
    __block BOOL finished=NO;
    void (^answer)(NSDictionary *,NSData *)=^(NSDictionary *v,NSData *j){dispatch_async(dispatch_get_main_queue(),^{if(finished)return;finished=YES;completion(v,j);});};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{answer(@{@"error":@"contained_observation_timeout"},nil);});
    [self ready:^(BOOL ready){if(!ready || epoch!=self.runEpoch){answer(@{@"error":@"task_stopped_or_guest_unavailable"},nil);return;}
        [self authorize:^(BOOL ok){if(!ok || epoch!=self.runEpoch){answer(@{@"error":@"guest_authorization_failed_or_task_stopped"},nil);return;}
            [[self remote] observe:^(NSDictionary *v,NSData *j){dispatch_async(dispatch_get_main_queue(),^{if(epoch!=self.runEpoch){answer(@{@"error":@"task_stopped"},nil);return;}self.observationID=v[@"observation"];if(j && !v[@"error"]){self.snapshotPreview.image=[UIImage imageWithData:j];self.snapshotPreview.hidden=NO;}answer(v,j);});}];
        }];
    }];
}
- (void)perform:(NSDictionary *)action completion:(void (^)(NSDictionary *))completion {
    if(!self.connection || !self.authorized || !self.observationID){completion(@{@"error":@"look_required_or_task_stopped"});return;}
    NSString *observation=self.observationID;self.observationID=nil;
    if([action[@"action"] isEqual:@"wait"]) {
        id value=action[@"ms"];
        if(![value isKindOfClass:NSNumber.class] || [value doubleValue]<0 || [value doubleValue]>3000){completion(@{@"error":@"invalid_wait"});return;}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,[value doubleValue]*NSEC_PER_MSEC),dispatch_get_main_queue(),^{completion(@{@"ok":@YES});});return;
    }
    if([action[@"action"] isEqual:@"navigate"]) {
        NSString *text=action[@"url"];NSURL *url=[text isKindOfClass:NSString.class] ? [NSURL URLWithString:text] : nil;
        if(!url.host.length || text.length>4096 || ![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]) {
            completion(@{@"error":@"only_http_safari_navigation_allowed"});return;
        }
        // LC delivers a UIOpenURLAction to THIS guest scene. No UIApplication.openURL / system launch.
        [self.guest openURLScheme:text];
        completion(@{@"ok":@YES,@"dispatch":@"Safari guest-scene URL action",@"verify":@"Read the guest again after loading"});return;
    }
    __block BOOL finished=NO;
    void (^answer)(NSDictionary *)=^(NSDictionary *v){dispatch_async(dispatch_get_main_queue(),^{if(finished)return;finished=YES;completion(v);});};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{answer(@{@"error":@"contained_action_timeout"});});
    if([@[@"navigate",@"web_click",@"web_fill",@"web_scroll"] containsObject:action[@"action"]])
        [[self remote] web:action run:self.runID observation:observation reply:answer];
    else [[self remote] perform:action run:self.runID observation:observation approval:NO reply:answer];
}
- (void)stop { self.runEpoch++; self.authorized=NO;self.observationID=nil;if(self.runID && self.connection)[[self remote] setRun:self.runID enabled:NO reply:^(BOOL ok){}]; }
- (void)toggleFloatingPreview {
    if(self.pip.isPictureInPictureActive){[self.pip stopPictureInPicture];return;}
    if(!AVPictureInPictureController.isPictureInPictureSupported || !self.guest.contentView){self.label.text=@"Floating preview unavailable";return;}
    [self.view endEditing:YES];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    self.pipVC=[AVPictureInPictureVideoCallViewController new];self.pipVC.preferredContentSize=CGSizeMake(402,874);
    AVPictureInPictureControllerContentSource *source=[[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:self.preview contentViewController:self.pipVC];
    self.pip=[[AVPictureInPictureController alloc] initWithContentSource:source];self.pip.delegate=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.4*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self.pip startPictureInPicture];});
}
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pip {
    self.guest.shouldIgnoreSceneUpdates=YES;UIView *view=self.guest.contentView;view.transform=CGAffineTransformIdentity;
    view.frame=self.pipVC.view.bounds;view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.pipVC.view addSubview:view];
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pip {
    self.guest.shouldIgnoreSceneUpdates=YES;[self.guest.view insertSubview:self.guest.contentView atIndex:0];[self.view setNeedsLayout];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)pip failedToStartPictureInPictureWithError:(NSError *)error {
    [self pictureInPictureControllerDidStopPictureInPicture:pip];self.label.text=@"System refused floating preview";
}
- (void)userTookControl { [self stop];[[NSNotificationCenter defaultCenter] postNotificationName:@"PokiContainedUserInterruption" object:self]; }
- (void)isolationBlocked:(NSString *)reason { self.label.text=reason;[self userTookControl]; }
- (void)appSceneVC:(id)vc didInitializeWithError:(NSError *)error { if(error)[self fail:@"Safari container process failed to launch"]; }
- (void)appSceneVCAppDidExit:(id)vc { self.generation++;[self stop];[self.connection invalidate];self.connection=nil;[self fail:@"Safari guest exited; no automatic restart"]; }
- (void)appSceneVCWillActivateScene:(PKLCScene *)vc { [vc setBackgroundNotificationEnabled:NO];[self appSceneVC:vc didUpdateFromSettings:nil transitionContext:nil lifecycleActionType:0]; }
- (void)appSceneVC:(PKLCScene *)vc didUpdateFromSettings:(id)base transitionContext:(id)context lifecycleActionType:(uint32_t)type {
    dispatch_async(dispatch_get_main_queue(),^{
        // LC's iOS 18+ updateSettings helper changes only the hosting view's frame. Send the
        // foreground setting to the actual guest FBSScene so WebKit can render while host is background.
        id scene=[vc.presenter valueForKey:@"scene"];
        [scene updateSettingsWithBlock:^(id settings){
            [settings setValue:@YES forKey:@"foreground"];
            [settings setValue:@1 forKey:@"interfaceOrientation"];
            [settings setValue:[NSValue valueWithCGRect:CGRectMake(0,0,402,874)] forKey:@"frame"];
        }];
        [self.view setNeedsLayout];
    });
}
@end
