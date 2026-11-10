// SPDX-License-Identifier: AGPL-3.0-only
#import <XCTest/XCTest.h>
// Requires a saved key in the host app. No key is passed through the test runner.
@interface WorkspaceConcurrencyTests : XCTestCase
@end
@implementation WorkspaceConcurrencyTests
- (void)testAutonomousGuestWhileTyping {
    self.continueAfterFailure = NO;
    XCUIApplication *workspace =
        [[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki.workspace"];
    [workspace activate];
    XCUIElement *status = workspace.staticTexts[@"workspace.status"];
    XCTAssertTrue([status waitForExistenceWithTimeout:15]);
    [workspace.buttons[@"开始"] tap];
    XCUIApplication *pad =
        [[XCUIApplication alloc] initWithBundleIdentifier:@"app.zealton.poki.TypingPad"];
    [pad launch];
    XCUIElement *editor = pad.textViews[@"user.editor"];
    XCTAssertTrue([editor waitForExistenceWithTimeout:10]);
    [editor tap];
    NSMutableString *expected = [NSMutableString new];
    for (int i = 0; i < 30; i++) {
        @autoreleasepool {
            NSString *line = [NSString stringWithFormat:@"owner-%02d keeps typing.\n", i];
            [editor typeText:line];
            [expected appendString:line];
            XCTAssertEqual(pad.state, XCUIApplicationStateRunningForeground);
            XCTAssertTrue(pad.keyboards.count > 0);
        }
    }
    XCTAssertEqualObjects(editor.value, expected);
    [workspace activate];
    // Background progress and completion must also be verified from fixture-run.json and
    // fixture.json: UI text alone does not prove a model call or an actual business callback.
    XCTAssertTrue([status waitForExistenceWithTimeout:10]);
}
@end
