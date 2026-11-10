// SPDX-License-Identifier: AGPL-3.0-only
#import "WorkspaceHostViewController.h"
#import "WorkspaceIPC.h"
#import "WorkspacePolicy.h"
#import "AppSceneViewController.h"
#import "LCAppInfo.h"
#import "LCSharedUtils.h"
#import "LCUtils.h"
#import <Security/Security.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <AVKit/AVKit.h>

static NSString *const WorkerName = @"PokiWorker.app";
static NSDictionary *VaultQuery(void) {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @"PokiWorkspace.OpenRouter",
        (__bridge id)kSecAttrAccount : @"owner",
        (__bridge id)kSecAttrAccessGroup : [NSString
            stringWithFormat:@"%@.app.zealton.poki.workspace.owner", LCSharedUtils.teamIdentifier]
    };
}
static NSString *ReadKey(void) {
    NSMutableDictionary *q = VaultQuery().mutableCopy;
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef value = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &value);
    return status == errSecSuccess ? [[NSString alloc] initWithData:CFBridgingRelease(value)
                                                           encoding:NSUTF8StringEncoding]
                                   : nil;
}

@interface WorkspaceHostViewController () <NSXPCListenerDelegate, PKWBroker,
                                           AppSceneViewControllerDelegate,
                                           AVPictureInPictureControllerDelegate>
@property NSXPCListener *broker;
@property NSMutableArray *clients;
@property NSMutableDictionary *endpoints;
@property AppSceneViewController *guest, *worker;
@property NSXPCConnection *guestConnection, *workerConnection;
@property UIView *preview, *workerFrame;
@property UITextField *credential, *model;
@property UITextView *goal;
@property UILabel *status, *details;
@property UIButton *choose;
@property NSString *selected, *runID, *volatileCredential;
@property NSDictionary *lastState;
@property BOOL starting, connecting, polling, preparing;
@property BOOL testAutostart;
@property NSInteger launchGeneration;
@property AVPictureInPictureController *pip;
@property AVPictureInPictureVideoCallViewController *pipVC;
@end
@implementation WorkspaceHostViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.clients = [NSMutableArray new];
    self.endpoints = [NSMutableDictionary new];
    self.selected = @"PokiFixture.app";
#if TARGET_OS_SIMULATOR && DEBUG
    // Explicit test-only, one-shot FIFO input: never put a key in argv, env, a file, or XCTest
    // logs.
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger fifoIndex = [args indexOfObject:@"--workspace-key-fifo"];
    if ([args containsObject:@"--workspace-test"] && fifoIndex != NSNotFound &&
        fifoIndex + 1 < args.count) {
        NSString *path = args[fifoIndex + 1];
        struct stat metadata;
        if (lstat(path.fileSystemRepresentation, &metadata) == 0 && S_ISFIFO(metadata.st_mode) &&
            metadata.st_uid == getuid() && (metadata.st_mode & 0077) == 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                int fd = open(path.fileSystemRepresentation, O_RDONLY);
                char buffer[257] = {0};
                ssize_t count = fd >= 0 ? read(fd, buffer, 256) : 0;
                if (fd >= 0)
                    close(fd);
                NSString *key = count > 0 ? [[NSString alloc] initWithBytes:buffer
                                                                     length:(NSUInteger)count
                                                                   encoding:NSUTF8StringEncoding]
                                          : nil;
                memset(buffer, 0, sizeof(buffer));
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.credential.text = key ?: @"";
                    [self saveKey];
                    self.testAutostart =
                        ([args containsObject:@"--workspace-run-fixture"] &&
                         (ReadKey().length > 0 || self.volatileCredential.length > 0));
                    if (self.workerConnection && self.testAutostart) {
                        self.testAutostart = NO;
                        [self start];
                    }
                });
            });
        }
    }
