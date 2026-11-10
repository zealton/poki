import Foundation
import PokiCore
import UIKit

/// A multi-call composition owns the input lane through read-back and removal.
private final class NativeInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if occupied { waiting.append(continuation); lock.unlock() }
            else { occupied = true; lock.unlock(); continuation.resume() }
        }
    }
    func release() {
        lock.lock()
        if waiting.isEmpty { occupied = false; lock.unlock() }
        else { let next = waiting.removeFirst(); lock.unlock(); next.resume() }
    }
}

/// A persistent banner-free client through PokiLauncher's paired CoreDevice services. Requests are
/// serial at both layers, like WDA and the desktop bridge, and the expensive tunnel/media handshake
/// is paid once per active transport rather than once per action.
private final class NativeServicesBridge: @unchecked Sendable {
    final class Box: @unchecked Sendable {
        let continuation: CheckedContinuation<[String: Any], Error>
        init(_ continuation: CheckedContinuation<[String: Any], Error>) { self.continuation = continuation }
        func finish(_ value: [String: Any]) {
            if value["ok"] as? Bool == true, let answer = value["value"] as? [String: Any] { continuation.resume(returning: answer) }
            else { continuation.resume(throwing: NSError(domain: "PokiNativeServices", code: 1, userInfo: [NSLocalizedDescriptionKey: value["error"] as? String ?? "native services returned no result"])) }
        }
    }

    private let handle: OpaquePointer?

    init() {
        let config: [String: Any] = [
            "device_address": "10.7.0.1", "pairing_file": AppFiles.pairingFile.path,
            "host_name": "Poki",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { handle = nil; return }
        let text = String(decoding: data, as: UTF8.self)
        handle = text.withCString { poki_native_client_new($0) }
    }

    deinit { if let handle { poki_native_client_free(handle) } }

    func call(_ request: [String: Any]) async throws -> [String: Any] {
        guard let handle else { throw NSError(domain: "PokiNativeServices", code: 2, userInfo: [NSLocalizedDescriptionKey: "native services could not be created"]) }
        let data = try JSONSerialization.data(withJSONObject: request)
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            let box = Box(continuation)
            let retained = Unmanaged.passRetained(box)
            let queued = text.withCString { json in
                poki_native_client_call(handle, json, { context, result in
                    guard let context, let result else { return }
                    let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
                    let data = Data(String(cString: result).utf8)
                    let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    box.finish(value ?? ["ok": false, "error": "native services returned invalid JSON"])
                }, retained.toOpaque())
            }
            guard queued == 0 else {
                retained.release()
                continuation.resume(throwing: NSError(domain: "PokiNativeServices", code: 2, userInfo: [NSLocalizedDescriptionKey: "native services could not queue the request"]))
                return
            }
        }
    }
}

/// Experimental WDA-shaped transport backed by accessibility, DVT screenshots and CoreDevice HID.
/// It never opens an XCTest session, so iOS does not show the Automation Running banner.
final class NativeServicesWDA: HTTPTransport, @unchecked Sendable {
    private struct Tree: @unchecked Sendable { var value: [String: Any] }
    private let screen: CGSize
    private let inputGate = NativeInputGate()
    /// Reads/launches, screenshots, and HID each keep their own tunnel. PokiCore reads the tree and
    /// picture together; separate lanes preserve the production path's parallel read latency.
    private let native = NativeServicesBridge()
    private let pictures = NativeServicesBridge()
    private let input = NativeServicesBridge()
    private let queue = DispatchQueue(label: "poki.native-services.wda")
    private var focused: [String: Any]?
    private var cachedTree: (at: Date, tree: Tree)?
    private var treeTask: Task<Tree, Error>?
    private var inputWarming = false

    init(screen: CGSize) { self.screen = screen }

    var verifiesNativeTyping: Bool { true }

