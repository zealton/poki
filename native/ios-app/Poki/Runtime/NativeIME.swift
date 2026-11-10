import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import Vision

/// Pasteboard-free text entry. This file also builds on macOS so the exact engine can be
/// exercised against the USB worker without building or installing an iOS application.
final class NativeIME {
  typealias Call = ([String: Any]) async throws -> [String: Any]
  typealias SourceReader = (Data, Data, CGRect, CGSize) throws -> Source?
  enum Source: Equatable { case roman, pinyin }
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  struct Field {
    let pid: Int
    let objectID: String
    let role: String
    let label: String
    let identifier: String
    let frame: CGRect
    let value: String
    func sameTarget(as other: Field) -> Bool {
      let sameIdentity =
        !objectID.isEmpty && !other.objectID.isEmpty
        ? objectID == other.objectID
        : role == other.role && label == other.label && identifier == other.identifier
      return pid == other.pid && sameIdentity
        && abs(frame.minX - other.frame.minX) < 2 && abs(frame.minY - other.frame.minY) < 2
        && abs(frame.width - other.frame.width) < 2
    }
  }
  struct Part {
    let text: String
    let source: Source
    let keys: String
    let composition: Bool
  }
  let call: Call
  let sourceReader: SourceReader
  let screen: CGSize
  private var target: Field?
  private var source: Source?
  private var frequency: Int?
  private var expectedValue: String?
  private var latestTree: [String: Any]?
  private var orientation = 1
  init(
    screen: CGSize, sourceReader: @escaping SourceReader = NativeIME.sourceMarker,
    call: @escaping Call
  ) {
    self.screen = screen
    self.call = call
    self.sourceReader = sourceReader
  }
  static func fail(_ message: String) -> Failure { Failure(message: message) }
  static func rect(_ value: Any?) -> CGRect {
    let f = value as? [String: Any] ?? [:]
    return CGRect(
      x: f["x"] as? Double ?? 0, y: f["y"] as? Double ?? 0,
      width: f["width"] as? Double ?? 0, height: f["height"] as? Double ?? 0)
  }
  static func field(_ tree: [String: Any]) throws -> Field {
    let fields = (tree["elements"] as? [[String: Any]] ?? []).filter {
      $0["focused"] as? Bool == true
        && ["TextField", "TextView", "SearchField"].contains($0["role"] as? String ?? "")
    }
    guard fields.count == 1, let f = fields.first, let value = f["value"] as? String,
      let app = tree["foreground_app"] as? [String: Any], let pid = app["pid"] as? Int
    else {
      throw fail("Native typing needs one readable focused text field; nothing more was typed")
    }
    return Field(
      pid: pid, objectID: f["object_id"] as? String ?? "", role: f["role"] as? String ?? "",
      label: f["label"] as? String ?? "",
      identifier: f["identifier"] as? String ?? "", frame: rect(f["frame"]), value: value)
  }
  private func checked(_ request: [String: Any]) async throws -> [String: Any] {
    try Task.checkCancellation()
    let result = try await call(request)
    try Task.checkCancellation()
    return result
  }
  private func observe(fresh: Bool = true) async throws -> (tree: [String: Any], field: Field) {
    var tree: [String: Any]
    if !fresh, let latestTree {
      tree = latestTree
    } else {
      tree = try await checked(["op": "ax_tree", "direct": true])
    }
    // UIKit can transiently omit its responder while rebuilding the text layout.
    // Retry observations only; never type into an unreadable or different target.
    for _ in 0..<2 where (try? Self.field(tree)) == nil {
      tree = try await checked(["op": "ax_tree", "direct": true])
    }
    let field = try Self.field(tree)
    latestTree = tree
    orientation = tree["orientation"] as? Int ?? orientation
    if let target, !target.sameTarget(as: field) {
      throw Self.fail("Typing focus changed; the remaining text was not sent")
    }
    return (tree, field)
  }
  private func screenshot() async throws -> Data {
    let value = try await checked(["op": "screenshot"])
    guard let encoded = value["base64"] as? String, let data = Data(base64Encoded: encoded) else {
      throw Self.fail("No screenshot for input-source verification")
    }
    return data
  }
  /// No input is replayed. Even cancellation waits for the in-flight bridge call and removal.
  func type(_ text: String, clear: Bool = false, frequency: Int? = nil) async throws -> String {
    self.frequency = frequency
    target = nil
    source = nil
    expectedValue = nil
    latestTree = nil
    var result: Result<String, Error>
    do {
      let parts = try Self.plan(text)  // reject unsupported text before clearing or sending a prefix
      let initial = try await observe()
      target = initial.field
      _ = try await checked(["op": "ime"])
      var attachedState = try await observe()
      let attachmentDeadline = Date().addingTimeInterval(2)
      while Self.hasSoftwareKeyboard(attachedState.tree) && Date() < attachmentDeadline {
        attachedState = try await observe()
      }
      guard !Self.hasCandidatePanel(attachedState.tree) else {
        throw Self.fail("Finish or cancel the existing IME composition before typing")
      }
      let attached = attachedState.field
      guard attached.value == target?.value else {
        throw Self.fail("The field changed while the keyboard attached")
      }
      expectedValue = attached.value
      if clear {
        _ = try await checked(["op": "ime", "key": "a", "modifiers": ["command"]])
        _ = try await checked(["op": "ime", "key": "backspace"])
        let clearDeadline = Date().addingTimeInterval(2)
        var cleared = try await observe().field.value
        while !cleared.isEmpty && Date() < clearDeadline {
          cleared = try await observe().field.value
        }
        guard cleared.isEmpty else {
          throw Self.fail("Clearing the target field was not confirmed; text was not sent")
        }
      }
      if clear { expectedValue = "" }
      var index = 0
      while index < parts.count {
        if parts[index].source == .pinyin {
          var end = index + 1
          while end < parts.count && parts[end].source == .pinyin { end += 1 }
          try await enterPinyinRun(Array(parts[index..<end]))
          index = end
        } else {
          try await enter(parts[index])
          index += 1
        }
      }
      let finalValue = try await observe(fresh: false).field.value
      guard finalValue == expectedValue else {
        throw Self.fail("The field changed after the last verified edit")
      }
      result = .success(finalValue)
    } catch { result = .failure(error) }
    do {
      let ended = try await call(["op": "ime", "end": true])
      guard ended["ended"] as? Bool == true else {
        throw Self.fail("Keyboard removal was not acknowledged")
      }
    } catch {
      let original = (try? result.get()).map { _ in "" } ?? "; input also failed: \(result)"
      throw Self.fail("Simulated keyboard removal failed: \(error.localizedDescription)\(original)")
    }
    let value = try result.get()
    guard try await observe().field.value == value else {
      throw Self.fail("The field changed when the simulated keyboard detached")
    }
    return value
  }
  private func selectSource(_ wanted: Source) async throws {
    if source == wanted { return }
    let beforeField = try await observe(fresh: false).field
    var previous = try await screenshot()
    for _ in 0..<8 {
      _ = try await checked(["op": "ime", "key": "next_input_source"])
      var picture = try await screenshot()
      var found = try sourceReader(previous, picture, beforeField.frame, orientedScreen())
      if found == nil {
        // Switcher animations vary by device and presentation. Observe the
        // same selection again before cycling past an unreadable frame.
        try await Task.sleep(nanoseconds: 80_000_000)
        picture = try await screenshot()
        found = try sourceReader(previous, picture, beforeField.frame, orientedScreen())
      }
      if found == wanted {
        let field = try await observe().field
        guard field.value == beforeField.value else {
          throw Self.fail("Input-source switching changed the field; stopped without replay")
        }
        source = wanted
        return
      }
      previous = picture
    }
    throw Self.fail(
      "The requested input source could not be verified from the visible switcher; no text was sent for this segment"
    )
  }
  private func orientedScreen(_ orientation: Int? = nil) -> CGSize {
    let value = orientation ?? self.orientation
    return [3, 4].contains(value)
      ? CGSize(width: max(screen.width, screen.height), height: min(screen.width, screen.height))
      : CGSize(width: min(screen.width, screen.height), height: max(screen.width, screen.height))
  }
  private func appendCompositionReady(_ field: String, before: String, keys: String) -> Bool {
    guard field.hasPrefix(before) else { return false }
    return Self.normalizedPinyin(String(field.dropFirst(before.count))) == keys
  }

