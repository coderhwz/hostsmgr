import SwiftUI
import AppKit
import HostsCore

@main
struct HostsMgrApp: App {
    @StateObject private var store = HostsStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("HostsMgr", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.save() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.reloadSystem() }
        }
        .defaultSize(width: 1060, height: 700)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入配置…") { store.importFile() }.keyboardShortcut("o")
                Button("从 SwitchHosts 迁移…") { store.migrateSwitchHosts() }
                Button("导出全部配置…") { store.exportFile() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("应用到系统") { Task { await store.apply() } }.keyboardShortcut("s").disabled(store.busy)
            }
        }
        MenuBarExtra("HostsMgr", systemImage: "network") {
            MenuContent(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct MenuContent: View {
    @ObservedObject var store: HostsStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("HostsMgr · \(store.activeProfiles.count) 个已选配置")
        Divider()
        ForEach(store.profiles) { profile in
            Button {
                store.toggle(profile.id)
                Task { await store.apply() }
            } label: {
                Label(profile.name, systemImage: profile.enabled ? "checkmark.circle.fill" : "circle")
            }.disabled(store.busy)
        }
        Divider()
        Button("应用所选配置") { Task { await store.apply() } }.disabled(store.busy)
        Button("打开 HostsMgr") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出") { store.save(); NSApp.terminate(nil) }.keyboardShortcut("q")
        .onChange(of: store.message) { message in
            if message != nil { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: HostsStore
    @State private var query = ""
    @State private var creating = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""
    @State private var remote = false
    @State private var address = ""
    private let accent = Color(red: 0.12, green: 0.58, blue: 0.50)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if let profile = store.selected { editor(profile) }
                else if store.selection == nil { systemEditor }
                footer
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("操作未完成", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("好", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .sheet(isPresented: $creating) { createSheet }
        .sheet(isPresented: $store.showPreview) { previewSheet }
        .alert("重命名配置", isPresented: $renaming) {
            TextField("配置名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let id = store.selection, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.rename(id, name: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        .alert("删除「\(store.selected?.name ?? "")」？", isPresented: $deleting) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { if let id = store.selection { store.remove(id) } }
        } message: { Text("删除后，点击“应用到系统”将移除它在系统中的规则。") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 42, height: 42).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("HostsMgr").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("你的网络，随心切换").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.top, 46).padding(.horizontal, 22).padding(.bottom, 26)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("搜索配置", text: $query).textFieldStyle(.plain)
            }.padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16)
            Button { store.selection = nil } label: {
                HStack {
                    Image(systemName: "desktopcomputer").frame(width: 20)
                    Text("系统 Hosts")
                    Spacer()
                    Image(systemName: "lock").font(.system(size: 10))
                }.padding(11).contentShape(Rectangle())
                    .background(store.selection == nil ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 18)
            HStack {
                Text("我的配置").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(store.profiles.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { beginCreate() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("新建配置")
            }.padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.profiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { profile in
                        profileRow(profile)
                    }
                    if store.profiles.isEmpty {
                        Text("添加你的第一个配置").font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 10)
            HStack {
                Button { beginCreate() } label: { Label("新建配置", systemImage: "plus") }
                Spacer()
                Menu {
                    Button("导入配置…", action: store.importFile)
                    Button("从 SwitchHosts 迁移…", action: store.migrateSwitchHosts)
                    Button("导出全部配置…", action: store.exportFile)
                    Divider()
                    Button("恢复系统 Hosts 备份…", action: store.restoreBackup)
                    Button("打开数据目录") { NSWorkspace.shared.open(store.directory) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            }.buttonStyle(.plain).padding(22)
            HStack(spacing: 6) {
                Image(systemName: "leaf").foregroundStyle(accent)
                Text("原生 Swift · 轻量运行").foregroundStyle(.secondary)
            }.font(.system(size: 10)).padding(.horizontal, 22).padding(.bottom, 18)
        }.background(.ultraThinMaterial)
    }

    private func profileRow(_ profile: HostProfile) -> some View {
        HStack(spacing: 10) {
            Button { store.selection = profile.id } label: {
                HStack(spacing: 10) {
                    Image(systemName: profile.remoteURL == nil ? "doc.text" : "cloud").foregroundStyle(store.selection == profile.id ? accent : .secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(profile.remoteURL == nil ? "本地配置" : "远程订阅").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle("启用 \(profile.name)", isOn: Binding(get: { profile.enabled }, set: { _ in store.toggle(profile.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(store.busy)
        }.padding(11).background(store.selection == profile.id ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("重命名…") { store.selection = profile.id; name = profile.name; renaming = true }
            Button("复制") { store.add(name: profile.name + " 副本", url: nil); if let id = store.selection { store.update(id, content: profile.content) } }
            Divider()
            Button("删除…", role: .destructive) { store.selection = profile.id; deleting = true }
        }.disabled(store.busy)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                Text(store.selected?.name ?? "系统 Hosts").font(.system(size: 23, weight: .semibold))
                Text(store.selected?.remoteURL ?? (store.selected == nil ? "/etc/hosts · 当前生效的系统配置" : "本地配置 · 编辑自动保存，应用后生效"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Button { store.reloadSystem(); store.showPreview = true } label: { Image(systemName: "eye") }.help("预览合并结果")
            Button { Task { await store.apply() } } label: {
                HStack(spacing: 7) {
                    if store.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "checkmark") }
                    Text(store.busy ? "正在应用…" : "应用到系统")
                }.padding(.horizontal, 5)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy || store.refreshing != nil)
        }.padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 24)
    }

    private func editor(_ profile: HostProfile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(profile.enabled ? accent : .secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(profile.enabled ? "已选择 · 应用后生效" : "未启用").foregroundStyle(.secondary)
                Spacer()
                if profile.remoteURL != nil {
                    if store.refreshing == profile.id { ProgressView().controlSize(.mini) }
                    Button { Task { await store.refresh(profile.id) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .disabled(store.refreshing != nil || store.busy)
                }
                Button { NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: findItem()) } label: { Image(systemName: "magnifyingglass") }.help("查找 ⌘F")
                Button { name = profile.name; renaming = true } label: { Image(systemName: "pencil") }.help("重命名")
            }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            CodeEditor(text: Binding(get: { store.profiles.first { $0.id == profile.id }?.content ?? "" }, set: { store.update(profile.id, content: $0) }), editable: profile.remoteURL == nil && !store.busy).id(profile.id)
            let issues = HostsComposer.issues(profile.content)
            if let first = issues.first {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(first).lineLimit(2)
                    Spacer()
                    Text("\(issues.count) 处问题")
                }.font(.caption).padding(12).background(Color.orange.opacity(0.08))
            }
            Divider()
            HStack {
                Text("\(profile.content.components(separatedBy: "\n").count) 行")
                Text("·")
                Text("\(HostsComposer.mappingCount(profile.content)) 条映射")
                Spacer()
                if let date = profile.updatedAt { Text("更新于 \(date.formatted(date: .omitted, time: .shortened))") }
                Text(profile.remoteURL == nil ? "UTF-8" : "远程 · 只读")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 10)
        }
    }

    private var systemEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Label("保留原有规则，仅管理 HostsMgr 区段", systemImage: "shield.lefthalf.filled")
                Spacer()
                Button("重新读取", action: store.reloadSystem).buttonStyle(.borderless)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            CodeEditor(text: .constant(store.systemText), editable: false)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: store.needsApply ? "circle.dotted" : "checkmark.circle.fill").foregroundStyle(store.needsApply ? .orange : accent)
            Text(store.needsApply ? "有待应用的更改" : "与系统配置一致").fontWeight(.medium)
            Spacer()
            Text(store.notice).foregroundStyle(.secondary)
        }.font(.system(size: 10)).padding(.horizontal, 28).padding(.vertical, 14).background(Color.primary.opacity(0.025))
    }

    private func beginCreate() { name = ""; address = ""; remote = false; creating = true }
    private func findItem() -> NSMenuItem { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; return item }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("新建配置").font(.title2.weight(.semibold))
            Picker("类型", selection: $remote) { Text("本地配置").tag(false); Text("远程订阅").tag(true) }.pickerStyle(.segmented)
            TextField("配置名称，例如：本地开发", text: $name).textFieldStyle(.roundedBorder)
            if remote {
                TextField("https://example.com/hosts", text: $address).textFieldStyle(.roundedBorder)
                Text("远程内容只读，手动刷新；更新后点击应用生效。").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("取消") { creating = false }.keyboardShortcut(.cancelAction)
                Button("创建") { store.add(name: name.trimmingCharacters(in: .whitespacesAndNewlines), url: remote ? address.trimmingCharacters(in: .whitespacesAndNewlines) : nil); creating = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!validNewProfile)
            }
        }.padding(28).frame(width: 400)
    }

    private var validNewProfile: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !remote { return true }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    }

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用预览").font(.title2.weight(.semibold))
                    Text("\(store.activeProfiles.count) 个配置将合并写入 /etc/hosts").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { store.showPreview = false }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            CodeEditor(text: .constant(store.preview), editable: false)
        }.frame(width: 700, height: 500)
    }
}
