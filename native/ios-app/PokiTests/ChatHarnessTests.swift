import Foundation
import Network
import PokiCore
import XCTest
@testable import Poki

/// The chat's agent as the model sees it: a task handed to Poki runs on a custom endpoint (an OpenAI
/// chat completions server on 127.0.0.1 that answers with scripted turns), so each request the model
/// gets and each answer Poki gives back are the real ones.
@MainActor
final class ChatHarnessTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private var app: AppModel?
    private var notes: [String] = []
    private static let settings = ["chat.provider", "chat.customURL", "chat.customModel"]

    override func setUp() async throws {
        for key in Self.settings { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        for key in Self.settings { UserDefaults.standard.set(saved[key] ?? nil, forKey: key) }
        for text in notes { _ = await app?.runTool("routines", arguments: Self.json(["action": "forget_note", "id": text])) }
        ChatModel.afterTask = nil
    }

    /// A conversation handed over by an outside agent, on the fake endpoint. The phone's tools answer
    /// without a session (the Debug probe's call), so routines reaches the app's own memory.
    private func chat(on server: FakeCompletions) -> ChatModel {
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        self.app = app
        return ChatModel(app: app, kind: .handoff, requester: "Test agent")
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// An isolated model cannot open an unprepared app by falling back to the
    /// whole-phone runner. Exercise the real ChatModel/backend dispatch.
    func testCarPlayRejectsUnpreparedAppsWithoutForegroundFallback() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(Self.json(["targets": [:]]).utf8).write(to: path)
        let prior = ProcessInfo.processInfo.environment["POKI_CARPLAY_CONFIG"]
        setenv("POKI_CARPLAY_CONFIG", path.path, 1)
        defer {
            if let prior { setenv("POKI_CARPLAY_CONFIG", prior, 1) } else { unsetenv("POKI_CARPLAY_CONFIG") }
            try? FileManager.default.removeItem(at: path)
        }
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("carplay_open", ["bundle": "com.apple.Preferences"]),
            FakeCompletions.tool("finish_task", ["success": false, "summary": "Unsupported global action blocked."]),
            FakeCompletions.text("Stopped without foreground control.")
        ])
        let chat = chat(on: server)
        chat.setCarPlay(true)
        let result = await chat.runDelegated("Open an unprepared app.")
        XCTAssertEqual(result.success, false, result.text)
        XCTAssertTrue(chat.calls.contains { $0.name == "carplay_open" && !$0.ok && $0.answer.contains("not in the prepared CarPlay allowlist") })
        let first = try XCTUnwrap(server.requests.first)
        let tools = first["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("carplay_open"))
        XCTAssertFalse(names.contains("do"))
        XCTAssertFalse(names.contains("container_do"))
    }
    #endif

    /// A note the agent saved during one task reaches the model with the next task of the same
    /// conversation.
    func testEachTaskTellsTheModelWhatMemoryHolds() async throws {
        let note = "The owner's gym is Fitness First on Queen Street \(UUID().uuidString.prefix(6))"
        notes.append(note)
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done.", "details": [], "answer": ["kind": "action"]])
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("routines", ["action": "remember", "text": note]), done, FakeCompletions.text("Noted."),
            done, FakeCompletions.text("Booked."),
        ])
        let chat = chat(on: server)

        _ = await chat.runDelegated("Remember that my gym is Fitness First on Queen Street")
        _ = await chat.runDelegated("Book a class at my gym")

        let requests = server.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertFalse(FakeCompletions.system(requests[0]).contains(note))
        XCTAssertTrue(FakeCompletions.system(requests[3]).contains(note), "the second task's prompt has the note the first saved")
    }

    /// finish_task's requested facts and the kind of answer go back to the agent that handed the task
    /// over, and the task's record keeps the answer with the element it was read from.
    func testTheFinishedTaskAnswersWithTheRequestedFacts() async throws {
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("finish_task", [
                "success": true, "summary": "Read the battery level in Settings.",
                "details": [["label": "Battery", "value": "81%"]],
                "answer": ["kind": "field", "items": [["ref": "7", "field": "value"]]],
            ]),
            FakeCompletions.text("Done."),
        ])
        let chat = chat(on: server)
        var records: [TaskRecord] = []
        ChatModel.afterTask = { records.append($0) }

        let reply = await chat.runDelegated("What is the battery level?")

        XCTAssertEqual(reply.success, true)
        XCTAssertTrue(reply.text.contains("answer (field): Battery: 81%"), reply.text)
        let result = try XCTUnwrap(records.last?.result)
        XCTAssertEqual(result.answer?.kind, .field)
        XCTAssertEqual(result.answer?.items?.map(\.ref), ["7"])
        XCTAssertEqual(result.details, [TaskResult.Detail(label: "Battery", value: "81%")])
    }

    /// The system prompt names no tool the model does not have (the app has no unlock_device or
    /// handle_alert).
    func testThePromptNamesOnlyToolsTheModelHas() throws {
        let tools = Set(Harness.tools.map(\.name))
        let regex = try NSRegularExpression(pattern: "\\b[a-z]+(?:_[a-z]+)+\\b")
        let text = Harness.system
        XCTAssertFalse(text.isEmpty, "agent-system.md is in the app")
        let named = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        XCTAssertEqual(named.subtracting(tools), [], "named in agent-system.md but not offered to the model")
    }
}

/// An OpenAI chat completions endpoint on 127.0.0.1: each request is kept and answered with the next
/// scripted turn as one server-sent event.
final class FakeCompletions: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-completions")
    private let lock = NSLock()
    private var replies: [String]
    private var bodies: [[String: Any]] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [[String: Any]] { lock.withLock { bodies } }

    init(replies: [String]) throws {
        self.replies = replies
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            let received = received + (data ?? Data())
            if let body = Self.body(received) { return self.answer(connection, body) }
            if done || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }

    /// The request's body once all of it is in.
    private static func body(_ data: Data) -> Data? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    private func answer(_ connection: NWConnection, _ body: Data) {
        let events = lock.withLock { () -> String in
            if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { bodies.append(json) }
            return replies.isEmpty ? Self.text("No more scripted turns.") : replies.removeFirst()
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(events.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + events).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func event(_ delta: [String: Any], finish: String) -> String {
        let chunk: [String: Any] = ["id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": "fake-model",
                                    "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
        return "data: \(json)\n\ndata: [DONE]\n\n"
    }

    static func tool(_ name: String, _ arguments: [String: Any]) -> String {
        let args = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return event(["role": "assistant", "tool_calls": [["index": 0, "id": "call_\(UUID().uuidString.prefix(8))", "type": "function",
                                                          "function": ["name": name, "arguments": args]]]], finish: "tool_calls")
    }

    static func text(_ words: String) -> String { event(["role": "assistant", "content": words], finish: "stop") }

    /// A request's system (or developer) messages, as text.
    static func system(_ request: [String: Any]) -> String {
        let messages = request["messages"] as? [[String: Any]] ?? []
        return messages.filter { ["system", "developer"].contains($0["role"] as? String ?? "") }.map { message in
            (message["content"] as? String) ?? ((message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "")
        }.joined(separator: "\n")
    }
}