    /// Drops all paired tunnels without destroying the transport. The next call reconnects them,
    /// which gives PokiCore's existing restart policy the same clean boundary as the runner path.
    func reset() async {
        await inputGate.acquire()
        defer { inputGate.release() }
        async let state: [String: Any]? = try? native.call(["op": "reset"])
        async let picture: [String: Any]? = try? pictures.call(["op": "reset"])
        async let controls: [String: Any]? = try? input.call(["op": "reset"])
        _ = await (state, picture, controls)
        queue.sync {
            focused = nil
            cachedTree = nil
            treeTask = nil
            inputWarming = false
        }
    }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.first == "session", parts.count >= 2 { parts.removeFirst(2) }
        var element: String?
        if parts.first == "element", parts.count >= 3 { element = parts[1]; parts.remove(at: 1) }
        let path = parts.isEmpty ? "/session" : "/" + parts.joined(separator: "/")
        let key = "\(method) \(path)"
        let ownsInput = method == "POST" && !["/session", "/appium/settings"].contains(path)
        if ownsInput { await inputGate.acquire() }
        defer { if ownsInput { inputGate.release() } }
        try Task.checkCancellation()
        let input = body.flatMap { try? JSON.parse($0) }
        let sourceIsXML = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "format" })?.value?.lowercased() == "xml"
        let started = Date()
        defer {
            let took = Int(Date().timeIntervalSince(started) * 1000)
            if took > 5 { NSLog("%@", "PokiNativeServices timing: \(key) \(took) ms") }
        }
        do {
            let value = try await answer(key, body: input, element: element, sourceIsXML: sourceIsXML)
            return (200, (["value": value] as JSON).data())
        } catch {
            let e = error as NSError
            let focusChanged = error.localizedDescription.localizedCaseInsensitiveContains("typing focus changed")
            let code = (e.domain == "PokiKeyboard" && e.code == 2) || focusChanged ? "poki user takeover" : "unknown error"
            return (500, (["value": ["error": .string(code), "message": .string(error.localizedDescription)]] as JSON).data())
        }
    }

    private func answer(_ key: String, body: JSON?, element: String?, sourceIsXML: Bool) async throws -> JSON {
        switch key {
        case "GET /status": return ["ready": true, "message": "experimental native services"]
        case "POST /session": return ["sessionId": "native-services"]
        case "DELETE /session", "POST /appium/settings": return .null
        case "GET /wda/screen": return ["screenSize": ["width": .number(screen.width), "height": .number(screen.height)]]
        case "GET /wda/locked":
            let tree = try await readTree()
            return .bool(Self.looksLocked(tree))
        case "GET /source":
            let tree = try await readTree()
            return .string(sourceIsXML ? Self.sourceXML(tree) : Self.sourceJSON(tree))
        case "GET /wda/activeAppInfo":
            let tree = try await readTree()
            let app = tree["foreground_app"] as? [String: Any] ?? [:]
            return ["bundleId": .string(app["bundle_id"] as? String ?? ""), "name": .string(app["name"] as? String ?? ""), "pid": .number(Double(app["pid"] as? Int ?? 0))]
        case "GET /screenshot":
            let result = try await pictures.call(["op": "screenshot"])
            guard let base64 = result["base64"] as? String else { throw Self.failure("the screenshot service returned no image") }
            return .string(base64)
        case "GET /element/active":
            let tree = try await readTree()
            let elements = tree["elements"] as? [[String: Any]] ?? []
            guard let field = elements.first(where: { $0["focused"] as? Bool == true }) else { throw Self.failure("no element has keyboard focus") }
            queue.sync { focused = field }
            return ["ELEMENT": "focused"]
        case "GET /element/attribute/value":
            guard element == "focused", let field = queue.sync(execute: { focused }) else { throw Self.failure("the focused element is gone") }
            return field["value"].map(Self.json) ?? .null
        case "GET /element/attribute/placeholderValue":
            guard element == "focused", let field = queue.sync(execute: { focused }) else { throw Self.failure("the focused element is gone") }
            return field["placeholder"].map(Self.json) ?? .null
        case "GET /element/rect":
            guard element == "focused", let field = queue.sync(execute: { focused }), let frame = field["frame"] as? [String: Any] else { throw Self.failure("the focused element is gone") }
            return Self.json(frame)
        case "POST /wda/tap":
            try await callPoint("tap", body: body); return .null
        case "POST /wda/touchAndHold":
            let point = try point(body, x: "x", y: "y")
            _ = try await input.call(["op": "long_press", "x": point.x, "y": point.y, "duration_ms": Int((body?["duration"]?.double ?? 1) * 1000)])
            return .null
        case "POST /wda/pressAndDragWithVelocity", "POST /wda/dragfromtoforduration":
            let from = try point(body, x: "fromX", y: "fromY"), to = try point(body, x: "toX", y: "toY")
            let duration = key.contains("pressAndDrag") ? Self.dragMilliseconds(body) : 300
            _ = try await input.call(["op": "drag", "x1": from.x, "y1": from.y, "x2": to.x, "y2": to.y, "duration_ms": duration, "hold_ms": Int((body?["duration"]?.double ?? body?["pressDuration"]?.double ?? 0) * 1000), "end_hold_ms": Int((body?["holdDuration"]?.double ?? 0) * 1000)])
            return .null
        case "POST /actions":
            try await actions(body); return .null
        case "POST /wda/keys":
            let text = (body?["value"]?.array ?? []).compactMap(\.string).joined()
            guard !text.isEmpty else { throw Self.failure("no keys given") }
            let preferred = PokiKeyboardTyping(screen: screen) { [input] request in try await input.call(request) }
            if let value = try await preferred.type(text, clear: body?["clear"]?.bool ?? false) {
                return ["textVerified": true, "value": .string(value)]
            }
            let engine = NativeIME(screen: screen) { [input] request in try await input.call(request) }
            let value = try await engine.type(text, clear: body?["clear"]?.bool ?? false, frequency: body?["frequency"]?.int)
            return ["textVerified": true, "value": .string(value)]
        case "POST /wda/homescreen": _ = try await input.call(["op": "button", "button": "home"]); return .null
        case "POST /wda/lock": _ = try await input.call(["op": "button", "button": "lock"]); return .null
        case "POST /wda/pressButton": _ = try await input.call(["op": "button", "button": body?["name"]?.string ?? ""]); return .null
        case "POST /wda/apps/launch": try await launch(body, terminate: true); return .null
        case "POST /wda/apps/activate": try await launch(body, terminate: false); return .null
        case "POST /wda/apps/terminate":
            guard let bundle = body?["bundleId"]?.string, !bundle.isEmpty else { throw Self.failure("bundleId is needed") }
            _ = try await native.call(["op": "terminate_app", "bundle_id": bundle]); return .null
        case "POST /wda/getPasteboard", "POST /wda/setPasteboard":
            throw Self.failure("Pasteboard access is disabled for native agent typing; use type without via:paste")
        default: throw Self.failure("\(key) is not implemented in the experimental native-services path")
        }
    }

    private func callPoint(_ op: String, body: JSON?) async throws {
        let point = try point(body, x: "x", y: "y")
        _ = try await input.call(["op": op, "x": point.x, "y": point.y])
    }

    private func launch(_ body: JSON?, terminate: Bool) async throws {
        guard let bundle = body?["bundleId"]?.string, !bundle.isEmpty else { throw Self.failure("bundleId is needed") }
        _ = try await native.call(["op": "launch_app", "bundle_id": bundle, "terminate_existing": terminate])
    }

    /// PokiCore sends every humanized tap, hold, drag and pinch as W3C pointer actions. Preserve
    /// every sampled point and its relative time for the native multitouch HID service.
    private func actions(_ body: JSON?) async throws {
        let sources = body?["actions"]?.array ?? []
        guard (1...5).contains(sources.count) else { throw Self.failure("W3C actions need 1 to 5 touch pointers") }
        let fingers = try sources.map(finger)
        _ = try await input.call(["op": "draw_fingers", "fingers": fingers])
    }

    func finger(_ source: JSON) throws -> [[String: Any]] {
        guard source["type"]?.string == "pointer",
              source["parameters"]?["pointerType"]?.string == "touch"
        else { throw Self.failure("W3C actions support touch pointers only") }
        var x: Double?, y: Double?, elapsed = 0.0
        var touching = false, lifted = false
        var points: [[String: Any]] = []
        for action in source["actions"]?.array ?? [] {
            switch action["type"]?.string {
            case "pointerMove":
                guard let nextX = action["x"]?.double, let nextY = action["y"]?.double else {
                    throw Self.failure("a pointerMove needs x and y")
                }
                x = nextX; y = nextY
                if touching {
                    elapsed += max(0.001, action["duration"]?.double ?? 0)
                    points.append(["x": coordinate(nextX, across: screen.width), "y": coordinate(nextY, across: screen.height), "time_ms": elapsed])
                }
            case "pointerDown":
                guard !touching, let x, let y else { throw Self.failure("pointerDown needs an initial pointerMove") }
                touching = true
                points.append(["x": coordinate(x, across: screen.width), "y": coordinate(y, across: screen.height), "time_ms": 0.0])
            case "pause":
                guard touching, let x, let y else { throw Self.failure("pause needs a pointerDown") }
                elapsed += max(0.001, action["duration"]?.double ?? 0)
                points.append(["x": coordinate(x, across: screen.width), "y": coordinate(y, across: screen.height), "time_ms": elapsed])
            case "pointerUp":
                guard touching else { throw Self.failure("pointerUp needs a pointerDown") }
                touching = false; lifted = true
            default: throw Self.failure("unsupported W3C pointer action: \(action["type"]?.string ?? "missing type")")
            }
        }
        guard lifted, !touching, let x, let y, !points.isEmpty else { throw Self.failure("the touch pointer did not lift") }
        if points.count == 1 {
            points.append(["x": coordinate(x, across: screen.width), "y": coordinate(y, across: screen.height), "time_ms": 50.0])
        }
        return points
    }

    /// Coalesces PokiCore's parallel source and foreground requests into the one accessibility read
    /// the Mac/Linux bridge already returns. The short cache never survives an action's 300 ms settle.
    private func readTree() async throws -> [String: Any] {
        let task: Task<Tree, Error> = queue.sync {
            if let cachedTree, Date().timeIntervalSince(cachedTree.at) < 0.15 {
                return Task { cachedTree.tree }
            }
            if let treeTask { return treeTask }
            let task = Task { Tree(value: try await native.call(["op": "ax_tree"])) }
            treeTask = task
            if !inputWarming {
                inputWarming = true
                Task { _ = try? await input.call(["op": "warm_input"]) }
            }
            return task
        }
        do {
            let tree = try await task.value
            queue.sync { cachedTree = (Date(), tree); treeTask = nil }
            return tree.value
        } catch {
            queue.sync { treeTask = nil }
            throw error
        }
    }

    /// WDA velocity is in screen points/second, not normalized HID units/second.
    static func dragMilliseconds(_ body: JSON?) -> Int {
        let distance = hypot((body?["toX"]?.double ?? 0) - (body?["fromX"]?.double ?? 0),
                             (body?["toY"]?.double ?? 0) - (body?["fromY"]?.double ?? 0))
        return max(80, Int(distance / max(1, body?["velocity"]?.double ?? 1000) * 1000))
    }

    private func point(_ body: JSON?, x: String, y: String) throws -> (x: Int, y: Int) {
        guard let px = body?[x]?.double, let py = body?[y]?.double else { throw Self.failure("\(x) and \(y) are needed") }
        return (coordinate(px, across: screen.width), coordinate(py, across: screen.height))
    }
    /// CoreDevice HID uses 0...65535 over each full display axis, while WDA and PokiCore use UIKit
    /// points. Use the same end-point mapping as the Mac/Linux bridge.
    private func coordinate(_ value: Double, across: CGFloat) -> Int {
        guard across > 1 else { return 0 }
        return max(0, min(65_535, Int((value / Double(across - 1) * 65_535).rounded())))
    }
    private static func looksLocked(_ tree: [String: Any]) -> Bool {
        let app = tree["foreground_app"] as? [String: Any]
        guard app?["bundle_id"] as? String == "com.apple.springboard" else { return false }
        let elements = tree["elements"] as? [[String: Any]] ?? []
        let words = elements.flatMap { [$0["identifier"], $0["label"], $0["placeholder"]] }
            .compactMap { $0 as? String }.joined(separator: " ").lowercased()
        // SpringBoard also owns Home, alerts and the app switcher. Only lock/passcode vocabulary (or
        // a secure field on SpringBoard) is treated as locked, so ordinary system prompts still work.
        return words.contains("unlock") || words.contains("passcode") || words.contains("locked")
            || elements.contains { ($0["role"] as? String) == "SecureTextField" }
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "PokiNativeServices", code: 3, userInfo: [NSLocalizedDescriptionKey: text]) }

    /// Turns the bridge's flat preorder accessibility records back into the JSON hierarchy PokiCore
    /// already consumes from WDA. Parent indices preserve containment and hit testing.
    private static func sourceJSON(_ tree: [String: Any]) -> String {
        let elements = tree["elements"] as? [[String: Any]] ?? []
        var nodes: [[String: Any]] = elements.map { element in
            let frame = element["frame"] as? [String: Any] ?? [:]
            return ["type": "XCUIElementType\(element["role"] as? String ?? "Other")", "name": element["identifier"] ?? element["label"] ?? "", "label": element["label"] ?? "", "value": element["value"] ?? "", "rect": frame, "children": []]
        }
        if nodes.isEmpty { return "{\"type\":\"XCUIElementTypeApplication\",\"children\":[]}" }
        for index in nodes.indices.reversed() {
            guard let parent = elements[index]["parent"] as? Int, nodes.indices.contains(parent) else { continue }
            var children = nodes[parent]["children"] as? [[String: Any]] ?? []
            children.insert(nodes[index], at: 0)
            nodes[parent]["children"] = children
        }
        let roots = elements.indices.filter { elements[$0]["parent"] is NSNull || elements[$0]["parent"] == nil }.map { nodes[$0] }
        let root: [String: Any] = roots.count == 1 ? roots[0] : ["type": "XCUIElementTypeApplication", "children": roots]
        let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// PokiCore's production configuration asks WDA for XML. The native AX service returns the same
    /// fields as a flat preorder list, so preserve its parent relationships in WDA's XML shape too.
    private static func sourceXML(_ tree: [String: Any]) -> String {
        let elements = tree["elements"] as? [[String: Any]] ?? []
        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for index in elements.indices {
            if let parent = elements[index]["parent"] as? Int, elements.indices.contains(parent) {
                children[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }
        func escaped(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "" }
            return String(describing: value)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        func node(_ index: Int) -> String {
            let element = elements[index]
            let frame = element["frame"] as? [String: Any] ?? [:]
            let type = "XCUIElementType\(element["role"] as? String ?? "Other")"
            let attributes = [
                ("name", element["identifier"] ?? element["label"]),
                ("label", element["label"]), ("value", element["value"]),
                ("x", frame["x"]), ("y", frame["y"]),
                ("width", frame["width"]), ("height", frame["height"]),
            ].map { "\($0.0)=\"\(escaped($0.1))\"" }.joined(separator: " ")
            let nested = (children[index] ?? []).map(node).joined()
            return nested.isEmpty ? "<\(type) \(attributes)/>" : "<\(type) \(attributes)>\(nested)</\(type)>"
        }
        let content = roots.map(node).joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><AppiumAUT>\(content.isEmpty ? "<XCUIElementTypeApplication/>" : content)</AppiumAUT>"
    }

    private static func json(_ value: Any) -> JSON {
        switch value {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as NSNumber: .number(value.doubleValue)
        case let value as [String: Any]: .object(value.mapValues(json))
        case let value as [Any]: .array(value.map(json))
        default: .null
        }
    }
}
