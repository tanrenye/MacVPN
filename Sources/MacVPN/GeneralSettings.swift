import AppKit
import MacVPNCore
import ServiceManagement
import SwiftUI

enum StartupPreferences {
    static let autoConnect = "autoConnectOnLaunch"
    static let silent = "silentLaunch"
    static let defaults: UserDefaults = {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [autoConnect: true, silent: true])
        return defaults
    }()
}

struct GeneralSettings: View {
    @ObservedObject var vpn: VPNController
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .chinese
    @AppStorage(StartupPreferences.autoConnect) private var autoConnect = true
    @AppStorage(StartupPreferences.silent) private var silent = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var errorMessage = ""
    @State private var showsError = false
    @State private var removing = false

    private var isRegistered: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(language.text("语言", "Language"), selection: $language) {
                Text("简体中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.menu)

            Group {
                Toggle(language.text("登录时启动 MacVPN", "Launch MacVPN at login"), isOn: Binding(get: { isRegistered }, set: setLaunchAtLogin))
                Toggle(language.text("启动时自动连接", "Connect automatically on launch"), isOn: $autoConnect)
                    .help(language.text("启动 MacVPN 时连接上次选中的配置。", "Connect using the last selected profile when MacVPN launches."))
                Toggle(language.text("静默启动", "Launch in the menu bar"), isOn: $silent)
                    .help(language.text("下次启动时隐藏主窗口，可从菜单栏打开。", "Hide the main window on launch. Open it from the menu bar."))
            }
            .toggleStyle(.checkbox)

            if loginStatus == .requiresApproval {
                Text(language.text("请在系统设置的「登录项」中允许 MacVPN。", "Allow MacVPN under Login Items in System Settings."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(language.text("打开登录项设置", "Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if SystemTunnel.isInstalled {
                Divider()
                Button(language.text("移除 MacVPN 连接服务…", "Remove MacVPN Connection Service…"), action: removeConnectionService)
                    .disabled(vpn.activeID != nil || removing)
                    .help(language.text("移除后，下次连接需要重新进行系统授权。", "The next connection will require administrator authorization."))
            }
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
        .alert(language.text("无法完成设置", "Unable to Change Settings"), isPresented: $showsError) {
            Button(language.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func removeConnectionService() {
        removing = true
        Task {
            defer { removing = false }
            do {
                try await SystemTunnel.remove()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                showsError = true
            }
        }
    }

    /// 以 macOS 的注册状态为准，用户在系统设置里的修改也会反映到开关。
    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        loginStatus = service.status
        guard isRegistered != enabled else { return }
        defer { loginStatus = service.status }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            loginStatus = service.status
            if isRegistered != enabled {
                errorMessage = error.localizedDescription
                showsError = true
            }
        }
    }
}
