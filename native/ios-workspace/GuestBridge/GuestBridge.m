// SPDX-License-Identifier: AGPL-3.0-only
#import "WorkspaceIPC.h"
#import "WorkspacePolicy.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>

static UIWindow *GuestWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)scene).windows)
                if (!w.hidden && w.rootViewController && w.bounds.size.width > 50)
                    return w;
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (!w.hidden && w.rootViewController)
            return w;
    return nil;
}
static BOOL SecureInput(UIView *view) {
    return ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) &&
           [(id<UITextInputTraits>)view isSecureTextEntry];
}
static NSString *ViewLabel(UIView *v) {
    if ([v isKindOfClass:UIButton.class])
        return ((UIButton *)v).currentTitle ?: v.accessibilityLabel ?: @"";
    if ([v isKindOfClass:UILabel.class])
        return ((UILabel *)v).text ?: @"";
    if ([v isKindOfClass:UITextField.class])
        return ((UITextField *)v).placeholder ?: v.accessibilityLabel ?: @"";
    return v.accessibilityLabel ?: @"";
}
static void Paint(CALayer *layer) {
    [layer displayIfNeeded];
    for (CALayer *child in layer.sublayers)
        Paint(child);
}
static WKWebView *GuestWeb(UIView *v, UIWindow *w) {
    if(v.hidden || v.alpha<.01 || !CGRectIntersectsRect([v convertRect:v.bounds toView:w],w.bounds))return nil;
    WKWebView *best=[v isKindOfClass:WKWebView.class] ? (id)v : nil;
    for(UIView *child in v.subviews) {
        WKWebView *next=GuestWeb(child,w);
        if(next && (!best || next.bounds.size.width*next.bounds.size.height>best.bounds.size.width*best.bounds.size.height))best=next;
    }
    return best;
}
static UIView *ControlAt(UIWindow *w, CGPoint point, BOOL scrolling) {
    UIView *v = [w hitTest:point withEvent:nil];
    while (v && v != w) {
        if (scrolling ? [v isKindOfClass:UIScrollView.class]
                      : ([v isKindOfClass:UIControl.class] || [v isKindOfClass:UITextView.class]))
            return v;
        v = v.superview;
    }
    return nil;
}

