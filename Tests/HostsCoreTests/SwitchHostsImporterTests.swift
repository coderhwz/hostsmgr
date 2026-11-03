import XCTest
@testable import HostsCore

final class SwitchHostsImporterTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ value: Any, _ path: String, at root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]).write(to: url)
    }

    func testLegacyDirectoryPreservesOrderAndContentWithoutEnabling() throws {
        try fixture { root in
            try write([
                ["id": "0", "title": "系统", "type": "local"],
                ["id": "folder", "type": "folder", "title": "开发", "children": [
                    ["id": "b", "title": "B", "on": true],
                    ["id": "a", "title": "A", "type": "remote", "url": "https://example.com/hosts"]
                ]],
                ["id": "empty", "title": "Empty"],
                ["id": "g", "title": "Group", "type": "group", "include": ["a"]]
            ] as [[String: Any]], "data/list/tree.json", at: root)
            try write(["1", "2"], "data/collection/hosts/ids.json", at: root)
            try write(["id": "a", "content": "::1 a.test\r\n"], "data/collection/hosts/data/1.json", at: root)
            try write(["id": "b", "content": "127.0.0.1 b.test\n"], "data/collection/hosts/data/2.json", at: root)
            let result = try SwitchHostsImporter.load(from: root)
            XCTAssertEqual(result.profiles.map(\.name), ["开发 / B", "开发 / A", "Empty"])
            XCTAssertEqual(result.profiles.map(\.content), ["127.0.0.1 b.test\n", "::1 a.test\n", ""])
            XCTAssertTrue(result.profiles.allSatisfy { !$0.enabled })
            XCTAssertEqual(result.profiles[1].remoteURL, "https://example.com/hosts")
            XCTAssertEqual(result.warnings.count, 1)
            XCTAssertEqual(result.additions(to: [result.profiles[0]]).count, 2)
            XCTAssertTrue(result.additions(to: result.profiles).isEmpty)
        }
    }

    func testV3V4AndV5Backups() throws {
        try fixture { root in
            let item: [String: Any] = ["id": "test", "title": "Test", "type": "local", "on": true]
            let formats: [[String: Any]] = [
                ["version": [3, 3, 12], "list": [["id": 12, "title": "Test", "where": "local", "content": "::1 app.test"]]],
                ["version": [4, 2, 0], "data": ["list": ["tree": [item]], "collection": ["hosts": ["data": [["id": "test", "content": "::1 app.test"]]]]]],
                ["format": "switchhosts-backup", "schemaVersion": 1, "manifest": ["format": "switchhosts-data", "root": [item]], "entries": ["test": "::1 app.test"]]
            ]
            for format in formats {
                try write(format, "backup.json", at: root)
                let result = try SwitchHostsImporter.load(from: root.appendingPathComponent("backup.json"))
                XCTAssertEqual(result.profiles.count, 1)
                XCTAssertEqual(result.profiles[0].content, "::1 app.test")
                XCTAssertFalse(result.profiles[0].enabled)
            }
        }
    }

    func testV5DirectoryAndUnsafeContentPath() throws {
        try fixture { root in
            let item: [String: Any] = ["id": "remote", "title": "Remote", "type": "remote", "source": ["url": "https://example.com/hosts"], "contentFile": "entries/remote.hosts"]
            try write(["format": "switchhosts-data", "schemaVersion": 1, "root": [item]], "manifest.json", at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("entries"), withIntermediateDirectories: true)
            try "::1 remote.test".write(to: root.appendingPathComponent("entries/remote.hosts"), atomically: true, encoding: .utf8)
            let result = try SwitchHostsImporter.load(from: root)
            XCTAssertEqual(result.profiles[0].remoteURL, "https://example.com/hosts")
            XCTAssertEqual(result.profiles[0].content, "::1 remote.test")
            var bad = item
            bad["contentFile"] = "../secret"
            try write(["format": "switchhosts-data", "root": [bad]], "manifest.json", at: root)
            XCTAssertThrowsError(try SwitchHostsImporter.load(from: root))
        }
    }

    func testIncompleteV5AndUnknownFormatFailWithoutPartialImport() throws {
        try fixture { root in
            try write(["format": "switchhosts-backup", "manifest": ["format": "switchhosts-data", "root": [["id": "a", "title": "A"]]], "entries": [:]], "backup.json", at: root)
            XCTAssertThrowsError(try SwitchHostsImporter.load(from: root.appendingPathComponent("backup.json")))
            try write(["profiles": []], "backup.json", at: root)
            XCTAssertThrowsError(try SwitchHostsImporter.load(from: root.appendingPathComponent("backup.json")))
        }
    }

    func testRealLocalDataReadOnlyWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["HOSTSMGR_SWITCHHOSTS_TEST_PATH"] else { throw XCTSkip("未指定本机只读验证目录") }
        let root = URL(fileURLWithPath: path)
        let result = try SwitchHostsImporter.load(from: root)
        XCTAssertFalse(result.profiles.isEmpty)
        XCTAssertTrue(result.profiles.allSatisfy { !$0.enabled })
        XCTAssertTrue(result.profiles.allSatisfy { !$0.content.isEmpty })
        print("Read-only local migration verified: \(result.profiles.count) profiles, \(result.warnings.count) warnings")
    }
}
