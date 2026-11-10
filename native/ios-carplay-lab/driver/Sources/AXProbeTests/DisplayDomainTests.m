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
    self.evidence=[NSMutableArray new];self.continueAfterFailure=NO;
    XCUIApplication *pad=[[XCUIApplication alloc]initWithBundleIdentifier:@"local.axlab.TypingPad"];
    [pad launch];XCUIElement *editor=pad.textViews[@"user.editor"];XCTAssertTrue([editor waitForExistenceWithTimeout:5]);[editor tap];
    NSMutableString *expected=[NSMutableString new];for(int i=0;i<24;i++)[expected appendFormat:@"Parallel typing %02d: abcdefghijklmnopqrstuvwxyz 0123456789.\n",i];
    [self emit:@"display.typingInterval" info:@{@"stage":@"start",@"length":@(expected.length)}];[self save];
    [editor typeText:expected];
    [self emit:@"display.typingInterval" info:@{@"stage":@"end",@"length":@(expected.length)}];
    BOOL focus=[[editor valueForKey:@"hasKeyboardFocus"]boolValue];
    [self emit:@"display.userVerdict" info:@{@"userTextExact":@([editor.value isEqual:expected]),@"userFocus":@(focus),@"userState":@(pad.state),@"length":@(expected.length)}];[self save];
    XCTAssertEqualObjects(editor.value,expected);XCTAssertTrue(focus);XCTAssertEqual(pad.state,XCUIApplicationStateRunningForeground);
}
@end
