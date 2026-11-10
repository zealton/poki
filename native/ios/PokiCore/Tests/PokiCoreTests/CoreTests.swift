import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import PokiCore

final class BasicsTests: XCTestCase {
    func testBase32() {
        XCTAssertEqual(base32(Data("foobar".utf8)), "mzxw6ytboi")
        XCTAssertEqual(base32(Data(count: 32)).count, 52)
    }

    func testJSONRoundTrip() throws {
        let value: JSON = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        XCTAssertEqual(try JSON.parse(value.serialized()), value)
    }

    func testDeadlineDoesNotWaitForAnOperationThatIgnoresCancellation() async {
        let started = Date()
        do {
            _ = try await withDeadline(0.2, "a stuck step") { await hang() }
            XCTFail("expected the deadline")
        } catch let error as DeadlineExceeded {
            XCTAssertEqual(error.what, "a stuck step")
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSensitiveWordsMatchWholeWords() {
        XCTAssertEqual(SensitivityRules.matches("Delete Photo", ["delete"]), "delete")
        XCTAssertNil(SensitivityRules.matches("Display & Brightness", ["pay"]))
        XCTAssertEqual(SensitivityRules.matches("确认支付", ["支付"]), "支付")
    }
}

/// What the agent reads while the loopback is down: the owner's way back depends on the connection.
final class LoopbackWaitTests: XCTestCase {
    func testTheBuiltInConnectionSendsTheOwnerBackToPokiNotToAProxyApp() {
        XCTAssertEqual(
            RunnerState.waitingForLoopback(since: "14:02:11", tunnelWithoutAnswer: false, connection: .builtIn),
            .starting("waiting for the loopback since 14:02:11: Poki's local connection is off, or another VPN app replaced it. The owner opens Poki and taps Enable local connection in Setup, or turns Poki's VPN back on in iOS Settings > VPN; the runner starts again by itself within seconds of that. Nothing on the phone changes meanwhile"))
        XCTAssertEqual(
            RunnerState.waitingForLoopback(since: nil, tunnelWithoutAnswer: true, connection: .builtIn),
            .starting("waiting for the loopback: Poki's local connection is on, but this iPhone's developer services do not answer at 10.7.0.1. The owner opens Poki and taps Enable local connection in Setup, or turns Poki's VPN back on in iOS Settings > VPN; the runner starts again by itself within seconds of that. Nothing on the phone changes meanwhile"))
    }

    func testAProxyAppKeepsItsOwnInstructions() {
        XCTAssertEqual(
            RunnerState.waitingForLoopback(since: "14:02:11", tunnelWithoutAnswer: false, connection: .external),
            .starting("waiting for the loopback since 14:02:11: the loopback at 10.7.0.1 is not answering. The owner turns the proxy app's tunnel (Surge, Loon, Shadowrocket or sing-box) back on; the runner starts again by itself within seconds of that. Nothing on the phone changes meanwhile"))
        XCTAssertEqual(
            RunnerState.waitingForLoopback(since: nil, tunnelWithoutAnswer: true, connection: .external),
            .starting("waiting for the loopback: the proxy app's tunnel is on but does not reflect 10.7.0.1. The owner turns the proxy app's tunnel (Surge, Loon, Shadowrocket or sing-box) back on; the runner starts again by itself within seconds of that. Nothing on the phone changes meanwhile"))
    }
}

final class ToolTests: XCTestCase {
    func testLookListsElementsWithAPicture() async {
        let (core, _, _) = makeCore()
        let result = await core.call("look", [:])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasPrefix("app: Settings"), result.text)
        XCTAssertTrue(result.text.contains("1 Button \"General\" [16,100,358,44]"), result.text)
        XCTAssertNotNil(result.jpeg)
    }

    func testAStuckTreeStillAnswersInTimeWithThePicture() async {
        let (core, wda, _) = makeCore()
        wda.set("GET /source") { _ in await hang() }
        let started = Date()
        let result = await core.call("look", [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertNotNil(result.jpeg, "the screenshot still comes back")
        XCTAssertTrue(result.text.contains("no element tree"), result.text)
    }

    func testANothingRunnerAnswersFastAndAsksForARestart() async {
        let (core, wda, host) = makeCore()
        let gone: FakeWDA.Route = { _ in throw TransportError.refused }
        for key in ["GET /source", "GET /screenshot", "GET /wda/activeAppInfo", "GET /wda/screen", "POST /session"] { wda.set(key, gone) }
        let started = Date()
        let result = await core.call("look", [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("read: failed"), result.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertGreaterThanOrEqual(host.restarts.value, 1)
        // A failed runner is answered at once, with its fix, and nothing is sent.
        host.state.value = .failed("Poki Runner is not installed", fix: "Install it")
        let count = wda.sent.count
        let quick = Date()
        let next = await core.call("do", ["actions": [["tap": [10, 10]]]])
        XCTAssertTrue(next.text.contains("runner: failed: Poki Runner is not installed. Fix on the phone: Install it"), next.text)
        XCTAssertLessThan(Date().timeIntervalSince(quick), 0.5)
        XCTAssertEqual(wda.sent.count, count)
    }

    func testACallWaitsForARunnerThatIsStartingThenGoesOn() async {
        let (core, wda, host) = makeCore()
        host.state.value = .starting("launching the runner")
        Task { try? await Task.sleep(nanoseconds: 600_000_000); host.state.value = .running }
        let started = Date()
        let result = await core.call("look", [:])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(wda.sent.isEmpty)
    }

    func testARunnerThatNeverStartsIsAnsweredWithinTheCap() async {
        let (core, wda, host) = makeCore { $0.runnerWait = 0.5 }
        host.state.value = .starting("mounting the developer disk image")
        let started = Date()
        let result = await core.call("do", ["actions": [["tap": [10, 10]]]])
        XCTAssertTrue(result.text.contains("still starting"), result.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(wda.sent.isEmpty)
    }

    func testTapByNumberHitsTheCentre() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 2]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").last, ["x": 195, "y": 166])
        XCTAssertTrue(result.text.contains("did: tap tap \"Privacy\" (sent"), result.text)
    }

    func testAStaleNumberSendsNothing() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 9]]])
        XCTAssertFalse(result.isError, "the screen was read, so the answer is not an error; its error line says what was wrong")
        XCTAssertTrue(result.text.contains("element 9 is not in the latest read"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testAStuckTapIsReportedAsMaybeDeliveredAndNothingAfterItIsSent() async {
        let (core, wda, _) = makeCore()
        wda.set("POST /wda/tap") { _ in await hang() }
        _ = await core.call("look", [:])
        let started = Date()
        let result = await core.call("do", ["actions": [["tap": 1], ["key": "return"]]])
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertTrue(result.text.contains("may have been delivered"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/keys").isEmpty)
        XCTAssertNotNil(result.jpeg, "the screen is still read after the failure")
    }

    func testTypingClearsWithDeletesInOneRequest() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("TextField", nil, [16, 100, 358, 44], value: "abc"), Node("Keyboard", nil, [0, 500, 390, 344])], app: "Notes")
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["type": "hi", "clear": true]]])
        XCTAssertEqual(wda.bodies("POST /wda/keys").last, ["value": ["\u{8}", "\u{8}", "\u{8}", "h", "i"]])
    }

    func testTheSecondCallIsBusyInsteadOfQueued() async {
        let (core, wda, _) = makeCore()
        wda.set("GET /source") { _ in try await Task.sleep(nanoseconds: 800_000_000); return (200, ["value": ["type": "XCUIElementTypeApplication"]]) }
        async let first = core.call("look", [:])
        try? await Task.sleep(nanoseconds: 100_000_000)
        let second = await core.call("look", [:])
        XCTAssertTrue(second.text.hasPrefix("busy"), second.text)
        _ = await first
    }
}