#endif
    self.broker = [NSXPCListener anonymousListener];
    self.broker.delegate = self;
    [self.broker resume];
    UILabel *title = [UILabel new];
    title.text = @"Poki Workspace";
    title.font = [UIFont boldSystemFontOfSize:22];
    UILabel *hint = [UILabel new];
    hint.text = @"仅控制容器内的 App · 原始远程窗口预览";
    hint.font = [UIFont systemFontOfSize:12];
    self.credential = [UITextField new];
    self.credential.secureTextEntry = YES;
    self.credential.placeholder =
        ReadKey().length ? @"OpenRouter 密钥已保存（留空保留）" : @"OpenRouter API key";
    self.credential.borderStyle = UITextBorderStyleRoundedRect;
    self.credential.autocorrectionType = UITextAutocorrectionTypeNo;
    self.credential.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.credential.accessibilityIdentifier = @"workspace.key";
    self.model = [UITextField new];
    self.model.text = @"deepseek/deepseek-v4.1-flash-1017";
    self.model.font = [UIFont systemFontOfSize:12];
    self.model.borderStyle = UITextBorderStyleRoundedRect;
    self.model.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.model.autocorrectionType = UITextAutocorrectionTypeNo;
    self.model.accessibilityIdentifier = @"workspace.model";
    self.goal = [UITextView new];
    self.goal.text = @"点击 Increment，直到计数等于 3，然后在 Name 输入 Poki，确认画面后结束。";
    self.goal.font = [UIFont systemFontOfSize:14];
    self.goal.accessibilityIdentifier = @"workspace.goal";
#if TARGET_OS_SIMULATOR && DEBUG
    NSUInteger countIndex =
        [NSProcessInfo.processInfo.arguments indexOfObject:@"--workspace-test-count"];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--workspace-test"] &&
        countIndex != NSNotFound && countIndex + 1 < NSProcessInfo.processInfo.arguments.count) {
        NSInteger count =
            MAX(1, MIN(10, [NSProcessInfo.processInfo.arguments[countIndex + 1] integerValue]));
        self.goal.text =
            [NSString stringWithFormat:@"Click Increment until Count equals %ld. Then set Name to "
                                       @"Poki. Verify the displayed result and finish.",
                                       (long)count];
    }
