// SPDX-License-Identifier: AGPL-3.0-only
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
@interface DisplayDomainTests : XCTestCase
@property NSMutableArray *evidence;
@end
@implementation DisplayDomainTests
- (void)emit:(NSString *)event info:(NSDictionary *)info {
    NSMutableDictionary *row=[@{@"event":event,@"at":@([NSDate date].timeIntervalSince1970)}mutableCopy];
    [row addEntriesFromDictionary:info?:@{}];[self.evidence addObject:row];
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    NSLog(@"AXLAB %@",[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]);
}
- (void)save {
    NSURL *url=[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"display-probe.json"];
    [[NSJSONSerialization dataWithJSONObject:self.evidence options:NSJSONWritingPrettyPrinted error:nil]writeToURL:url atomically:YES];
}
- (void)testUserTypingForIndependentAgent {
    [self typeLines:24];
}
- (void)testUserTypingForLiveCarPlay {
    [self typeLines:160];
}
- (void)testAgentExecutionPreferenceUI {
    self.continueAfterFailure=NO;
    XCUIApplication *app=[[XCUIApplication alloc]initWithBundleIdentifier:@"app.zealton.poki"];
    NSArray *chatArgs=@[@"-pokiScreen",@"chat",@"-pokiInProcess",@"none",@"-AppleLanguages",@"(zh-Hans)",@"-AppleLocale",@"zh_CN"];
    app.launchArguments=chatArgs;[app launch];
    XCUIElement *toggle=app.switches[@"agent.backgroundExecution"];
    XCTAssertTrue([toggle waitForExistenceWithTimeout:8]);
    XCTAssertEqualObjects(toggle.value,@"1",@"A fresh installation defaults to background execution");
    XCTAssertTrue([toggle.label containsString:@"后台执行"]);
    [self attachScreen:@"Background default on"];
    [self setSwitch:toggle value:@"0"];
    XCTAssertTrue([app.staticTexts[@"agent.executionStatus"].label containsString:@"原来的方式"]);
    [self attachScreen:@"Original mode off"];
    [app terminate];[app launch];
    toggle=app.switches[@"agent.backgroundExecution"];XCTAssertTrue([toggle waitForExistenceWithTimeout:8]);
    XCTAssertEqualObjects(toggle.value,@"0",@"Off survives an app restart");
    [app terminate];
    app.launchArguments=@[@"-pokiScreen",@"settings",@"-pokiInProcess",@"none",@"-AppleLanguages",@"(zh-Hans)",@"-AppleLocale",@"zh_CN"];
    [app launch];toggle=app.switches[@"agent.backgroundExecution"];
    XCTAssertTrue([toggle waitForExistenceWithTimeout:8]);XCTAssertEqualObjects(toggle.value,@"0");
    [self setSwitch:toggle value:@"1"];
    [self attachScreen:@"Global setting on"];
    [app terminate];app.launchArguments=chatArgs;[app launch];
    toggle=app.switches[@"agent.backgroundExecution"];XCTAssertTrue([toggle waitForExistenceWithTimeout:8]);
    XCTAssertEqualObjects(toggle.value,@"1",@"Settings and chat use the same saved preference");
    [self attachScreen:@"Chat setting synchronized"];
}
- (void)setSwitch:(XCUIElement *)toggle value:(NSString *)value {
    XCTAssertTrue(toggle.enabled);
    // SwiftUI exposes the whole labelled row as a switch; tap its visible trailing control.
    [[toggle coordinateWithNormalizedOffset:CGVectorMake(.94,.5)]tap];
    XCTNSPredicateExpectation *changed=[[XCTNSPredicateExpectation alloc]initWithPredicate:[NSPredicate predicateWithFormat:@"value == %@",value] object:toggle];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[changed] timeout:3],XCTWaiterResultCompleted);
}
- (void)attachScreen:(NSString *)name {
    XCTAttachment *shot=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    shot.name=name;shot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:shot];
}
- (void)typeLines:(int)lines {
    self.evidence=[NSMutableArray new];self.continueAfterFailure=NO;
    XCUIApplication *pad=[[XCUIApplication alloc]initWithBundleIdentifier:@"local.axlab.TypingPad"];
    [pad launch];XCUIElement *editor=pad.textViews[@"user.editor"];XCTAssertTrue([editor waitForExistenceWithTimeout:5]);[editor tap];
    NSMutableString *expected=[NSMutableString new];for(int i=0;i<lines;i++)[expected appendFormat:@"Parallel typing %02d: abcdefghijklmnopqrstuvwxyz 0123456789.\n",i];
    [self emit:@"display.typingInterval" info:@{@"stage":@"start",@"length":@(expected.length)}];[self save];
    [editor typeText:expected];
    [self emit:@"display.typingInterval" info:@{@"stage":@"end",@"length":@(expected.length)}];
    BOOL focus=[[editor valueForKey:@"hasKeyboardFocus"]boolValue];
    [self emit:@"display.userVerdict" info:@{@"userTextExact":@([editor.value isEqual:expected]),@"userFocus":@(focus),@"userState":@(pad.state),@"length":@(expected.length)}];[self save];
    XCTAssertEqualObjects(editor.value,expected);XCTAssertTrue(focus);XCTAssertEqual(pad.state,XCUIApplicationStateRunningForeground);
}
@end