final class ApprovalTests: XCTestCase {
    func screenWithDelete() -> FakeWDA {
        let wda = FakeWDA()
        wda.source([("Button", "Delete Photo"), ("Button", "Share")], app: "Photos")
        return wda
    }

    func testADeletionWaitsForTheOwnerAndSendsNothing() async {
        let (core, wda, _) = makeCore(screenWithDelete())
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        let pending = core.pendingApproval
        XCTAssertEqual(pending?.reason, "deleting (\"delete\")")
        // Approved on the phone: the same actions sent again run once.
        core.resolveApproval(id: pending!.id, approved: true)
        let again = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(again.isError, again.text)
        XCTAssertTrue(again.text.contains("approved on the phone"), again.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        // Used up: a third time asks again.
        let third = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(third.text.contains("approval_required"), third.text)
    }

    /// The chat's model loop in the app calls the tools with JSON text through `callTool`; a deletion
    /// still waits for the owner and taps nothing.
    func testTheInAppChatPathWaitsForTheOwnerToo() async {
        let (core, wda, _) = makeCore(screenWithDelete())
        _ = await core.callTool("look", arguments: "{}")
        let result = await core.callTool("do", arguments: #"{"actions":[{"tap":1}]}"#)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        XCTAssertEqual(core.pendingApproval?.reason, "deleting (\"delete\")")
    }

    func testApprovalDuringTheWaitRunsTheActionsInTheSameCall() async {
        let (core, wda, _) = makeCore(screenWithDelete()) { $0.approvalWait = 2 }
        _ = await core.call("look", [:])
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let p = core.pendingApproval { core.resolveApproval(id: p.id, approved: true) }
        }
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    /// Seen on the phone (GitHub issue 44): owners took 42 to 47 s to approve, `do` gave up after 20 s,
    /// and every sensitive action failed once before it went through.
    func testTheDefaultWaitOutlastsAHumanApprovalAndEndsWithTheRequest() {
        let slowestApprovalSeen = 47.0
        let wait = CoreConfig().approvalWait
        XCTAssertGreaterThan(wait, slowestApprovalSeen)
        XCTAssertLessThanOrEqual(wait, Approvals(emit: { _ in }).lifetime, "a request that has ended cannot be waited for")
    }

    /// A phone connected to a relay that gives up on a request `reqTimeoutMs` after it arrives, with a
    /// `do` that taps the Delete button sent through it.
    private func relayedDelete(_ core: PokiCore, reqTimeoutMs: Int) async -> FakeSocket {
        let sockets = FakeSockets()
        core.start(relay: testRelay, socketFactory: sockets)
        let connected = await eventually(3) { !sockets.sockets.value.isEmpty }
        XCTAssertTrue(connected)
        let socket = sockets.sockets.value[0]
        socket.push((["t": "challenge", "nonce": .string(Data(repeating: 1, count: 32).base64EncodedString())] as JSON).serialized())
        let shook = await eventually(3) { socket.sent.contains { $0.contains("\"t\":\"hello\"") } }
        XCTAssertTrue(shook)
        socket.push((["t": "ready", "max_body": 4_194_304, "req_timeout_ms": .number(Double(reqTimeoutMs))] as JSON).serialized())
        let body: JSON = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "do", "arguments": ["actions": [["tap": 1]]]]]
        socket.push((["t": "req", "id": "r1", "method": "POST", "headers": ["content-type": "application/json"], "body": .string(body.serialized())] as JSON).serialized())
        return socket
    }

