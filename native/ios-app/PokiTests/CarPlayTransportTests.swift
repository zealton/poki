// SPDX-License-Identifier: AGPL-3.0-only
import UIKit
import PokiCore
import XCTest
@testable import Poki

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class CarPlayTransportTests: XCTestCase {
    private var folder: URL!
    private var previous: String?
    private var worker: Task<Void, Never>?
    private var state: [String: Any] = [:]
    private var commands: [[String: Any]] = []
    private let bundle = "test.poki.transport"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previous = ProcessInfo.processInfo.environment["POKI_CARPLAY_CONFIG"]
        let config: [String: Any] = ["coordinator": folder.path, "targets": [bundle: folder.path],
                                   "apps": [["name": "Synthetic App", "bundle": bundle]]]
        try write(config, "config.json")
        setenv("POKI_CARPLAY_CONFIG", folder.appendingPathComponent("config.json").path, 1)
        state = ["bundle": bundle, "window": "UIWindow", "windowBounds": "{{0, 0}, {100, 100}}",
                 "screenBounds": "{{0, 0}, {100, 100}}", "sceneState": 0, "scene": "test-scene", "pid": 42,
                 "silentFocus": true, "keyboardFocusHook": true, "primarySceneActive": false, "instance": "boot-1",
                 "views": [["class": "UIButton", "identifier": "button", "frame": "{{20, 30}, {40, 20}}", "control": true, "enabled": true, "label": "Test button"]]]
        worker = Task { @MainActor [weak self] in
            var last = ""
            while !Task.isCancelled, let self {
                self.state["at"] = Date().timeIntervalSince1970
                try? self.write(self.state, "state.json")
                if let data = try? Data(contentsOf: self.folder.appendingPathComponent("command.json")),
                   let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let id = command["id"] as? String, id != last {
                    last = id; self.commands.append(command)
                    let capture = command["op"] as? String == "capture"
                    if capture {
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { _ in UIColor.blue.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 100)) }
                        try? image.pngData()?.write(to: self.folder.appendingPathComponent("frame.png"))
                    }
                    try? self.write(["id": id, "ok": true, "event": capture ? "frame.captured" : "nativeTouch.ended"], "result.json")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    override func tearDown() async throws {
        worker?.cancel(); worker = nil
        if let previous { setenv("POKI_CARPLAY_CONFIG", previous, 1) } else { unsetenv("POKI_CARPLAY_CONFIG") }
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ value: [String: Any], _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    private func token(_ answer: PokiCore.ToolAnswer) throws -> String {
        let value = try JSONSerialization.jsonObject(with: Data(answer.text.utf8)) as? [String: Any]
        return try XCTUnwrap(value?["observation"] as? String, answer.text)
    }

    func testDiscoveryDoesNotExposeHostPaths() {
        let answer = CarPlayWorkspace().listApps()
        XCTAssertTrue(answer.text.contains("Synthetic App"))
        XCTAssertFalse(answer.text.contains(folder.path))
    }

    func testControlRefsRejectUnknownAndMovedViews() async throws {
        let workspace = CarPlayWorkspace(); workspace.begin()
        let observation = try token(await workspace.open(bundle))
        let before = commands.count
        let bad = await workspace.perform(["action": "tap", "target": "c999", "observation": observation])
        XCTAssertTrue(bad.isError); XCTAssertEqual(commands.count, before)
        let action = await workspace.perform(["action": "tap", "target": "c0", "observation": observation])
        XCTAssertFalse(action.isError, action.text)
        let tap = try XCTUnwrap(commands.first { $0["op"] as? String == "tap" })
        XCTAssertEqual(tap["x"] as? Double, 40); XCTAssertEqual(tap["y"] as? Double, 40)
        XCTAssertEqual(tap["instance"] as? String, "boot-1")
        XCTAssertGreaterThan(tap["expiresAt"] as? Double ?? 0, Date().timeIntervalSince1970)
        let next = try token(action)
        var rows = try XCTUnwrap(state["views"] as? [[String: Any]])
        rows[0]["label"] = "Different action at the same position"; state["views"] = rows
        try write(state, "state.json")
        let count = commands.count
        let moved = await workspace.perform(["action": "tap", "target": "c0", "observation": next])
        XCTAssertTrue(moved.isError); XCTAssertEqual(commands.count, count)
    }

    func testRestartAndCancellationRevokeObservation() async throws {
        let workspace = CarPlayWorkspace(); workspace.begin()
        let observation = try token(await workspace.open(bundle))
        state["pid"] = 43; state["instance"] = "boot-2"; try write(state, "state.json")
        let count = commands.count
        let restarted = await workspace.perform(["action": "tap", "target": "c0", "observation": observation])
        XCTAssertTrue(restarted.isError); XCTAssertEqual(commands.count, count)
        workspace.stop()
        let stopped = await workspace.perform(["action": "tap", "target": "c0", "observation": observation])
        XCTAssertTrue(stopped.isError); XCTAssertEqual(commands.count, count)
    }
}
#endif
