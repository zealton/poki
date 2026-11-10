// SPDX-License-Identifier: AGPL-3.0-only
#import "WorkspaceIPC.h"
#import "WorkspacePolicy.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

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
    if (pid == self.workerPID)
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
        reply(
            @{
                @"observation" : self.observationID,
                @"width" : @(w.bounds.size.width),
                @"height" : @(w.bounds.size.height),
                @"controls" : rows,
                @"bundle" : NSBundle.mainBundle.bundleIdentifier ?: @"",
                @"pid" : @(NSProcessInfo.processInfo.processIdentifier),
                @"capture" : @"guest-calayer"
            },
            UIImageJPEGRepresentation(image, .65));
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
        if ([kind isEqual:@"tap"] && [v isKindOfClass:UIControl.class])
            [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
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
    if (bridge.enabled)
        return NO;
    return oldResponder(object, selector);
}
static BOOL (*oldFieldResponder)(id, SEL);
static BOOL NoFieldResponder(id object, SEL selector) {
    if (bridge.enabled)
        return NO;
    return oldFieldResponder(object, selector);
}
static BOOL (*oldTextResponder)(id, SEL);
static BOOL NoTextResponder(id object, SEL selector) {
    if (bridge.enabled)
        return NO;
    return oldTextResponder(object, selector);
}
static void (*oldMakeKey)(id, SEL);
static void NoAgentKeyWindow(UIWindow *window, SEL selector) {
    if (bridge.enabled)
        return;
    oldMakeKey(window, selector);
}
static void (*oldMakeVisible)(id, SEL);
static void NoAgentVisibleKeyWindow(UIWindow *window, SEL selector) {
    if (bridge.enabled) {
        window.hidden = NO;
        return;
    }
    oldMakeVisible(window, selector);
}
static void (*oldOpenURL)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void ContainedOpenURL(id object, SEL selector, NSURL *url, NSDictionary *options,
                             void (^reply)(BOOL)) {
    if (bridge.enabled) {
        [bridge blockIsolation:@"客体请求打开其他 App，Agent 已暂停"];
        if (reply)
            reply(NO);
        return;
    }
    oldOpenURL(object, selector, url, options, reply);
}
static BOOL (*oldLegacyURL)(id, SEL, NSURL *);
static BOOL ContainedLegacyURL(id object, SEL selector, NSURL *url) {
    if (bridge.enabled) {
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
    if (bridge.enabled) {
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