    private func approveAfter(_ seconds: Double, _ core: PokiCore) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if let p = core.pendingApproval { core.resolveApproval(id: p.id, approved: true) }
        }
    }

    /// The relay answers the caller with a 504 once `req_timeout_ms` of its ready frame has passed. A
    /// `do` holding for the owner past that would lose its answer, so it answers `approval_required`
    /// first, with the request still open for the owner to approve and send again.
    func testTheApprovalWaitEndsBeforeTheRelayGivesUp() async throws {
        let (core, wda, _) = makeCore(screenWithDelete()) { $0.approvalWait = 30 }
        _ = await core.call("look", [:])
        let socket = await relayedDelete(core, reqTimeoutMs: 8000)
        let sent = Date()
        let answered = await eventually(8) { socket.sent.contains { $0.contains("\"t\":\"res\"") } }
        let took = Date().timeIntervalSince(sent)
        core.stop()
        XCTAssertTrue(answered, "no answer before the relay's 8 s")
        XCTAssertLessThan(took, 7.5)
        XCTAssertGreaterThan(took, 1.5, "it held for the owner instead of failing at once")
        XCTAssertTrue(socket.sent.contains { $0.contains("approval_required") })
        XCTAssertNotNil(core.pendingApproval, "the request stays open for the owner")
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    /// An approval that comes in the last seconds before the relay gives up leaves no time to send the
    /// actions and read the screen. The actions would run after the relay's 504, so the caller would
    /// see a failure for something that happened and send it again. Nothing is sent in this call; the
    /// approval is kept, and the same `do` sent again runs at once. (Real time: about 4 s.)
    func testAnApprovalTooLateForTheRelayIsKeptForTheNextCallInsteadOfRunning() async throws {
        let (core, wda, _) = makeCore(screenWithDelete()) { $0.approvalWait = 30 }
        _ = await core.call("look", [:])
        approveAfter(3.5, core)
        let socket = await relayedDelete(core, reqTimeoutMs: 9000)
        let sent = Date()
        let answered = await eventually(9) { socket.sent.contains { $0.contains("\"t\":\"res\"") } }
        let took = Date().timeIntervalSince(sent)
        core.stop()
        XCTAssertTrue(answered)
        XCTAssertLessThan(took, 8)
        XCTAssertTrue(socket.sent.contains { $0.contains("approval_required") })
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, "the actions were sent after the owner approved too late")
        let again = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "the kept approval runs the same actions once")
    }

    /// The other side of the one above: an approval with time to spare runs in the same call, behind a relay too.
    func testAnApprovalWithTimeToSpareRunsInTheSameCallBehindARelay() async throws {
        let (core, wda, _) = makeCore(screenWithDelete()) { $0.approvalWait = 30 }
        _ = await core.call("look", [:])
        approveAfter(0.3, core)
        let socket = await relayedDelete(core, reqTimeoutMs: 9000)
        let answered = await eventually(9) { socket.sent.contains { $0.contains("\"t\":\"res\"") } }
        core.stop()
        XCTAssertTrue(answered)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertTrue(socket.sent.contains { $0.contains("approved on the phone") })
    }

    /// The caller gave up (the relay sent `cancel`: its own time ran out, or the client's did) while
    /// the owner was still being waited for. An approval that comes later must not run the actions
    /// for a call nobody is waiting on: the model would send them again and they would go twice.
    func testACancelledCallDoesNotRunWhenTheOwnerApprovesLater() async throws {
        let (core, wda, _) = makeCore(screenWithDelete()) { $0.approvalWait = 30 }
        _ = await core.call("look", [:])
        let socket = await relayedDelete(core, reqTimeoutMs: 60_000)
        let asked = await eventually(3) { core.pendingApproval != nil }
        XCTAssertTrue(asked)
        socket.push((["t": "cancel", "id": "r1"] as JSON).serialized())
        try await Task.sleep(nanoseconds: 300_000_000)
        core.resolveApproval(id: core.pendingApproval!.id, approved: true)
        try await Task.sleep(nanoseconds: 700_000_000)
        core.stop()
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, "the cancelled call ran its actions")
    }

    func testDeclinedSendsNothing() async {
        let (core, wda, _) = makeCore(screenWithDelete()) { $0.approvalWait = 2 }
        _ = await core.call("look", [:])
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let p = core.pendingApproval { core.resolveApproval(id: p.id, approved: false) }
        }
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.hasPrefix("not_sent from action 1: the owner declined on the phone"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        // The screen it was refused on comes with the answer (the gym: the one answer without a picture).
        XCTAssertNotNil(result.jpeg, result.text)
        XCTAssertTrue(result.text.contains("Nothing was sent.\napp: "), result.text)
    }

    func testOtherActionsWithdrawThePendingRequestSoTheAutomationCannotApproveIt() async {
        let (core, _, _) = makeCore(screenWithDelete())
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": 1]]])
        let id = core.pendingApproval!.id
        _ = await core.call("do", ["actions": [["tap": 2]]])
        XCTAssertNil(core.pendingApproval)
        core.resolveApproval(id: id, approved: true)  // a press that arrives late does nothing
        let again = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(again.text.contains("approval_required"), again.text)
    }

    func testTappingAContactInPhonePlacesNoCallWithoutTheOwner() async {
        let wda = FakeWDA()
        wda.source([("Cell", "Mom, mobile"), ("Button", "Keypad")], app: "Phone")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilephone", "name": "Phone"]]) }
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        XCTAssertEqual(core.pendingApproval?.reason, "a call (in Phone)")
    }

    /// The Voice tab's "tap Send" goes through the Mac, not `do`; it is held by the same rules and the same approval.
    func testAVoiceTapOnSendInMessagesWaitsForTheOwner() async {
        let (core, _, _) = makeCore()
        let unanswered = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.2)
        XCTAssertEqual(unanswered, .unanswered("sending a message (\"send\")"))
        XCTAssertFalse(unanswered.mayTap)
        XCTAssertNil(core.pendingApproval, "a request nobody answered is withdrawn")

        Task {
            _ = await eventually { core.pendingApproval != nil }
            XCTAssertEqual(core.pendingApproval?.summary, "Tap “Send”")
            XCTAssertEqual(core.pendingApproval?.app, "Messages")
            core.resolveApproval(id: core.pendingApproval!.id, approved: true)
        }
        let approved = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 2)
        XCTAssertTrue(approved.mayTap, "\(approved)")

        let settings = await core.clearTap(on: "Display & Brightness", inApp: "com.apple.Preferences", named: "Settings", waiting: 2)
        XCTAssertEqual(settings, .clear)
    }

    /// The approval card is in Poki: a voice "tap Allow" with Poki in front taps nothing, and the request
    /// it would have granted stays for the owner.
    func testAVoiceTapInPokiCannotApproveThePendingRequest() async throws {
        let (core, _, _) = makeCore()
        let send = Task { await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 3) }
        let asked = await eventually { core.pendingApproval != nil }
        XCTAssertTrue(asked, "the Send tap asks the owner")
        let pending = try XCTUnwrap(core.pendingApproval)

        let allow = await core.clearTap(on: "Allow", inApp: "nz.zheha.poki", named: "Poki", waiting: 1)
        XCTAssertFalse(allow.mayTap, "\(allow)")
        XCTAssertEqual(core.pendingApproval?.id, pending.id, "the owner still decides the Send tap")

        core.resolveApproval(id: pending.id, approved: false)
        let sent = await send.value
        XCTAssertFalse(sent.mayTap)
    }

    /// Like `do`: another voice tap withdraws the request still waiting, so two taps never wait side by side.
    func testAnotherVoiceTapWithdrawsThePendingRequest() async throws {
        let (core, _, _) = makeCore()
        let send = Task { await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 3) }
        let asked = await eventually { core.pendingApproval != nil }
        XCTAssertTrue(asked, "the Send tap asks the owner")
        let pending = try XCTUnwrap(core.pendingApproval)

        let settings = await core.clearTap(on: "Display & Brightness", inApp: "com.apple.Preferences", named: "Settings", waiting: 1)
        XCTAssertEqual(settings, .clear)
        XCTAssertNil(core.pendingApproval, "the Send request is withdrawn")
        core.resolveApproval(id: pending.id, approved: true)  // a press that arrives late does nothing
        let sent = await send.value
        XCTAssertFalse(sent.mayTap, "\(sent)")
    }

    /// A voice tap on an element with no readable text cannot be checked against the rules, so the owner
    /// is asked (a Send button known only by its identifier would otherwise go through).
    func testAVoiceTapWithNoReadableTextAsksTheOwner() async {
        let (core, _, _) = makeCore()
        let asked = Task { await eventually { core.pendingApproval != nil } }
        let tap = await core.clearTap(on: "  ", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.3)
        let wasAsked = await asked.value
        XCTAssertFalse(tap.mayTap, "\(tap)")
        XCTAssertTrue(wasAsked, "the owner is asked on the phone")
    }

    /// An element can read "Done" and still be the Send button by its identifier; `do` checks both.
    func testDoAsksForAButtonOnlyItsIdentifierCallsSend() async {
        let wda = FakeWDA()
        let button: JSON = ["type": "XCUIElementTypeButton", "label": "Done", "name": "send-button", "rect": ["x": 16, "y": 100, "width": 358, "height": 44]]
        let root: JSON = ["type": "XCUIElementTypeApplication", "label": "Messages", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": [button]]
        wda.set("GET /source") { _ in (200, ["value": root]) }
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.MobileSMS", "name": "Messages"]]) }
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    /// The relay agent's `do` never taps in Poki either.
    func testDoTapsNothingInPoki() async {
        let wda = FakeWDA()
        wda.source([("Button", "Allow"), ("Button", "Deny")], app: "Poki")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("only the phone's owner"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    /// Nobody answered and the agent sent nothing more: the request still ends when its time is up, and
    /// says so. The app holds its Live Activity card, the idle stop and Stop Runner until it hears that.
    func testAnUnansweredRequestEndsByItselfWhenItsTimeIsUp() async {
        let ended = LockedBox<[String]>([])
        let approvals = Approvals(lifetime: 0.3) { event in
            if case .approvalEnded(let id, nil) = event { ended.update { $0.append(id) } }
        }
        let approval = approvals.request(app: "Photos", summary: "Tap “Delete Photo”", reason: "deleting (\"delete\")", fingerprint: "f")
        let heard = await eventually(1.5) { ended.value == [approval.id] }
        XCTAssertTrue(heard, "no approvalEnded for a request whose time ran out")
    }

    private func wallet() -> FakeWDA {
        let wda = FakeWDA()
        wda.source([("Button", "Apple Card"), ("Button", "Add Card")], app: "Wallet")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.Passbook", "name": "Wallet"]]) }
        return wda
    }

    /// Wallet asks for every input, but waiting, handing the screen to the owner and leaving are not
    /// input: asking for them held every Wallet run at each step, and an agent could not even go Home.
    func testInWalletWaitingAndLeavingNeedNoApprovalButATapDoes() async {
        let (core, wda, _) = makeCore(wallet())
        _ = await core.call("look", [:])
        let waited = await core.call("do", ["actions": [["wait": 10], ["wait_until": ["settled": true, "ms": 200]]]])
        XCTAssertFalse(waited.text.contains("approval"), waited.text)
        let tapped = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(tapped.text.contains("approval_required"), tapped.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        let home = await core.call("do", ["actions": [["button": "home"]]])
        XCTAssertFalse(home.text.contains("approval"), home.text)
        XCTAssertEqual(wda.sent.filter { $0 == "POST /wda/homescreen" }.count, 1, home.text)
    }

    func testInWalletTheAgentCanHandTheScreenToTheOwnerWithoutApproval() async {
        let (core, _, _) = makeCore(wallet())
        _ = await core.call("look", [:])
        let handed = await core.call("do", ["actions": [["handoff": ["kind": "payment", "text": "Confirm the payment"]]]])
        XCTAssertFalse(handed.text.contains("approval"), handed.text)
        XCTAssertNotNil(core.handoff, handed.text)
    }

    /// A tap in Phone can ring a contact whatever it reads, so a tap on a point with nothing readable
    /// under it asks too.
    func testATapOnNothingReadableInPhoneAsks() async {
        let wda = FakeWDA()
        wda.source([("Button", "Keypad")], app: "Phone")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilephone", "name": "Phone"]]) }
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": [200, 600]]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    /// The actions after a launch land in the launched app, on a screen not read yet: they are checked
    /// against that app, the way `landsInPoki` follows launches, not against the app of the last read.
    func testActionsAfterALaunchAreCheckedAgainstTheLaunchedApp() async {
        for (bundle, reason) in [("com.apple.mobilephone", "a call"), ("com.apple.MobileSMS", "sending a message"), ("com.apple.Passbook", "input in")] {
            let (core, wda, _) = makeCore()
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["launch": .string(bundle)], ["wait": 300], ["tap": [350, 790]]]])
            XCTAssertTrue(result.text.contains("approval_required"), "\(bundle): \(result.text)")
            XCTAssertTrue(core.pendingApproval?.reason.hasPrefix(reason) == true, "\(bundle): \(core.pendingApproval?.reason ?? "no request")")
            XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1, "the launch before it goes first")
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, "\(bundle): the tap was sent")
        }
    }

    private func store(routine name: String, app: String, steps: [JSON]) -> RoutineStore {
        let store = RoutineStore(url: nil)
        store.save(Routine(name: name, description: "", app: app, steps: steps.map { RoutineStep(action: $0, target: nil, app: app, secret: nil) }, params: [:], expect: [], read: [],
                           runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, savedBy: "test", created: Date(), updated: Date()))
        return store
    }

    /// A routine run in Wallet is input in Wallet: its point tap (recorded without an element) is not
    /// sent before the owner approves, whether Wallet is in front or the run launches it.
    func testARoutineRunInWalletAsksBeforeItsPointTap() async {
        for front in ["com.apple.Passbook", "com.apple.Preferences"] {
            let wda = wallet()
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(front), "name": "X"]]) }
            let (core, _, _) = makeCore(wda) { $0.memory = self.store(routine: "card", app: "com.apple.Passbook", steps: [["tap": [200, 400]]]) }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["run": "card"]]])
            XCTAssertTrue(result.text.contains("approval_required"), "\(front): \(result.text)")
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, "\(front): the routine's tap was sent")
        }
    }

    /// The same rules hold inside a run: a routine's point tap in Phone rings whatever is there, so the
    /// run stops before it; the same routine in Settings taps.
    func testARoutinesPointTapInPhoneIsNotSentWithoutTheOwner() async {
        for (bundle, name, sends) in [("com.apple.mobilephone", "Phone", false), ("com.apple.Preferences", "Settings", true)] {
            let wda = FakeWDA()
            wda.source([("Button", "Keypad")], app: name)
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(bundle), "name": .string(name)]]) }
            let (core, _, _) = makeCore(wda) { $0.memory = self.store(routine: "ring", app: bundle, steps: [["tap": [200, 600]]]) }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["run": "ring"]]])
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, sends ? 1 : 0, "\(name): \(result.text)")
            if !sends { XCTAssertTrue(result.text.contains("approval"), result.text) }
        }
    }

    private func messages(_ bundle: String = "com.apple.MobileSMS", _ rows: [(String, String)] = [("Cell", "Mom"), ("Cell", "Work")]) -> FakeWDA {
        let wda = FakeWDA()
        wda.source(rows, app: "Messages")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(bundle), "name": "Messages"]]) }
        return wda
    }

    func testAPointAfterATapReturnsAFreshScreenBeforeChoosingWhetherToAsk() async {
        for (label, bundle, asks) in [
            ("查询", "test.travel", false), ("搜索", "test.travel", false),
            ("筛选", "test.travel", false), ("选日期", "test.travel", false),
            ("付款", "test.travel", true), ("删除", "test.photos", true),
            ("发送", "com.apple.MobileSMS", true), ("拨打", "test.contacts", true)
        ] {
            let wda = messages(bundle, [("Button", "popClose")])
            let (core, _, _) = makeCore(wda)
            _ = await core.call("look", [:])
            wda.set("POST /wda/tap") { _ in
                wda.source([("Button", label)])
                return (200, ["value": .null])
            }
            let result = await core.call("do", ["actions": [["tap": 1], ["tap": [100, 120]]]])
            XCTAssertNil(core.pendingApproval, label)
            XCTAssertTrue(result.text.contains("not_sent from action 2"), result.text)
            XCTAssertTrue(result.text.contains(label), result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "the stale point must not be sent")
            let retry = await core.call("do", ["actions": [["tap": [100, 120]]]])
            XCTAssertEqual(core.pendingApproval != nil, asks, "\(label): \(retry.text)")
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, asks ? 1 : 2, label)
        }
    }

    /// Return sends in a messaging app: typed text is not sent by a return key, or a newline in the
    /// text, before the owner approves.
    func testInAMessagingAppReturnAfterTypingAsks() async {
        let composer = [("TextView", "Message")], list = [("SearchField", "Search"), ("Cell", "Mom")]
        // A tap on a conversation opens it: the search field's number belongs to the list read before,
        // and the text goes to the composer.
        for (rows, actions): ([(String, String)], [JSON]) in [(composer, [["tap": 1], ["type": "on my way"], ["key": "return"]]), (composer, [["tap": 1], ["type": "on my way\n"]]),
                                                             (list, [["tap": 2], ["type": "on my way", "ref": 1], ["key": "return"]]), (list, [["tap": 2], ["type": "on my way\n", "ref": 1]])] {
            let (core, wda, _) = makeCore(messages("com.tencent.xin", rows))
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": .array(actions)])
            XCTAssertTrue(result.text.contains("approval_required"), "\(actions): \(result.text)")
            XCTAssertTrue(core.pendingApproval?.reason.hasPrefix("sending a message") == true, core.pendingApproval?.reason ?? "no request")
            XCTAssertFalse(wda.bodies("POST /wda/keys").contains { $0.serialized().contains("\\n") }, "\(actions): a return went out")
        }
        // Return in the app's search field searches: nothing is sent to anyone, whether the field was
        // tapped first or typed into by its number.
        for actions: [JSON] in [[["tap": 1], ["type": "Mom"], ["key": "return"]], [["type": "Mom", "ref": 1], ["key": "return"]]] {
            let (core, wda, _) = makeCore(messages("com.tencent.xin", [("SearchField", "Search")]))
            _ = await core.call("look", [:])
            let searched = await core.call("do", ["actions": .array(actions)])
            XCTAssertFalse(searched.text.contains("approval"), "\(actions): \(searched.text)")
            XCTAssertTrue(wda.bodies("POST /wda/keys").contains { $0.serialized().contains("\\n") }, "\(actions): the return was not sent")
        }
    }

    /// A routine's typing step recorded on an element (type with ref) is held by the same return rule:
    /// in a messaging app a newline in its text sends the message, so the run stops before it; typed
    /// into the search field it runs.
    func testARoutinesTypedReturnInAMessagingAppIsNotSentWithoutTheOwner() async {
        for (field, sends) in [(("TextView", "Message"), false), (("SearchField", "Search"), true)] {
            let element = Element(type: field.0, label: field.1, value: nil, identifier: nil, frame: Rect(x: 16, y: 100, width: 358, height: 44), depth: 1)
            let store = RoutineStore(url: nil)
            store.save(Routine(name: "say", description: "", app: "com.tencent.xin", steps: [RoutineStep(action: ["type": "{{text_1}}", "ref": "@"], target: RoutineTarget(element), app: "com.tencent.xin", secret: nil)],
                               params: ["text_1": "hi"], expect: [], read: [], runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, savedBy: "test", created: Date(), updated: Date()))
            let wda = messages("com.tencent.xin", [field])
            // The fake focuses no field, so the type waits out its 2 s for one: the step gets the time for that.
            let (core, _, _) = makeCore(wda) { $0.memory = store; $0.actionCap = 6; $0.toolDeadline = 12 }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["run": ["name": "say", "with": ["text_1": "on my way\n"]]]]])
            XCTAssertEqual(wda.bodies("POST /wda/keys").contains { $0.serialized().contains("\\n") }, sends, "\(field.1): \(result.text)")
            if !sends { XCTAssertTrue(result.text.contains("sending a message"), result.text) }
        }
    }

    /// After a launch the screen is the launched app's and not read yet: a tap there is not judged by
    /// the last read's labels (a point on Photos' Delete read as nothing), so it asks in any app.
    func testATapAfterALaunchAsksInAnAppOnNoList() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": "com.apple.mobileslideshow"], ["wait": 300], ["tap": [200, 790]]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1, "the launch before it goes first")
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, "the tap was sent")
    }

    func testPasswordsNeedApproval() async {
        let wda = FakeWDA()
        wda.source([("TextField", "Email"), ("SecureTextField", "Password")])
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        let typed = await core.call("do", ["actions": [["type": "hunter2", "ref": 2]]])
        XCTAssertTrue(typed.text.contains("password field"), typed.text)
        XCTAssertFalse(core.pendingApproval!.summary.contains("hunter2"), "the summary hides the text")
        let email = await core.call("do", ["actions": [["type": "a@b.c", "ref": 1]]])
        XCTAssertFalse(email.isError, email.text)
    }
}

