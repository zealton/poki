import Darwin
// Build with NativeIME.swift using the macOS Command Line Tools. Runs the same
// typing engine as /wda/keys, against the native_usb Rust example over stdin.
import Foundation
import CoreText
import ImageIO

final class USBLineClient {
  let process = Process()
  let input = Pipe(), output = Pipe()
  var buffered = Data()
  init(binary: String, udid: String) throws {
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [udid]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
  }
  func call(_ request: [String: Any]) throws -> [String: Any] {
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(10)
    try input.fileHandleForWriting.write(contentsOf: data)
    while !buffered.contains(10) {
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else { throw NativeIME.fail("USB worker exited") }
      buffered.append(chunk)
    }
    let end = buffered.firstIndex(of: 10)!
    let line = buffered.prefix(upTo: end)
    buffered.removeSubrange(...end)
    let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
    guard result["ok"] as? Bool == true, let value = result["value"] as? [String: Any] else {
      throw NativeIME.fail(result["error"] as? String ?? "Invalid USB reply")
    }
    return value
  }
  func close() {
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
  }
}

final class FakeNativeInput {
  var value = ""
  var textCalls = 0
  var detached = false
  var partial = false
  var cancel = false
  var wrongFocus = false
  var failDetach = false
  var driftAfterCommit = false
  func call(_ request: [String: Any]) throws -> [String: Any] {
    if request["op"] as? String == "ax_tree" {
      let tree: [String: Any] = [
        "foreground_app": ["pid": 42], "orientation": 1,
        "elements": [
          [
            "role": "TextField", "label": "test", "focused": true, "value": value,
            "frame": ["x": 0.0, "y": wrongFocus ? 100.0 : 0.0, "width": 400.0, "height": 600.0],
          ]
        ],
      ]
      if driftAfterCommit && value == "hello" { value += "!" }
      return tree
    }
    if request["op"] as? String == "screenshot" { return ["base64": "AA=="] }
    if request["end"] as? Bool == true {
      detached = true
      if failDetach { throw NativeIME.fail("remove refused") }
      return ["ended": true]
    }
    if let text = request["text"] as? String {
      textCalls += 1
      value += partial ? String(text.prefix(1)) : text
      if cancel { throw CancellationError() }
    }
    return ["sent": true]
  }
}

final class FakePinyinPipeline {
  var committed = ""
  var composing = ""
  var visibleCandidate = ""
  var pendingCandidate = ""
  var reads = 0
  var selections = 0
  var detached = false
  var drift = false
  var sequence = 0
  func call(_ request: [String: Any]) throws -> [String: Any] {
    if request["end"] as? Bool == true {
      detached = true
      return ["ended": true]
    }
    if request["op"] as? String == "screenshot" { return ["base64": "AA=="] }
    if request["op"] as? String == "ax_tree" {
      sequence += 1
      if !composing.isEmpty {
        reads += 1
        if reads >= 3 || visibleCandidate.isEmpty { visibleCandidate = pendingCandidate }
      }
      var elements: [[String: Any]] = [
        [
          "role": "TextField", "focused": !(reads == 1 && selections > 0), "label": "test",
          "value": committed + composing,
          "frame": ["x": 0.0, "y": 0.0, "width": 400.0, "height": 600.0],
        ]
      ]
      if !composing.isEmpty {
        elements += [
          ["role": "Button", "label": "More suggestions"],
          [
            "role": "Key", "label": visibleCandidate, "trait_names": ["Keyboard Key"],
            "frame": ["x": 10.0, "y": 50.0, "width": 80.0, "height": 40.0],
          ],
        ]
      }
      return [
        "foreground_app": ["pid": 42], "orientation": 1, "sequence": sequence, "elements": elements,
      ]
    }
    if let text = request["text"] as? String {
      composing = text
      reads = 0
      pendingCandidate = text == "jintianxiawuwomen" ? "今天下午我们" : "你好"
      if drift && selections > 0 { committed += "错误" }
    }
    if request["tap"] != nil {
      precondition(visibleCandidate == pendingCandidate, "must not tap the preceding candidates")
      committed += pendingCandidate
      composing = ""
      selections += 1
    }
    return ["sent": true]
  }
}

