import Foundation

public struct SwitchHostsMigration {
    public var profiles: [HostProfile]
    public var warnings: [String]

    public func additions(to existing: [HostProfile]) -> [HostProfile] {
        var result: [HostProfile] = []
        for profile in profiles where !(existing + result).contains(where: {
            $0.name == profile.name && $0.content == profile.content && $0.remoteURL == profile.remoteURL
        }) { result.append(profile) }
        return result
    }
}

public enum SwitchHostsImporter {
    public static func load(from url: URL) throws -> SwitchHostsMigration {
        var reader = Reader()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HostsError.message("找不到 SwitchHosts 数据，请选择数据目录或导出的 JSON。")
        }
        var tree: [[String: Any]]
        var contents: [String: String] = [:]
        var entriesDirectory: URL?
        var inline = false
        var allowMissingContent = false
        if isDirectory.boolValue {
            let manifest = url.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                tree = try manifestTree(reader.json(manifest))
                entriesDirectory = url
            } else {
                tree = try nodes(reader.json(url.appendingPathComponent("data/list/tree.json")))
                allowMissingContent = true
                let collection = url.appendingPathComponent("data/collection/hosts")
                let ids = try reader.json(collection.appendingPathComponent("ids.json")) as? [String]
                guard let ids else { throw invalid() }
                for id in ids {
                    let path = try safePath("data/\(id).json", within: collection)
                    guard let row = try reader.json(path) as? [String: Any] else { throw invalid() }
                    try addRow(row, to: &contents)
                }
            }
        } else {
            guard let data = try reader.json(url) as? [String: Any] else { throw invalid() }
            if data["format"] as? String == "switchhosts-backup" {
                guard (data["schemaVersion"] as? Int ?? 1) == 1 else { throw invalid() }
                tree = try manifestTree(data["manifest"] as Any)
                guard let entries = data["entries"] as? [String: String] else { throw invalid() }
                contents = entries
            } else if let version = data["version"] as? [Int], version.first == 4 {
                guard let inner = data["data"] as? [String: Any], let list = inner["list"] as? [String: Any],
                      let collection = inner["collection"] as? [String: Any], let hosts = collection["hosts"] as? [String: Any],
                      let rows = hosts["data"] as? [[String: Any]] else { throw invalid() }
                tree = try nodes(list["tree"] as Any)
                allowMissingContent = true
                for row in rows { try addRow(row, to: &contents) }
            } else if let version = data["version"] as? [Int], version.first == 3 {
                tree = try nodes(data["list"] as Any)
                inline = true
            } else { throw invalid() }
        }
        var result = SwitchHostsMigration(profiles: [], warnings: [])
        var seen = Set<String>()
        func visit(_ items: [[String: Any]], parents: [String], depth: Int) throws {
            guard depth < 32 else { throw invalid() }
            for node in items {
                let id = try identifier(node["id"])
                if id == "0" || node["is_sys"] as? Bool == true || node["isSys"] as? Bool == true { continue }
                guard seen.insert(id).inserted, seen.count <= 10_000 else { throw invalid() }
                let title = node["title"] as? String ?? "未命名配置"
                let name = (parents + [title]).joined(separator: " / ")
                let kind = node["type"] as? String ?? node["where"] as? String ?? "local"
                if kind == "folder" {
                    try visit(try nodes(node["children"] ?? []), parents: parents + [title], depth: depth + 1)
                    continue
                }
                guard kind == "local" || kind == "remote" else {
                    result.warnings.append("未导入「\(name)」：暂不支持 \(kind) 类型。")
                    continue
                }
                let content: String
                if let root = entriesDirectory {
                    let path = try safePath(node["contentFile"] as? String ?? "entries/\(id).hosts", within: root)
                    // Only Hosts content may be read, never arbitrary files referenced by a manifest.
                    let entries = root.resolvingSymlinksInPath().appendingPathComponent("entries").standardizedFileURL.path + "/"
                    guard path.path.hasPrefix(entries) else { throw invalid() }
                    content = try reader.text(path)
                } else if inline {
                    if let value = node["content"], !(value is String) { throw invalid() }
                    content = node["content"] as? String ?? ""
                } else {
                    // Legacy PotDb creates content records lazily for untouched empty profiles.
                    // A v5 backup, however, must carry every entry explicitly.
                    if let text = contents[id] { content = text }
                    else if allowMissingContent { content = "" }
                    else { throw invalid() }
                }
                let source = node["source"] as? [String: Any]
                let rawURL = source?["url"] as? String ?? node["url"] as? String
                var remoteURL: String?
                if kind == "remote" {
                    if let rawURL, let parsed = URL(string: rawURL), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil {
                        remoteURL = rawURL
                    } else {
                        result.warnings.append("「\(name)」缺少有效 HTTP(S) 订阅地址，已保留为本地配置。")
                    }
                }
                let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                result.profiles.append(HostProfile(name: name, content: normalized, remoteURL: remoteURL))
            }
        }
        try visit(tree, parents: [], depth: 0)
        return result
    }

    private static func nodes(_ value: Any) throws -> [[String: Any]] {
        guard let nodes = value as? [[String: Any]] else { throw invalid() }
        return nodes
    }

    private static func manifestTree(_ value: Any) throws -> [[String: Any]] {
        guard let manifest = value as? [String: Any], manifest["format"] as? String == "switchhosts-data",
              (manifest["schemaVersion"] as? Int ?? 1) == 1 else { throw invalid() }
        return try nodes(manifest["root"] as Any)
    }

    private static func identifier(_ value: Any?) throws -> String {
        if let id = value as? String, !id.isEmpty { return id }
        if let id = value as? Int { return String(id) }
        throw invalid()
    }

    private static func addRow(_ row: [String: Any], to contents: inout [String: String]) throws {
        let id = try identifier(row["id"])
        guard let content = row["content"] as? String, contents[id] == nil else { throw invalid() }
        contents[id] = content
    }

    private static func safePath(_ relative: String, within root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let path = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), path.path.hasPrefix(base.path + "/") else { throw invalid() }
        return path
    }

    private static func invalid() -> HostsError {
        .message("SwitchHosts 数据格式不受支持或不完整。请选择完整的数据目录，或 v3/v4/v5 导出的 JSON 备份。")
    }

    private struct Reader {
        var remaining = 50 * 1024 * 1024
        mutating func data(_ url: URL) throws -> Data {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10 * 1024 * 1024, size <= remaining else {
                throw HostsError.message("迁移数据过大：单文件上限 10 MB，总读取上限 50 MB。")
            }
            let data = try Data(contentsOf: url)
            remaining -= data.count
            return data
        }
        mutating func json(_ url: URL) throws -> Any {
            try JSONSerialization.jsonObject(with: data(url), options: [.fragmentsAllowed])
        }
        mutating func text(_ url: URL) throws -> String {
            guard let text = String(data: try data(url), encoding: .utf8) else { throw invalid() }
            return text
        }
    }
}
