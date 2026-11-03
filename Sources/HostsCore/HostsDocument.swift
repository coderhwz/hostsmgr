import Foundation
import Darwin

public struct HostProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var content: String
    public var enabled: Bool
    public var remoteURL: String?
    public var updatedAt: Date?

    public init(id: UUID = UUID(), name: String, content: String = "# 在这里添加 IP 和域名\n", enabled: Bool = false, remoteURL: String? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.enabled = enabled
        self.remoteURL = remoteURL
    }
}

public struct HostsDocument: Codable {
    public var profiles: [HostProfile]
    public init(profiles: [HostProfile] = []) { self.profiles = profiles }
}

public enum HostsError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public enum HostsComposer {
    public static let begin = "# >>> HostsMgr managed section >>>"
    public static let end = "# <<< HostsMgr managed section <<<"

    // Remove exactly one complete managed block; refuse malformed markers to avoid data loss.
    public static func unmanaged(_ text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0] == begin }
        let ends = lines.indices.filter { lines[$0] == end }
        if starts.isEmpty && ends.isEmpty { return text }
        guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else {
            throw HostsError.message("系统 Hosts 的管理区段不完整，请先检查区段标记。")
        }
        var remaining = lines
        remaining.removeSubrange(starts[0]...ends[0])
        return remaining.joined(separator: "\n")
    }

    public static func compose(system: String, profiles: [HostProfile]) throws -> String {
        let base = try unmanaged(system)
        let active = profiles.filter(\.enabled)
        guard !active.isEmpty else { return base }
        for profile in active {
            let problems = issues(profile.content)
            if let first = problems.first {
                throw HostsError.message("「\(profile.name)」\(first)")
            }
        }
        let blocks = active.map { "# Profile: \($0.name.replacingOccurrences(of: "\n", with: " "))\n\($0.content.trimmingCharacters(in: .newlines))" }
        return base + (base.isEmpty || base.hasSuffix("\n") ? "" : "\n") + begin + "\n" + blocks.joined(separator: "\n\n") + "\n" + end + "\n"
    }

    public static func issues(_ content: String) -> [String] {
        var result: [String] = []
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            if line == begin || line == end {
                result.append("第 \(index + 1) 行包含保留的管理标记")
                continue
            }
            if line.contains("\0") { result.append("第 \(index + 1) 行包含空字符"); continue }
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = body.split(whereSeparator: \.isWhitespace)
            guard !parts.isEmpty else { continue }
            var v4 = in_addr()
            var v6 = in6_addr()
            let ip = String(parts[0])
            let validIP = ip.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
            if !validIP || parts.count < 2 {
                result.append("第 \(index + 1) 行需要有效的 IPv4/IPv6 地址和域名")
            } else if parts.dropFirst().contains(where: { !validHostname(String($0)) }) {
                result.append("第 \(index + 1) 行包含无效域名（请勿填写协议、端口或路径）")
            }
        }
        return result
    }

    private static func validHostname(_ hostname: String) -> Bool {
        let name = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
        }
    }

    public static func mappingCount(_ text: String) -> Int {
        text.split(separator: "\n").reduce(0) { count, line in
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return count + max(0, body.split(whereSeparator: \.isWhitespace).count - 1)
        }
    }
}
