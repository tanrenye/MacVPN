import AppKit
import CryptoKit
import Foundation
import MacVPNCore

enum ConnectionState {
    case idle, authorizing, connecting, authenticating, connected, reconnecting, disconnecting, failed

    func title(in language: AppLanguage) -> String {
        switch self {
        case .idle: return language.text("未连接", "Disconnected")
        case .authorizing: return language.text("等待系统授权", "Awaiting Authorization")
        case .connecting: return language.text("正在连接", "Connecting")
        case .authenticating: return language.text("等待凭据", "Waiting for Credentials")
        case .connected: return language.text("已连接", "Connected")
        case .reconnecting: return language.text("正在重连", "Reconnecting")
        case .disconnecting: return language.text("正在断开", "Disconnecting")
        case .failed: return language.text("连接失败", "Connection Failed")
        }
    }
}

/// OpenVPN 当前请求的凭据类型及 MFA 提示。
struct CredentialRequest: Identifiable {
    let id = UUID()
    let needsUsername: Bool
    let challenge: String?
    let challengeFlags: Int
}

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published var selection: UUID?
    @Published private(set) var state = ConnectionState.idle
    @Published private(set) var activeID: UUID?
    @Published private(set) var tunnelIP = ""
    @Published private(set) var connectedAt: Date?
    @Published private(set) var downloaded: UInt64 = 0
    @Published private(set) var uploaded: UInt64 = 0
    @Published private(set) var logs: [String] = []
    @Published var message: String?
    @Published var credentialRequest: CredentialRequest?
    @Published private(set) var engine: URL?
    @Published private(set) var lastProfileID: UUID?

    private let store = ProfileStore()
    private var session: UUID?
    private var sessionDirectory: URL?
    private var transport: ManagementSocket?
    private var rootConnection: NSXPCConnection?
    private var stopRequested = false
    private var failure: String?
    private var authType = ""
    private var pendingLogin: VPNLogin?
    private var usedSavedLogin = false

    var selected: Profile? { profiles.first { $0.id == selection } }
    var active: Profile? { profiles.first { $0.id == activeID } }
    var canStop: Bool { activeID != nil && state != .disconnecting }

    init() {
        refreshEngine()
        do {
            profiles = try store.load()
            let saved = UserDefaults.standard.string(forKey: "selectedProfile").flatMap(UUID.init(uuidString:))
            selection = profiles.first { $0.id == saved }?.id ?? profiles.first?.id
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshEngine() {
        if let builtIn = Bundle.main.url(forAuxiliaryExecutable: "openvpn"),
           FileManager.default.isExecutableFile(atPath: builtIn.path) {
            engine = builtIn
            return
        }
        let paths = [
            "/opt/homebrew/opt/openvpn/sbin/openvpn",
            "/usr/local/opt/openvpn/sbin/openvpn",
            "/opt/homebrew/sbin/openvpn",
            "/usr/local/sbin/openvpn"
        ]
        engine = paths.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    func select(_ id: UUID?) {
        selection = id
        UserDefaults.standard.set(id?.uuidString, forKey: "selectedProfile")
    }

    func importProfiles(_ urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            do {
                let profile = try store.importFile(url)
                profiles.append(profile)
                select(profile.id)
            } catch {
                errors.append("\(url.lastPathComponent) · \(error.localizedDescription)")
            }
        }
        sortProfiles()
        if !errors.isEmpty { message = errors.joined(separator: "\n") }
    }

    func rename(_ profile: Profile, to name: String) {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        do {
            var updated = profiles[index]
            updated.name = newName
            try store.rename(updated)
            profiles[index] = updated
            sortProfiles()
        } catch {
            message = error.localizedDescription
        }
    }

    func remove(_ profile: Profile) {
        guard profile.id != activeID else { return }
        do {
            try CredentialsVault.remove(for: profile.id)
            try store.remove(profile)
            profiles.removeAll { $0.id == profile.id }
            if selection == profile.id { select(profiles.first?.id) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func sortProfiles() {
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func forgetCredentials(for profile: Profile) {
        do { try CredentialsVault.remove(for: profile.id) } catch { message = error.localizedDescription }
    }

    /// 内置引擎通过连接服务启动，外部引擎沿用每次连接时的系统授权。
    func connect(_ profile: Profile) {
        guard session == nil else { return }
        refreshEngine()
        guard let engine else {
            message = AppLanguage.current.text("请先在终端运行 brew install openvpn，安装完成后可直接重试。", "Run brew install openvpn in Terminal, then try again.")
            return
        }
        let id = UUID()
        let directory = URL(fileURLWithPath: "/private/tmp/macvpn-\(id.uuidString)", isDirectory: true)
        do {
            let config = try store.configuration(for: profile.id)
            session = id
            stopRequested = false
            failure = nil
            logs = []
            downloaded = 0
            uploaded = 0
            connectedAt = nil
            tunnelIP = ""
            activeID = profile.id
            lastProfileID = profile.id
            state = .authorizing
            select(profile.id)
            if SystemTunnel.isBundled {
                startSystemTunnel(configuration: config, session: id)
                return
            }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            sessionDirectory = directory
            let snapshot = directory.appending(path: "client.ovpn")
            try config.write(to: snapshot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)

            let socket = try ManagementSocket(directory: directory, receive: { [weak self] line in
                DispatchQueue.main.async { [weak self] in self?.receive(line, session: id) }
            }, didClose: { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.managementClosed(session: id) }
            })
            transport = socket
            appendLog(AppLanguage.current.text("请求 macOS 管理员授权。", "Requesting macOS administrator authorization."))

            let outputURL = directory.appending(path: "output")
            try Data().write(to: outputURL)
            let output = try FileHandle(forUpdating: outputURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", SystemTunnel.authorizationScript, Self.launchCommand(engine: engine, config: snapshot, data: config, socket: socket.path)
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                try? output.seek(toOffset: 0)
                let data = (try? output.read(upToCount: 64_000)) ?? Data()
                try? output.close()
                let lines = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { [weak self] in self?.finished(id, status: status, output: lines) }
            }
            try process.run()
        } catch {
            transport?.close()
            try? FileManager.default.removeItem(at: directory)
            resetSession()
            state = .failed
            message = error.localizedDescription
        }
    }

    private func startSystemTunnel(configuration: Data, session id: UUID) {
        Task {
            do {
                try await SystemTunnel.prepare()
                guard id == session else { return }
                guard !stopRequested else {
                    finished(id, status: 0, output: "")
                    return
                }
                state = .connecting
                appendLog(AppLanguage.current.text("通过 MacVPN 连接服务启动 OpenVPN。", "Starting OpenVPN through the MacVPN connection service."))
                let connection = NSXPCConnection(machServiceName: TunnelService.name, options: .privileged)
                connection.remoteObjectInterface = NSXPCInterface(with: TunnelControl.self)
                connection.exportedInterface = NSXPCInterface(with: TunnelEvents.self)
                connection.exportedObject = SystemTunnelEvents { [weak self] status, diagnostics in
                    DispatchQueue.main.async { self?.finished(id, status: status, output: diagnostics) }
                }
                connection.invalidationHandler = { [weak self] in
                    DispatchQueue.main.async { self?.systemTunnelFailed(id, AppLanguage.current.text("MacVPN 连接服务已断开。", "The MacVPN connection service disconnected.")) }
                }
                rootConnection = connection
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                    DispatchQueue.main.async { self?.systemTunnelFailed(id, error.localizedDescription) }
                } as? TunnelControl
                guard let proxy else {
                    systemTunnelFailed(id, AppLanguage.current.text("无法打开 MacVPN 连接服务。", "Could not open the MacVPN connection service."))
                    return
                }
                proxy.start(configuration, language: AppLanguage.current.rawValue) { [weak self] path, password, detail in
                    DispatchQueue.main.async { self?.attachSystemTunnel(path, password: password, detail: detail, session: id) }
                }
            } catch is CancellationError {
                guard id == session else { return }
                stopRequested = true
                finished(id, status: 0, output: "")
            } catch {
                systemTunnelFailed(id, error.localizedDescription)
            }
        }
    }

    private func attachSystemTunnel(_ path: String?, password: String?, detail: String?, session id: UUID) {
        guard id == session else { return }
        guard !stopRequested else {
            finished(id, status: 0, output: "")
            return
        }
        guard let path, path.hasPrefix(TunnelService.runtime + "/"), let password, password.utf8.count == 64 else {
            systemTunnelFailed(id, detail ?? AppLanguage.current.text("连接服务没有返回 OpenVPN 管理接口。", "The connection service did not return an OpenVPN management interface."))
            return
        }
        do {
            transport = try ManagementSocket(connectingTo: path, password: password, receive: { [weak self] line in
                DispatchQueue.main.async { self?.receive(line, session: id) }
            }, didClose: { [weak self] in
                DispatchQueue.main.async { self?.managementClosed(session: id) }
            })
        } catch {
            systemTunnelFailed(id, error.localizedDescription)
        }
    }

    private func systemTunnelFailed(_ id: UUID, _ detail: String) {
        guard id == session else { return }
        if !stopRequested, failure == nil {
            failure = AppLanguage.current.text("无法启动或访问 MacVPN 连接服务。可在「设置」中移除服务后重新授权。", "Could not start or reach the MacVPN connection service. Remove the service in Settings, then reconnect to authorize it again.")
            for line in detail.split(whereSeparator: \.isNewline) { appendLog(String(line)) }
        }
        finished(id, status: 0, output: "")
    }

    func disconnect() {
        guard canStop else { return }
        let awaitingAuthorization = state == .authorizing
        stopRequested = true
        credentialRequest = nil
        state = .disconnecting
        if let rootConnection, transport == nil {
            rootConnection.invalidate()
        } else if awaitingAuthorization {
            transport?.close()
        } else {
            transport?.send(["signal SIGTERM"])
        }
    }

    func shutdown() {
        rootConnection?.invalidate()
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
    }

    func submit(_ request: CredentialRequest, username: String, password: String, response: String, remember: Bool) {
        guard credentialRequest?.id == request.id else { return }
        let valid = [username, password, response].allSatisfy { value in
            value.utf8.count < 192 && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        }
        guard valid else {
            message = AppLanguage.current.text("凭据过长或含无效控制字符。", "The credentials are too long or contain invalid control characters.")
            return
        }
        let login = VPNLogin(username: username, password: password)
        if remember, request.needsUsername, request.challenge == nil { pendingLogin = login }
        sendCredentials(request, login: login, response: response)
    }

    private func sendCredentials(_ request: CredentialRequest, login: VPNLogin, response: String = "") {
        let password = login.password
        var secret = password
        if request.challenge != nil {
            if request.challengeFlags & 2 != 0 {
                secret += response
            } else {
                secret = "SCRV1:\(Data(password.utf8).base64EncodedString()):\(Data(response.utf8).base64EncodedString())"
            }
        }
        let type = OpenVPNProfile.quote(authType)
        var commands: [String] = []
        if request.needsUsername { commands.append("username \(type) \(OpenVPNProfile.quote(login.username))") }
        commands.append("password \(type) \(OpenVPNProfile.quote(secret))")
        transport?.send(commands)
        credentialRequest = nil
        state = .connecting
    }

    func clearLogs() { logs = [] }

    /// 将 OpenVPN 管理协议事件映射为界面状态。只显示普通日志，不显示认证报文。
    private func receive(_ line: String, session id: UUID) {
        guard id == session else { return }
        if line.hasPrefix(">LOG:") {
            let fields = line.dropFirst(5).split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3 { appendLog(String(fields[2])) }
        } else if line.hasPrefix(">STATE:"), !stopRequested {
            updateState(line.dropFirst(7))
        } else if line.hasPrefix(">BYTECOUNT:") {
            let fields = line.dropFirst(11).split(separator: ",")
            if fields.count == 2 {
                downloaded = UInt64(fields[0]) ?? downloaded
                uploaded = UInt64(fields[1]) ?? uploaded
            }
        } else if line.hasPrefix(">HOLD:"), !stopRequested {
            state = .connecting
            transport?.send(["hold off", "hold release"])
        } else if line.hasPrefix(">PASSWORD:"), !stopRequested {
            requestCredentials(String(line.dropFirst(10)))
        } else if line.hasPrefix(">INFOMSG:WEB_AUTH:") || line.hasPrefix(">INFOMSG:OPEN_URL:") {
            fail(AppLanguage.current.text("此连接需要网页认证，当前版本只支持应用内输入凭据。", "This connection requires web authentication. Entering credentials in the app is the only supported method."))
        } else if !line.hasPrefix(">") {
            let fields = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3, Int(fields[0]) != nil { appendLog(String(fields[2])) }
        }
    }

    private func updateState(_ payload: Substring) {
        let parts = payload.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, failure == nil else { return }
        switch parts[1] {
        case "CONNECTED":
            state = .connected
            connectedAt = parts.first.flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)) ?? Date()
            tunnelIP = [3, 8].compactMap { index in parts.indices.contains(index) && !parts[index].isEmpty ? String(parts[index]) : nil }
                .joined(separator: "  ")
            if let login = pendingLogin, let id = activeID {
                pendingLogin = nil
                do { try CredentialsVault.save(login, for: id) } catch { message = error.localizedDescription }
            }
            usedSavedLogin = false
        case "RECONNECTING":
            state = .reconnecting
            connectedAt = nil
            tunnelIP = ""
        case "EXITING": state = .disconnecting
        default:
            if credentialRequest == nil, state != .reconnecting { state = .connecting }
        }
    }

    private func requestCredentials(_ prompt: String) {
        if prompt.hasPrefix("Verification Failed") {
            if prompt.contains("CRV1:") {
                fail(AppLanguage.current.text("服务器要求动态二次验证，当前版本暂不支持。", "The server requires dynamic multi-factor authentication, which this version does not support."))
            } else if usedSavedLogin, let id = activeID {
                do {
                    try CredentialsVault.remove(for: id)
                    fail(AppLanguage.current.text("已保存的 VPN 凭据验证失败。请重新连接并输入新凭据。", "The saved VPN credentials were rejected. Reconnect and enter new credentials."))
                } catch {
                    fail(AppLanguage.current.text("已保存的 VPN 凭据验证失败。\(error.localizedDescription)", "The saved VPN credentials were rejected. \(error.localizedDescription)"))
                }
            } else {
                fail(AppLanguage.current.text("VPN 凭据验证失败。", "The VPN credentials were rejected."))
            }
            return
        }
        guard prompt.hasPrefix("Need '"), let closing = prompt.dropFirst(6).firstIndex(of: "'") else { return }
        authType = String(prompt[prompt.index(prompt.startIndex, offsetBy: 6)..<closing])
        guard ["Auth", "Private Key"].contains(authType) else {
            fail(AppLanguage.current.text("服务器要求当前版本暂不支持的认证方式。", "The server requires an authentication method that this version does not support."))
            return
        }
        var challenge: String?
        var flags = 0
        if let marker = prompt.range(of: " SC:") {
            let parts = prompt[marker.upperBound...].split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, let mode = Int(parts[0]) { flags = mode; challenge = String(parts[1]) }
        }
        let request = CredentialRequest(needsUsername: authType == "Auth", challenge: challenge, challengeFlags: flags)
        if request.needsUsername, challenge == nil, !usedSavedLogin, let id = activeID {
            do {
                if let saved = try CredentialsVault.read(for: id) {
                    usedSavedLogin = true
                    sendCredentials(request, login: saved)
                    return
                }
            } catch {
                appendLog(AppLanguage.current.text("未能从钥匙串读取 VPN 凭据，请手动输入。", "Could not read VPN credentials from Keychain. Enter them manually."))
            }
        }
        credentialRequest = request
        state = .authenticating
    }

    private func fail(_ detail: String) {
        guard !stopRequested, failure == nil else { return }
        failure = detail
        appendLog(detail)
        transport?.send(["signal SIGTERM"])
        credentialRequest = nil
    }

    private func managementClosed(session id: UUID) {
        guard id == session else { return }
        credentialRequest = nil
        state = .disconnecting
        if rootConnection != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.systemTunnelFailed(id, AppLanguage.current.text("OpenVPN 管理连接已关闭。", "The OpenVPN management connection closed."))
            }
        }
    }

    private func finished(_ id: UUID, status: Int32, output: String) {
        guard id == session else { return }
        let cancelled = output.contains("(-128)")
        if !stopRequested, status != 0, !cancelled {
            for line in output.split(whereSeparator: \.isNewline) { appendLog(String(line)) }
        }
        let error = failure ?? (status != 0 && !stopRequested && !cancelled ? AppLanguage.current.text("OpenVPN 已退出，可在日志中查看原因。", "OpenVPN exited. See the connection log for details.") : nil)
        transport?.close()
        resetSession()
        state = error == nil ? .idle : .failed
        if let error { message = error }
    }

    private func resetSession() {
        session = nil
        rootConnection?.invalidate()
        rootConnection = nil
        sessionDirectory = nil
        transport = nil
        activeID = nil
        credentialRequest = nil
        authType = ""
        pendingLogin = nil
        usedSavedLogin = false
        connectedAt = nil
        tunnelIP = ""
    }

    private func appendLog(_ line: String) {
        guard !line.localizedCaseInsensitiveContains("auth-token"), !line.contains("CRV1:"),
              !line.contains("MANAGEMENT: CMD 'username") else { return }
        let time = Date.now.formatted(.dateTime.hour().minute().second())
        logs.append("\(time)  \(line)")
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    /// 在 root 私有目录核对已校验配置的摘要，再启动固定参数的 OpenVPN。
    private static func launchCommand(engine: URL, config: URL, data: Data, socket: String) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let script = #"""
        set -eu
        set -o pipefail
        umask 077
        work=$(/usr/bin/mktemp -d /private/tmp/macvpn-root.XXXXXXXX)
        trap '/bin/rm -rf -- "$work"' EXIT
        cd "$work"
        /bin/cat "$1" > client.ovpn
        actual=$(/usr/bin/shasum -a 256 client.ovpn)
        if [[ "${actual%% *}" != "$2" ]]; then
            echo "OpenVPN configuration changed before launch." >&2
            exit 1
        fi
        config_args=(--pull-filter ignore setenv --config client.ovpn)
        if [[ -n "$5" ]]; then
            /bin/cat "$5" > dns-updown
            actual=$(/usr/bin/shasum -a 256 dns-updown)
            if [[ "${actual%% *}" != "$6" ]]; then
                echo "OpenVPN DNS helper changed before launch." >&2
                exit 1
            fi
            /bin/chmod 700 dns-updown
            config_args+=(--script-security 2 --dns-updown ./dns-updown)
        fi
        "$3" "${config_args[@]}" --management "$4" unix --management-client \
            --management-hold --management-query-passwords --auth-retry none --verb 3 \
            2>&1 | /usr/bin/tail -n 25
        """#
        let dnsHelper = Bundle.main.url(forResource: "dns-updown", withExtension: nil)
        let dnsData = dnsHelper.flatMap { try? Data(contentsOf: $0) }
        let dnsDigest = dnsData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        let args = [script, "macvpn", config.path, digest, engine.path, socket, dnsHelper?.path ?? "", dnsDigest]
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin OPENSSL_CONF=/dev/null /bin/bash -c " + quoted.joined(separator: " ")
    }
}
