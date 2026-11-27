import AppKit
import MacVPNCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vpn = VPNController()
    let startsSilently = StartupPreferences.defaults.bool(forKey: StartupPreferences.silent)
    private var legacyWindow: NSWindow?
    private var pendingImports: [URL] = []
    private var finishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if #unavailable(macOS 15), !startsSilently { showLegacyWindow() }
        let autoConnect = StartupPreferences.defaults.bool(forKey: StartupPreferences.autoConnect)
        if autoConnect, let profile = vpn.selected { vpn.connect(profile) }
        if !pendingImports.isEmpty {
            vpn.importProfiles(pendingImports)
            pendingImports.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // 启动时打开的文件不参与本次自动连接，先使用已有的配置。
        if finishedLaunching {
            vpn.importProfiles(urls)
        } else {
            pendingImports.append(contentsOf: urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        vpn.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if #unavailable(macOS 15), !flag { showLegacyWindow() }
        return true
    }

    func applicationDidUpdate(_ notification: Notification) {
        // SwiftUI 自行打开主窗口时也要显示 Dock 图标，例如关闭了「静默启动」。
        if NSApp.activationPolicy() == .accessory,
           NSApp.windows.contains(where: { $0.isVisible && isOperationWindow($0) }) {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, isOperationWindow(closing) else { return }
        let hasOtherWindow = NSApp.windows.contains { window in
            window !== closing && (window.isVisible || window.isMiniaturized) && isOperationWindow(window)
        }
        if !hasOtherWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func isOperationWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.sheetParent == nil && window.parent == nil
    }

    /// macOS 14 的 SwiftUI 窗口不能禁用启动显示，按需创建主窗口。
    func showLegacyWindow() {
        if legacyWindow == nil {
            let controller = NSHostingController(rootView: Dashboard(vpn: vpn))
            let window = NSWindow(contentViewController: controller)
            window.title = "MacVPN"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 760, height: 560)
            window.setContentSize(NSSize(width: 940, height: 665))
            window.center()
            legacyWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        legacyWindow?.makeKeyAndOrderFront(nil)
    }
}

@main
@MainActor
struct MacVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .chinese

    var body: some Scene {
        if #available(macOS 15, *) {
            Window("MacVPN", id: "connections") {
                Dashboard(vpn: delegate.vpn)
                    .frame(minWidth: 760, minHeight: 560)
            }
            .defaultSize(width: 940, height: 665)
            .defaultLaunchBehavior(delegate.startsSilently ? .suppressed : .presented)
            .restorationBehavior(delegate.startsSilently ? .disabled : .automatic)
        }

        MenuBarExtra {
            VPNMenu(vpn: delegate.vpn, delegate: delegate)
        } label: {
            VPNMenuLabel(vpn: delegate.vpn)
        }

        Settings {
            GeneralSettings(vpn: delegate.vpn)
                .onChange(of: language) { _, value in updateImportCommand(in: value) }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(importCommandTitle(in: language)) { openProfiles(delegate.vpn) }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func importCommandTitle(in language: AppLanguage) -> String {
        language.text("导入 OpenVPN 配置…", "Import OpenVPN Profiles…")
    }

    /// SwiftUI 不会即时刷新系统「文件」菜单中已创建的导入命令。
    private func updateImportCommand(in language: AppLanguage) {
        let titles = [importCommandTitle(in: .chinese), importCommandTitle(in: .english)]
        let items = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).flatMap(\.items)
        let command = items?.first { $0.keyEquivalent == "o" && titles.contains($0.title) }
        command?.title = importCommandTitle(in: language)
    }
}

private struct VPNMenuLabel: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .chinese
    @ObservedObject var vpn: VPNController

    var body: some View {
        Image(nsImage: vpn.state == .connected ? MenuBarIcon.connected : MenuBarIcon.inactive)
            .accessibilityLabel("MacVPN · \(vpn.state.title(in: language))")
    }
}