final class MCPTests: XCTestCase {
    func post(_ core: PokiCore, _ body: JSON, session: String? = nil) async -> RelayResponse {
        await core.handle(RelayRequest(id: "r", method: "POST", headers: session.map { ["mcp-session-id": $0] } ?? [:], body: body.serialized()))
    }

    func testInitializeListAndCall() async throws {
        let (core, _, _) = makeCore()
        let initialized = await post(core, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertEqual(initialized.status, 200)
        let session = try XCTUnwrap(initialized.headers["mcp-session-id"])
        XCTAssertEqual(try JSON.parse(initialized.body)["result"]?["protocolVersion"], "2025-06-18")
        let note = await post(core, ["jsonrpc": "2.0", "method": "notifications/initialized"], session: session)
        XCTAssertEqual(note.status, 202)
        let list = try JSON.parse(await post(core, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: session).body)
        XCTAssertEqual(list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }, ["look", "do", "routines", "status"])
        let call = try JSON.parse(await post(core, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "look", "arguments": .object([:])]], session: session).body)
        XCTAssertEqual(call["result"]?["content"]?[1]?["type"], "image")
        XCTAssertEqual(call["result"]?["isError"], false)
    }

    /// The app opens its session when an agent connects, so the first look does not pay for it.
    func testInitializeWarmsTheHostUp() async {
        let (core, _, host) = makeCore()
        _ = await post(core, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertEqual(host.warmUps.value, 1)
    }

    /// The app hears about each client's session (its name from clientInfo) and adds its own tools to
    /// the catalog; an app tool runs with the caller's session and the gate left free for its own calls.
    func testSessionsAreReportedAndHostToolsListedAndCalled() async throws {
        let (core, _, _) = makeCore()
        let signals = LockedBox<[SessionSignal]>([])
        core.onSession { signal in signals.update { $0.append(signal) } }
        let seen = LockedBox<String?>(nil)
        core.setHostTools([HostTool(name: "ask_poki", description: "Hand a task to Poki.", schemaJSON: #"{"type":"object","properties":{"task":{"type":"string"}},"required":["task"]}"#) { [core] arguments, session, _ in
            seen.value = session
            let inner = await core.callTool("look", arguments: "{}")
            return PokiCore.ToolAnswer(text: "done: \(arguments) · inner \(inner.isError ? "failed" : "ok")", jpeg: nil, isError: false)
        }])
        let initialized = await post(core, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-ai", "version": "1.2"]]])
        let session = try XCTUnwrap(initialized.headers["mcp-session-id"])
        XCTAssertEqual(signals.value, [.started(id: session, client: "claude-ai", version: "1.2")])
        let list = try JSON.parse(await post(core, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: session).body)
        XCTAssertEqual(list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }, ["look", "do", "routines", "status", "ask_poki"])
        XCTAssertEqual(list["result"]?["tools"]?[4]?["inputSchema"]?["required"]?[0], "task")
        let call = try JSON.parse(await post(core, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "ask_poki", "arguments": ["task": "read the time"]]], session: session).body)
        let text = call["result"]?["content"]?[0]?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("read the time") && text.contains("inner ok"), text)
        XCTAssertEqual(seen.value, session)
        _ = await core.handle(RelayRequest(id: "d", method: "DELETE", headers: ["mcp-session-id": session], body: ""))
        XCTAssertEqual(signals.value.last, .ended(id: session))
        XCTAssertNil(core.clientNames.value[session])
        // An app tool cannot take a built-in's name.
        core.setHostTools([HostTool(name: "look", description: "", schemaJSON: "{}") { _, _, _ in PokiCore.ToolAnswer(text: "shadow", jpeg: nil, isError: false) }])
        let look = await core.callTool("look", arguments: "{}")
        XCTAssertNotEqual(look.text, "shadow")
        core.setHostTools([])
        let after = try JSON.parse(await post(core, ["jsonrpc": "2.0", "id": 4, "method": "tools/list"]).body)
        XCTAssertEqual(after["result"]?["tools"]?.array?.count, 4)
    }

    /// Each tool event carries the session that made the call, so the app can show it in that session.
    func testToolEventsCarryTheCallersSession() async throws {
        let (core, _, _) = makeCore()
        let started = LockedBox<[String?]>([])
        let listen = Task { for await event in core.events { if case .toolStarted(let a) = event { started.update { $0.append(a.session) } } } }
        defer { listen.cancel() }
        _ = await core.call("look", [:], session: "s1")
        _ = await core.callTool("look", arguments: "{}")
        for _ in 0..<50 where started.value.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(started.value, ["s1", nil])
    }

    func testGetIsNotAllowed() async {
        let (core, _, _) = makeCore()
        let r = await core.handle(RelayRequest(id: "r", method: "GET", headers: [:], body: ""))
        XCTAssertEqual(r.status, 405)
    }
}

