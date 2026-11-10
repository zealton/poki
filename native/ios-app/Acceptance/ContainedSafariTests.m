// SPDX-License-Identifier: AGPL-3.0-only
#import <XCTest/XCTest.h>
/// Build in the ios-workspace UI driver; all agent work is performed by original Poki.
@interface ContainedSafariTests : XCTestCase @end
@implementation ContainedSafariTests
- (void)typeWithoutRefocusing:(NSInteger)lines {
    XCUIApplication *pad=[[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki.TypingPad"];
    [pad launch];XCUIElement *editor=pad.textViews[@"user.editor"];
    XCTAssertTrue([editor waitForExistenceWithTimeout:10]);[editor tap];
    NSMutableString *expected=[NSMutableString new];
    NSLog(@"CONTAINED_TYPING_BEGIN at=%f",NSDate.date.timeIntervalSince1970);
    for(NSInteger i=0;i<lines;i++) {
        XCTAssertEqual(pad.state,XCUIApplicationStateRunningForeground);
        XCTAssertGreaterThan(pad.keyboards.count,0);
        NSString *line=[NSString stringWithFormat:@"owner-%02ld keeps typing.\n",(long)i];
        [editor typeText:line];[expected appendString:line];
        XCTAssertEqualObjects(editor.value,expected);
        XCTAssertEqual(pad.state,XCUIApplicationStateRunningForeground);
        [NSThread sleepForTimeInterval:1];
    }
    XCUIApplication *poki=[[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki"];
    XCTAssertNotEqual(poki.state,XCUIApplicationStateNotRunning,@"Agent host terminated during concurrent typing");
    NSLog(@"CONTAINED_TYPING_END at=%f exactCharacters=%lu",NSDate.date.timeIntervalSince1970,(unsigned long)expected.length);
    XCTAttachment *a=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];a.name=@"User typing remained foreground";a.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:a];
}
- (void)testTransportWhileTyping {
    self.continueAfterFailure=NO;
    XCUIApplication *poki=[[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki"];
    poki.launchArguments=@[@"-pokiScreen",@"chat",@"-pokiContainedSafari",@"YES",@"-pokiInProcess",@"contained",@"-AppleLanguages",@"(en)",@"-AppleLocale",@"en_US"];
    [poki launch];
    XCTAssertTrue([poki.otherElements[@"poki.contained.preview"] waitForExistenceWithTimeout:20]);
    [self typeWithoutRefocusing:18];
}
- (void)testDeepSeekSearchWhileTyping {
    self.continueAfterFailure=NO;
    XCUIApplication *poki=[[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki"];
    [poki activate];
    XCUIElement *input=[[poki descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"poki.chat.input"].firstMatch;
    XCTAssertTrue([input waitForExistenceWithTimeout:15]);[input tap];
    NSString *goal=@"Use the real Safari in the container to search for a picture of Pikachu. Show actual image search results. Verify the loaded images, not just text or a search URL. I will type in another app; do not interrupt my app or keyboard.";
    [input typeText:goal];XCTAssertEqualObjects(input.value,goal);[poki.buttons[@"poki.chat.send"] tap];
    NSLog(@"CONTAINED_AGENT_SUBMITTED at=%f",NSDate.date.timeIntervalSince1970);
    [self typeWithoutRefocusing:40];
}
- (void)testSearchButtonWithFloatingPreview {
    self.continueAfterFailure=NO;
    XCUIApplication *poki=[[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki"];
    [poki activate];
    XCUIElement *floating=poki.buttons[@"poki.contained.floating"];
    XCTAssertTrue([floating waitForExistenceWithTimeout:15]);[floating tap];
    [NSThread sleepForTimeInterval:2];
    XCUIElement *input=[[poki descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"poki.chat.input"].firstMatch;
    XCTAssertTrue([input waitForExistenceWithTimeout:10]);[input tap];
    NSString *goal=@"In the container Safari, search for Pikachu wallpaper images. First press Safari's native refresh button once. Then fill the webpage search input with Pikachu wallpaper and click its ordinary Search button. Do not just verify old results or navigate to a constructed search URL. Verify the newly loaded images. I am typing in another app; keep my foreground and keyboard untouched.";
    [input typeText:goal];XCTAssertEqualObjects(input.value,goal);[poki.buttons[@"poki.chat.send"] tap];
    NSLog(@"CONTAINED_BUTTON_AGENT_SUBMITTED at=%f",NSDate.date.timeIntervalSince1970);
    [self typeWithoutRefocusing:40];
    XCUIApplication *safari=[[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.mobilesafari"];
    NSLog(@"CONTAINED_SYSTEM_SAFARI_STATE=%lu",(unsigned long)safari.state);
}
@end
