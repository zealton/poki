import ActivityKit
import UIKit
import XCTest
@testable import Poki

@MainActor
final class AgentActivityTests: XCTestCase {
    func testModelWaitDoesNotBecomeAFalseCompletionAndOldTaskCannotFinishNewOne() async throws {
        let activity = ActivityController(snapshotDirectory: nil)
        activity.finishAfter = .milliseconds(20)
        let old = UUID()
        activity.beginAgentTask(old, background: true)
        activity.stepStarted("Open Safari")
        activity.record(step: "Open Safari", ok: true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(activity.state.phase, .working, "A slow model response is still a running task")
        XCTAssertEqual(activity.state.agentTask?.thinking, true)
        let new = UUID()
        activity.beginAgentTask(new, background: true)
        activity.endAgentTask(old, success: true, stopped: false)
        XCTAssertEqual(activity.state.agentTask?.id, new)
        XCTAssertEqual(activity.state.phase, .working)
        activity.endAgentTask(new, success: false, stopped: false)
        XCTAssertEqual(activity.state.phase, .problem, "A failed task must not show Done")
        let stopped = UUID(); activity.beginAgentTask(stopped, background: true)
        activity.stepStarted("Read screen")
        activity.endAgentTask(stopped, success: nil, stopped: true)
        XCTAssertEqual(activity.state.agentTask?.steps.last?.status, .stopped)
        XCTAssertEqual(activity.state.face.shortStatus, String(activity: "Stopped"), "A stopped task must not say Ready")
        XCTAssertEqual(activity.state.face.tone, .quiet)
        activity.update { $0.headline = "已停止" }
        XCTAssertEqual(activity.state.face.shortStatus, String(activity: "Stopped"), "State must not depend on the app and widget using the same language")
    }

    func testImagesAreImmutableAndNewTaskDoesNotInheritThePreviousScreenshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = ActivityController(snapshotDirectory: directory)
        activity.beginAgentTask(UUID(), background: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.yellow.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }.jpegData(compressionQuality: 0.8)!
        activity.setThumbnail(image)
        let first = try XCTUnwrap(activity.state.snapshotID)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(first + ".jpg"))
        activity.setThumbnail(image)
        XCTAssertNotEqual(activity.state.snapshotID, first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(first + ".jpg")), bytes)
        activity.setThumbnail(Data("invalid".utf8))
        XCTAssertEqual(activity.state.thumbnailVersion, 2, "Invalid images must not announce a new frame")
        let decoded = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 240)
        activity.beginAgentTask(UUID(), background: true)
        XCTAssertNil(activity.state.snapshotID)
        XCTAssertEqual(activity.state.thumbnailVersion, 0)
    }

    func testBoundedTracePayloadAndOlderContentStillDecode() throws {
        let activity = ActivityController(snapshotDirectory: nil)
        let id = UUID(); activity.beginAgentTask(id, background: true)
        for index in 0..<8 {
            let title = "\(index) " + String(repeating: "操作", count: 100)
            activity.stepStarted(title); activity.record(step: title, ok: index != 7)
        }
        let task = try XCTUnwrap(activity.state.agentTask)
        XCTAssertEqual(task.steps.count, 3)
        XCTAssertEqual(task.steps.last?.status, .failed)
        XCTAssertTrue(task.steps.allSatisfy { $0.title.utf8.count <= 120 })
        activity.agentPlan(id, steps: ["Open", "Search", "Verify"], current: 2)
        XCTAssertEqual(activity.state.agentTask?.current, 2)
        let data = try JSONEncoder().encode(activity.state)
        XCTAssertLessThan(data.count, 4096)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "agentTask"); legacy.removeValue(forKey: "snapshotID"); legacy.removeValue(forKey: "snapshotAt")
        let restored = try JSONDecoder().decode(PokiState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.agentTask)
        XCTAssertEqual(restored.stepCount, 8)
    }
}

@MainActor
final class OnDemandAutomationTests: XCTestCase {
    func testOpeningNativeServicesDoesNotExpectAnXCTestPasscode() {
        let automation = FakeAutomation()
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation, automationPath: .nativeServices)
        XCTAssertFalse(model.passcodeExpected)
        model.requestAutomationForTask("a native-services action")
        XCTAssertEqual(automation.prepares, 0)
    }

    func testStartingAndRevisitingPokiDoesNotOpenXCTestButAPhoneTaskDoes() async throws {
        let defaults = UserDefaults.standard
        let keys = ["relayAddress", "relayEnabled", "wantsOn", "setup"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let automation = FakeAutomation()
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation, automationPath: .inProcess)
        defer {
            model.stopSession()
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        model.loopback.simulate(.working(ms: 1)); model.setup.loopback = .proxy
        XCTAssertTrue(model.setRelay("https://relay.invalid"))
        model.startSession()
        model.runnerChanged(RunnerStatus(state: "running"))
        model.becameActive()
        model.warmInProcess("Poki came to the front")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(automation.prepares, 0, "Starting/revisiting the app must not raise iOS authorization")
        XCTAssertTrue(model.sessionOn)
        model.wakeRunner() // The real host wakes a paused runner before its first phone call.
        model.runnerChanged(RunnerStatus(state: "running"))
        model.requestAutomationForTask("the first real phone call")
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in automation.prepares > 0 }, object: nil)
        await fulfillment(of: [opened], timeout: 3)
    }
}