func sourceFixture(label: String?, rect: CGRect, screen: CGSize) throws -> Data {
  let scale = 2.0
  let context = CGContext(data: nil, width: Int(screen.width * scale), height: Int(screen.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.scaleBy(x: scale, y: scale)
  context.setFillColor(CGColor(gray: 0.08, alpha: 1))
  context.fill(CGRect(origin: .zero, size: screen))
  if let label {
    let box = CGRect(x: rect.minX, y: screen.height - rect.maxY, width: rect.width, height: rect.height)
    context.setFillColor(CGColor(red: 0.05, green: 0.45, blue: 0.95, alpha: 1))
    context.fill(box)
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 22, nil)
    let text = NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
    context.textPosition = CGPoint(x: box.minX + 12, y: box.minY + (box.height - 22) / 2 + 3)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
  }
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  precondition(CGImageDestinationFinalize(destination))
  return data as Data
}

@main struct NativeIMEUSB {
  static func main() async {
    signal(SIGPIPE, SIG_IGN)
    do { try await run() } catch {
      FileHandle.standardError.write(Data(("FAILED: " + error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  static func run() async throws {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--source-layout-tests" {
      let cases: [(String, CGSize, CGRect, NativeIME.Source?)] = [
        ("拼", CGSize(width: 1376, height: 1032), CGRect(x: 690, y: 180, width: 52, height: 42), .pinyin),
        ("拼音", CGSize(width: 390, height: 844), CGRect(x: 30, y: 690, width: 100, height: 44), .pinyin),
        ("English (US)", CGSize(width: 390, height: 844), CGRect(x: 30, y: 440, width: 285, height: 48), .roman),
        ("简体手写", CGSize(width: 390, height: 844), CGRect(x: 30, y: 440, width: 285, height: 48), nil),
      ]
      for (label,screen,rect,expected) in cases {
        let before = try sourceFixture(label: nil, rect: rect, screen: screen)
        let after = try sourceFixture(label: label, rect: rect, screen: screen)
        let actual = try NativeIME.sourceMarker(before: before, after: after, field: CGRect(x: 10, y: 40, width: screen.width - 20, height: 230), screen: screen)
        guard actual == expected else { throw NativeIME.fail("Source layout failed: \(label)") }
      }
      print("Source layouts passed: caret badge, bottom picker, wide language row, handwriting rejection")
      return
    }
    if args.count == 2 && args[1] == "--self-test" {
      let rgb16 = Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACEAIAAACtREYwAAAAEklEQVR4nGP4/58BCCAkAzIHAHeiB/kKf4rQAAAAAElFTkSuQmCC"
      )!
      let decoded = try NativeIME.image(rgb16)
      precondition(decoded.bitsPerComponent == 8 && decoded.width == 2 && decoded.height == 2)
      let parts = try NativeIME.plan("Hello 你好，world!\u{8}?")
      precondition(parts.map(\.text).joined() == "Hello 你好，world!\u{8}?")
      precondition((try? NativeIME.pinyin("女")) == "nv")
      precondition((try? NativeIME.pinyin("选择")) == "xuanze")
      precondition((try? NativeIME.pinyin("绿色")) == "lvse")
      precondition(NativeIME.sourceLabel("简体中文 - 拼音") == .pinyin)
      precondition(NativeIME.sourceLabel("Pinyin") == .pinyin)
      precondition(NativeIME.sourceLabel("English (US)") == .roman)
      precondition(NativeIME.sourceLabel("简体手写") == nil)
      precondition(NativeIME.sourceLabel("Japanese") == nil)
      let sentence = "今天我们一起测试中文输入"
      let words = try NativeIME.plan(sentence)
      precondition(words.map(\.text).joined() == sentence && words.count >= 2)
      precondition(words.allSatisfy { $0.text.count <= 6 })
      precondition(NativeIME.words(sentence).contains("我们"))
      precondition((try? NativeIME.pinyin("重庆")) == "chongqing")
      precondition((try? NativeIME.plan("prefix🙂")) == nil)
      precondition(NativeIME.matchesEdit(before: "ab", after: "a你好b", keys: "你好"))
      precondition(NativeIME.matchesEdit(before: "selected", after: "你好", keys: "你好"))
      precondition(!NativeIME.matchesEdit(before: "ab", after: "X你好b", keys: "你好"))
      precondition(NativeIME.matchesEdit(before: "a你b", after: "ab", keys: "\u{8}"))
      precondition(!NativeIME.matchesEdit(before: "abc", after: "a", keys: "\u{8}"))
      precondition(!NativeIME.matchesEdit(before: "abc", after: "abc", keys: "\u{8}"))
      let candidate: [String: Any] = [
        "role": "Key", "label": "你好, 你们的你，好友的好", "trait_names": ["Keyboard Key"],
        "frame": ["x": 672.0, "y": 132.5, "width": 76.0, "height": 41.0],
      ]
      let anchor: [String: Any] = ["role": "Button", "label": "More suggestions"]
      precondition(NativeIME.candidates(["elements": [candidate]], matching: "你好").isEmpty)
      precondition(
        NativeIME.candidates(["elements": [candidate, anchor]], matching: "你好").count == 1)
      precondition(NativeIME.candidates(["elements": [candidate, anchor]], matching: "你").isEmpty)
      let point = try NativeIME.hidPoint(
        CGRect(x: 691, y: 36, width: 36, height: 36), screen: CGSize(width: 1376, height: 1032),
        orientation: 3)
      precondition(abs(point.0 - 62106) < 10 && abs(point.1 - 33768) < 40)
      for mode in ["success", "partial", "cancel", "detach"] {
        let fake = FakeNativeInput()
        fake.partial = mode == "partial"
        fake.cancel = mode == "cancel"
        fake.failDetach = mode == "detach"
        let engine = NativeIME(
          screen: CGSize(width: 400, height: 800), sourceReader: { _, _, _, _ in .roman }
        ) { try fake.call($0) }
        do {
          let value = try await engine.type("hello")
          precondition(mode == "success" && value == "hello")
        } catch { precondition(mode != "success") }
        precondition(fake.detached && fake.textCalls == 1)
      }
      for drift in [false, true] {
        let fake = FakePinyinPipeline()
        fake.drift = drift
        let engine = NativeIME(
          screen: CGSize(width: 400, height: 800), sourceReader: { _, _, _, _ in .pinyin }
        ) { try fake.call($0) }
        do {
          let text = try await engine.type("今天下午我们你好")
          precondition(!drift && text == "今天下午我们你好" && fake.selections == 2)
        } catch { precondition(drift && fake.selections == 1) }
        precondition(fake.detached)
      }
      let drift = FakeNativeInput()
      drift.driftAfterCommit = true
      let driftEngine = NativeIME(
        screen: CGSize(width: 400, height: 800), sourceReader: { _, _, _, _ in .roman }
      ) { try drift.call($0) }
      do {
        _ = try await driftEngine.type("hello\n")
        preconditionFailure("external edits must stop remaining input")
      } catch {}
      precondition(drift.detached && drift.textCalls == 1)
      let unsupported = FakeNativeInput()
      let unsupportedEngine = NativeIME(
        screen: CGSize(width: 400, height: 800), sourceReader: { _, _, _, _ in .roman }
      ) { try unsupported.call($0) }
      do {
        _ = try await unsupportedEngine.type("prefix🙂")
        preconditionFailure("unsupported text must fail before its prefix")
      } catch {}
      precondition(unsupported.detached && unsupported.textCalls == 0)
      let unknown = FakeNativeInput()
      let unverified = NativeIME(
        screen: CGSize(width: 400, height: 800), sourceReader: { _, _, _, _ in nil }
      ) { try unknown.call($0) }
      do {
        _ = try await unverified.type("hello")
        preconditionFailure("unknown source must fail")
      } catch {}
      precondition(unknown.detached && unknown.textCalls == 0)
      let focus = FakeNativeInput()
      let engine = NativeIME(
        screen: CGSize(width: 400, height: 800), sourceReader: { _, _, _, _ in .roman }
      ) { request in
        if request["key"] as? String == "next_input_source" { focus.wrongFocus = true }
        return try focus.call(request)
      }
      do {
        _ = try await engine.type("hello")
        preconditionFailure("lost focus must fail")
      } catch {}
      precondition(focus.detached && focus.textCalls == 0)
      print(
        "Native IME checks passed: planning, candidates, exact edits, partial commit, unknown source, lost focus, cancellation, cleanup"
      )
      return
    }
    if args.count == 4 && args[1] == "--marker" {
      let source = try NativeIME.sourceMarker(
        before: Data(contentsOf: URL(fileURLWithPath: args[2])),
        after: Data(contentsOf: URL(fileURLWithPath: args[3])),
        field: CGRect(x: 621, y: 0, width: 755, height: 1032),
        screen: CGSize(width: 1376, height: 1032))
      print(source.map { $0 == .pinyin ? "pinyin" : "roman" } ?? "unverified")
      return
    }
    guard args.count >= 4 else {
      throw NativeIME.fail("usage: native-ime-usb NATIVE_USB_BINARY UDID TEXT [--clear]")
    }
    let started = Date()
    let client = try USBLineClient(binary: args[1], udid: args[2])
    defer { client.close() }
    let tree = try client.call(["op": "ax_tree"])
    guard let elements = tree["elements"] as? [[String: Any]], let root = elements.first else {
      throw NativeIME.fail("Missing display geometry")
    }
    let size = NativeIME.rect(root["frame"]).size
    var typingStarted: Date?
    var compositions = 0
    var selections = 0
    var expansions = 0
    var lastTree: [String: Any] = [:]
    let engine = NativeIME(
      screen: size,
      sourceReader: { before, after, field, screen in
        do {
          let source = try NativeIME.sourceMarker(
            before: before, after: after, field: field, screen: screen)
          if source == nil && args.contains("--source-images") {
            try? before.write(to: URL(fileURLWithPath: "/tmp/poki-ime-source-before.png"))
            try? after.write(to: URL(fileURLWithPath: "/tmp/poki-ime-source-after.png"))
          }
          return source
        } catch {
          try? before.write(to: URL(fileURLWithPath: "/tmp/poki-ime-source-before.png"))
          try? after.write(to: URL(fileURLWithPath: "/tmp/poki-ime-source-after.png"))
          throw error
        }
      }
    ) { request in
      if request["text"] != nil {
        compositions += 1
        if typingStarted == nil { typingStarted = Date() }
      }
      if let tap = request["tap"] as? [Int] {
        selections += 1
        let orientation = lastTree["orientation"] as? Int ?? 1
        let keys = (lastTree["elements"] as? [[String: Any]] ?? []).filter {
          $0["role"] as? String == "Key"
        }
        for (index, key) in keys.enumerated() {
          if let point = try? NativeIME.hidPoint(
            NativeIME.rect(key["frame"]), screen: size, orientation: orientation),
            tap == [point.0, point.1]
          {
            FileHandle.standardError.write(
              Data(("candidate index=\(index + 1) label=\(key["label"] ?? "")\n").utf8))
          }
        }
      }
      if request["key"] as? String == "down" { expansions += 1 }
      let operation =
        (request["op"] as? String ?? "") + (request["key"].map { " key=\($0)" } ?? "")
        + (request["text"].map { " text=\($0)" } ?? "")
        + (request["tap"] == nil ? "" : " candidate tap")
      do {
        let callStart = Date()
        let value = try client.call(request)
        FileHandle.standardError.write(
          Data(
            ("timing op=\(request["op"] ?? "") ms=\(Int(Date().timeIntervalSince(callStart) * 1000)) direct=\(value["direct"] ?? false)\n")
              .utf8))
        if request["op"] as? String == "ax_tree" {
          lastTree = value
          if args.contains("--candidates") {
            let labels = (value["elements"] as? [[String: Any]] ?? []).filter {
              $0["role"] as? String == "Key"
            }.map { "\($0["label"] ?? "") traits=\($0["trait_names"] ?? "")" }
            FileHandle.standardError.write(
              Data(("candidates: " + labels.joined(separator: " | ") + "\n").utf8))
          }
        }
        if request["op"] as? String == "ime" {
          FileHandle.standardError.write(Data((operation + " acknowledged\n").utf8))
        }
        return value
      } catch { throw NativeIME.fail("\(operation): \(error.localizedDescription)") }
    }
    var verified = false
    defer {
      if verified, let typingStarted {
        let active = Date().timeIntervalSince(typingStarted)
        let total = Date().timeIntervalSince(started)
        print(
          "RATE chars=\(args[3].count) activeSeconds=\(String(format: "%.2f", active)) totalSeconds=\(String(format: "%.2f", total)) activeCPM=\(Int(Double(args[3].count) * 60 / active)) totalCPM=\(Int(Double(args[3].count) * 60 / total))"
        )
      }
      print(
        "INPUT rounds=\(compositions) candidateChoices=\(selections) expansions=\(expansions) seconds=\(Int(Date().timeIntervalSince(started)))"
      )
    }
    let value = try await engine.type(args[3], clear: args.contains("--clear"))
    verified = true
    print("VERIFIED " + value)
  }
}