@MainActor
private func openProfiles(_ vpn: VPNController) {
    let language = AppLanguage.current
    let panel = NSOpenPanel()
    panel.title = language.text("导入 OpenVPN 配置", "Import OpenVPN Profiles")
    panel.prompt = language.text("导入", "Import")
    panel.allowedContentTypes = ["ovpn", "conf"].compactMap { UTType(filenameExtension: $0) }
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if let window = NSApp.keyWindow, window.isVisible, window.attachedSheet == nil {
        panel.beginSheetModal(for: window) { reply in
            if reply == .OK { vpn.importProfiles(panel.urls) }
        }
    } else {
        panel.begin { reply in
            if reply == .OK { vpn.importProfiles(panel.urls) }
        }
    }
}

private struct VPNMenu: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .chinese
    @ObservedObject var vpn: VPNController
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(menuStatus)
        if vpn.credentialRequest != nil {
            Button(language.text("输入 VPN 凭据…", "Enter VPN Credentials…"), action: showWindow)
        }
        if vpn.canStop {
            Button(language.text("断开连接", "Disconnect"), action: vpn.disconnect)
        }
        if vpn.activeID == nil {
            ForEach(vpn.profiles) { profile in
                Button(language.text("连接 \(profile.name)", "Connect to \(profile.name)")) {
                    showWindow()
                    vpn.connect(profile)
                }
            }
        }
        Divider()
        Button(language.text("打开 MacVPN", "Open MacVPN"), action: showWindow)
        Button(language.text("导入配置…", "Import Profiles…")) {
            showWindow()
            openProfiles(vpn)
        }
        Button(language.text("设置…", "Settings…")) {
            NSApp.setActivationPolicy(.regular)
            openSettings()
            NSApp.activate()
        }
        Divider()
        Button(language.text("退出 MacVPN", "Quit MacVPN")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var menuStatus: String {
        if let active = vpn.active { return "\(active.name) · \(vpn.state.title(in: language))" }
        return vpn.state.title(in: language)
    }

    private func showWindow() {
        if #available(macOS 15, *) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "connections")
        } else {
            delegate.showLegacyWindow()
        }
        NSApp.activate()
    }
}