@interface PKWGuestBridge : NSObject <PKWGuest, NSXPCListenerDelegate>
@property NSXPCListener *listener;
@property int hostPID, workerPID;
@property NSString *runID, *observationID;
@property BOOL enabled;
@property BOOL strictIsolation;
@property WKWebView *observedWeb;
@property NSMutableDictionary *targets;
@property NSArray *labels;
@property NSMutableArray<NSXPCConnection *> *connections;
- (void)blockIsolation:(NSString *)reason;
@end
@implementation PKWGuestBridge
- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *b = [NSClassFromString(@"LiveProcessHandler") retrievedAppInfo];
        self.hostPID = [b[@"pokiHostPID"] intValue];
        self.strictIsolation=[b[@"pokiStrictIsolation"] boolValue];
        self.connections = [NSMutableArray new];
        self.listener = [NSXPCListener anonymousListener];
        self.listener.delegate = self;
        [self.listener resume];
        PKWConnectBroker(@"guest", self.listener.endpoint);
        [NSNotificationCenter.defaultCenter addObserverForName:@"PKWHostDisconnected"
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) {
                                                        self.enabled = NO;
                                                    }];
    }
    return self;
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    if (![c respondsToSelector:@selector(processIdentifier)])
        return NO;
    int pid = c.processIdentifier;
    if (pid != self.hostPID && pid != self.workerPID)
        return NO;
    c.exportedInterface = PKWInterface(@protocol(PKWGuest));
    c.exportedObject = self;
    if (pid == self.workerPID || pid == self.hostPID)
        c.remoteObjectInterface = PKWInterface(@protocol(PKWGuestEvents));
    [self.connections addObject:c];
    [c resume];
    return YES;
}
- (void)authorizeWorker:(int)pid run:(NSString *)run reply:(void (^)(BOOL))reply {
    if (NSXPCConnection.currentConnection.processIdentifier != self.hostPID) {
        reply(NO);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.workerPID = pid;
        self.runID = run;
        [GuestWindow() endEditing:YES];
        self.enabled = YES;
        reply(YES);
    });
}
- (void)setRun:(NSString *)run enabled:(BOOL)enabled reply:(void (^)(BOOL))reply {
    int caller = NSXPCConnection.currentConnection.processIdentifier;
    if (caller != self.hostPID && caller != self.workerPID) {
        reply(NO);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL valid = [run isEqual:self.runID];
        if (valid)
            self.enabled = enabled;
        reply(valid);
    });
}
- (void)walk:(UIView *)v window:(UIWindow *)w rows:(NSMutableArray *)rows {
    if (rows.count >= 160 || v.hidden || v.alpha < .01)
        return;
    CGRect r = [v convertRect:v.bounds toView:w];
    if (!CGRectIntersectsRect(r, w.bounds))
        return;
    NSString *label = ViewLabel(v);
    BOOL editable = [v isKindOfClass:UITextField.class] || [v isKindOfClass:UITextView.class];
    BOOL secure = SecureInput(v);
    if (label.length || editable || [v isKindOfClass:UIControl.class] ||
        [v isKindOfClass:UIScrollView.class]) {
        NSString *identifier = [NSString stringWithFormat:@"v%lu", (unsigned long)rows.count];
        NSString *kind = [v isKindOfClass:UIButton.class] ? @"button"
                         : editable ? @"text"
                                    : ([v isKindOfClass:UIScrollView.class] ? @"scroll" : @"label");
        NSMutableDictionary *row = [@{
            @"id" : identifier,
            @"kind" : kind,
            @"label" : label.length > 180 ? [label substringToIndex:180] : label,
            @"x" : @(CGRectGetMidX(r)),
            @"y" : @(CGRectGetMidY(r)),
            @"width" : @(r.size.width),
            @"height" : @(r.size.height),
            @"secure" : @(secure)
        } mutableCopy];
        if (!secure && editable) {
            NSString *value = [v valueForKey:@"text"] ?: @"";
            row[@"value"] = value.length > 250 ? [value substringToIndex:250] : value;
        }
        [rows addObject:row];
        self.targets[identifier] =
            @{@"view" : v, @"label" : label, @"rect" : [NSValue valueWithCGRect:r]};
    }
    // Secure values are not exposed as text; their normal UIKit rendering contains only masking
    // dots.
    for (UIView *child in v.subviews)
        [self walk:child window:w rows:rows];
}
- (void)observe:(void (^)(NSDictionary *, NSData *))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = GuestWindow();
        if (!w) {
            reply(@{@"error" : @"guest_window_unavailable"}, nil);
            return;
        }
        [w layoutIfNeeded];
        Paint(w.layer);
        self.targets = [NSMutableDictionary new];
        NSMutableArray *rows = [NSMutableArray new];
        [self walk:w window:w rows:rows];
        self.labels = [rows valueForKey:@"label"];
        self.observationID = NSUUID.UUID.UUIDString;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = MIN(2, 900.0 / MAX(1, w.bounds.size.width));
        format.opaque = YES;
        UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *c) {
                [w.layer renderInContext:c.CGContext];
            }];
        NSMutableDictionary *observation=[@{
                @"observation" : self.observationID,
                @"width" : @(w.bounds.size.width),
                @"height" : @(w.bounds.size.height),
                @"controls" : rows,
                @"bundle" : NSBundle.mainBundle.bundleIdentifier ?: @"",
                @"pid" : @(NSProcessInfo.processInfo.processIdentifier),
                @"capture" : @"guest-calayer"
            } mutableCopy];
        observation[@"applicationClass"]=NSStringFromClass(UIApplication.sharedApplication.class);
        self.observedWeb=GuestWeb(w,w);
        WKWebView *web=self.observedWeb;
        if(self.strictIsolation) NSLog(@"PokiContained observe: UIKit rendered; web=%d",web!=nil);
        if(!web){observation[@"web"]=@{@"available":@NO};reply(observation,UIImageJPEGRepresentation(image,.65));return;}
        NSString *script=@"(()=>{const es=[...document.querySelectorAll('a,button,input:not([type=password]),textarea,select')].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight}).slice(0,90);return {url:location.href,title:document.title,text:document.body.innerText.slice(0,7000),controls:es.map((e,i)=>{e.setAttribute('data-poki-target','p'+i);let r=e.getBoundingClientRect();return {id:'p'+i,tag:e.tagName,label:(e.innerText||e.getAttribute('aria-label')||e.placeholder||'').slice(0,160),value:e.type==='password'?'':(e.value||'').slice(0,150),href:e.href||'',x:r.x,y:r.y,width:r.width,height:r.height}}),images:[...document.images].filter(e=>e.complete&&e.naturalWidth>0).map(e=>({alt:e.alt,width:e.naturalWidth,height:e.naturalHeight})).slice(0,30)}})()";
        [web evaluateJavaScript:script completionHandler:^(id dom,NSError *error){
            if(self.strictIsolation) NSLog(@"PokiContained observe: DOM returned; error=%d",error!=nil);
            observation[@"web"]= [dom isKindOfClass:NSDictionary.class] ? dom : @{@"error":@"web_dom_not_ready",@"url":web.URL.absoluteString?:@""};
            WKSnapshotConfiguration *config=[WKSnapshotConfiguration new];config.afterScreenUpdates=NO;config.rect=web.bounds;config.snapshotWidth=@(web.bounds.size.width);
            __block BOOL snapshotFinished=NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                if(snapshotFinished)return;snapshotFinished=YES;
                observation[@"error"]=@"real_web_snapshot_timed_out";observation[@"capture"]=@"guest-calayer-without-web-pixels";
                reply(observation,UIImageJPEGRepresentation(image,.65));
            });
            [web takeSnapshotWithConfiguration:config completionHandler:^(UIImage *webImage,NSError *snapshotError){
                if(snapshotFinished)return;snapshotFinished=YES;
                if(self.strictIsolation) NSLog(@"PokiContained observe: snapshot returned; pixels=%d error=%d",webImage!=nil,snapshotError!=nil);
                UIImage *combined=image;
                if(webImage){
                    CGRect rect=[web convertRect:web.bounds toView:w];
                    combined=[[[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *c){[image drawAtPoint:CGPointZero];[webImage drawInRect:rect];}];
                    observation[@"capture"]=@"guest-calayer+real-WKWebView-snapshot";
                } else observation[@"webSnapshotError"]=@"WebKit did not return independent pixels";
                reply(observation,UIImageJPEGRepresentation(combined,.75));
            }];
        }];
    });
}
- (void)web:(NSDictionary *)action run:(NSString *)run observation:(NSString *)observation reply:(void (^)(NSDictionary *))reply {
    int caller=NSXPCConnection.currentConnection.processIdentifier;
    dispatch_async(dispatch_get_main_queue(),^{
        if(caller!=self.workerPID || !self.enabled || ![run isEqual:self.runID]){reply(@{@"error":@"run_revoked"});return;}
        if(![observation isEqual:self.observationID] || !self.observedWeb){reply(@{@"error":@"fresh_web_observation_required"});return;}
        NSString *kind=action[@"action"],*script=nil;
        if([kind isEqual:@"web_scroll"]) {
            NSNumber *dy=action[@"dy"];
            if(![dy isKindOfClass:NSNumber.class] || fabs(dy.doubleValue)>2000){reply(@{@"error":@"invalid_scroll"});return;}
            script=[NSString stringWithFormat:@"window.scrollBy(0,%f);true",dy.doubleValue];
        } else if([@[@"web_click",@"web_fill"] containsObject:kind]) {
            NSString *target=action[@"target"];
            if(![target isKindOfClass:NSString.class] || ![target hasPrefix:@"p"] || target.length>6){reply(@{@"error":@"invalid_web_target"});return;}
            NSCharacterSet *digits=NSCharacterSet.decimalDigitCharacterSet;
            if([[target substringFromIndex:1] rangeOfCharacterFromSet:digits.invertedSet].location!=NSNotFound){reply(@{@"error":@"invalid_web_target"});return;}
            if([kind isEqual:@"web_click"])script=[NSString stringWithFormat:@"(()=>{let e=document.querySelector('[data-poki-target=%@]');if(!e||e.disabled||e.type==='password')return {error:'unsupported'};e.click();return {ok:true}})()",target];
            else {
                NSString *text=action[@"text"];
                if(![text isKindOfClass:NSString.class] || text.length>2000){reply(@{@"error":@"invalid_web_text"});return;}
                NSString *quoted=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil] encoding:NSUTF8StringEncoding];
                script=[NSString stringWithFormat:@"(()=>{let e=document.querySelector('[data-poki-target=%@]');if(!e||e.disabled||e.readOnly||e.type==='password'||!['INPUT','TEXTAREA'].includes(e.tagName))return {error:'unsupported'};Object.getOwnPropertyDescriptor(e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype,'value').set.call(e,(%@)[0]);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return {ok:true}})()",target,quoted];
            }
        } else {reply(@{@"error":@"unsupported_web_action"});return;}
        self.observationID=nil;
        [self.observedWeb evaluateJavaScript:script completionHandler:^(id value,NSError *error){reply(error?@{@"error":@"web_action_failed"}:([value isKindOfClass:NSDictionary.class] && value[@"error"] ? value : @{@"ok":@YES,@"result":value?:NSNull.null,@"pid":@(getpid())}));}];
    });
}
- (void)perform:(NSDictionary *)action
            run:(NSString *)run
    observation:(NSString *)observation
       approval:(BOOL)approved
          reply:(void (^)(NSDictionary *))reply {
    int caller = NSXPCConnection.currentConnection.processIdentifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (caller != self.workerPID || !self.enabled || ![run isEqual:self.runID]) {
            reply(@{@"error" : @"run_revoked"});
            return;
        }
        NSError *error = nil;
        NSDictionary *a = PKWParseAction(
            [NSJSONSerialization dataWithJSONObject:action options:0 error:nil], &error);
        if (!a || ![observation isEqual:self.observationID]) {
            reply(@{@"error" : a ? @"stale_observation" : @"invalid_action"});
            return;
        }
        UIWindow *w = GuestWindow();
        CGPoint point = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        if (!w || !CGRectContainsPoint(w.bounds, point)) {
            reply(@{@"error" : @"outside_guest"});
            return;
        }
        NSString *kind = a[@"action"];
        UIView *v = ControlAt(w, point, [kind isEqual:@"scroll"]);
        NSDictionary *cached = nil;
        for (NSDictionary *row in self.targets.allValues)
            if (row[@"view"] == v) {
                cached = row;
                break;
            }
        if (!v || !cached || ![cached[@"label"] isEqual:ViewLabel(v)]) {
            reply(@{@"error" : @"target_changed_or_unsupported"});
            return;
        }
        CGRect prior = [cached[@"rect"] CGRectValue], now = [v convertRect:v.bounds toView:w];
        if (fabs(prior.origin.x - now.origin.x) > 2 || fabs(prior.origin.y - now.origin.y) > 2) {
            reply(@{@"error" : @"target_moved"});
            return;
        }
        if (!v.userInteractionEnabled ||
            ([v isKindOfClass:UIControl.class] && !((UIControl *)v).enabled) ||
            ([kind isEqual:@"set_text"] && [v isKindOfClass:UITextView.class] && !((UITextView *)v).editable) ||
            ([kind isEqual:@"scroll"] && [v isKindOfClass:UIScrollView.class] && !((UIScrollView *)v).scrollEnabled)) {
            reply(@{@"error":@"control_not_interactive"});
            return;
        }
        if (SecureInput(v)) {
            reply(@{@"error" : @"owner_must_enter_secret"});
            return;
        }
        if ([kind isEqual:@"tap"] && PKWNeedsApproval(ViewLabel(v), self.labels) && !approved) {
            reply(@{@"approval_required" : @YES, @"label" : ViewLabel(v)});
            return;
        }
        if ([kind isEqual:@"tap"] && [v isKindOfClass:UIControl.class]) {
            UIControl *control=(id)v;
            UIControlEvents event=(control.allControlEvents & UIControlEventPrimaryActionTriggered) ? UIControlEventPrimaryActionTriggered : UIControlEventTouchUpInside;
            [control sendActionsForControlEvents:event];
        }
        else if ([kind isEqual:@"set_text"] && [v isKindOfClass:UITextField.class]) {
            UITextField *f = (id)v;
            f.text = a[@"text"];
            [f sendActionsForControlEvents:UIControlEventEditingChanged];
            [NSNotificationCenter.defaultCenter
                postNotificationName:UITextFieldTextDidChangeNotification
                              object:f];
        } else if ([kind isEqual:@"set_text"] && [v isKindOfClass:UITextView.class]) {
            UITextView *t = (id)v;
            t.text = a[@"text"];
            [NSNotificationCenter.defaultCenter
                postNotificationName:UITextViewTextDidChangeNotification
                              object:t];
            if ([t.delegate respondsToSelector:@selector(textViewDidChange:)])
                [t.delegate textViewDidChange:t];
        } else if ([kind isEqual:@"scroll"] && [v isKindOfClass:UIScrollView.class]) {
            UIScrollView *s = (id)v;
            CGFloat y = MAX(-s.adjustedContentInset.top,
                            MIN(s.contentOffset.y + [a[@"dy"] doubleValue],
                                MAX(0, s.contentSize.height - s.bounds.size.height +
                                           s.adjustedContentInset.bottom)));
            [s setContentOffset:CGPointMake(s.contentOffset.x, y) animated:NO];
        } else {
            reply(@{@"error" : @"unsupported_control_action"});
            return;
        }
        // No global touch synthesis, window activation, keyboard focus or application launch.
        self.observationID = nil;
        reply(@{
            @"ok" : @YES,
            @"action" : kind,
            @"target" : ViewLabel(v),
            @"pid" : @(NSProcessInfo.processInfo.processIdentifier)
        });
    });
}
- (void)blockIsolation:(NSString *)reason {
    self.enabled = NO;
    for (NSXPCConnection *c in self.connections)
        if (c.processIdentifier == self.workerPID) {
            id<PKWGuestEvents> agent = [c remoteObjectProxyWithErrorHandler:^(NSError *e){
            }];
            [agent isolationBlocked:reason];
        }
}
- (void)humanInput {
    if (!self.enabled)
        return;
    self.enabled = NO;
    for (NSXPCConnection *c in self.connections)
        if (c.processIdentifier == self.workerPID) {
            id<PKWGuestEvents> agent = [c remoteObjectProxyWithErrorHandler:^(NSError *e){
            }];
            [agent userTookControl];
        }
}
@end
static PKWGuestBridge *bridge;
static void (*originalSendEvent)(id, SEL, UIEvent *);
static void GuestSendEvent(UIApplication *app, SEL selector, UIEvent *event) {
    for (UITouch *touch in event.allTouches)
        if (touch.phase == UITouchPhaseBegan) {
            [bridge humanInput];
            break;
        }
    originalSendEvent(app, selector, event);
}
static BOOL (*oldResponder)(id, SEL);
static BOOL NoAgentResponder(id object, SEL selector) {
    if (bridge.enabled || bridge.strictIsolation)
        return NO;
    return oldResponder(object, selector);
}
static BOOL (*oldFieldResponder)(id, SEL);
static BOOL NoFieldResponder(id object, SEL selector) {
    if (bridge.enabled || bridge.strictIsolation)
        return NO;
    return oldFieldResponder(object, selector);
}
static BOOL (*oldTextResponder)(id, SEL);
static BOOL NoTextResponder(id object, SEL selector) {
    if (bridge.enabled || bridge.strictIsolation)
        return NO;
    return oldTextResponder(object, selector);
}
static void (*oldMakeKey)(id, SEL);
static void NoAgentKeyWindow(UIWindow *window, SEL selector) {
    if (bridge.enabled || bridge.strictIsolation)
        return;
    oldMakeKey(window, selector);
}
static void (*oldMakeVisible)(id, SEL);
static void NoAgentVisibleKeyWindow(UIWindow *window, SEL selector) {
    if (bridge.enabled || bridge.strictIsolation) {
        window.hidden = NO;
        return;
    }
    oldMakeVisible(window, selector);
}
static void (*oldOpenURL)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void ContainedOpenURL(id object, SEL selector, NSURL *url, NSDictionary *options,
                             void (^reply)(BOOL)) {
    if (bridge.enabled || bridge.strictIsolation) {
        [bridge blockIsolation:@"客体请求打开其他 App，Agent 已暂停"];
        if (reply)
            reply(NO);
        return;
    }
    oldOpenURL(object, selector, url, options, reply);
}
static BOOL (*oldLegacyURL)(id, SEL, NSURL *);
static BOOL ContainedLegacyURL(id object, SEL selector, NSURL *url) {
    if (bridge.enabled || bridge.strictIsolation) {
        [bridge blockIsolation:@"客体请求打开其他 App，Agent 已暂停"];
        return NO;
    }
    return oldLegacyURL(object, selector, url);
}
static void (*oldSceneActivation)(id, SEL, UISceneSession *, NSUserActivity *,
                                  UISceneActivationRequestOptions *, void (^)(NSError *));