final class RelayTests: XCTestCase {
    func testHandshakeRequestsAndKeepalive() async throws {
        let (core, _, _) = makeCore()
        let sockets = FakeSockets()
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        core.start(relay: testRelay, socketFactory: sockets)
        core.relay?.pingEvery = 0.1
        do { let ok = await eventually { !sockets.sockets.value.isEmpty }; XCTAssertTrue(ok) }
        let socket = sockets.sockets.value[0]
        let label = base32(FakeKey().publicKey)
        XCTAssertEqual(sockets.urls.value[0].absoluteString, "wss://relay.example.com/v1/\(label)/connect")

        let nonce = Data(repeating: 7, count: 32)
        socket.push((["t": "challenge", "nonce": .string(nonce.base64EncodedString())] as JSON).serialized())
        do { let ok = await eventually { !socket.sent.isEmpty }; XCTAssertTrue(ok) }
        let hello = try JSON.parse(socket.sent[0])
        XCTAssertEqual(hello["t"], "hello")
        XCTAssertEqual(hello["access"], ["abc123"])
        var signed = Data("poki-relay-v1:\(label):".utf8)
        signed.append(nonce)
        XCTAssertEqual(hello["sig"]?.string, try FakeKey().sign(signed).base64EncodedString())

        socket.push((["t": "ready", "max_body": 4_194_304] as JSON).serialized())
        do { let ok = await eventually { events.value.contains(.relay(.ready(url: "wss://relay.example.com/v1/\(label)"))) }; XCTAssertTrue(ok) }
        do { let ok = await eventually { socket.sent.contains("ping") }; XCTAssertTrue(ok) }

        let body = (["jsonrpc": "2.0", "id": 1, "method": "tools/list"] as JSON).serialized()
        socket.push((["t": "req", "id": "q1", "method": "POST", "headers": ["Content-Type": "application/json"], "body": .string(body)] as JSON).serialized())
        do { let ok = await eventually { socket.sent.contains { $0.contains("\"t\":\"res\"") } }; XCTAssertTrue(ok) }
        let res = try JSON.parse(socket.sent.first { $0.contains("\"t\":\"res\"") }!)
        XCTAssertEqual(res["id"], "q1")
        XCTAssertEqual(res["status"], 200)
        XCTAssertNotNil(try JSON.parse(res["body"]!.string!)["result"]?["tools"])
        core.stop()
    }