private struct Dashboard: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .chinese
    @ObservedObject var vpn: VPNController
    @State private var renameProfile: Profile?
    @State private var newName = ""
    @State private var removeProfile: Profile?
    @State private var showEngineHelp = false
    @State private var logVisible = true

    private let accent = Color(red: 0.08, green: 0.59, blue: 0.54)

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 206, ideal: 238, max: 300)
        } detail: {
            Group {
                if let profile = vpn.selected {
                    detail(profile)
                } else {
                    emptyState
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { openProfiles(vpn) } label: {
                        Label(language.text("导入配置", "Import Profiles"), systemImage: "plus")
                    }
                    .help(language.text("导入 OpenVPN 配置", "Import OpenVPN Profiles"))
                }
            }
        }
        .tint(accent)
        .alert("MacVPN", isPresented: Binding(get: { vpn.message != nil }, set: { if !$0 { vpn.message = nil } })) {
            Button(language.text("好", "OK"), role: .cancel) { vpn.message = nil }
        } message: { Text(vpn.message ?? "") }
        .alert(language.text("重命名连接", "Rename Connection"), isPresented: Binding(
            get: { renameProfile != nil }, set: { if !$0 { renameProfile = nil } }
        )) {
            TextField(language.text("连接名称", "Connection Name"), text: $newName)
            Button(language.text("保存", "Save")) {
                if let profile = renameProfile { vpn.rename(profile, to: newName) }
                renameProfile = nil
            }
            Button(language.text("取消", "Cancel"), role: .cancel) { renameProfile = nil }
        }
        .confirmationDialog(language.text("移除「\(removeProfile?.name ?? "")」？", "Remove “\(removeProfile?.name ?? "")”?"), isPresented: Binding(
            get: { removeProfile != nil }, set: { if !$0 { removeProfile = nil } }
        ), titleVisibility: .visible) {
            Button(language.text("移除配置", "Remove Profile"), role: .destructive) {
                if let profile = removeProfile { vpn.remove(profile) }
                removeProfile = nil
            }
        } message: {
            Text(language.text("将删除 MacVPN 保存在本机的配置副本。", "This deletes the copy of the profile stored by MacVPN."))
        }
        .sheet(item: $vpn.credentialRequest) { request in
            CredentialsView(request: request, vpn: vpn, language: language)
                .interactiveDismissDisabled()
        }
        .onAppear(perform: vpn.refreshEngine)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text("MacVPN").font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 15)

            List(selection: Binding(get: { vpn.selection }, set: vpn.select)) {
                Section(language.text("连接", "Connections")) {
                    ForEach(vpn.profiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.id == vpn.activeID && vpn.state == .connected ? "lock.shield.fill" : "lock.shield")
                                .foregroundStyle(profile.id == vpn.activeID ? accent : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(profile.server).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .tag(profile.id)
                        .contextMenu { profileActions(profile) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                vpn.refreshEngine()
                showEngineHelp.toggle()
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(vpn.engine == nil ? Color.orange : accent).frame(width: 7, height: 7)
                    Text(vpn.engine == nil
                         ? language.text("需要安装 OpenVPN", "OpenVPN required")
                         : language.text("OpenVPN 已就绪", "OpenVPN ready"))
                        .font(.caption)
                    Spacer()
                    Image(systemName: "info.circle").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(14)
            .popover(isPresented: $showEngineHelp, arrowEdge: .trailing) {
                engineHelp.padding(18).frame(width: 330)
            }
        }
    }

    private var engineHelp: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(vpn.engine == nil
                 ? language.text("安装 OpenVPN", "Install OpenVPN")
                 : language.text("OpenVPN 引擎", "OpenVPN Engine"))
                .font(.headline)
            if let engine = vpn.engine {
                Text(engine.path).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(language.text("在终端运行以下命令，安装完成后重新检查。", "Run this command in Terminal, then check again.")).foregroundStyle(.secondary)
                Text("brew install openvpn")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button(language.text("重新检查", "Check Again"), action: vpn.refreshEngine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 39, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 82, height: 82)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 23))
            Text(language.text("添加 VPN 连接", "Add a VPN Connection")).font(.system(size: 25, weight: .semibold))
            Text(language.text("导入管理员提供的 .ovpn 或 .conf 文件。", "Import an .ovpn or .conf file from your administrator."))
                .foregroundStyle(.secondary)
            Button { openProfiles(vpn) } label: { Label(language.text("导入配置", "Import Profiles"), systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func detail(_ profile: Profile) -> some View {
        let isActive = vpn.activeID == profile.id
        let isCurrent = vpn.lastProfileID == profile.id
        let displayedState = isActive || (isCurrent && vpn.state == .failed) ? vpn.state : .idle
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(profile.name).font(.system(size: 30, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Menu { profileActions(profile) } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(language.text("连接操作", "Connection Actions"))
            }

            HStack(spacing: 14) {
                Image(systemName: displayedState == .connected ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(statusColor(displayedState))
                    .frame(width: 48, height: 48)
                    .background(statusColor(displayedState).opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayedState.title(in: language)).font(.headline)
                    Text("\(profile.server)  ·  \(profile.transport)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    if isActive { vpn.disconnect() } else { vpn.connect(profile) }
                } label: {
                    Label(
                        isActive ? language.text("断开", "Disconnect") : language.text("连接", "Connect"),
                        systemImage: isActive ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(isActive ? .secondary : accent)
                .disabled(isActive ? !vpn.canStop : vpn.activeID != nil)
            }
            .padding(16)
            .background(card)

            HStack(spacing: 10) {
                metric(language.text("隧道地址", "Tunnel Address"), icon: "point.3.filled.connected.trianglepath.dotted",
                       value: isActive && !vpn.tunnelIP.isEmpty ? vpn.tunnelIP : "—")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let time = isActive ? vpn.connectedAt : nil
                    let seconds = time.map { max(0, Int(context.date.timeIntervalSince($0))) }
                    metric(language.text("连接时长", "Duration"), icon: "clock", value: seconds.map {
                        String(format: "%02d:%02d:%02d", $0 / 3600, $0 / 60 % 60, $0 % 60)
                    } ?? "—")
                }
                metric(language.text("接收", "Received"), icon: "arrow.down", value: isCurrent ? bytes(vpn.downloaded) : "—")
                metric(language.text("发送", "Sent"), icon: "arrow.up", value: isCurrent ? bytes(vpn.uploaded) : "—")
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        logVisible.toggle()
                    } label: {
                        Label(language.text("连接日志", "Connection Log"), systemImage: logVisible ? "chevron.down" : "chevron.right")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Group {
                        Button(language.text("复制", "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vpn.logs.joined(separator: "\n"), forType: .string)
                        }
                        Button(language.text("清空", "Clear"), action: vpn.clearLogs)
                    }
                    .disabled(!isCurrent || vpn.logs.isEmpty)
                }
                .buttonStyle(.borderless)

                if logVisible {
                    if isCurrent, !vpn.logs.isEmpty {
                        ScrollView {
                            Text(vpn.logs.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                    } else {
                        Text(language.text("此连接暂无日志。", "No logs for this connection yet.")).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card)
            if !logVisible { Spacer(minLength: 0) }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(Color(nsColor: .controlBackgroundColor))
            .strokeBorder(.quaternary.opacity(0.45), lineWidth: 1)
    }

    private func metric(_ label: String, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(label, systemImage: icon).foregroundStyle(.secondary).font(.caption)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(card)
    }

    @ViewBuilder
    private func profileActions(_ profile: Profile) -> some View {
        Button(language.text("重命名…", "Rename…")) {
            newName = profile.name
            renameProfile = profile
        }
        Button(language.text("清除记住的 VPN 凭据", "Forget Saved VPN Credentials")) { vpn.forgetCredentials(for: profile) }
            .disabled(vpn.activeID == profile.id)
        Button(language.text("移除配置…", "Remove Profile…"), role: .destructive) { removeProfile = profile }
            .disabled(vpn.activeID == profile.id)
    }

    private func statusColor(_ state: ConnectionState) -> Color {
        switch state {
        case .idle: return .secondary
        case .connected: return accent
        case .failed: return .red
        default: return .orange
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }
}

private struct CredentialsView: View {
    let request: CredentialRequest
    @ObservedObject var vpn: VPNController
    let language: AppLanguage
    @State private var username = ""
    @State private var password = ""
    @State private var response = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(request.needsUsername
                 ? language.text("输入 VPN 凭据", "Enter VPN Credentials")
                 : language.text("输入私钥密码", "Enter Private Key Password"))
                .font(.title3.weight(.semibold))
            if let profile = vpn.active { Text(profile.name).foregroundStyle(.secondary) }
            if request.needsUsername { TextField(language.text("用户名", "Username"), text: $username) }
            SecureField(
                request.needsUsername
                    ? language.text("密码", "Password")
                    : language.text("私钥密码", "Private Key Password"),
                text: $password
            )
            if request.needsUsername, request.challenge == nil {
                Toggle(language.text("在钥匙串中记住 VPN 凭据", "Remember VPN credentials in Keychain"), isOn: $remember)
                    .toggleStyle(.checkbox)
            }
            if let challenge = request.challenge {
                Text(challenge).font(.callout)
                if request.challengeFlags & 1 == 0 {
                    SecureField(language.text("验证码", "Verification Code"), text: $response)
                } else {
                    TextField(language.text("验证码", "Verification Code"), text: $response)
                }
            }
            HStack {
                Spacer()
                Button(language.text("取消", "Cancel"), action: vpn.disconnect).keyboardShortcut(.cancelAction)
                Button(language.text("继续", "Continue")) {
                    vpn.submit(request, username: username, password: password, response: response, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((request.needsUsername && username.isEmpty) || (request.challenge != nil && response.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 390)
    }
}
