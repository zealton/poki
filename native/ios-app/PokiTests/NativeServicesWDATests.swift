import PokiCore
import UIKit
import XCTest
@testable import Poki

final class NativeServicesWDATests: XCTestCase {
    @MainActor
    func testChineseInputVerificationRejectsUnknownAndOtherLanguages() {
        for language in ["zh", "zh-Hans", "zh-Hant", "zh_CN"] {
            XCTAssertTrue(InProcessProbe.isChineseInputLanguage(language))
        }
        let otherLanguages: [String?] = [nil, "", "en-US", "ja-JP", "zhongwen"]
        for language in otherLanguages {
            XCTAssertFalse(InProcessProbe.isChineseInputLanguage(language))
        }
    }

    func testNativeIMEPreservesEditOrderWithoutPasteFallback() throws {
        let parts = try NativeIME.plan("\u{8}\u{8}中文\t姓名\n")
        XCTAssertEqual(parts.map(\.text), ["\u{8}", "\u{8}", "中文", "\t", "姓名", "\n"])
        XCTAssertTrue(parts[2].composition)
        XCTAssertEqual(parts[2].keys, "zhongwen")
        XCTAssertThrowsError(try NativeIME.plan("prefix🙂"))
    }

    func testNativeIMEUsesWordsAndLiteralUmlautConversion() throws {
        let sentence = "今天我们一起测试中文输入"
        let parts = try NativeIME.plan(sentence)
        XCTAssertEqual(parts.map(\.text).joined(), sentence)
        XCTAssertTrue(NativeIME.words(sentence).contains("我们"))
        XCTAssertEqual(try NativeIME.pinyin("选择"), "xuanze")
        XCTAssertEqual(try NativeIME.pinyin("绿色"), "lvse")
        XCTAssertEqual(try NativeIME.pinyin("女"), "nv")
    }

    func testNativeIMEVerifiesExactEdits() {
        XCTAssertTrue(NativeIME.matchesEdit(before: "ab", after: "a你好b", keys: "你好"))
        XCTAssertFalse(NativeIME.matchesEdit(before: "ab", after: "X你好b", keys: "你好"))
        XCTAssertFalse(NativeIME.matchesEdit(before: "abc", after: "a", keys: "\u{8}"))
        XCTAssertFalse(NativeIME.matchesEdit(before: "abc", after: "abc", keys: "\u{8}"))
    }

    func testCompactStatusAndGlyphShareEventColor() {
        var state = PokiState(phase: .idle, headline: "Ready", thumbnailVersion: 0)
        state.event = .init(kind: .started, text: "Started")
        let face = state.face
        guard case .text(_, let tone) = face.compact else { return XCTFail("Expected compact status") }
        XCTAssertEqual(tone, face.tone)
    }

    func testDragVelocityUsesScreenPointsNotHIDCoordinates() {
        let body: JSON = ["fromX": 201, "fromY": 300, "toX": 201, "toY": 480, "velocity": 800]
        XCTAssertEqual(NativeServicesWDA.dragMilliseconds(body), 225)
        let diagonal: JSON = ["fromX": 0, "fromY": 0, "toX": 300, "toY": 400, "velocity": 1000]
        XCTAssertEqual(NativeServicesWDA.dragMilliseconds(diagonal), 500)
        XCTAssertEqual(NativeServicesWDA.dragMilliseconds(nil), 80)
    }

    func testHumanizedPointerActionsKeepEveryPointAndRelativeTime() throws {
        let wda = NativeServicesWDA(screen: CGSize(width: 401, height: 801))
        let source: JSON = [
            "type": "pointer",
            "parameters": ["pointerType": "touch"],
            "actions": [
                ["type": "pointerMove", "duration": 0, "x": 100.25, "y": 200.25],
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": 30],
                ["type": "pointerMove", "duration": 45, "x": 101.75, "y": 201.75],
                ["type": "pointerUp", "button": 0],
            ],
        ]

        let points = try wda.finger(source)

        XCTAssertEqual(points.count, 3)
        // Screen endpoints map to 0...65535: round(100.25 / 400 * 65535) = 16425.
        XCTAssertEqual(points[0]["x"] as? Int, 16_425)
        XCTAssertEqual(points[0]["y"] as? Int, 16_404)
        XCTAssertEqual(points[0]["time_ms"] as? Double, 0)
        XCTAssertEqual(points[1]["x"] as? Int, 16_425)
        XCTAssertEqual(points[1]["time_ms"] as? Double, 30)
        XCTAssertEqual(points[2]["x"] as? Int, 16_670)
        XCTAssertEqual(points[2]["y"] as? Int, 16_527)
        XCTAssertEqual(points[2]["time_ms"] as? Double, 75)
    }
}
