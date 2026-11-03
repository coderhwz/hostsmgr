import Foundation

public enum HostsWriter {
    private static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // Both payloads are embedded as base64. No profile text is evaluated as shell code.
    // Expected content is checked AFTER authorization, since the dialog may stay open.
    public static func script(expected: String, replacement: String, path: String = "/etc/hosts") -> String {
        let expected64 = Data(expected.utf8).base64EncodedString()
        let next64 = Data(replacement.utf8).base64EncodedString()
        let target = quote(path)
        return """
        set -eu
        target=\(target)
        actual=$(/usr/bin/base64 < "$target" | /usr/bin/tr -d '\\n')
        [ "$actual" = \(quote(expected64)) ] || { echo 'Hosts 已被其他程序修改，请重新应用。' >&2; exit 42; }
        [ ! -L "$target" ] || { echo '拒绝写入符号链接 Hosts。' >&2; exit 43; }
        tmp=$(/usr/bin/mktemp "${target}.hostsmgr.XXXXXX")
        trap '/bin/rm -f "$tmp"' EXIT
        /bin/cp -p "$target" "$tmp"
        /usr/bin/base64 -D > "$tmp" <<'HOSTSMGR_PAYLOAD'
        \(next64)
        HOSTSMGR_PAYLOAD
        if [ ! -e "${target}.hostsmgr-backup" ]; then /bin/cp -p "$target" "${target}.hostsmgr-backup"; fi
        /bin/mv -f "$tmp" "$target"
        if [ "$target" = /etc/hosts ]; then
            /usr/bin/dscacheutil -flushcache || true
            /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
        fi
        """
    }

    public static func apply(expected: String, replacement: String) throws {
        // Pass only the script path through argv: large blocklists exceed macOS ARG_MAX.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HostsMgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("apply.sh")
        try script(expected: expected, replacement: replacement).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let shell = "/bin/sh " + quote(file.path)
        let appleString = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(appleString)\" with administrator privileges"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self)
            if message.contains("-128") { throw HostsError.message("已取消授权，系统 Hosts 未更改。") }
            throw HostsError.message(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