#endif
    [self.goal.heightAnchor constraintEqualToConstant:58].active = YES;
    self.status = [UILabel new];
    self.status.numberOfLines = 3;
    self.status.font = [UIFont systemFontOfSize:13];
    self.status.text = @"准备容器…";
    self.status.accessibilityIdentifier = @"workspace.status";
    self.details = [UILabel new];
    self.details.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.details.numberOfLines = 2;
    self.details.accessibilityIdentifier = @"workspace.details";
    self.choose = [self button:@"测试 App ▾" action:@selector(pickApp)];
    UIStackView *settings = [self row:@[
        self.choose, [self button:@"保存密钥" action:@selector(saveKey)],
        [self button:@"清除密钥" action:@selector(clearKey)],
        [self button:@"导入 / 管理" action:@selector(manager)]
    ]];
    UIStackView *controls = [self row:@[
        [self button:@"开始" action:@selector(start)],
        [self button:@"暂停" action:@selector(pause)],
        [self button:@"继续" action:@selector(resume)], [self button:@"停止" action:@selector(stop)]
    ]];
    UIStackView *review = [self row:@[
        [self button:@"批准这一步" action:@selector(approve)], [self button:@"悬浮预览"
                                                                     action:@selector(showPiP)]
    ]];
    self.preview = [UIView new];
    self.preview.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.preview.clipsToBounds = YES;
    self.preview.accessibilityIdentifier = @"workspace.preview";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, hint, self.credential, self.model, self.goal, settings, controls, review,
        self.status, self.details, self.preview
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                        constant:5],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                           constant:-5],
        [self.preview.heightAnchor constraintGreaterThanOrEqualToConstant:180]
    ]];
    // A distinct LiveProcess owns networking and the loop. No Mac command queue is involved.
    self.workerFrame = [[UIView alloc] initWithFrame:CGRectMake(-4096, 0, 360, 310)];
    self.workerFrame.clipsToBounds = YES;
    [self.view addSubview:self.workerFrame];
    __weak typeof(self) owner = self;
    [NSTimer scheduledTimerWithTimeInterval:.5
                                    repeats:YES
                                      block:^(NSTimer *t) {
                                          [owner poll];
                                      }];
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UIStackView *)row:(NSArray *)views {
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:views];
    r.distribution = UIStackViewDistributionFillEqually;
    r.spacing = 4;
    return r;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.worker)
        [self prepare];
}
- (void)prepare {
    if (self.preparing)
        return;
    self.preparing = YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    for (NSString *name in @[ WorkerName, @"PokiFixture.app" ]) {
        NSString *dest =
            [docs stringByAppendingPathComponent:[@"Applications/" stringByAppendingString:name]];
        NSString *source = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:[@"WorkspaceResources/" stringByAppendingString:name]];
        NSString *current = [NSDictionary
            dictionaryWithContentsOfFile:[dest stringByAppendingPathComponent:@"LCAppInfo.plist"]]
            [@"PKWBuildHash"];
        NSString *incoming = [NSDictionary
            dictionaryWithContentsOfFile:[source stringByAppendingPathComponent:@"LCAppInfo.plist"]]
            [@"PKWBuildHash"];
        if (![fm fileExistsAtPath:dest] || ![current isEqual:incoming]) {
            [fm removeItemAtPath:dest error:nil];
            [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:nil];
            NSError *error;
            [fm copyItemAtPath:[NSBundle.mainBundle.bundlePath
                                   stringByAppendingPathComponent:[@"WorkspaceResources/"
                                                                      stringByAppendingString:name]]
                        toPath:dest
                         error:&error];
            if (error) {
                self.status.text = @"内置工作进程缺失，请重新构建";
                self.preparing = NO;
                return;
            }
        }
    }
    NSString *tweaks = [docs stringByAppendingPathComponent:@"Tweaks"];
    [fm createDirectoryAtPath:tweaks withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dylib = [tweaks stringByAppendingPathComponent:@"WorkspaceBridge.dylib"];
    [fm removeItemAtPath:dylib error:nil];
    [fm copyItemAtPath:
            [NSBundle.mainBundle.bundlePath
                stringByAppendingPathComponent:@"WorkspaceResources/WorkspaceBridge.dylib"]
                toPath:dylib
                 error:nil];
    void (^launchScenes)(void) = ^{
        [self patchApplication:WorkerName
                    completion:^(BOOL ok) {
                        if (!ok) {
                            self.preparing = NO;
                            return;
                        }
                        [self patchApplication:self.selected
                                    completion:^(BOOL ready) {
                                        self.preparing = NO;
                                        if (!ready)
                                            return;
                                        self.worker = [self launch:WorkerName
                                                              role:@"worker"
                                                             frame:self.workerFrame];
                                        self.guest = [self launch:self.selected
                                                             role:@"guest"
                                                            frame:self.preview];
                                    }];
                    }];
    };
#if TARGET_OS_SIMULATOR
    launchScenes();
#else
    if (!LCUtils.certificateData.length || !LCSharedUtils.certificatePassword) {
        self.preparing = NO;
        self.status.text =
            @"请在导入 / 管理的设置中配置你自己的 LiveContainer 签名证书，然后点开始重试";
        return;
    }
    [LCUtils signFilesWithZSignWithURLs:@[ [NSURL fileURLWithPath:dylib] ]
                      completionHandler:^(BOOL ok, NSError *error) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              if (ok)
                                  launchScenes();
                              else {
                                  self.preparing = NO;
                                  self.status.text = @"工作桥签名失败，请检查容器证书";
                              }
                          });
                      }];