  private func waitForField(_ matches: (String) -> Bool) async throws -> String {
    let deadline = Date().addingTimeInterval(2.5)
    var reads = 0
    repeat {
      let value = try await observe().field.value
      reads += 1
      if matches(value) { return value }
    } while reads < 2 || Date() < deadline
    throw Self.fail("The requested field edit was not observed; stopped without replay")
  }

  /// Pipeline append-only Chinese groups: select a verified candidate and start
  /// the next composition immediately. The next fresh snapshot must prove the
  /// preceding commit AND the complete new Pinyin before any further selection.
  private func enterPinyinRun(_ planned: [Part]) async throws {
    try await selectSource(.pinyin)
    var queue = planned
    var index = 0
    var prepared = false
    var previousCandidates: [String] = []
    var previousKeys = ""
    while index < queue.count {
      let part = queue[index]
      if !part.composition {
        try await enter(part)
        index += 1
        continue
      }
      guard let before = expectedValue else { throw Self.fail("Missing verified field state") }
      if !prepared {
        guard try await observe(fresh: false).field.value == before else {
          throw Self.fail("The field changed between edits")
        }
        _ = try await checked(["op": "ime", "text": part.keys, "frequency": frequency ?? 1000])
      }
      var seen = try await observe()
      let deadline = Date().addingTimeInterval(2.5)
      while !(prepared
        ? Self.hasCandidatePanel(seen.tree)
          && appendCompositionReady(seen.field.value, before: before, keys: part.keys)
        : Self.compositionReady(
          before: before, field: seen.field.value, keys: part.keys, tree: seen.tree))
      {
        guard Date() < deadline else {
          throw Self.fail(
            "Commit and complete Pinyin were not verified; no further candidate selected")
        }
        seen = try await observe()
      }
      // Field values and candidate labels can arrive in different AX updates.
      // Do not expand or select from the preceding composition's candidate list.
      while part.keys != previousKeys && !previousCandidates.isEmpty
        && Self.candidateLabels(seen.tree) == previousCandidates
      {
        guard Date() < deadline else {
          throw Self.fail("The candidate list did not update for the new Pinyin")
        }
        seen = try await observe()
      }
      // For a prepared group, this observation also confirms the previous commit.
      let appending = appendCompositionReady(seen.field.value, before: before, keys: part.keys)
      var matches = Self.candidates(seen.tree, matching: part.text)
      if matches.isEmpty {
        _ = try await checked(["op": "ime", "key": "down"])
        let expansionDeadline = Date().addingTimeInterval(2.5)
        repeat {
          seen = try await observe()
          if Self.hasExpandedCandidates(seen.tree) { break }
        } while Date() < expansionDeadline
        matches = Self.candidates(seen.tree, matching: part.text)
      }
      if matches.isEmpty && part.text.count == 1 && Self.hasExpandedCandidates(seen.tree) {
        var pages = Set<[String]>()
        for _ in 0..<8 {
          guard pages.insert(Self.candidateLabels(seen.tree)).inserted else { break }
          _ = try await checked(["op": "ime", "key": "page_down"])
          seen = try await observe()
          guard
            Self.compositionReady(
              before: before, field: seen.field.value, keys: part.keys, tree: seen.tree),
            Self.hasExpandedCandidates(seen.tree)
          else {
            throw Self.fail("Composition changed while paging candidates")
          }
          matches = Self.candidates(seen.tree, matching: part.text)
          if !matches.isEmpty { break }
        }
      }
      guard matches.count == 1 else {
        _ = try await checked(["op": "ime", "key": "escape"])
        _ = try await waitForField { $0 == before }
        if matches.isEmpty && appending && part.text.count > 1 {
          let words = Self.words(part.text)
          let smaller = words.count > 1 ? words : part.text.map(String.init)
          let replacements = try smaller.map {
            Part(text: $0, source: .pinyin, keys: try Self.pinyin($0), composition: true)
          }
          queue.replaceSubrange(index...index, with: replacements)
          prepared = false
          continue
        }
        throw Self.fail(
          "No unique exact Chinese candidate for \(part.text); no substitute selected")
      }
      guard
        Self.compositionReady(
          before: before, field: seen.field.value, keys: part.keys, tree: seen.tree)
      else {
        throw Self.fail("Composition changed before candidate selection")
      }
      guard let orientation = seen.tree["orientation"] as? Int else {
        throw Self.fail("Unknown candidate orientation")
      }
      previousCandidates = Self.candidateLabels(seen.tree)
      previousKeys = part.keys
      let point = try Self.hidPoint(
        matches[0], screen: orientedScreen(orientation), orientation: orientation)
      var next = index + 1
      var trailingText = ""
      var trailingKeys = ""
      while next < queue.count && !queue[next].composition {
        trailingText += queue[next].text
        trailingKeys += queue[next].keys
        next += 1
      }
      let output = part.text + trailingText
      let pipeline = appending && next < queue.count
      let followingKeys = trailingKeys + (pipeline ? queue[next].keys : "")
      _ = try await checked(["op": "ime", "tap": [point.0, point.1]])
      if !followingKeys.isEmpty {
        // One display frame for the touch selection to reach the input method.
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await checked(["op": "ime", "text": followingKeys, "frequency": frequency ?? 1000])
      }
      if pipeline {
        // This is provisional until the next observation proves the exact prefix.
        expectedValue = before + output
        prepared = true
      } else {
        expectedValue = try await waitForField {
          appending
            ? $0 == before + output : Self.matchesEdit(before: before, after: $0, keys: output)
        }
        prepared = false
      }
      index = next
    }
  }

