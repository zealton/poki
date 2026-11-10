// SPDX-License-Identifier: AGPL-3.0-only
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <UserNotifications/UserNotifications.h>
#include <float.h>
#include <math.h>

static BOOL silentFocus=YES;
static NSString *instance;
static NSMutableSet *deferredPermissions;
static BOOL HasActivePrimaryScene(void) {
    for(UIWindowScene *s in UIApplication.sharedApplication.connectedScenes)
        if([s isKindOfClass:UIWindowScene.class]&&s.screen==UIScreen.mainScreen&&s.activationState==UISceneActivationStateForegroundActive)return YES;
    return NO;
}
static BOOL IsIsolated(void) {return silentFocus&&!HasActivePrimaryScene();}
static NSURL *BridgeURL(NSString *name) {
    const char *configured=getenv("POKI_SCENE_BRIDGE_DIRECTORY");
    NSURL *dir=configured?[[NSURL alloc]initFileURLWithPath:@(configured) isDirectory:YES]:[[[NSFileManager defaultManager]URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"SceneBridge"];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:name];
}
static void WriteJSON(id object,NSString *name) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    NSError *error=nil;[d writeToURL:BridgeURL(name) options:NSDataWritingAtomic error:&error];
    static BOOL reported=NO;if(error&&!reported){reported=YES;NSLog(@"[PokiSceneBridge] Transport write failed: %@",error);}
}
static NSMutableArray *bridgeEvents;
static void Trace(NSString *event,NSDictionary *info) {
    if(!bridgeEvents)bridgeEvents=[NSMutableArray new];
    NSMutableDictionary *r=[@{@"event":event,@"at":@([NSDate date].timeIntervalSince1970)} mutableCopy];
    [r addEntriesFromDictionary:info?:@{}];[bridgeEvents addObject:r];
    if(bridgeEvents.count>512)[bridgeEvents removeObjectsInRange:NSMakeRange(0,bridgeEvents.count-512)];
    WriteJSON(bridgeEvents,@"events.json");
    static NSSet *terminal;static dispatch_once_t once;
    dispatch_once(&once,^{terminal=[NSSet setWithArray:@[@"frame.captured",@"frame.captureFailed",@"nativeTouch.ended",@"nativeTouch.failed",@"text.inserted",@"text.noInput",@"text.replaceUnsupported",@"command.exception",@"command.noExternalWindow",@"command.isolationUnavailable",@"command.instanceMismatch",@"command.expired",@"command.unsupported"]];});
    if(r[@"id"]&&[terminal containsObject:event]) {
        NSMutableDictionary *result=r.mutableCopy;result[@"instance"]=instance?:@"";
        result[@"ok"]=@([@[@"frame.captured",@"nativeTouch.ended",@"text.inserted"]containsObject:event]);
        WriteJSON(result,@"result.json");
    }
}
static UIWindow *ExternalWindow(void) {
    UIWindow *best=nil;double score=-DBL_MAX;
    for(UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
        if(![s isKindOfClass:UIWindowScene.class]||s.screen==UIScreen.mainScreen)continue;
        for(UIWindow *w in s.windows) {
            if(w.hidden||!w.rootViewController||w.bounds.size.width<1||w.bounds.size.height<1)continue;
            double active=s.activationState==UISceneActivationStateForegroundActive?1e9:s.activationState==UISceneActivationStateForegroundInactive?1e8:0;
            double area=w.bounds.size.width*w.bounds.size.height;
            double candidate=active+area-(fabs(w.windowLevel)>1?1e6:0);
            if(candidate>score){score=candidate;best=w;}
        }
    }
    return best;
}
static NSUInteger visited;
static void Flatten(UIView *v,UIWindow *w,NSMutableArray *rows) {
    if(rows.count>=250||visited++>=1500||v.hidden)return;
    NSMutableDictionary *r=[@{@"class":NSStringFromClass(v.class),@"frame":NSStringFromCGRect([v convertRect:v.bounds toView:w]),@"identifier":v.accessibilityIdentifier?:@"",@"firstResponder":@(v.isFirstResponder)}mutableCopy];
    r[@"acceptsText"]=@([v conformsToProtocol:@protocol(UIKeyInput)]);
    @try {
        if(v.accessibilityLabel.length)r[@"label"]=v.accessibilityLabel;
        id value=v.accessibilityValue;if([value isKindOfClass:NSString.class]&&[value length])r[@"value"]=value;
        if([v isKindOfClass:UIControl.class]){r[@"control"]=@YES;r[@"enabled"]=@([(UIControl *)v isEnabled]);}
        if([v isKindOfClass:UICollectionViewCell.class]||[v isKindOfClass:UITableViewCell.class])r[@"cell"]=@YES;
        SEL text=NSSelectorFromString(@"text");
        if([v respondsToSelector:text]) {id value=((id(*)(id,SEL))objc_msgSend)(v,text);if([value isKindOfClass:NSString.class])r[@"text"]=value;}
        if([v isKindOfClass:UIButton.class])r[@"title"]=[(UIButton *)v currentTitle]?:@"";
        Class web=NSClassFromString(@"WKWebView");
        if(web&&[v isKindOfClass:web]) {
            id url=((id(*)(id,SEL))objc_msgSend)(v,NSSelectorFromString(@"URL"));
            id title=((id(*)(id,SEL))objc_msgSend)(v,NSSelectorFromString(@"title"));
            BOOL loading=((BOOL(*)(id,SEL))objc_msgSend)(v,NSSelectorFromString(@"isLoading"));
            UIScrollView *scroll=((id(*)(id,SEL))objc_msgSend)(v,NSSelectorFromString(@"scrollView"));
            r[@"webURL"]=[url isKindOfClass:NSURL.class]?[url absoluteString]:@"";
            r[@"webTitle"]=[title isKindOfClass:NSString.class]?title:@"";r[@"webLoading"]=@(loading);r[@"webScrollOffset"]=NSStringFromCGPoint(scroll.contentOffset);
            static NSString *previousWebState;NSString *key=[NSString stringWithFormat:@"%@|%@|%d|%@",r[@"webURL"],r[@"webTitle"],loading,r[@"webScrollOffset"]];
            if(![key isEqual:previousWebState]){previousWebState=key;Trace(@"web.observed",r);}
            [rows addObject:r];return; // Rendering layers are not semantic controls.
        }
    } @catch(NSException *e) {r[@"observationError"]=e.name;}
    if([r[@"acceptsText"]boolValue]||r[@"control"]||r[@"cell"]||[r[@"identifier"]length]||[r[@"text"]length]||[r[@"title"]length]||[r[@"label"]length]||[r[@"value"]length])[rows addObject:r];
    for(UIView *child in v.subviews)Flatten(child,w,rows);
}
static BOOL (*originalSuppressFocus)(id,SEL);
static BOOL SuppressFocus(id self,SEL cmd) {return IsIsolated()?YES:originalSuppressFocus(self,cmd);}
static BOOL (*originalSuppressKeyboard)(id,SEL);
static BOOL SuppressKeyboard(id self,SEL cmd) {return IsIsolated()?YES:originalSuppressKeyboard(self,cmd);}
static void (*originalNotificationRequest)(id,SEL,UNAuthorizationOptions,void(^)(BOOL,NSError *));
static void NotificationRequest(id self,SEL cmd,UNAuthorizationOptions options,void(^done)(BOOL,NSError *)) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(getenv("POKI_CARPLAY_ISOLATED_LAUNCH")&&IsIsolated()) {
            if(![deferredPermissions containsObject:@"notifications"]){[deferredPermissions addObject:@"notifications"];Trace(@"permission.deferred",@{@"kind":@"notifications"});}
            if(done)done(NO,[NSError errorWithDomain:@"PokiExternalDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Interactive notification authorization is deferred during external-display automation. Open this app normally to authorize it."}]);
        } else originalNotificationRequest(self,cmd,options,done);
    });
}
static BOOL NativePhase(UIWindow *w,CGPoint point,NSInteger phase,uint32_t finger) {
    typedef CFTypeRef (*HandFn)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
    typedef CFTypeRef (*FingerFn)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
    typedef void (*IntFn)(CFTypeRef,uint32_t,CFIndex);
    typedef void (*FloatFn)(CFTypeRef,uint32_t,double);
    typedef void (*AppendFn)(CFTypeRef,CFTypeRef,uint32_t);
    typedef void (*ContextFn)(CFTypeRef,uint32_t,uint8_t,uint8_t,CFStringRef,CFTimeInterval,float);
    static HandFn hand;static FingerFn fingerEvent;static IntFn setInt;static FloatFn setFloat;static AppendFn append;static ContextFn context;
    static dispatch_once_t once;dispatch_once(&once,^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",RTLD_NOW|RTLD_GLOBAL);
        hand=(HandFn)dlsym(RTLD_DEFAULT,"IOHIDEventCreateDigitizerEvent");fingerEvent=(FingerFn)dlsym(RTLD_DEFAULT,"IOHIDEventCreateDigitizerFingerEvent");
        setInt=(IntFn)dlsym(RTLD_DEFAULT,"IOHIDEventSetIntegerValue");setFloat=(FloatFn)dlsym(RTLD_DEFAULT,"IOHIDEventSetFloatValue");
        append=(AppendFn)dlsym(RTLD_DEFAULT,"IOHIDEventAppendEvent");context=(ContextFn)dlsym(RTLD_DEFAULT,"BKSHIDEventSetDigitizerInfo");
    });
    SEL enqueue=NSSelectorFromString(@"_enqueueHIDEvent:");SEL contextID=NSSelectorFromString(@"_contextId");
    if(!hand||!fingerEvent||!setInt||!append||!context||![w respondsToSelector:contextID]||![UIApplication.sharedApplication respondsToSelector:enqueue]) {Trace(@"nativeTouch.unavailable",nil);return NO;}
    uint32_t cid=((uint32_t(*)(id,SEL))objc_msgSend)(w,contextID);if(!cid){Trace(@"nativeTouch.zeroContext",nil);return NO;}
    BOOL down=phase!=2;uint32_t mask=phase==1?0x44:0x22;uint64_t now=mach_absolute_time();
    CFTypeRef event=hand(kCFAllocatorDefault,now,3,0,0,mask,0,0,0,0,0,0,0,down,0);
    CFTypeRef child=fingerEvent(kCFAllocatorDefault,now,finger,finger,phase==1?4:3,point.x,point.y,0,down?1:0,0,down,down,0);
    if(!event||!child){if(event)CFRelease(event);if(child)CFRelease(child);return NO;}
    setInt(event,(11<<16)+25,1);
    if(setFloat){setFloat(child,(11<<16)+20,5);setFloat(child,(11<<16)+21,5);}
    append(event,child,0);context(event,cid,0,0,NULL,0,0);
    ((void(*)(id,SEL,CFTypeRef))objc_msgSend)(UIApplication.sharedApplication,enqueue,event);
    CFRelease(child);CFRelease(event);return YES;
}
static void NativeGesture(UIWindow *w,CGPoint start,CGPoint end,BOOL swipe,NSString *commandID) {
    if(silentFocus&&originalSuppressFocus&&!w.isKeyWindow) {
        [w makeKeyWindow];Trace(@"window.localKey",@{@"id":commandID,@"key":@(w.isKeyWindow)});
    }
    static uint32_t sequence=700;uint32_t finger=sequence++;
    UIView *hit=[w hitTest:start withEvent:nil];
    if(!NativePhase(w,start,0,finger)){Trace(@"nativeTouch.failed",@{@"id":commandID});return;}
    Trace(@"nativeTouch.began",@{@"id":commandID,@"hit":hit?NSStringFromClass(hit.class):@"nil",@"swipe":@(swipe)});
    NSUInteger steps=swipe?10:0;
    for(NSUInteger i=1;i<=steps;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(i*.035*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        CGPoint p=CGPointMake(start.x+(end.x-start.x)*i/steps,start.y+(end.y-start.y)*i/steps);NativePhase(w,p,1,finger);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((swipe?.4:.1)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{NativePhase(w,swipe?end:start,2,finger);Trace(@"nativeTouch.ended",@{@"id":commandID});});
}
static void InsertTargetText(UIWindow *w,CGPoint point,NSString *text,BOOL replace,NSString *cid) {
    UIView *v=[w hitTest:point withEvent:nil];
    while(v&&![v conformsToProtocol:@protocol(UIKeyInput)])v=v.superview;
    if(!v){Trace(@"text.noInput",@{@"id":cid});return;}
    BOOL became=[v becomeFirstResponder];
    if(replace) {
        if(![v conformsToProtocol:@protocol(UITextInput)]){Trace(@"text.replaceUnsupported",@{@"id":cid});return;}
        id<UITextInput> input=(id)v;input.selectedTextRange=[input textRangeFromPosition:input.beginningOfDocument toPosition:input.endOfDocument];
    }
    [(id<UIKeyInput>)v insertText:text?:@""];
    NSString *actual=nil;
    @try {
        SEL getter=NSSelectorFromString(@"text");
        if([v respondsToSelector:getter])actual=((id(*)(id,SEL))objc_msgSend)(v,getter);
        else if([v conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> input=(id)v;UITextRange *range=[input textRangeFromPosition:input.beginningOfDocument toPosition:input.endOfDocument];
            if(range)actual=[input textInRange:range];
        }
    } @catch(NSException *e) {Trace(@"text.readbackUnavailable",@{@"id":cid,@"error":e.name});}
    Trace(@"text.inserted",@{@"id":cid,@"class":NSStringFromClass(v.class),@"became":@(became),@"firstResponder":@(v.isFirstResponder),@"text":[actual isKindOfClass:NSString.class]?actual:@"",@"actualTextReadable":@([actual isKindOfClass:NSString.class]),@"requestedText":text?:@""});
}
static void Tick(void) {
    UIWindow *w=ExternalWindow();NSMutableArray *rows=[NSMutableArray new];visited=0;
    @try {if(w)Flatten(w,w,rows);}
    @catch(NSException *e){Trace(@"observation.exception",@{@"error":e.name});}
    WriteJSON(@{@"at":@([NSDate date].timeIntervalSince1970),@"instance":instance?:@"",@"keyboardFocusHook":@(originalSuppressFocus!=NULL),@"primarySceneActive":@(HasActivePrimaryScene()),@"deferredPermissions":deferredPermissions.allObjects?:@[],@"pid":@(getpid()),@"bundle":NSBundle.mainBundle.bundleIdentifier?:@"",@"window":w?NSStringFromClass(w.class):@"none",@"screenBounds":w?NSStringFromCGRect(w.screen.bounds):@"",@"windowBounds":w?NSStringFromCGRect(w.bounds):@"",@"scene":w.windowScene.session.persistentIdentifier?:@"",@"localKeyWindow":@(w.isKeyWindow),@"applicationState":@(UIApplication.sharedApplication.applicationState),@"sceneState":w?@(w.windowScene.activationState):@(-1),@"silentFocus":@(silentFocus),@"views":rows},@"state.json");
    static NSString *lastID;
    NSDictionary *command=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:BridgeURL(@"command.json")]?:[NSData data] options:0 error:nil];
    NSString *cid=command[@"id"];
    if(!cid||[cid isEqual:lastID])return;lastID=cid;
    @try {
        if(![command[@"instance"]isEqual:instance]){Trace(@"command.instanceMismatch",@{@"id":cid});return;}
        double expires=[command[@"expiresAt"]doubleValue];
        if(expires<=NSDate.date.timeIntervalSince1970){Trace(@"command.expired",@{@"id":cid});return;}
        NSString *op=command[@"op"];
        if([op isEqual:@"policy"]){silentFocus=[command[@"silentFocus"]boolValue];Trace(@"policy",@{@"id":cid,@"silentFocus":@(silentFocus)});return;}
        if(!w){Trace(@"command.noExternalWindow",@{@"id":cid});return;}
        if(HasActivePrimaryScene()&&![op isEqual:@"capture"]){Trace(@"command.isolationUnavailable",@{@"id":cid,@"reason":@"Owner is using this app on the primary display"});return;}
        if(silentFocus&&!originalSuppressFocus&&![op isEqual:@"capture"]){Trace(@"command.isolationUnavailable",@{@"id":cid});return;}
        CGPoint point=CGPointMake([command[@"x"]doubleValue],[command[@"y"]doubleValue]);
        UIView *v=[w hitTest:point withEvent:nil];
        if([op isEqual:@"sequence"]){
            NSArray *steps=command[@"steps"];if(steps.count>100){Trace(@"sequence.tooLong",@{@"id":cid});return;}
            [steps enumerateObjectsUsingBlock:^(NSDictionary *step,NSUInteger i,BOOL *stop){
                double after=MAX(0,MIN(60,[step[@"after"]doubleValue]));NSString *sid=[cid stringByAppendingFormat:@"_%lu",(unsigned long)i];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(after*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    @try {
                        if(!w.windowScene||w.hidden){Trace(@"sequence.windowGone",@{@"id":sid});return;}
                        CGPoint p=CGPointMake([step[@"x"]doubleValue],[step[@"y"]doubleValue]);NSString *kind=step[@"op"];
                        if([kind isEqual:@"text"])InsertTargetText(w,p,step[@"text"],[step[@"replace"]boolValue],sid);
                        else if([kind isEqual:@"tap"]||[kind isEqual:@"swipe"])NativeGesture(w,p,CGPointMake([step[@"endX"]doubleValue],[step[@"endY"]doubleValue]),[kind isEqual:@"swipe"],sid);
                    } @catch(NSException *e){Trace(@"sequence.exception",@{@"id":sid,@"error":e.description});}
                });
            }];
            Trace(@"sequence.scheduled",@{@"id":cid,@"steps":@(steps.count)});
        } else if([op isEqual:@"tap"]||[op isEqual:@"swipe"]){
            NativeGesture(w,point,CGPointMake([command[@"endX"]doubleValue],[command[@"endY"]doubleValue]),[op isEqual:@"swipe"],cid);
        } else if([op isEqual:@"text"]){
            InsertTargetText(w,point,command[@"text"],[command[@"replace"]boolValue],cid);
        } else if([op isEqual:@"capture"]){
            UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc]initWithBounds:w.bounds];
            __block BOOL drawn=NO;UIImage *im=[r imageWithActions:^(UIGraphicsImageRendererContext *c){drawn=[w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];}];
            BOOL saved=[UIImagePNGRepresentation(im)writeToURL:BridgeURL(@"frame.png") atomically:YES];Trace(drawn&&saved?@"frame.captured":@"frame.captureFailed",@{@"id":cid});
        } else Trace(@"command.unsupported",@{@"id":cid});
    } @catch(NSException *e){Trace(@"command.exception",@{@"id":cid,@"error":e.description});}
}