    func testTheRelayAddressThePersonEntersDecidesWhereThePhoneDials() {
        let entered: [(String, String?, String?)] = [
            ("poki-relay.you.workers.dev", "wss://poki-relay.you.workers.dev/v1", "https://poki-relay.you.workers.dev/v1"),
            (" https://Relay.Example.com/v1/ ", "wss://relay.example.com/v1", "https://relay.example.com/v1"),
            ("http://127.0.0.1:8787", "ws://127.0.0.1:8787/v1", "http://127.0.0.1:8787/v1"),
            ("https://relay.example.com/other", nil, nil),
            ("ftp://relay.example.com", nil, nil),
            ("", nil, nil),
        ]
        for (text, phone, connector) in entered {
            let address = RelayAddress(text)
            XCTAssertEqual(address?.phoneURL.absoluteString, phone, text)
            XCTAssertEqual(address?.connectorBase.absoluteString, connector, text)
        }
    }

    /// A three-action do answered "what was sent is unknown" when the relay reset mid-call: the
    /// call now runs to its end and its answer comes with the next call.
    func testAnAnswerReadyAfterTheConnectionDroppedComesWithTheNextCall() async throws {
        let (core, wda, _) = makeCore()
        wda.delay("GET /source", 0.7)
        let sockets = FakeSockets()
        core.start(relay: testRelay, socketFactory: sockets)
        core.relay?.maxBackoff = 0.05
        func ready(_ socket: FakeSocket) async {
            socket.push((["t": "challenge", "nonce": .string(Data(repeating: 7, count: 32).base64EncodedString())] as JSON).serialized())
            _ = await eventually { !socket.sent.isEmpty }
            socket.push((["t": "ready", "max_body": 4_194_304] as JSON).serialized())
        }
        func call(_ socket: FakeSocket, _ id: String) {
            let body = (["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "look", "arguments": [:]]] as JSON).serialized()
            socket.push((["t": "req", "id": .string(id), "method": "POST", "headers": ["Content-Type": "application/json"], "body": .string(body)] as JSON).serialized())
        }
        do { let ok = await eventually { !sockets.sockets.value.isEmpty }; XCTAssertTrue(ok) }
        let first = sockets.sockets.value[0]
        await ready(first)
        call(first, "q1")
        try await Task.sleep(nanoseconds: 200_000_000)
        first.close(code: 1006, reason: "reset")
        do { let ok = await eventually(5) { sockets.sockets.value.count >= 2 }; XCTAssertTrue(ok) }
        let second = sockets.sockets.value[1]
        await ready(second)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(first.sent.contains { $0.contains("\"t\":\"res\"") }, "nothing goes to the dropped connection")
        call(second, "q2")
        do { let ok = await eventually(5) { second.sent.contains { $0.contains("\"t\":\"res\"") } }; XCTAssertTrue(ok) }
        let res = try JSON.parse(second.sent.first { $0.contains("\"t\":\"res\"") }!)
        XCTAssertEqual(res["id"], "q2")
        let text = try JSON.parse(res["body"]!.string!)["result"]?["content"]?[0]?["text"]?.string ?? ""
        XCTAssertTrue(text.hasPrefix("earlier, never delivered to you: the look call whose connection dropped (finished at "), text)
        XCTAssertTrue(text.contains("\n\nnow:\napp: Settings"), text)
        core.stop()
    }

    func testTheRelayIsDialedAgainAfterADrop() async {
        let (core, _, _) = makeCore()
        let sockets = FakeSockets()
        core.start(relay: testRelay, socketFactory: sockets)
        core.relay?.maxBackoff = 0.05
        do { let ok = await eventually { !sockets.sockets.value.isEmpty }; XCTAssertTrue(ok) }
        sockets.sockets.value[0].close(code: 1006, reason: "gone")
        do { let ok = await eventually(5) { sockets.sockets.value.count >= 2 }; XCTAssertTrue(ok) }
        core.stop()
    }
}

final class EventTests: XCTestCase {
    func testAFinishedCallCarriesTheAppAndAThumbnail() async {
        let (core, _, _) = makeCore()
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        _ = await core.call("look", [:])
        let finished = await eventually { events.value.contains { if case .toolFinished = $0 { return true }; return false } }
        XCTAssertTrue(finished)
        guard case .toolFinished(_, .done, let facts)? = events.value.last else { return XCTFail("\(events.value)") }
        XCTAssertEqual(facts.app, "Settings")
        XCTAssertNotNil(facts.thumbnail)
    }

    /// The app logs each call's summary. What was typed stays out of the log, after the first step too.
    func testTheSummariesTheAppLogsKeepNoTypedText() async {
        let wda = FakeWDA()
        wda.source([("SearchField", "Search")])
        let (core, _, _) = makeCore(wda)
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        _ = await core.call("do", ["actions": [["type": "door code 4412"]]])
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": 1], ["type": "meet at 5, door code 4412"]]])
        _ = await core.call("do", ["actions": [["type": "他说“好的”就在4412"]]])
        let summaries = { events.value.compactMap { e -> String? in if case .toolStarted(let a) = e, a.name == "do" { return a.summary }; return nil } }
        let started = await eventually { summaries().count == 3 }
        XCTAssertTrue(started)
        XCTAssertEqual(summaries().map(StepLabels.withoutTypedText), ["Type “…”", "Tap “Search”, then type “…”", "Type “…”"])
    }
}

final class DDITests: XCTestCase {
    final class Mirror: HTTPTransport, @unchecked Sendable {
        var files: [String: Data] = [:]
        func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
            files[url.lastPathComponent].map { (200, $0) } ?? (404, Data())
        }
    }

    func testDownloadsIntoPlaceAndKeepsAVerifiedCopy() async throws {
        let mirror = Mirror()
        var manifestEntries: [String: Any] = [:]
        for (key, path) in zip(DeveloperDiskImage.payloadKeys, ["Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"]) {
            #if canImport(CryptoKit)
            let digest = Data(SHA384.hash(data: Data(path.utf8)))
            #else
            let digest = Data([1])
            #endif
            manifestEntries[key] = ["Info": ["Path": path], "Digest": digest]
            mirror.files[path] = Data(path.utf8)
        }
        let manifest: [String: Any] = ["ProductBuildVersion": "22A1", "BuildIdentities": [["Manifest": manifestEntries]]]
        mirror.files["BuildManifest.plist"] = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ddi-\(UUID().uuidString)")
        let build = try await DeveloperDiskImage.ensure(in: dir, from: URL(string: "https://mirror.invalid/x")!, transport: mirror)
        XCTAssertEqual(build, "22A1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Image.dmg").path))
        mirror.files = [:]  // a verified copy is not downloaded again
        let again = try await DeveloperDiskImage.ensure(in: dir, from: URL(string: "https://mirror.invalid/x")!, transport: mirror)
        XCTAssertEqual(again, "22A1")
        try? FileManager.default.removeItem(at: dir)
    }
}

