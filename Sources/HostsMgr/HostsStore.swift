import AppKit
import SwiftUI
import HostsCore
import UniformTypeIdentifiers

@MainActor
final class HostsStore: ObservableObject {
    @Published var profiles: [HostProfile] = []
    @Published var selection: UUID?
    @Published var systemText = ""
    @Published var busy = false
    @Published var message: String?
    @Published var notice = "配置保存在本机"
    @Published var lastApplied: Date?
    @Published var showPreview = false
    @Published var refreshing: UUID?
    private var saveTask: Task<Void, Never>?
    private var loaded = false
    let directory: URL
    private var dataURL: URL { directory.appendingPathComponent("profiles.json") }
    var activeProfiles: [HostProfile] { profiles.filter(\.enabled) }
    var selected: HostProfile? { profiles.first { $0.id == selection } }
    var preview: String { (try? HostsComposer.compose(system: systemText, profiles: profiles)) ?? systemText }
    var needsApply: Bool { preview != systemText }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HostsMgr")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dataURL.path) {
                profiles = try JSONDecoder().decode(HostsDocument.self, from: Data(contentsOf: dataURL)).profiles
            } else {
                profiles = [HostProfile(name: "本地开发", content: "# 本地服务\n# 取消下面的注释，添加你的域名\n# 127.0.0.1  app.test api.test\n"), HostProfile(name: "测试环境", content: "# 测试环境\n# 192.168.1.10  staging.example.com\n")]
            }
            loaded = true
            selection = profiles.first?.id
            reloadSystem()
        } catch { message = "读取配置失败：\(error.localizedDescription)" }
    }

    func reloadSystem() {
        do { systemText = try String(contentsOfFile: "/etc/hosts", encoding: .utf8) }
        catch { message = error.localizedDescription }
    }

    func persistSoon() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            save()
        }
    }

    func save() {
        guard loaded else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(HostsDocument(profiles: profiles)).write(to: dataURL, options: .atomic)
        } catch { message = "保存失败：\(error.localizedDescription)" }
    }

    func update(_ id: UUID, content: String) {
        guard !busy, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].content = content
        persistSoon()
    }

    func add(name: String, url: String?) {
        guard !busy else { return }
        let profile = HostProfile(name: name, content: url == nil ? "# \(name)\n" : "# 点击刷新，从远程地址获取内容\n", remoteURL: url)
        profiles.append(profile)
        selection = profile.id
        save()
        if url != nil { Task { await refresh(profile.id) } }
    }

    func toggle(_ id: UUID) {
        guard !busy, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].enabled.toggle()
        save()
    }

    func remove(_ id: UUID) {
        guard !busy else { return }
        profiles.removeAll { $0.id == id }
        if selection == id { selection = profiles.first?.id }
        save()
    }

    func rename(_ id: UUID, name: String) {
        guard !busy, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        save()
    }

    func apply(replacement: String? = nil) async {
        guard !busy, refreshing == nil else { return }
        busy = true
        defer { busy = false }
        do {
            save()
            let original = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            let next = try replacement ?? HostsComposer.compose(system: original, profiles: profiles)
            guard next != original else { systemText = original; notice = "已与系统 Hosts 同步"; return }
            let backupFolder = directory.appendingPathComponent("Backups")
            try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            let backup = backupFolder.appendingPathComponent("hosts-\(UUID().uuidString).txt")
            try original.write(to: backup, atomically: true, encoding: .utf8)
            try await Task.detached(priority: .userInitiated) { try HostsWriter.apply(expected: original, replacement: next) }.value
            reloadSystem()
            lastApplied = Date()
            notice = replacement == nil ? "已应用 · \(activeProfiles.count) 个配置" : "已恢复系统 Hosts 备份"
            // Retain the most recent 20 app backups; the initial system backup is separate.
            let backups = try FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: [.creationDateKey]).filter { $0.pathExtension == "txt" }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return left > right
            }
            for old in backups.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        } catch { message = error.localizedDescription; reloadSystem() }
    }

    func refresh(_ id: UUID) async {
        guard refreshing == nil, !busy, let profile = profiles.first(where: { $0.id == id }), let address = profile.remoteURL,
              let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
        refreshing = id
        defer { refreshing = nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw HostsError.message("远程服务器返回错误。") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 5 * 1024 * 1024 else { throw HostsError.message("远程配置超过 5 MB，已停止下载。") }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw HostsError.message("远程配置需要使用 UTF-8 编码。") }
            if let issue = HostsComposer.issues(text).first { throw HostsError.message(issue) }
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].content = text
            profiles[index].updatedAt = Date()
            save()
            notice = "远程配置已更新，应用后生效"
        } catch { message = error.localizedDescription }
    }

    func importFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 10 * 1024 * 1024 else { throw HostsError.message("导入文件不能超过 10 MB。") }
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "json" {
                let document = try JSONDecoder().decode(HostsDocument.self, from: data)
                // Imported entries are deliberately inactive and receive fresh identities.
                for entry in document.profiles {
                    profiles.append(HostProfile(name: entry.name, content: entry.content, remoteURL: entry.remoteURL))
                }
            } else {
                guard let text = String(data: data, encoding: .utf8) else { throw HostsError.message("请选择 UTF-8 文本。") }
                profiles.append(HostProfile(name: url.deletingPathExtension().lastPathComponent, content: text))
            }
            selection = profiles.last?.id
            save()
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }

    func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HostsMgr-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(HostsDocument(profiles: profiles)).write(to: url, options: .atomic)
        } catch { message = error.localizedDescription }
    }

    func migrateSwitchHosts() {
        guard !busy, refreshing == nil, loaded else { return }
        let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".SwitchHosts")
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            previewSwitchHosts(defaultURL, canChooseOther: true)
        } else {
            chooseSwitchHostsSource()
        }
    }

    private func chooseSwitchHostsSource() {
        let panel = NSOpenPanel()
        panel.title = "从 SwitchHosts 迁移"
        panel.message = "选择 SwitchHosts 数据目录，或 v3/v4/v5 导出的 JSON 备份。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        previewSwitchHosts(url, canChooseOther: false)
    }

    private func previewSwitchHosts(_ url: URL, canChooseOther: Bool) {
        do {
            let migration = try SwitchHostsImporter.load(from: url)
            let additions = migration.additions(to: profiles)
            let duplicateCount = migration.profiles.count - additions.count
            let alert = NSAlert()
            alert.messageText = "从 SwitchHosts 迁移"
            let names = additions.prefix(12).map { "• " + $0.name }.joined(separator: "\n")
            let more = additions.count > 12 ? "\n…另有 \(additions.count - 12) 个配置" : ""
            let warnings = migration.warnings.prefix(8).joined(separator: "\n")
            alert.informativeText = "来源：\(url.path)\n\n可新增 \(additions.count) 个配置，跳过 \(duplicateCount) 个重复配置。\n\(names)\(more)\n\n保留名称、内容、顺序与订阅地址；文件夹转为名称路径。迁移后全部停用，不修改系统 Hosts。原 SwitchHosts 的分组与设置不迁移。\n应用前请先在原应用中停用旧规则并退出，避免重复映射。" + (warnings.isEmpty ? "" : "\n\n注意（共 \(migration.warnings.count) 项）：\n" + warnings)
            alert.addButton(withTitle: additions.isEmpty ? "完成" : "迁移 \(additions.count) 个配置")
            alert.addButton(withTitle: "取消")
            if canChooseOther { alert.addButton(withTitle: "选择其他来源…") }
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { chooseSwitchHostsSource(); return }
            guard response == .alertFirstButtonReturn, !additions.isEmpty else { return }
            let previous = profiles
            let next = profiles + additions
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Commit to disk before updating UI; a failed save leaves the old profiles intact.
            let backup = directory.appendingPathComponent("profiles-before-migration-\(UUID().uuidString).json")
            try encoder.encode(HostsDocument(profiles: previous)).write(to: backup, options: .atomic)
            try encoder.encode(HostsDocument(profiles: next)).write(to: dataURL, options: .atomic)
            profiles = next
            selection = additions.first?.id
            notice = "已迁移 \(additions.count) 个配置 · 默认停用"
        } catch {
            if canChooseOther {
                let alert = NSAlert()
                alert.messageText = "无法读取本机 SwitchHosts 数据"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "选择其他来源…")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn { chooseSwitchHostsSource() }
            } else {
                message = "迁移失败：\(error.localizedDescription)"
            }
        }
    }

    func restoreBackup() {
        guard !busy, refreshing == nil else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = directory.appendingPathComponent("Backups")
        panel.message = "选择要恢复的系统 Hosts 备份"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10 * 1024 * 1024 else { throw HostsError.message("备份文件不能超过 10 MB。") }
            let content = try String(contentsOf: url, encoding: .utf8)
            let alert = NSAlert()
            alert.messageText = "恢复系统 Hosts？"
            alert.informativeText = "将用 \(url.lastPathComponent) 替换整个 /etc/hosts。当前内容会先备份；已选配置保持不变，可稍后重新应用。"
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { await apply(replacement: content) }
        } catch { message = error.localizedDescription }
    }
}
