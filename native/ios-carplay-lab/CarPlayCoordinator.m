// SPDX-License-Identifier: AGPL-3.0-only
// Simulator-only, narrowly allowlisted experiment. Runtime metadata is changed
// in the CarPlay/SpringBoard processes; installed app bundles are not modified.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>
#ifndef COORDINATOR_DIR
#define COORDINATOR_DIR "/tmp/PokiCarPlayCoordinator"
#endif
static NSMutableArray *trace;
static NSMutableDictionary *originals;
static NSMutableDictionary *pinned;
static __weak id workspace;
static NSArray *AllowedIdentifiers(void) {
    static NSArray *ids;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSData *d=[NSData dataWithContentsOfFile:[@COORDINATOR_DIR stringByAppendingPathComponent:@"allowlist.json"]];
        id value=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;
        NSMutableArray *valid=[NSMutableArray new];
        if([value isKindOfClass:NSArray.class]&&[value count]<=20) {
            for(id item in value)if([item isKindOfClass:NSString.class]&&[item length]>0&&[item length]<256)[valid addObject:item];
            ids=valid.copy;
        } else ids=@[@"com.apple.mobilesafari"];
    });return ids;
}
static BOOL Allowed(NSString *bid) {return [AllowedIdentifiers() containsObject:bid?:@""];}
static id Get(id obj,NSString *selector) {
    SEL s=NSSelectorFromString(selector);return [obj respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(obj,s):nil;
}
static NSString *Bundle(id obj) {return Get(obj,@"bundleIdentifier")?:Get(obj,@"applicationIdentifier");}
static void Trace(NSString *event,NSDictionary *data) {
    if(!trace)trace=[NSMutableArray new];
    @synchronized(trace){
        NSMutableDictionary *r=[@{@"event":event,@"at":@([NSDate date].timeIntervalSince1970)}mutableCopy];[r addEntriesFromDictionary:data?:@{}];
        [trace addObject:r];
        NSString *dir=@COORDINATOR_DIR;[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path=[dir stringByAppendingPathComponent:[NSProcessInfo.processInfo.processName stringByAppendingString:@".json"]];
        [[NSJSONSerialization dataWithJSONObject:trace options:NSJSONWritingPrettyPrinted error:nil]writeToFile:path atomically:YES];
    }
}
static BOOL Hook(Class cls,SEL s,IMP next) {
    NSString *key=[NSString stringWithFormat:@"%s/%@",class_getName(cls),NSStringFromSelector(s)];
    if(!cls||originals[key])return NO;
    Method m=class_getInstanceMethod(cls,s);if(!m)return NO;
    originals[key]=[NSValue valueWithPointer:method_getImplementation(m)];
    class_replaceMethod(cls,s,next,method_getTypeEncoding(m));
    Trace(@"hook.installed",@{@"class":@(class_getName(cls)),@"selector":NSStringFromSelector(s)});return YES;
}
static IMP Original(Class cls,SEL s) {return [originals[[NSString stringWithFormat:@"%s/%@",class_getName(cls),NSStringFromSelector(s)]]pointerValue];}

@interface AdmissionValues : NSProxy
@property(strong) id source;
@end
@implementation AdmissionValues
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    id sig=[self.source methodSignatureForSelector:s];if(sig)return sig;
    NSString *n=NSStringFromSelector(s);NSUInteger arity=[[n componentsSeparatedByString:@":"]count]-1;
    if([n isEqual:@"boolForKey:"])return [NSMethodSignature signatureWithObjCTypes:"B@:@"];
    if([n hasPrefix:@"objectForKey:"]&&arity==1)return [NSMethodSignature signatureWithObjCTypes:"@@:@"];
    if([n hasPrefix:@"objectForKey:"]&&arity==2)return [NSMethodSignature signatureWithObjCTypes:"@@:@#"];
    if([n hasPrefix:@"objectForKey:"]&&arity==3)return [NSMethodSignature signatureWithObjCTypes:"@@:@##"];
    return nil;
}
- (void)forwardInvocation:(NSInvocation *)i {
    NSString *s=NSStringFromSelector(i.selector);
    if([s hasPrefix:@"objectForKey:"]||[s isEqual:@"boolForKey:"]||[s isEqual:@"objectForKeyedSubscript:"]) {
        __unsafe_unretained id key=nil;[i getArgument:&key atIndex:2];
        BOOL yes=[key isEqual:@"SBStarkCapable"]||[key isEqual:@"CARCapableApp"];
        BOOL hide=[key isKindOfClass:NSString.class]&&[key hasPrefix:@"com.apple.developer.carplay-"];
        if(yes||hide||![self.source respondsToSelector:i.selector]) {
            id value=yes?@YES:hide?nil:[self.source objectForKey:key];
            if([s isEqual:@"boolForKey:"]){BOOL b=[value boolValue];[i setReturnValue:&b];}
            else [i setReturnValue:&value];return;
        }
    }
    [i invokeWithTarget:self.source];
}
- (BOOL)respondsToSelector:(SEL)s {return [NSStringFromSelector(s)hasPrefix:@"objectForKey:"]||[NSStringFromSelector(s)isEqual:@"boolForKey:"]||[self.source respondsToSelector:s];}
- (BOOL)isKindOfClass:(Class)c {return [self.source isKindOfClass:c];}
- (Class)class {return [self.source class];}
@end
static id Values(id source) {AdmissionValues *p=[AdmissionValues alloc];p.source=source?:@{};return p;}
static id Factory3(id self,SEL s,id bid,id a,id b) {
    IMP original=Original(object_getClass(self),s);
    if(Allowed(bid)) {
        if([NSStringFromSelector(s)hasPrefix:@"declarationForBundleIdentifier:info"])b=Values(b);else a=Values(a);
    }
    id result=((id(*)(id,SEL,id,id,id))original)(self,s,bid,a,b);
    if(Allowed(bid))Trace(@"declaration",@{@"bundle":bid,@"selector":NSStringFromSelector(s),@"created":@(result!=nil)});
    return result;
}
static id Factory4(id self,SEL s,id bid,id a,id b,id path) {
    IMP original=Original(object_getClass(self),s);
    if(Allowed(bid)){if([NSStringFromSelector(s)hasPrefix:@"declarationForBundleIdentifier:info"])b=Values(b);else a=Values(a);}
    id result=((id(*)(id,SEL,id,id,id,id))original)(self,s,bid,a,b,path);
    if(Allowed(bid))Trace(@"declaration",@{@"bundle":bid,@"selector":NSStringFromSelector(s),@"created":@(result!=nil)});
    return result;
}
static id Promote(id policy,id declaration) {
    NSString *bid=Bundle(declaration);if(!Allowed(bid)||!policy)return policy;
    for(NSString *name in @[@"setCanDisplayOnCarScreen:",@"setCarPlayCapable:",@"setCarPlaySupported:",@"setLaunchUsingTemplateUI:"]) {
        SEL s=NSSelectorFromString(name);if([policy respondsToSelector:s])((void(*)(id,SEL,BOOL))objc_msgSend)(policy,s,![name isEqual:@"setLaunchUsingTemplateUI:"]);
    }
    Trace(@"policy.promoted",@{@"bundle":bid});return policy;
}
static id Policy1(id self,SEL s,id d) {return Promote(((id(*)(id,SEL,id))Original(NSClassFromString(@"CRCarPlayAppPolicyEvaluator"),s))(self,s,d),d);}
static id Policy2(id self,SEL s,id d,id vehicle) {return Promote(((id(*)(id,SEL,id,id))Original(NSClassFromString(@"CRCarPlayAppPolicyEvaluator"),s))(self,s,d,vehicle),d);}
static id InfoValue(id self,SEL s,id key,Class expected) {
    id result=((id(*)(id,SEL,id,Class))Original(NSClassFromString(@"LSBundleProxy"),s))(self,s,key,expected);
    if(![key isEqual:@"UIApplicationSceneManifest"]&&![key isEqual:@"SBStarkLaunchModes"])return result;
    if(!Allowed(Bundle(self)))return result;
    if([key isEqual:@"SBStarkLaunchModes"])return result?:@[@"Default"];
    NSMutableDictionary *manifest=[result isKindOfClass:NSDictionary.class]?[result mutableCopy]:[NSMutableDictionary new];
    NSMutableDictionary *configs=[manifest[@"UISceneConfigurations"]mutableCopy]?:[NSMutableDictionary new];
    NSArray *main=configs[@"UIWindowSceneSessionRoleApplication"];
    configs[@"UIWindowSceneSessionRoleCarPlay"]=main?:@[@{@"UISceneClassName":@"UIWindowScene"}];
    manifest[@"UISceneConfigurations"]=configs;manifest[@"UIApplicationSupportsMultipleScenes"]=@YES;
    Trace(@"manifest.advertised",@{@"bundle":Bundle(self)?:@""});return manifest;
}
static id InstalledApps(id self,SEL s) {
    NSArray *apps=((id(*)(id,SEL))Original(NSClassFromString(@"FBSApplicationLibrary"),s))(self,s);
    if(![NSProcessInfo.processInfo.processName isEqual:@"CarPlay"]||![apps isKindOfClass:NSArray.class])return apps;
    NSMutableArray *result=[apps mutableCopy];NSMutableSet *present=[NSMutableSet new];for(id app in apps){NSString *b=Bundle(app);if(b)[present addObject:b];}
    for(NSString *bid in AllowedIdentifiers()) {
        if([present containsObject:bid])continue;
        id info=pinned[bid];
        if(!info){
            Class proxy=NSClassFromString(@"LSApplicationProxy");SEL psel=NSSelectorFromString(@"applicationProxyForIdentifier:");
            id p=((id(*)(id,SEL,id))objc_msgSend)(proxy,psel,bid);Class cls=NSClassFromString(@"DBApplicationInfo");SEL init=NSSelectorFromString(@"initWithApplicationProxy:");
            if(!p||![cls instancesRespondToSelector:init])continue;
            NSURL *url=Get(p,@"bundleURL");
            if(![url isKindOfClass:NSURL.class]||![NSFileManager.defaultManager fileExistsAtPath:url.path]){Trace(@"roster.notInstalled",@{@"bundle":bid});continue;}
            info=((id(*)(id,SEL,id))objc_msgSend)([cls alloc],init,p);
            if(info)pinned[bid]=info;
            Trace(@"roster.candidate",@{@"bundle":bid,@"created":@(info!=nil),@"declaration":@(Get(info,@"carPlayDeclaration")!=nil)});
        }
        if(info&&Get(info,@"carPlayDeclaration"))[result addObject:info];
    }
    return result;
}
static id ForwardInfo(id self,SEL cmd,SEL selector) {
    id info=Get(self,@"info");return [info respondsToSelector:selector]?info:nil;
}
static id WorkspaceInit(id self,SEL cmd,id owner) {
    id result=((id(*)(id,SEL,id))Original(NSClassFromString(@"DBWorkspace"),cmd))(self,cmd,owner);
    if([owner isKindOfClass:NSClassFromString(@"DBDashboardWorkspaceOwner")]){workspace=result;Trace(@"workspace.captured",nil);}return result;
}
static void PollLaunch(void) {
    static NSString *last;
    NSString *path=[@COORDINATOR_DIR stringByAppendingPathComponent:@"launch.json"];
    NSData *d=[NSData dataWithContentsOfFile:path];if(!d)return;
    NSDictionary *r=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSString *rid=r[@"id"],*bid=r[@"bundle"];if(!rid||[rid isEqual:last])return;last=rid;
    if(!Allowed(bid)){Trace(@"launch.denied",@{@"id":rid});return;}
    @try {
        id controller=Get(NSClassFromString(@"DBApplicationController"),@"sharedInstance");SEL find=NSSelectorFromString(@"applicationWithBundleIdentifier:");
        id app=[controller respondsToSelector:find]?((id(*)(id,SEL,id))objc_msgSend)(controller,find,bid):nil;
        if(!workspace||!app){Trace(@"launch.unavailable",@{@"bundle":bid,@"workspace":@(workspace!=nil),@"app":@(app!=nil)});return;}
        id req=[NSClassFromString(@"DBMutableWorkspaceStateChangeRequest")new];SEL activate=NSSelectorFromString(@"activateApplication:"),change=NSSelectorFromString(@"requestStateChange:");
        if(![req respondsToSelector:activate]||![workspace respondsToSelector:change]){Trace(@"launch.missingAPI",nil);return;}
        ((void(*)(id,SEL,id))objc_msgSend)(req,activate,app);((void(*)(id,SEL,id))objc_msgSend)(workspace,change,req);
        Trace(@"launch.requested",@{@"bundle":bid});
    } @catch(NSException *e){Trace(@"launch.exception",@{@"error":e.description});}
}
static void Install(void) {
    Class declaration=NSClassFromString(@"CRCarPlayAppDeclaration");unsigned n=0;Method *methods=class_copyMethodList(object_getClass(declaration),&n);
    for(unsigned i=0;i<n;i++) {
        SEL s=method_getName(methods[i]);NSString *name=NSStringFromSelector(s);unsigned argc=method_getNumberOfArguments(methods[i]);
        if([name hasPrefix:@"declarationForBundleIdentifier:"]&&[name containsString:@"entitlements"]&&(argc==5||argc==6))Hook(object_getClass(declaration),s,argc==5?(IMP)Factory3:(IMP)Factory4);
    }free(methods);
    Class policy=NSClassFromString(@"CRCarPlayAppPolicyEvaluator");
    Hook(policy,NSSelectorFromString(@"effectivePolicyForAppDeclaration:"),(IMP)Policy1);
    Hook(policy,NSSelectorFromString(@"effectivePolicyForAppDeclaration:inVehicleWithCertificateSerial:"),(IMP)Policy2);
    Hook(policy,NSSelectorFromString(@"effectivePolicyForAppDeclaration:withVerifiedPunchThroughs:"),(IMP)Policy2);
    Hook(NSClassFromString(@"LSBundleProxy"),NSSelectorFromString(@"objectForInfoDictionaryKey:ofClass:"),(IMP)InfoValue);
    Hook(NSClassFromString(@"FBSApplicationLibrary"),NSSelectorFromString(@"allInstalledApplications"),(IMP)InstalledApps);
    Hook(NSClassFromString(@"DBWorkspace"),NSSelectorFromString(@"initWithOwner:"),(IMP)WorkspaceInit);
    Class db=NSClassFromString(@"DBApplication");if(db)class_addMethod(db,@selector(forwardingTargetForSelector:),(IMP)ForwardInfo,"@@::");
}
__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        NSString *p=NSProcessInfo.processInfo.processName;if(![@[@"SpringBoard",@"CarPlay"]containsObject:p])return;
        originals=[NSMutableDictionary new];pinned=[NSMutableDictionary new];Trace(@"coordinator.loaded",@{@"pid":@(getpid()),@"process":p});Install();
        dispatch_async(dispatch_get_main_queue(),^{[NSTimer scheduledTimerWithTimeInterval:.25 repeats:YES block:^(NSTimer *t){Install();if([p isEqual:@"CarPlay"])PollLaunch();}];});
    }
}