static BOOL IsExternalRole(NSString *role) {
    return [role hasPrefix:@"UIWindowSceneSessionRoleCarPlay"] || [role hasPrefix:@"CPTemplateApplicationSceneSessionRole"] || [role hasPrefix:@"UIWindowSceneSessionRoleExternalDisplay"];
}
static NSString *(*originalRole)(id,SEL);
static NSString *BridgeRole(id self,SEL cmd) {
    NSString *role=originalRole(self,cmd);
    return IsExternalRole(role)?UIWindowSceneSessionRoleApplication:role;
}
static id (*originalConfig)(id,SEL,NSString *,NSString *);
static id BridgeConfig(id self,SEL cmd,NSString *name,NSString *role) {
    if(IsExternalRole(role)) {role=UIWindowSceneSessionRoleApplication;name=nil;}
    return originalConfig(self,cmd,name,role);
}
static UIUserInterfaceIdiom (*originalIdiom)(id,SEL);
static UIUserInterfaceIdiom BridgeIdiom(id self,SEL cmd) {
    UIUserInterfaceIdiom idiom=originalIdiom(self,cmd);
    return idiom==UIUserInterfaceIdiomCarPlay?UIUserInterfaceIdiomPhone:idiom;
}
__attribute__((constructor)) static void Install(void) {
    @autoreleasepool {
        instance=NSUUID.UUID.UUIDString;
        deferredPermissions=[NSMutableSet new];
        Trace(@"bridge.loaded",@{@"bundle":NSBundle.mainBundle.bundleIdentifier?:@"",@"pid":@(getpid())});
        Method role=class_getInstanceMethod(UISceneSession.class,@selector(role));
        Method config=class_getInstanceMethod(UISceneConfiguration.class,@selector(initWithName:sessionRole:));
        originalRole=(void *)method_setImplementation(role,(IMP)BridgeRole);
        originalConfig=(void *)method_setImplementation(config,(IMP)BridgeConfig);
        Method idiom=class_getInstanceMethod(UITraitCollection.class,@selector(userInterfaceIdiom));
        originalIdiom=(void *)method_setImplementation(idiom,(IMP)BridgeIdiom);
        Method focus=class_getInstanceMethod(NSClassFromString(@"_UIApplicationSceneKeyboardClientComponent"),NSSelectorFromString(@"suppressKeyboardFocusRequests"));
        if(focus)originalSuppressFocus=(void *)method_setImplementation(focus,(IMP)SuppressFocus);
        Method keyboard=class_getInstanceMethod(NSClassFromString(@"UIKeyboardImpl"),NSSelectorFromString(@"_shouldSuppressSoftwareKeyboard"));
        if(keyboard)originalSuppressKeyboard=(void *)method_setImplementation(keyboard,(IMP)SuppressKeyboard);
        Method notifications=class_getInstanceMethod(UNUserNotificationCenter.class,@selector(requestAuthorizationWithOptions:completionHandler:));
        if(notifications)originalNotificationRequest=(void *)method_setImplementation(notifications,(IMP)NotificationRequest);
        dispatch_async(dispatch_get_main_queue(),^{
            Trace(@"bridge.installed",@{@"keyboardFocusHook":@(focus!=NULL),@"keyboardAppearanceHook":@(keyboard!=NULL)});
            [NSTimer scheduledTimerWithTimeInterval:.15 repeats:YES block:^(NSTimer *t){Tick();}];
        });
        NSLog(@"[PokiSceneBridge] Installed scene-role normalization in %@",NSBundle.mainBundle.bundleIdentifier);
    }
}