#endif
}
- (void)patchApplication:(NSString *)name completion:(void (^)(BOOL))completion {
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Applications"]
        stringByAppendingPathComponent:name];
    LCAppInfo *info = [[LCAppInfo alloc] initWithBundlePath:path];
    if (![name isEqual:WorkerName] && (info.dontInjectTweakLoader || info.dontLoadTweakLoader)) {
        self.status.text = @"此客体关闭了 TweakLoader，不能使用定向 Agent";
        completion(NO);
        return;
    }
    [info
        patchExecAndSignIfNeedWithCompletionHandler:^(bool ok, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok)
                    self.status.text = @"客体签名或可执行文件转换失败，请检查导入 / 管理";
                completion(ok);
            });
        }
                                    progressHandler:nil
                                          forceSign:NO];
}
- (AppSceneViewController *)launch:(NSString *)name role:(NSString *)role frame:(UIView *)frame {
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Applications"]
        stringByAppendingPathComponent:name];
    LCAppInfo *info = [[LCAppInfo alloc] initWithBundlePath:path];
    NSString *dataID = info.dataUUID
                           ?: [[@"PKW-" stringByAppendingString:role]
                                  stringByAppendingString:NSUUID.UUID.UUIDString];
    info.dataUUID = dataID;
    // Device imports use LiveContainer's signing/import flow before selection.
    [info save];
    NSString *dataPath =
        [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Data/Application"]
            stringByAppendingPathComponent:dataID];
    [NSFileManager.defaultManager
              createDirectoryAtPath:[dataPath stringByAppendingPathComponent:@"Documents"]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    [NSFileManager.defaultManager
              createDirectoryAtPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences"]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    PKWSetLaunchOptions(dataID, @{
        @"pokiRole" : role,
        @"pokiHostPID" : @(NSProcessInfo.processInfo.processIdentifier),
        @"pokiBroker" : self.broker.endpoint,
        @"pokiTestFocus" :
            @([NSProcessInfo.processInfo.arguments containsObject:@"--workspace-test-focus"])
    });
    AppSceneViewController *vc = [[AppSceneViewController alloc] initWithBundleId:name
                                                                         dataUUID:dataID
                                                                         delegate:self];
    if (!vc)
        return nil;
    [self addChildViewController:vc];
    vc.view.frame = frame.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [frame addSubview:vc.view];
    [vc didMoveToParentViewController:self];
    return vc;
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    c.exportedInterface = PKWInterface(@protocol(PKWBroker));
    c.exportedObject = self;
    [self.clients addObject:c];
    [c resume];
    return YES;
}
- (void)registerRole:(NSString *)role
             process:(int)pid
            endpoint:(NSXPCListenerEndpoint *)endpoint
               reply:(void (^)(BOOL))reply {
    int actual = NSXPCConnection.currentConnection.processIdentifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        int expected = [role isEqual:@"guest"] ? self.guest.pid
                                               : ([role isEqual:@"worker"] ? self.worker.pid : 0);
        BOOL valid = actual > 0 && actual == pid && pid == expected;
        if (valid) {
            self.endpoints[role] = endpoint;
            [self connect];
        }
        reply(valid);
    });
}
- (void)connect {
    if (!self.endpoints[@"guest"] || !self.endpoints[@"worker"] || self.guestConnection)
        return;
    self.guestConnection =
        [[NSXPCConnection alloc] initWithListenerEndpoint:self.endpoints[@"guest"]];
    self.guestConnection.remoteObjectInterface = PKWInterface(@protocol(PKWGuest));
    [self.guestConnection resume];
    self.workerConnection =
        [[NSXPCConnection alloc] initWithListenerEndpoint:self.endpoints[@"worker"]];
    self.workerConnection.remoteObjectInterface = PKWInterface(@protocol(PKWWorker));
    [self.workerConnection resume];
    self.status.text = @"已就绪：模型和操作均在设备内运行";
    if (self.testAutostart) {
        self.testAutostart = NO;
        [self start];
    }
}
- (void)clearKey {
    [self stop];
    SecItemDelete((__bridge CFDictionaryRef)VaultQuery());
    self.volatileCredential = nil;
    self.credential.text = @"";
    self.credential.placeholder = @"OpenRouter API key";
    self.status.text = @"已请求停止任务并清除本机密钥";
}
- (void)saveKey {
    NSString *key = [self.credential.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!key.length)
        return;
    if (![key hasPrefix:@"sk-or-"]) {
        self.status.text = @"请输入 OpenRouter 密钥";
        return;
    }
    NSMutableDictionary *q = VaultQuery().mutableCopy;
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status =
        SecItemUpdate((__bridge CFDictionaryRef)q,
                      (__bridge CFDictionaryRef) @{(__bridge id)kSecValueData : data});
    if (status == errSecItemNotFound) {
        q[(__bridge id)kSecValueData] = data;
        q[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    }
    if (status == errSecSuccess) {
        self.volatileCredential = nil;
        self.status.text = @"密钥已保存到本机 Keychain";
        self.credential.placeholder = @"OpenRouter 密钥已保存（留空保留）";
    } else {
        self.volatileCredential = key;
        self.status.text = [NSString
            stringWithFormat:@"Keychain 不可用（%d）；仅在本次运行的内存中使用", (int)status];
        self.credential.placeholder = @"密钥仅在内存中，退出后需重输";
    }
    self.credential.text = @"";
    [self.view endEditing:YES];
}
- (id<PKWWorker>)agent {
    return [self.workerConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.text = @"工作进程已断开；请停止并重开 App";
            self.starting = NO;
            self.polling = NO;
        });
    }];
}
- (id<PKWGuest>)target {
    return [self.guestConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.text = @"客体连接不可用，未执行操作";
            self.starting = NO;
        });
    }];
}
- (void)start {
    if (!self.worker) {
        [self prepare];
        return;
    }
    [self.view endEditing:YES];
    if (self.credential.text.length)
        [self saveKey];
    NSString *key = self.volatileCredential ?: ReadKey();
    if (!key.length) {
        self.status.text = @"请先保存 OpenRouter 密钥";
        return;
    }
    if (!self.workerConnection || !self.guestConnection) {
        self.status.text = @"等待客体和工作进程就绪";
        return;
    }
    if (self.starting ||
        [@[ @"running", @"pausing", @"approval" ] containsObject:self.lastState[@"phase"]])
        return;
    if (!PKWAllowedModel(self.model.text) || !self.goal.text.length) {
        self.status.text = @"填写任务和 DeepSeek 模型 ID";
        return;
    }
    self.starting = YES;
    NSInteger generation = ++self.launchGeneration;
    self.runID = NSUUID.UUID.UUIDString;
    NSDictionary *config = @{
        @"run" : self.runID,
        @"goal" : self.goal.text,
        @"model" : self.model.text,
        @"maxSteps" : @24,
        @"fixtureDiagnostics" :
            @([self.selected isEqual:@"PokiFixture.app"] &&
              [NSProcessInfo.processInfo.arguments containsObject:@"--workspace-test"])
    };
    [[self target] authorizeWorker:self.worker.pid
                               run:self.runID
                             reply:^(BOOL accepted) {
                                 dispatch_async(dispatch_get_main_queue(), ^{
                                     if (generation != self.launchGeneration)
                                         return;
                                     if (!accepted) {
                                         self.starting = NO;
                                         self.status.text = @"客体拒绝授权";
                                         return;
                                     }
                                     [[self agent] start:config
                                                   guest:self.endpoints[@"guest"]
                                              credential:key
                                                   reply:^(NSDictionary *state) {
                                                       dispatch_async(dispatch_get_main_queue(), ^{
                                                           if (generation != self.launchGeneration)
                                                               return;
                                                           self.starting = NO;
                                                           self.lastState = state;
                                                           [self showState:state];
                                                       });
                                                   }];
                                 });
                             }];
}
- (void)command:(NSString *)command {
    if (!self.workerConnection)
        return;
    [[self agent] control:command
                    reply:^(NSDictionary *state) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.lastState = state;
                            [self showState:state];
                        });
                    }];
}
- (void)pause {
    [self revoke:@"pause"];
}
- (void)stop {
    [self revoke:@"stop"];
}
- (void)revoke:(NSString *)command {
    self.launchGeneration++;
    self.starting = NO;
    if (self.runID)
        [[self target] setRun:self.runID
                      enabled:NO
                        reply:^(BOOL ok) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self command:command];
                            });
                        }];
    else
        [self command:command];
}
- (void)resume {
    [self command:@"resume"];
}
- (void)approve {
    [self command:@"approve"];
}
- (void)poll {
    if (!self.workerConnection || self.polling)
        return;
    self.polling = YES;
    [[self agent] status:^(NSDictionary *state, NSData *jpeg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.polling = NO;
            self.lastState = state;
            [self showState:state];
        });
    }];
}
- (void)showState:(NSDictionary *)state {
    self.status.text=[NSString stringWithFormat:@"%@ · %@/%@\n%@",state[@"phase"]?:@"idle",state[@"step"]?:@0,state[@"limit"]?:@0,state[@"message"]?:state[@"error"]?:@""];
    self.details.text =
        [NSString stringWithFormat:@"host %d · worker %d · guest %d\nPiP %@ · %@",
                                   NSProcessInfo.processInfo.processIdentifier, self.worker.pid,
                                   self.guest.pid,
                                   [AVPictureInPictureController isPictureInPictureSupported]
                                       ? @"available"
                                       : @"unavailable",
                                   self.selected];
}
- (void)pickApp {
    if ([@[ @"running", @"pausing", @"approval" ] containsObject:self.lastState[@"phase"]]) {
        self.status.text = @"先停止任务再选择 App";
        return;
    }
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:@"选择容器内 App"
                         message:@"普通安装的 App 不在此列表。仅支持可注入的 UIKit 客体。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Applications"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([name hasSuffix:@".app"] && ![name isEqual:WorkerName]) {
            [menu addAction:[UIAlertAction actionWithTitle:name
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                                                       [self switchGuest:name];
                                                   }]];
        }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    menu.popoverPresentationController.sourceView = self.choose;
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)switchGuest:(NSString *)name {
    [self command:@"stop"];
    [self.guestConnection invalidate];
    self.guestConnection = nil;
    [self.workerConnection invalidate];
    self.workerConnection = nil;
    [self.endpoints removeObjectForKey:@"guest"];
    [self.guest terminate];
    [self.guest.view removeFromSuperview];
    [self.guest removeFromParentViewController];
    self.selected = name;
    [self.choose setTitle:name forState:UIControlStateNormal];
    [self patchApplication:name
                completion:^(BOOL ok) {
                    if (ok)
                        self.guest = [self launch:name role:@"guest" frame:self.preview];
                }];
}
- (void)manager {
    Class factory = NSClassFromString(@"PKWManagerFactory");
    UIViewController *controller = [factory performSelector:NSSelectorFromString(@"controller")];
    if (controller)
        [self presentViewController:controller animated:YES completion:nil];
}
- (void)appSceneVC:(AppSceneViewController *)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error)
            self.status.text = @"容器进程启动失败，请停止并重新打开";
        [self connect];
    });
}
- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self revoke:@"stop"];
        self.status.text = @"容器进程已退出；没有自动重启任务";
    });
}
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appSceneVC:vc
            didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy
                transitionContext:nil
              lifecycleActionType:0];
        [vc setBackgroundNotificationEnabled:NO];
    });
}
- (void)appSceneVC:(AppSceneViewController *)vc
    didUpdateFromSettings:(UIMutableApplicationSceneSettings *)base
        transitionContext:(id)context
      lifecycleActionType:(uint32_t)type {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGSize size = vc == self.worker ? CGSizeMake(360, 310) : self.preview.bounds.size;
        [vc updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *s) {
            s.foreground = YES;
            s.interfaceOrientation = UIInterfaceOrientationPortrait;
            s.userInterfaceStyle = base.userInterfaceStyle;
            s.frame = (CGRect){CGPointZero, size};
        }];
    });
}
- (void)showPiP {
    [self.view endEditing:YES];
    if (![AVPictureInPictureController isPictureInPictureSupported] || !self.guest.contentView) {
        self.status.text = @"当前设备不支持悬浮预览；此页显示真实客体窗口";
        return;
    }
    if (self.pip.isPictureInPictureActive) {
        [self.pip stopPictureInPicture];
        return;
    }
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    self.pipVC = [AVPictureInPictureVideoCallViewController new];
    self.pipVC.preferredContentSize = self.preview.bounds.size;
    AVPictureInPictureControllerContentSource *source =
        [[AVPictureInPictureControllerContentSource alloc]
            initWithActiveVideoCallSourceView:self.preview
                        contentViewController:self.pipVC];
    self.pip = [[AVPictureInPictureController alloc] initWithContentSource:source];
    self.pip.delegate = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .4 * NSEC_PER_SEC), dispatch_get_main_queue(),
                   ^{
                       [self.pip startPictureInPicture];
                   });
}
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pip {
    self.guest.shouldIgnoreSceneUpdates = YES;
    UIView *v = self.guest.contentView;
    v.frame = self.pipVC.view.bounds;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.pipVC.view addSubview:v];
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pip {
    self.guest.shouldIgnoreSceneUpdates = NO;
    self.guest.contentView.frame = self.guest.view.bounds;
    [self.guest.view insertSubview:self.guest.contentView atIndex:0];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)pip
    failedToStartPictureInPictureWithError:(NSError *)error {
    [self pictureInPictureControllerDidStopPictureInPicture:pip];
    self.status.text = @"系统拒绝悬浮预览；此页仍可查看实际窗口";
}
@end