/// ESP-176: the owner asks in one app (Grok Bot, or Poki's own chat), Poki works in others, and when
/// the task ends the phone is back where the owner asked, showing the reply.
final class ReturnToOriginTests: XCTestCase {
    /// The app in front as WDA reports it, moved by launch, activate and Home like on the phone.
    func phone(_ wda: FakeWDA, front: String) -> LockedBox<String> {
        let box = LockedBox(front)
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(box.value), "name": .string(box.value)]]) }
        for key in ["POST /wda/apps/activate", "POST /wda/apps/launch"] {
            wda.set(key) { body in box.value = body?["bundleId"]?.string ?? box.value; return (200, ["value": .null]) }
        }
        wda.set("POST /wda/homescreen") { _ in box.value = "com.apple.springboard"; return (200, ["value": .null]) }
        return box
    }

    func testFinishGoesBackToTheAppTheTaskBeganIn() async {
        for (origin, startsWithLook) in [("ai.x.grok", true), ("ai.x.grok", false), ("nz.zheha.poki", true), ("com.apple.springboard", true)] {
            let (core, wda, _) = makeCore()
            let front = phone(wda, front: origin)
            if startsWithLook { _ = await core.call("look", [:]) }
            _ = await core.call("do", ["actions": [["launch": "com.apple.weather"]]])
            _ = await core.call("look", [:])
            XCTAssertEqual(front.value, "com.apple.weather", "between calls the phone stays where the work is (\(origin))")
            let done = await core.call("do", ["actions": [], "finish": true])
            XCTAssertFalse(done.isError, done.text)
            XCTAssertTrue(done.text.hasPrefix("app: com.apple.weather"), "the answer still shows the work's last screen: \(done.text)")
            XCTAssertEqual(front.value, origin, "\(origin), look first: \(startsWithLook): \(done.text)")
        }
    }

    /// One do that launches an app and finishes the task: the launched app is slow to come to the
    /// front, so the read is made again until it is (cdebb5d), and only then does the phone go back
    /// to the app the task began in (ESP-176). The answer shows the work's screen, not the origin's.
    func testALaunchThatFinishesReadsTheLaunchedAppBeforeGoingBack() async {
        let (core, wda, _) = makeCore()
        let front = LockedBox("ai.x.grok"), pending = LockedBox<String?>(nil), lagging = LockedBox(0)
        wda.set("GET /wda/activeAppInfo") { _ in
            if let target = pending.value {
                if lagging.update({ $0 += 1; return $0 }) > 2 { front.value = target; pending.value = nil }
            }
            return (200, ["value": ["bundleId": .string(front.value), "name": .string(front.value)]])
        }
        for key in ["POST /wda/apps/activate", "POST /wda/apps/launch"] {
            wda.set(key) { body in
                let bundle = body?["bundleId"]?.string ?? front.value
                if bundle == "ai.x.grok" { front.value = bundle } else { pending.value = bundle; lagging.value = 0 }
                return (200, ["value": .null])
            }
        }
        _ = await core.call("look", [:])
        let done = await core.call("do", ["actions": [["launch": "com.apple.weather"]], "finish": true])
        XCTAssertFalse(done.isError, done.text)
        XCTAssertTrue(done.text.hasPrefix("app: com.apple.weather"), "the answer shows the launched app's screen: \(done.text)")
        XCTAssertTrue(done.text.contains("was not in front yet"), done.text)
        XCTAssertTrue(done.text.contains("finish: back in"), done.text)
        XCTAssertEqual(front.value, "ai.x.grok", "the phone ends where the task began")
    }

    func testFinishWhereTheTaskBeganSendsNothing() async {
        let (core, wda, _) = makeCore()
        _ = phone(wda, front: "ai.x.grok")
        _ = await core.call("look", [:])
        let done = await core.call("do", ["actions": [], "finish": true])
        XCTAssertFalse(done.isError, done.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 0)
        XCTAssertEqual(wda.sent.filter { $0 == "POST /wda/homescreen" }.count, 0)
    }

    /// Seen on the simulator: activate answers while the switch animates, and a look right after
    /// still finds the App Switcher. "back in" is said only once the app is in front.
    func testFinishSaysSoWhenTheAppDoesNotComeToTheFront() async {
        let (core, wda, _) = makeCore()
        let front = phone(wda, front: "ai.x.grok")
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["launch": "com.apple.weather"]]])
        wda.set("POST /wda/apps/activate") { _ in (200, ["value": .null]) }
        let done = await core.call("do", ["actions": [], "finish": true])
        XCTAssertEqual(front.value, "com.apple.weather")
        XCTAssertFalse(done.text.contains("finish: back in"), done.text)
        XCTAssertTrue(done.text.contains("is not in front"), done.text)
    }

    func testTheClientEndingItsSessionEndsTheTask() async throws {
        let (core, wda, _) = makeCore()
        let front = phone(wda, front: "ai.x.grok")
        func post(_ body: JSON, _ session: String?) async -> RelayResponse {
            await core.handle(RelayRequest(id: "r", method: "POST", headers: session.map { ["mcp-session-id": $0] } ?? [:], body: body.serialized()))
        }
        func delete(_ session: String) async { _ = await core.handle(RelayRequest(id: "d", method: "DELETE", headers: ["mcp-session-id": session], body: "")) }
        let initialized = await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], nil)
        let session = try XCTUnwrap(initialized.headers["mcp-session-id"])
        _ = await post(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "look", "arguments": .object([:])]], session)
        _ = await post(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "do", "arguments": ["actions": [["launch": "com.apple.weather"]]]]], session)
        await delete("another-client")
        XCTAssertEqual(front.value, "com.apple.weather", "another client's session is not this task")
        await delete(session)
        XCTAssertEqual(front.value, "ai.x.grok")
    }

    /// The app calls this before it stops an idle runner.
    func testFinishingFromTheAppGoesBackOnce() async {
        let (core, wda, _) = makeCore()
        let front = phone(wda, front: "ai.x.grok")
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["launch": "com.apple.weather"]]])
        _ = await core.finishTask()
        XCTAssertEqual(front.value, "ai.x.grok")
        front.value = "com.apple.weather"
        _ = await core.finishTask()
        XCTAssertEqual(front.value, "com.apple.weather", "the task is over: a second finish moves nothing")
    }

    func testFinishingFromTheAppDuringOwnerTakeoverKeepsTheCurrentApp() async {
        let (core, wda, _) = makeCore()
        let front = phone(wda, front: "ai.x.grok")
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["launch": "com.apple.weather"]]])
        let takeover = Handoff(id: "takeover", kind: "other", text: "Editing", requested: Date(), ownerOnly: true)
        core.computer.handoff.value = takeover
        let before = wda.sent.count
        let finish = await core.finishTask()
        XCTAssertEqual(front.value, "com.apple.weather")
        XCTAssertEqual(wda.sent.count, before, "Task cleanup must send no commands during owner takeover")
        XCTAssertEqual(core.handoff?.id, takeover.id)
        XCTAssertTrue(finish?.contains("stays in front") == true)
    }

    /// The owner stopped the runner: a client's DELETE afterwards must not send requests to the
    /// stopped runner, whose misses would start it again.
    func testATaskDroppedWithoutSwitchingSendsNothingLater() async throws {
        let (core, wda, _) = makeCore()
        let front = phone(wda, front: "ai.x.grok")
        let initialized = await core.handle(RelayRequest(id: "i", method: "POST", headers: [:], body: (["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]] as JSON).serialized()))
        let session = try XCTUnwrap(initialized.headers["mcp-session-id"])
        _ = await core.call("do", ["actions": [["launch": "com.apple.weather"]]], session: session)
        _ = await core.finishTask(switching: false)
        let before = wda.sent.count
        _ = await core.handle(RelayRequest(id: "d", method: "DELETE", headers: ["mcp-session-id": session], body: ""))
        XCTAssertEqual(wda.sent.count, before, "\(wda.sent.suffix(3))")
        XCTAssertEqual(front.value, "com.apple.weather")
    }

    /// A task never finished (no finish, idle stop off) does not send a later task's phone back to it.
    func testACallAfterTheTaskGapStartsANewTask() async {
        let (core, wda, _) = makeCore { $0.taskGap = 0 }
        let front = phone(wda, front: "ai.x.grok")
        _ = await core.call("look", [:])
        front.value = "com.apple.weather"
        _ = await core.call("do", ["actions": [], "finish": true])
        XCTAssertEqual(front.value, "com.apple.weather")
    }
}

/// ESP-221: WeChat came to the front, but its element tree could not be read (on the phone, in-process:
/// "Error getting main window kAXError"). The runner still says which app is in front, so that app is
/// the one in front: the launch answer names it, and a tap in it is sent. Before, the failed read kept
/// Poki as the app in front, the launch was read again six times as "not in front yet", and every tap
/// was refused as a tap inside Poki, so the voice model kept saying WeChat was still opening.
final class UnreadableTreeTests: XCTestCase {
    func testAnAppWhoseTreeCannotBeReadIsStillTheAppInFront() async {
        let (core, wda, _) = makeCore()
        let front = LockedBox("nz.zheha.poki")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(front.value), "name": ""]]) }
        for key in ["POST /wda/apps/activate", "POST /wda/apps/launch"] {
            wda.set(key) { body in front.value = body?["bundleId"]?.string ?? front.value; return (200, ["value": .null]) }
        }
        let poki: JSON = ["type": "XCUIElementTypeApplication", "label": "Poki", "rect": ["x": 0, "y": 0, "width": 390, "height": 844],
                          "children": [["type": "XCUIElementTypeButton", "label": "Talk", "rect": ["x": 16, "y": 700, "width": 358, "height": 44]]]]
        wda.set("GET /source") { _ in
            front.value == "com.tencent.xin"
                ? (500, ["value": ["error": "unknown error", "message": "no element tree: Error getting main window kAXError"]])
                : (200, ["value": poki])
        }
        _ = await core.call("look", [:])

        let opened = await core.call("do", ["actions": [["launch": "com.tencent.xin"]]])
        XCTAssertTrue(opened.text.hasPrefix("app: com.tencent.xin"), opened.text)
        XCTAssertFalse(opened.text.contains("was not in front yet"), opened.text)
        XCTAssertNotNil(opened.jpeg, "the picture is the screen to go by")

        let tapped = await core.call("do", ["actions": [["tap": [200, 300]]]])
        XCTAssertFalse(tapped.text.contains(CoreConfig.ownAppRefusal), tapped.text)
        XCTAssertEqual(wda.sent.filter { $0.hasSuffix("/wda/tap") }.count, 1, tapped.text)
    }
}