static void ContainedSceneActivation(id object, SEL selector, UISceneSession *scene,
                                     NSUserActivity *activity,
                                     UISceneActivationRequestOptions *options,
                                     void (^reply)(NSError *)) {
    if (bridge.enabled || bridge.strictIsolation) {
        [bridge blockIsolation:@"客体请求切换系统窗口，Agent 已暂停"];
        if (reply)
            reply(PKWError(@"owner_required_for_scene_activation"));
        return;
    }
    oldSceneActivation(object, selector, scene, activity, options, reply);
}
static IMP Replace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        return NULL;
    IMP original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return original;
}
static void InstallIsolationGuards(void) {
    // Only this contained guest process is affected. Physical user input pauses ownership first.
    oldResponder =
        (void *)Replace(UIResponder.class, @selector(becomeFirstResponder), (IMP)NoAgentResponder);
    oldFieldResponder =
        (void *)Replace(UITextField.class, @selector(becomeFirstResponder), (IMP)NoFieldResponder);
    oldTextResponder =
        (void *)Replace(UITextView.class, @selector(becomeFirstResponder), (IMP)NoTextResponder);
    oldMakeKey = (void *)Replace(UIWindow.class, @selector(makeKeyWindow), (IMP)NoAgentKeyWindow);
    oldMakeVisible =
        (void *)Replace(UIWindow.class, @selector(makeKeyAndVisible), (IMP)NoAgentVisibleKeyWindow);
    oldOpenURL = (void *)Replace(UIApplication.class, @selector(openURL:options:completionHandler:),
                                 (IMP)ContainedOpenURL);
    oldLegacyURL =
        (void *)Replace(UIApplication.class, @selector(openURL:), (IMP)ContainedLegacyURL);
    oldSceneActivation =
        (void *)Replace(UIApplication.class,
                        @selector(requestSceneSessionActivation:userActivity:options:errorHandler:),
                        (IMP)ContainedSceneActivation);
}
__attribute__((constructor)) static void LoadGuestBridge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *b = [NSClassFromString(@"LiveProcessHandler") retrievedAppInfo];
        if (![b[@"pokiRole"] isEqual:@"guest"])
            return;
        bridge = [PKWGuestBridge new];
        InstallIsolationGuards();
        Method method = class_getInstanceMethod(UIApplication.class, @selector(sendEvent:));
        originalSendEvent = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)GuestSendEvent);
    });
}
