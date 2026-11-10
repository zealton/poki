#import <UIKit/UIKit.h>
@interface PadVC : UIViewController <UITextViewDelegate>
@property UITextView *editor;
@property NSMutableArray *events;
@property NSInteger activations;
@end
@implementation PadVC
- (void)viewDidLoad { [super viewDidLoad]; self.events=[NSMutableArray new]; self.view.backgroundColor=UIColor.systemBackgroundColor; UILabel *title=[UILabel new]; title.text=@"Typing Pad · user-only surface"; title.font=[UIFont boldSystemFontOfSize:21]; title.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:title]; self.editor=[UITextView new]; self.editor.font=[UIFont systemFontOfSize:20]; self.editor.text=@""; self.editor.accessibilityIdentifier=@"user.editor"; self.editor.autocorrectionType=UITextAutocorrectionTypeNo; self.editor.spellCheckingType=UITextSpellCheckingTypeNo; self.editor.smartQuotesType=UITextSmartQuotesTypeNo; self.editor.delegate=self; self.editor.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:self.editor]; [NSLayoutConstraint activateConstraints:@[[title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],[title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[self.editor.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:20],[self.editor.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[self.editor.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[self.editor.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8]]]; for(NSString *name in @[UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification,UIApplicationDidEnterBackgroundNotification])[[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(lifecycle:) name:name object:nil]; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; self.editor.selectedRange=NSMakeRange(self.editor.text.length,0); [self.editor becomeFirstResponder]; [self record:@"appeared"]; }
- (void)lifecycle:(NSNotification *)n { if([n.name isEqual:UIApplicationDidBecomeActiveNotification])self.activations++; [self record:n.name]; }
- (void)textViewDidChange:(UITextView *)v { [self record:@"text.change"]; }
- (void)textViewDidBeginEditing:(UITextView *)v { [self record:@"text.focus"]; }
- (void)textViewDidEndEditing:(UITextView *)v { [self record:@"text.blur"]; }
- (void)record:(NSString *)event { [self.events addObject:@{@"event":event,@"at":@([NSDate date].timeIntervalSince1970),@"state":@(UIApplication.sharedApplication.applicationState),@"firstResponder":@(self.editor.isFirstResponder),@"text":self.editor.text?:@""}]; NSDictionary *state=@{@"text":self.editor.text?:@"",@"active":@(UIApplication.sharedApplication.applicationState==UIApplicationStateActive),@"firstResponder":@(self.editor.isFirstResponder),@"activations":@(self.activations),@"pid":@(NSProcessInfo.processInfo.processIdentifier),@"events":self.events}; NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil]; [data writeToURL:[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"evidence.json"] options:NSDataWritingAtomic error:nil]; }
@end
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o { self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController=[PadVC new]; [self.window makeKeyAndVisible]; return YES; }
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
