import AppKit
import Foundation
import XCTest
@testable import CpKit

/// Scratch directories live under the package's own `.build`, so the suite never
/// writes outside the repository.
enum TestDirectory {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CpKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent(".build/cp-test-data", isDirectory: true)
    }

    static func make(_ name: String = #function) -> URL {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let directory = root.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// `UserDefaults` that keeps everything in memory. A real suite would write a
/// plist into ~/Library/Preferences on the first `set`.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Float, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ url: URL?, forKey defaultName: String) { values[defaultName] = url }
    override func integer(forKey defaultName: String) -> Int { (values[defaultName] as? NSNumber)?.intValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? NSNumber)?.boolValue ?? false }
    override func double(forKey defaultName: String) -> Double { (values[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { (values[defaultName] as? NSNumber)?.floatValue ?? 0 }
    override func array(forKey defaultName: String) -> [Any]? { values[defaultName] as? [Any] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
}

extension XCTestCase {
    /// Spins the main run loop until `condition` holds or `timeout` passes.
    /// Capture delivers on the main queue and the store expires secrets with
    /// timers, so tests have to let the loop turn.
    @MainActor
    func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }
}

/// Credential-shaped strings for the privacy tests, assembled at run time.
///
/// Written out as literals they match the patterns that secret scanners look
/// for, and a repository full of "leaked tokens" is a poor first impression
/// even when every one of them is made up. None of these has ever been valid.
enum FakeSecret {
    private static let filler = "abcdefghijklmnopqrstuvwxyz0123456789"

    static let github = "ghp" + "_" + filler
    static let openAI = "sk" + "-proj-" + filler
    static let slack = "xoxb" + "-123456789012-" + String(filler.prefix(12))
    static let gitLab = "glpat" + "-" + String(filler.prefix(20))
    /// Amazon's own documented example key.
    static let aws = "AKIA" + "IOSFODNN7EXAMPLE"
    /// Three base64url segments, shaped like a JWT and signed by nobody.
    static let jwt = ["eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "dBjftJeZ4CVPmB92K27uhbUJU1p1r"]
        .joined(separator: ".")
}

/// Ages, in seconds, that land on the day a test means whatever the clock says.
///
/// "Sixty seconds ago" is yesterday for the first minute after midnight, and
/// "twenty-six hours ago" is the day before yesterday until two in the
/// morning. A suite that groups by day has to measure from midnight instead.
enum Ago {
    private static var sinceMidnight: TimeInterval {
        let now = Date()
        return now.timeIntervalSince(Calendar.current.startOfDay(for: now))
    }

    /// A moment ago, and certainly today.
    static var today: TimeInterval { min(60, sinceMidnight / 2) }
    /// An hour before midnight: always yesterday.
    static var yesterday: TimeInterval { sinceMidnight + 3_600 }
}
