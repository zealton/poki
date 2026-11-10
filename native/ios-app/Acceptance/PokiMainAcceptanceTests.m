// SPDX-License-Identifier: AGPL-3.0-only
#import <XCTest/XCTest.h>
@interface PokiMainAcceptanceTests : XCTestCase
@end
@implementation PokiMainAcceptanceTests
- (void)testOriginalPokiSafariSearchWhileTyping {
    self.continueAfterFailure = NO;
    XCUIApplication *poki = [[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki"];
    [poki activate];
    XCUIElement *input = [[poki descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"poki.chat.input"].firstMatch;
    XCTAssertTrue([input waitForExistenceWithTimeout:15]);
    [input tap];
    NSString *goal = @"Open Safari and search for a picture of Pikachu. Confirm image search results are displayed.";
    [input typeText:goal];
    XCTAssertEqualObjects(input.value, goal);
    [poki.buttons[@"poki.chat.send"] tap];
    NSLog(@"POKI_MAIN_ACCEPTANCE submitted=%f", NSDate.date.timeIntervalSince1970);
    XCUIApplication *pad = [[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki.TypingPad"];
    [pad launch];
    XCUIElement *editor = pad.textViews[@"user.editor"];
    XCTAssertTrue([editor waitForExistenceWithTimeout:10]);
    [editor tap];
    NSMutableString *expected = [NSMutableString new];
    BOOL interrupted = NO;
    for (int i = 0; i < 60; i++) {
        // Stop upon foreground loss; do not have the test reactivate the editor and hide a switch.
        if (pad.state != XCUIApplicationStateRunningForeground) { interrupted = YES; break; }
        NSString *line = [NSString stringWithFormat:@"poki-main-%02d user keeps typing.\n", i];
        [editor typeText:line];
        [expected appendString:line];
        if (pad.state != XCUIApplicationStateRunningForeground || pad.keyboards.count == 0) { interrupted = YES; break; }
    }
    NSLog(@"POKI_MAIN_ACCEPTANCE interrupted=%d completedCharacters=%lu at=%f", interrupted, (unsigned long)expected.length, NSDate.date.timeIntervalSince1970);
    XCUIApplication *safari = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.mobilesafari"];
    NSLog(@"POKI_MAIN_ACCEPTANCE safariState=%lu", (unsigned long)safari.state);
    XCTAttachment *screen = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    screen.name = @"system-screen-after-typing";
    screen.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:screen];
    XCTAssertFalse(interrupted, @"Original Poki switched foreground or keyboard while the user was typing");
    XCTAssertEqualObjects(editor.value, expected);
}
@end
