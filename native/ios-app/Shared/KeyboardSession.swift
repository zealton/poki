import Foundation
import Darwin

/// A local, single-transaction mailbox. Both processes lock the same inode before
/// changing state, so a revoked offer cannot later become an executing command.
enum KeyboardSession {
    struct Piece: Codable, Equatable { var text: String; var pinyin: String?; var language: String }
    struct State: Codable, Equatable {
        var id: UUID
        var phase: String = "armed"
        var expires: Date
        var baseline: String
        var pieces: [Piece]
        var document: UUID?
        var error: String?
        var exited: Bool = false
    }
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PokiAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return root.appendingPathComponent("KeyboardSession", isDirectory: true)
    }
    static func access<T>(_ body: (inout State?) throws -> T) throws -> T {
        guard let directory else { throw failure("Poki keyboard shared container is unavailable") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure("Cannot open keyboard session lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw failure("Cannot lock keyboard session") }
        defer { flock(fd, LOCK_UN) }
        let file = directory.appendingPathComponent("session.json")
        var state: State?
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        }
        let original = state
        if let expiry = state?.expires, expiry <= Date() {
            state?.pieces = []
            state?.baseline = ""
        }
        let result = try body(&state)
        guard state != original else { return result }
        if let state {
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtection])
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        return result
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PokiKeyboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
