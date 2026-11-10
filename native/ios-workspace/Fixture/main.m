// SPDX-License-Identifier: AGPL-3.0-only
#import <UIKit/UIKit.h>
@interface PixelView : UIView
@property NSInteger count;
@end
@implementation PixelView
- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithRed:.08 green:.13 blue:.28 alpha:1] setFill];
    UIRectFill(rect);
    [[NSString stringWithFormat:@"PIXEL COUNT %ld", (long)self.count]
            drawInRect:CGRectInset(rect, 12, 15)
        withAttributes:@{
            NSFontAttributeName : [UIFont boldSystemFontOfSize:24],
            NSForegroundColorAttributeName : UIColor.whiteColor
        }];
}
@end
@interface FixtureVC : UIViewController
@property NSInteger count;
@property NSMutableArray *events;
@property BOOL focusAttempted, focusGranted;
@property UILabel *label;
@property UITextField *name;
@property PixelView *pixels;
@end
@implementation FixtureVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.events = [NSMutableArray new];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.label = [UILabel new];
    self.label.text = @"Count: 0";
    self.label.accessibilityIdentifier = @"fixture.count";
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Increment" forState:UIControlStateNormal];
    [b addTarget:self action:@selector(increment) forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:42].active = YES;
    self.name = [UITextField new];
    self.name.placeholder = @"Name";
    self.name.borderStyle = UITextBorderStyleRoundedRect;
    self.name.accessibilityIdentifier = @"fixture.name";
    [self.name addTarget:self
                  action:@selector(persist)
        forControlEvents:UIControlEventEditingChanged];
    self.pixels = [PixelView new];
    self.pixels.accessibilityElementsHidden = YES;
    [self.pixels.heightAnchor constraintEqualToConstant:65].active = YES;
    UIStackView *stack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ self.label, b, self.name, self.pixels ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                        constant:6],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12]
    ]];
    [self persist];
}
- (void)increment {
    Class handler = NSClassFromString(@"LiveProcessHandler");
    NSDictionary *launch = [handler performSelector:NSSelectorFromString(@"retrievedAppInfo")];
    if ([launch[@"pokiTestFocus"] boolValue]) {
        self.focusAttempted = YES;
        self.focusGranted = [self.name becomeFirstResponder];
    }
    self.count++;
    self.label.text = [NSString stringWithFormat:@"Count: %ld", (long)self.count];
    self.pixels.count = self.count;
    [self.pixels setNeedsDisplay];
    [self persist];
}
- (void)persist {
    NSDictionary *state = @{
        @"count" : @(self.count),
        @"name" : self.name.text ?: @"",
        @"pid" : @(NSProcessInfo.processInfo.processIdentifier),
        @"at" : @(NSDate.date.timeIntervalSince1970),
        @"nameFocused" : @(self.name.isFirstResponder),
        @"focusAttempted" : @(self.focusAttempted),
        @"focusGranted" : @(self.focusGranted)
    };
    [self.events addObject:state];
    NSMutableDictionary *full = state.mutableCopy;
    full[@"events"] = self.events;
    [[NSJSONSerialization dataWithJSONObject:full options:0 error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/fixture.json"]
         atomically:YES];
}
@end
@interface FixtureDelegate : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@end
@implementation FixtureDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [FixtureVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(FixtureDelegate.class));
    }
}
