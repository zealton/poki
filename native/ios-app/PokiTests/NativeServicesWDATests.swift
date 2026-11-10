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

    func testUnicodeEditingPreservesBackspaceCountAndControlOrder() {
        let requests = NativeServicesWDA.typingRequests("\u{8}\u{8}中文\t姓名\n", frequency: 55)
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0]["text"] as? String, "\u{8}\u{8}")
        XCTAssertEqual(requests[0]["op"] as? String, "type_keys")
        XCTAssertEqual(requests[0]["frequency"] as? Int, 55)
        XCTAssertEqual(requests[1]["text"] as? String, "中文")
        XCTAssertEqual(requests[1]["clear"] as? Bool, false)
        XCTAssertEqual(requests[1]["submit"] as? Bool, false)
        XCTAssertEqual(requests[2]["text"] as? String, "\t")
        XCTAssertEqual(requests[3]["text"] as? String, "姓名")
        XCTAssertEqual(requests[4]["text"] as? String, "\n")
    }

    func testUnicodeRunsStayBatchedAndASCIIKeepsCadence() {
        let unicode = NativeServicesWDA.typingRequests("Hello 中文 👨‍👩‍👧", frequency: nil)
        XCTAssertEqual(unicode.count, 1)
        XCTAssertEqual(unicode[0]["text"] as? String, "Hello 中文 👨‍👩‍👧")
        let ascii = NativeServicesWDA.typingRequests("AbC!?\n", frequency: 120)
        XCTAssertEqual(ascii.count, 1)
        XCTAssertEqual(ascii[0]["frequency"] as? Int, 120)
    }

    func testUnconfirmedPasteIsNotReportedAsSuccessfulTyping() {
        XCTAssertThrowsError(try NativeServicesWDA.checkTypingResult(["isError": true, "instruction": "Read the field before retrying"]))
        XCTAssertNoThrow(try NativeServicesWDA.checkTypingResult(["text_verified": true]))
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
