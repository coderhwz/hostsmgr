import XCTest
@testable import HostsCore

final class HostsCoreTests: XCTestCase {
    func testMergeKeepsSystemAndCombinesOnlyEnabledProfiles() throws {
        let system = "127.0.0.1 localhost\n::1 localhost\n# keep this\n"
        let profiles = [HostProfile(name: "Dev", content: "127.0.0.2 app.test", enabled: true), HostProfile(name: "Off", content: "192.168.0.1 off.test"), HostProfile(name: "QA", content: "::1 qa.test", enabled: true)]
        let merged = try HostsComposer.compose(system: system, profiles: profiles)
        XCTAssertTrue(merged.hasPrefix(system))
        XCTAssertTrue(merged.contains("app.test"))
        XCTAssertTrue(merged.contains("qa.test"))
        XCTAssertFalse(merged.contains("off.test"))
        XCTAssertEqual(try HostsComposer.compose(system: merged, profiles: profiles), merged)
        XCTAssertEqual(try HostsComposer.compose(system: merged, profiles: []), system)
    }

    func testMalformedBlocksAreRejected() {
        for text in [HostsComposer.begin, HostsComposer.end, "\(HostsComposer.end)\n\(HostsComposer.begin)", "\(HostsComposer.begin)\n\(HostsComposer.begin)\n\(HostsComposer.end)"] {
            XCTAssertThrowsError(try HostsComposer.unmanaged(text))
        }
    }

    func testUnmanagedTextAfterBlockSurvives() throws {
        let text = "first\n\(HostsComposer.begin)\nold\n\(HostsComposer.end)\nlast\n"
        XCTAssertEqual(try HostsComposer.unmanaged(text), "first\nlast\n")
    }

    func testValidation() {
        XCTAssertTrue(HostsComposer.issues("# comment\n127.0.0.1 app.test api.test # note\n::1 localhost\n0.0.0.0 ads.example\n").isEmpty)
        for text in ["999.1.2.3 app.test", "127.0.0.1", "127.0.0.1 https://bad.test", "::1 bad:8080", "::1 bad/path", "::1 -bad.test", HostsComposer.begin, "::1 test\0"] {
            XCTAssertFalse(HostsComposer.issues(text).isEmpty, text)
        }
    }

    func testWriterRoundTripAndConcurrentModificationProtection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appendingPathComponent("hosts ' test")
        let original = "127.0.0.1 localhost\n"
        let replacement = original + "# quotes ' \" $(touch SHOULD_NOT_EXIST) `whoami` \\ 中文\n::1 app.test\n"
        try original.write(to: hosts, atomically: true, encoding: .utf8)
        func run(_ expected: String, _ next: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HostsWriter.script(expected: expected, replacement: next, path: hosts.path)]
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run(original, replacement), 0)
        XCTAssertEqual(try String(contentsOf: hosts), replacement)
        XCTAssertEqual(try String(contentsOfFile: hosts.path + ".hostsmgr-backup"), original)
        XCTAssertEqual(try run(original, "unexpected"), 42)
        XCTAssertEqual(try String(contentsOf: hosts), replacement)
        XCTAssertEqual(try run(replacement, original), 0)
        XCTAssertEqual(try String(contentsOf: hosts), original)
    }

    func testWriterSupportsPayloadBeyondArgumentLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appendingPathComponent("hosts")
        let script = dir.appendingPathComponent("apply.sh")
        let original = "127.0.0.1 localhost\n"
        let content = String(repeating: "0.0.0.0 ads.example\n", count: 30_000)
        try original.write(to: hosts, atomically: true, encoding: .utf8)
        try HostsWriter.script(expected: original, replacement: content, path: hosts.path).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: hosts), content)
    }
}