  private func enter(_ part: Part) async throws {
    if part.text != "\n" && part.text != "\u{8}" { try await selectSource(part.source) }
    let before = try await observe().field.value
    guard before == expectedValue else {
      throw Self.fail("The field changed between edits; remaining text was not sent")
    }
    guard !part.composition else { throw Self.fail("Composition requires candidate selection") }
    _ = try await checked(["op": "ime", "text": part.keys, "frequency": frequency ?? 1000])
    // AX may publish the last composition once while the commit is settling. Only read;
    // never resend keys to repair an uncertain or partially committed result.
    var after = ""
    let readDeadline = Date().addingTimeInterval(2.5)
    var reads = 0
    repeat {
      after = try await observe().field.value
      reads += 1
      if Self.matchesEdit(before: before, after: after, keys: part.text) {
        expectedValue = after
        return
      }
    } while reads < 2 || Date() < readDeadline
    throw Self.fail(
      "Native typing read-back did not match the requested edit; stopped without replay")
  }
  static func normalizedPinyin(_ value: String) -> String {
    value.replacingOccurrences(of: "\u{2006}", with: "").replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "ü", with: "v", options: .literal)
  }
  static func compositionReady(before: String, field: String, keys: String, tree: [String: Any])
    -> Bool
  {
    hasCandidatePanel(tree)
      && matchesEdit(before: normalizedPinyin(before), after: normalizedPinyin(field), keys: keys)
  }
  static func isHan(_ c: Character) -> Bool {
    c.unicodeScalars.allSatisfy {
      (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value)
    }
  }
  static let punctuation: [Character: String] = [
    "，": ",", "。": ".", "！": "!", "？": "?", "：": ":", "；": ";", "（": "(", "）": ")", "、": "\\",
    "《": "<", "》": ">", "“": "\"", "”": "\"", "‘": "'", "’": "'",
  ]
  static func pinyin(_ text: String) throws -> String {
    var latin = text.applyingTransform(.toLatin, reverse: false) ?? ""
    // Foundation substring search can match a toned vowel across grapheme
    // boundaries (xuǎn matched ǚ on macOS). Match composed scalars exactly.
    latin = String(
      String.UnicodeScalarView(
        latin.precomposedStringWithCanonicalMapping.unicodeScalars.map {
          [0x00fc, 0x01d6, 0x01d8, 0x01da, 0x01dc].contains($0.value) ? UnicodeScalar(0x76)! : $0
        }))
    latin = (latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? "").lowercased()
      .filter { !$0.isWhitespace }
    guard !latin.isEmpty, latin.utf8.allSatisfy({ (97...122).contains($0) }) else {
      throw fail("No supported Pinyin spelling for \(text)")
    }
    return latin
  }
  static func words(_ text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.setLanguage(.simplifiedChinese)
    tokenizer.string = text
    var cursor = text.startIndex
    var result: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      if cursor < range.lowerBound { result.append(String(text[cursor..<range.lowerBound])) }
      result.append(String(text[range]))
      cursor = range.upperBound
      return true
    }
    if cursor < text.endIndex { result.append(String(text[cursor...])) }
    return result
  }
  static func plan(_ text: String) throws -> [Part] {
    guard !text.isEmpty, text.count <= 2000 else {
      throw fail("Native typing requires 1...2000 characters")
    }
    var parts: [Part] = []
    var han = ""
    var roman = ""
    func flushHan() throws {
      guard !han.isEmpty else { return }
      // Feed phrase-sized groups at lexical word boundaries. Prefer one exact
      // phrase candidate; only fall back to words after confirmed cancellation.
      var phrase = ""
      func appendPhrase() throws {
        guard !phrase.isEmpty else { return }
        let keys = try pinyin(phrase)
        guard keys.utf8.count <= 200 else {
          throw fail("A Chinese phrase exceeds the composition limit")
        }
        parts.append(Part(text: phrase, source: .pinyin, keys: keys, composition: true))
        phrase = ""
      }
      for word in Self.words(han) {
        if !phrase.isEmpty && phrase.count + word.count > 6 { try appendPhrase() }
        for character in word {
          if phrase.count == 6 { try appendPhrase() }
          phrase.append(character)
        }
      }
      try appendPhrase()
      han = ""
    }
    func flushRoman() {
      if !roman.isEmpty {
        parts.append(Part(text: roman, source: .roman, keys: roman, composition: false))
        roman = ""
      }
    }
    for c in text {
      if isHan(c) {
        flushRoman()
        han.append(c)
        continue
      }
      try flushHan()
      if let keys = punctuation[c] {
        flushRoman()
        parts.append(Part(text: String(c), source: .pinyin, keys: keys, composition: false))
        continue
      }
      guard
        c.unicodeScalars.allSatisfy({
          [8, 9, 10].contains($0.value) || (32...126).contains($0.value)
        })
      else { throw fail("Pasteboard-free typing does not yet support \(c)") }
      if c == "\u{8}" || c == "\t" || c == "\n" {
        flushRoman()
        parts.append(Part(text: String(c), source: .roman, keys: String(c), composition: false))
      } else {
        roman.append(c)
        if roman.utf8.count >= 180 { flushRoman() }
      }
    }
    try flushHan()
    flushRoman()
    return parts
  }
  /// Confirm the exact insertion/replacement or one real Backspace at the current selection.
  /// The AX service doesn't expose caret ranges, so it must be a single contiguous edit;
  /// no other field content may change. Actual caret/selection behavior stays with iOS.
  static func matchesEdit(before: String, after: String, keys: String) -> Bool {
    let a = Array(before)
    let b = Array(after)
    let insert = Array(keys)
    if keys == "\u{8}" {
      if a.isEmpty { return b.isEmpty }
      for i in 0..<a.count { if Array(a[..<i]) + Array(a[(i + 1)...]) == b { return true } }
      return false  // AX cannot distinguish a no-op at the beginning from lost input.
    }
    if keys == "\t" { return false }  // focus-changing controls require a separate agent action
    guard b.count >= insert.count else { return false }
    for i in 0...(b.count - insert.count) {
      guard Array(b[i..<(i + insert.count)]) == insert, i <= a.count,
        Array(a.prefix(i)) == Array(b.prefix(i))
      else { continue }
      let suffix = Array(b.dropFirst(i + insert.count))
      if suffix.count <= a.count - i && Array(a.suffix(suffix.count)) == suffix { return true }
    }
    return false
  }
  static func hasExpandedCandidates(_ tree: [String: Any]) -> Bool {
    let elements = tree["elements"] as? [[String: Any]] ?? []
    return ["词频", "部首", "笔画"].allSatisfy { label in
      elements.contains { $0["role"] as? String == "Button" && $0["label"] as? String == label }
    }
  }
  static func hasSoftwareKeyboard(_ tree: [String: Any]) -> Bool {
    (tree["elements"] as? [[String: Any]] ?? []).contains {
      $0["role"] as? String == "Key"
        && ["Next keyboard", "Hide keyboard"].contains($0["label"] as? String ?? "")
    }
  }
  static func hasCandidatePanel(_ tree: [String: Any]) -> Bool {
    let elements = tree["elements"] as? [[String: Any]] ?? []
    let collapsed = elements.contains {
      $0["role"] as? String == "Button" && $0["label"] as? String == "More suggestions"
    }
    let expanded = ["词频", "部首", "笔画"].allSatisfy { label in
      elements.contains { $0["role"] as? String == "Button" && $0["label"] as? String == label }
    }
    return collapsed || expanded
  }
  static func candidateLabels(_ tree: [String: Any]) -> [String] {
    (tree["elements"] as? [[String: Any]] ?? []).compactMap {
      guard $0["role"] as? String == "Key",
        ($0["trait_names"] as? [String] ?? []).contains("Keyboard Key")
      else { return nil }
      return $0["label"] as? String
    }
  }
  static func candidates(_ tree: [String: Any], matching text: String) -> [CGRect] {
    let elements = tree["elements"] as? [[String: Any]] ?? []
    // Require the observed hardware candidate-panel controls and Keyboard Key
    // traits; ordinary Chinese app labels are never selectable candidates.
    guard hasCandidatePanel(tree) else { return [] }
    return elements.compactMap { e in
      guard e["role"] as? String == "Key",
        (e["trait_names"] as? [String] ?? []).contains("Keyboard Key"),
        let label = e["label"] as? String, label.components(separatedBy: ", ").first == text
      else { return nil }
      let frame = rect(e["frame"])
      return frame.width > 0 && frame.height > 0 ? frame : nil
    }
  }
  static func hidPoint(_ frame: CGRect, screen: CGSize, orientation: Int) throws -> (Int, Int) {
    guard screen.width > 1, screen.height > 1, frame.midX >= 0, frame.midY >= 0,
      frame.midX < screen.width, frame.midY < screen.height
    else { throw fail("Candidate is outside the display") }
    let x = frame.midX / (screen.width - 1)
    let y = frame.midY / (screen.height - 1)
    let point: (Double, Double)
    switch orientation {
    case 1: point = (x, y)
    case 2: point = (1 - x, 1 - y)
    case 3: point = (1 - y, x)
    case 4: point = (y, 1 - x)
    default: throw fail("Unsupported display orientation")
    }
    return (Int((point.0 * 65535).rounded()), Int((point.1 * 65535).rounded()))
  }
  static func image(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw fail("Invalid native screenshot") }
    // Native screenshots can be 16-bit RGB. Vision's image reader rejects that
    // format on some OS versions. Materialize ordinary 8-bit RGBA first.
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw fail("Cannot decode screenshot") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let decoded = context.makeImage() else { throw fail("Cannot decode screenshot") }
    return decoded
  }
  private static func pixels(_ image: CGImage, crop: CGRect) -> [UInt8]? {
    guard let cropped = image.cropping(to: crop) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
    let drawn = bytes.withUnsafeMutableBytes { ptr -> Bool in
      guard
        let ctx = CGContext(
          data: ptr.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32))
      return true
    }
    return drawn ? bytes : nil
  }
  /// Find small, newly colored regions before OCR. Reading whole documents is
  /// slower and can fail in Vision's multilingual image reader on long notes.
  private static func markerRegions(
    _ old: CGImage, _ current: CGImage, field: CGRect, screen: CGSize
  ) -> [CGRect] {
    let width = 512
    let height = max(1, current.height * 512 / current.width)
    func raster(_ image: CGImage) -> [UInt8] {
      var data = [UInt8](repeating: 0, count: width * height * 4)
      data.withUnsafeMutableBytes { bytes in
        if let context = CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
          context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
      }
      return data
    }
    let a = raster(old)
    let b = raster(current)
    var mask = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        let rgb = [Int(b[i]), Int(b[i + 1]), Int(b[i + 2])]
        mask[y * width + x] =
          rgb.max()! > 120 && rgb.max()! - rgb.min()! > 80
          && abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1]))
            + abs(Int(a[i + 2]) - Int(b[i + 2])) > 100
      }
    }
    var regions: [CGRect] = []
    for start in mask.indices where mask[start] {
      var queue = [start]
      var cursor = 0
      mask[start] = false
      var minX = start % width
      var maxX = minX
      var minY = start / width
      var maxY = minY
      while cursor < queue.count {
        let value = queue[cursor]
        cursor += 1
        let x = value % width
        let y = value / width
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        where nx >= 0 && nx < width && ny >= 0 && ny < height {
          let next = ny * width + nx
          if mask[next] {
            mask[next] = false
            queue.append(next)
          }
        }
      }
      guard queue.count >= 8, maxX - minX < width * 4 / 5, maxY - minY < height / 5 else {
        continue
      }
      let scale = Double(current.width) / Double(width)
      regions.append(
        CGRect(
          x: Double(minX) * scale, y: Double(minY) * scale,
          width: Double(maxX - minX + 1) * scale, height: Double(maxY - minY + 1) * scale
        )
        .insetBy(dx: -60, dy: -30).intersection(
          CGRect(x: 0, y: 0, width: current.width, height: current.height)))
    }
    var merged: [CGRect] = []
    for region in regions {
      var combined = region
      while let index = merged.firstIndex(where: { $0.intersects(combined) }) {
        combined = combined.union(merged.remove(at: index))
      }
      merged.append(combined)
    }
    return merged.count <= 8 ? merged : []
  }
  static func sourceLabel(_ label: String) -> Source? {
    let value = label.lowercased().replacingOccurrences(of: " ", with: "")
    if value.contains("手写") || value.contains("handwriting") { return nil }
    if value == "拼" || value.contains("拼音") || value == "pinyin" { return .pinyin }
    if ["en", "enfr", "enus"].contains(value) || value == "english" || value.hasPrefix("english(") {
      return .roman
    }
    return nil
  }
  /// Verify the changed selection, without assuming a caret-relative position or
  /// a fixed iPad/iPhone switcher layout. A source name alone never authorizes input.
  static func sourceMarker(before: Data, after: Data, field: CGRect, screen: CGSize) throws
    -> Source?
  {
    let old = try image(before)
    let current = try image(after)
    guard old.width == current.width, old.height == current.height else { return nil }
    var found: [(Source, CGRect)] = []
    for region in markerRegions(old, current, field: field, screen: screen) {
      guard let cropImage = current.cropping(to: region) else { continue }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      // Revision 3 intermittently failed to create its compute operation on the
      // test Mac (E5RT code 13). Revision 2 supports both required languages.
      request.revision = VNRecognizeTextRequestRevision2
      request.usesLanguageCorrection = false
      request.recognitionLanguages = ["zh-Hans", "en-US"]
      request.customWords = ["拼", "ENFR", "ENUS", "EN"]
      do {
        try VNImageRequestHandler(cgImage: cropImage).perform([request])
      } catch {
        // Some small badge crops fail the multilingual recognizer. A fresh
        // English-only read can still verify an English badge; otherwise this
        // region remains unknown and cannot authorize typing.
        request.recognitionLanguages = ["en-US"]
        do { try VNImageRequestHandler(cgImage: cropImage).perform([request]) } catch { continue }
      }
      for observation in request.results ?? [] {
        guard let text = observation.topCandidates(1).first, text.confidence >= 0.25 else {
          continue
        }
        let pattern =
          #"(?:简体(?:中文)?[\s·—-]*)?拼音|拼|\bPinyin\b|\bEnglish(?:\s*\([^)]*\))?|E\s*N\s*F\s*R|E\s*N\s*U\s*S|\bE\s*N\b"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        for match in regex.matches(
          in: text.string, range: NSRange(text.string.startIndex..., in: text.string))
        {
          guard let range = Range(match.range, in: text.string),
            let bounds = try text.boundingBox(for: range)
          else { continue }
          guard let source = Self.sourceLabel(String(text.string[range])) else { continue }
          let b = bounds.boundingBox
          let box = CGRect(
            x: (region.minX + b.minX * region.width) / Double(current.width),
            y: (region.minY + (1 - b.maxY) * region.height) / Double(current.height),
            width: b.width * region.width / Double(current.width),
            height: b.height * region.height / Double(current.height))
          guard box.width < 0.7, box.height < 0.12 else { continue }
          let crop = CGRect(
            x: box.minX * Double(current.width), y: box.minY * Double(current.height),
            width: box.width * Double(current.width), height: box.height * Double(current.height)
          )
          .insetBy(dx: -8, dy: -8).intersection(
            CGRect(x: 0, y: 0, width: current.width, height: current.height))
          guard let a = pixels(old, crop: crop), let z = pixels(current, crop: crop) else {
            continue
          }
          var colored = 0
          var changed = 0
          for i in stride(from: 0, to: a.count, by: 4) {
            let rgb = [Int(z[i]), Int(z[i + 1]), Int(z[i + 2])]
            if rgb.max()! > 120 && rgb.max()! - rgb.min()! > 80 { colored += 1 }
            if abs(Int(a[i]) - Int(z[i])) + abs(Int(a[i + 1]) - Int(z[i + 1]))
              + abs(Int(a[i + 2]) - Int(z[i + 2])) > 100
            {
              changed += 1
            }
          }
          if colored > 300 && changed > 100 {
            let duplicate = found.contains { item in
              let overlap = item.1.intersection(box)
              let area = min(item.1.width * item.1.height, box.width * box.height)
              return item.0 == source && area > 0 && overlap.width * overlap.height / area > 0.5
            }
            if !duplicate { found.append((source, box)) }
          }
        }
      }
    }
    return found.count == 1 ? found[0].0 : nil
  }
}