/// ESP-229: on the phone, WeChat's tree failed with "Error getting main window kAXErrorServerNotFound"
/// for half an hour (no accessibility server in its process), while Settings and Poki read fine; the
/// same WeChat process read fine later. A call that opened the app and then finds no accessibility
/// server in it opens the app once more from a fresh start and reads again; a look, which opened
/// nothing, never ends an app.
final class AccessibilityServerMissingTests: XCTestCase {
    func testAnAppOpenedWithoutAnAccessibilityServerIsOpenedAgainFreshAndRead() async {
        let (core, wda, _) = makeCore()
        let front = LockedBox("nz.zheha.poki")
        let restarted = LockedBox(false)
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(front.value), "name": ""]]) }
        for key in ["POST /wda/apps/activate", "POST /wda/apps/launch"] {
            wda.set(key) { body in front.value = body?["bundleId"]?.string ?? front.value; return (200, ["value": .null]) }
        }
        wda.set("POST /wda/apps/terminate") { _ in restarted.value = true; front.value = "com.apple.springboard"; return (200, ["value": .null]) }
        let rect: JSON = ["x": 0, "y": 0, "width": 390, "height": 844]
        let poki: JSON = ["type": "XCUIElementTypeApplication", "label": "Poki", "rect": rect,
                          "children": [["type": "XCUIElementTypeButton", "label": "Talk", "rect": ["x": 16, "y": 700, "width": 358, "height": 44]]]]
        let wechat: JSON = ["type": "XCUIElementTypeApplication", "label": "WeChat", "rect": rect,
                            "children": [["type": "XCUIElementTypeButton", "label": "Chats", "rect": ["x": 16, "y": 790, "width": 80, "height": 44]]]]
        wda.set("GET /source") { _ in
            guard front.value == "com.tencent.xin" else { return (200, ["value": poki]) }
            return restarted.value ? (200, ["value": wechat])
                : (500, ["value": ["error": "unknown error", "message": "no element tree: Error getting main window kAXErrorServerNotFound"]])
        }
        _ = await core.call("look", [:])

        let opened = await core.call("do", ["actions": [["launch": "com.tencent.xin"]]])
        XCTAssertTrue(opened.text.contains("\"Chats\""), opened.text)
        XCTAssertTrue(opened.text.contains("opened again from a fresh start"), opened.text)
        XCTAssertEqual(wda.sent.filter { $0.hasSuffix("/wda/apps/terminate") }.count, 1, opened.text)

        restarted.value = false
        let looked = await core.call("look", [:])
        XCTAssertTrue(looked.text.contains("kAXErrorServerNotFound"), looked.text)
        XCTAssertEqual(wda.sent.filter { $0.hasSuffix("/wda/apps/terminate") }.count, 1, "a look ends no app: \(looked.text)")
    }
}
