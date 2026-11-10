import XCTest
@testable import PokiCore

final class UserLearningTests: XCTestCase {
    func testOwnerTakeoverCannotBeDismissedOrReplacedByAgent() async {
        let (core, wda, _) = makeCore()
        let h = Handoff(id: "takeover", kind: "other", text: "Editing", requested: Date(), ownerOnly: true)
        core.computer.handoff.value = h
        let dismiss = await core.call("do", ["actions": [["handoff": false], ["tap": [20, 20]]]])
        XCTAssertNotNil(core.handoff)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        XCTAssertTrue(dismiss.text.contains("owner"))
        _ = await core.call("do", ["actions": [["handoff": ["kind": "other", "text": "Replace pause"]]]])
        XCTAssertEqual(core.handoff?.id, h.id)
        core.handoffDone(id: h.id)
        XCTAssertNil(core.handoff)
    }

    func testLearningExcludesSecretsAndUnidentifiedFields() {
        let rect = Rect(x: 0, y: 0, width: 100, height: 30)
        let secret = Element(type: "SecureTextField", label: "Password", value: "secret", identifier: "password", frame: rect, depth: 0)
        let unknown = Element(type: "TextField", label: "Name", value: "text", identifier: nil, frame: rect, depth: 0)
        XCTAssertFalse(Computer.learnableField(secret))
        XCTAssertFalse(Computer.learnableField(unknown))
    }

    func testManualGapCannotBeSavedWithExperimentOff() {
        let (core, _, _) = makeCore()
        core.computer.traceHasUserGap = true
        XCTAssertFalse(core.computer.config.userRoutineLearning())
        // A manual gap stays distinct from an automatically successful trace.
        core.computer.handoff.value = Handoff(id: "manual", kind: "other", text: "Editing", requested: Date(), ownerOnly: true)
        core.computer.beginRecording()
        XCTAssertTrue(core.computer.traceHasUserGap)
    }
}
