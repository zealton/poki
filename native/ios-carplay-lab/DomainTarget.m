// SPDX-License-Identifier: AGPL-3.0-only
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSMutableArray *events;
static void Log(NSString *event, NSDictionary *info) {
    if (!events) events=[NSMutableArray new];
    NSMutableDictionary *row=[@{@"event":event,@"at":@([NSDate date].timeIntervalSince1970),@"pid":@(getpid())} mutableCopy];
    [row addEntriesFromDictionary:info?:@{}]; [events addObject:row];
    NSURL *url=[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"events.json"];
    [[NSJSONSerialization dataWithJSONObject:events options:NSJSONWritingPrettyPrinted error:nil] writeToURL:url atomically:YES];
}

@interface DomainVC : UIViewController <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@property NSInteger count;
@property UILabel *label;
@property UILabel *titleLabel;
@property UIButton *button;
@property UITextField *field;
@property UITableView *table;
@end
@implementation DomainVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.systemIndigoColor;
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(20,35,650,40)];
    title.text=@"Ordinary UIKit target / independent display"; title.textColor=UIColor.whiteColor;
    title.font=[UIFont boldSystemFontOfSize:13];self.titleLabel=title;[self.view addSubview:title];
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.frame=CGRectMake(20,90,240,60);
    button.backgroundColor=UIColor.whiteColor;[button setTitle:@"Ordinary button: increment" forState:UIControlStateNormal];
    button.accessibilityIdentifier=@"domain.button";button.titleLabel.font=[UIFont systemFontOfSize:12];[button setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];self.button=button;[button addTarget:self action:@selector(pressed) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:button];
    self.label=[[UILabel alloc]initWithFrame:CGRectMake(280,90,360,60)];self.label.textColor=UIColor.whiteColor;self.label.accessibilityIdentifier=@"domain.counter";[self.view addSubview:self.label];
    self.field=[[UITextField alloc]initWithFrame:CGRectMake(20,165,620,48)];self.field.backgroundColor=UIColor.whiteColor;
    self.field.borderStyle=UITextBorderStyleRoundedRect;self.field.textColor=UIColor.blackColor;self.field.attributedPlaceholder=[[NSAttributedString alloc]initWithString:@"Agent text input" attributes:@{NSForegroundColorAttributeName:UIColor.grayColor}];self.field.accessibilityIdentifier=@"domain.field";
    self.field.delegate=self;self.field.autocorrectionType=UITextAutocorrectionTypeNo;
    [self.field addTarget:self action:@selector(edited) forControlEvents:UIControlEventEditingChanged];[self.view addSubview:self.field];
    self.table=[[UITableView alloc]initWithFrame:CGRectMake(20,230,620,180) style:UITableViewStylePlain];
    self.table.dataSource=self;self.table.delegate=self;self.table.accessibilityIdentifier=@"domain.table";[self.view addSubview:self.table];
    [self refresh];Log(@"view.loaded",nil);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets i=self.view.safeAreaInsets;CGFloat x=MAX(12,i.left+8),y=MAX(8,i.top+6);
    CGFloat w=MAX(180,self.view.bounds.size.width-x-MAX(8,i.right+6));
    self.titleLabel.frame=CGRectMake(x,y,w,24);
    CGFloat b=MIN(180,w*.57);self.button.frame=CGRectMake(x,y+28,b,36);
    self.label.frame=CGRectMake(x+b+8,y+28,w-b-8,36);self.label.font=[UIFont systemFontOfSize:13];
    self.field.frame=CGRectMake(x,y+70,w,32);
    self.table.frame=CGRectMake(x,y+110,w,MAX(35,self.view.bounds.size.height-y-116-i.bottom));
}
- (void)refresh {self.label.text=[NSString stringWithFormat:@"REAL COUNT: %ld",(long)self.count];}
- (void)pressed {self.count++;[self refresh];Log(@"button.pressed",@{@"count":@(self.count)});}
- (void)edited {Log(@"text.changed",@{@"text":self.field.text?:@"",@"focus":@(self.field.isFirstResponder)});}
- (void)textFieldDidBeginEditing:(UITextField *)f {Log(@"text.focus",nil);}
- (void)textFieldDidEndEditing:(UITextField *)f {Log(@"text.blur",nil);}
- (BOOL)textFieldShouldReturn:(UITextField *)f {Log(@"text.submit",@{@"text":f.text?:@""});return YES;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {return 60;}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.textLabel.text=[NSString stringWithFormat:@"Native row %02ld",(long)p.row];return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {Log(@"row.selected",@{@"row":@(p.row)});}
- (void)scrollViewDidScroll:(UIScrollView *)s {Log(@"table.scrolled",@{@"y":@(s.contentOffset.y)});}
@end

@interface DomainScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation DomainScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    Log(@"scene.connect",@{@"class":NSStringFromClass(scene.class),@"role":session.role,@"scene":session.persistentIdentifier});
    // Ordinary app logic. A separate bridge must normalize an unfamiliar role.
    if(![session.role isEqual:UIWindowSceneSessionRoleApplication]) {Log(@"scene.unrecognizedRole",nil);return;}
    if(![scene isKindOfClass:UIWindowScene.class])return;
    UIWindowScene *ws=(id)scene;
    self.window=[[UIWindow alloc]initWithWindowScene:ws];self.window.rootViewController=[DomainVC new];
    [self.window makeKeyAndVisible];
    Log(@"window.created",@{@"screenMain":@(ws.screen==UIScreen.mainScreen),@"bounds":NSStringFromCGRect(ws.screen.bounds),@"sceneBounds":NSStringFromCGRect(ws.coordinateSpace.bounds)});
}
- (void)sceneDidBecomeActive:(UIScene *)s {Log(@"scene.active",@{@"scene":s.session.persistentIdentifier});}
- (void)sceneWillResignActive:(UIScene *)s {Log(@"scene.inactive",@{@"scene":s.session.persistentIdentifier});}
- (void)sceneDidEnterBackground:(UIScene *)s {Log(@"scene.background",@{@"scene":s.session.persistentIdentifier});}
@end
@interface DomainApp : UIResponder <UIApplicationDelegate> @end
@implementation DomainApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    Log(@"app.launch",nil);
    @try {
        Class c=NSClassFromString(@"LSApplicationProxy");
        id proxy=((id(*)(id,SEL,id))objc_msgSend)(c,NSSelectorFromString(@"applicationProxyForIdentifier:"),NSBundle.mainBundle.bundleIdentifier);
        id ent=[proxy valueForKey:@"entitlements"];
        Log(@"app.registry",@{@"entitlements":[ent description]?:@"nil"});
    } @catch(NSException *e) {Log(@"app.registry.error",@{@"error":e.description});}
    return YES;
}
@end
int main(int argc,char **argv) {@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(DomainApp.class));}}
