import Darwin
import Foundation
import MacVPNCore
import Security

private final class TunnelProcess {
    let owner: UUID
    let directory: URL
    let socket: URL
    let password: String
    let language: AppLanguage
    let process = Process()
    let output = Pipe()
    var diagnostics = Data()
    var starting: ((String?, String?, String?) -> Void)?
    let events: TunnelEvents

    init(owner: UUID, directory: URL, password: String, language: AppLanguage, events: TunnelEvents,
         reply: @escaping (String?, String?, String?) -> Void) {
        self.owner = owner
        self.directory = directory
        socket = directory.appending(path: "management")
        self.password = password
        self.language = language
        self.events = events
        starting = reply
    }
}

/// 连接服务只接受已授权账户和指定签名的 GUI。OpenVPN 始终读取服务自己的配置副本。
private final class TunnelListener: NSObject, NSXPCListenerDelegate {
    private let uid: uid_t
    private let username: String
    private let signingRequirement: String
    private let installation: URL
    private let runtime: URL
    private let queue = DispatchQueue(label: "MacVPN.TunnelHelper")
    private var active: TunnelProcess?

    init(uid: uid_t, username: String, hash: String, installation: URL, runtime: URL) {
        self.uid = uid
        self.username = username
        signingRequirement = "identifier \"local.macvpn.client\" and cdhash H\"\(hash)\""
        self.installation = installation
        self.runtime = runtime
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == uid else { return false }
        connection.setCodeSigningRequirement(signingRequirement)
        connection.exportedInterface = NSXPCInterface(with: TunnelControl.self)
        connection.remoteObjectInterface = NSXPCInterface(with: TunnelEvents.self)
        guard let events = connection.remoteObjectProxy as? TunnelEvents else { return false }
        let client = Client(listener: self, events: events)
        connection.exportedObject = client
        connection.invalidationHandler = { [weak self, id = client.id] in self?.stop(owner: id) }
        connection.resume()
        return true
    }

    private final class Client: NSObject, TunnelControl {
        let id = UUID()
        private weak var listener: TunnelListener?
        private let events: TunnelEvents

        init(listener: TunnelListener, events: TunnelEvents) {
            self.listener = listener
            self.events = events
        }

        func start(_ configuration: Data, language: String, reply: @escaping (String?, String?, String?) -> Void) {
            listener?.start(configuration, owner: id, language: AppLanguage(rawValue: language) ?? .chinese,
                            events: events, reply: reply)
        }
    }

    private func start(_ configuration: Data, owner: UUID, language: AppLanguage, events: TunnelEvents,
                       reply: @escaping (String?, String?, String?) -> Void) {
        queue.async { [self] in
            guard active == nil else {
                reply(nil, nil, language.text("已有 VPN 连接正在运行。", "A VPN connection is already running."))
                return
            }
            guard configuration.count <= 4_000_000 else {
                reply(nil, nil, language.text("VPN 配置超过 4 MB。", "The VPN profile exceeds 4 MB."))
                return
            }
            let directory = runtime.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                let files = FileManager.default
                try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let configFile = directory.appending(path: "client.ovpn")
                try configuration.write(to: configFile)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
                let checked = try OpenVPNProfile(file: configFile, allowExternalFiles: false, language: language)
                try checked.data.write(to: configFile)

                var random = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                    throw ProfileError.invalid(language.text("无法创建 OpenVPN 管理接口的临时密码。", "Could not create a temporary password for OpenVPN management."))
                }
                let password = random.map { String(format: "%02x", $0) }.joined()
                let passwordFile = directory.appending(path: "management-password")
                try Data((password + "\n").utf8).write(to: passwordFile)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
                let session = TunnelProcess(owner: owner, directory: directory, password: password,
                                            language: language, events: events, reply: reply)
                let process = session.process
                process.executableURL = installation.appending(path: "openvpn")
                process.currentDirectoryURL = directory
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "OPENSSL_CONF": "/dev/null"]
                process.arguments = [
                    "--pull-filter", "ignore", "setenv", "--config", "client.ovpn",
                    "--script-security", "2", "--dns-updown", installation.appending(path: "dns-updown").path.replacingOccurrences(of: " ", with: "\\ "),
                    "--management", session.socket.path, "unix", "management-password", "--management-client-user", username,
                    "--management-hold", "--management-query-passwords", "--auth-retry", "none", "--verb", "3"
                ]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = session.output
                process.standardError = session.output
                session.output.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    guard let self, let session, !data.isEmpty else { return }
                    self.queue.async {
                        session.diagnostics.append(data)
                        if session.diagnostics.count > 24_000 {
                            session.diagnostics.removeFirst(session.diagnostics.count - 24_000)
                        }
                    }
                }
                process.terminationHandler = { [weak self, weak session] process in
                    guard let self, let session else { return }
                    self.queue.async { self.finish(session, status: process.terminationStatus) }
                }
                active = session
                try process.run()
                waitForSocket(session, until: .now() + 5)
            } catch {
                active?.output.fileHandleForReading.readabilityHandler = nil
                active = nil
                try? FileManager.default.removeItem(at: directory)
                reply(nil, nil, error.localizedDescription)
            }
        }
    }

    /// 等管理 socket 监听后才交给 GUI，配置文件仍只有 root 可读。
    private func waitForSocket(_ session: TunnelProcess, until deadline: DispatchTime) {
        guard active === session, session.starting != nil else { return }
        if FileManager.default.fileExists(atPath: session.socket.path) {
            do {
                let files = FileManager.default
                try files.setAttributes([.posixPermissions: 0o666], ofItemAtPath: session.socket.path)
                try files.setAttributes([.posixPermissions: 0o711], ofItemAtPath: session.directory.path)
                session.starting?(session.socket.path, session.password, nil)
                session.starting = nil
            } catch {
                session.starting?(nil, nil, error.localizedDescription)
                session.starting = nil
                terminate(session)
            }
        } else if DispatchTime.now() >= deadline {
            session.starting?(nil, nil, session.language.text("OpenVPN 管理接口启动超时。", "Timed out waiting for the OpenVPN management interface."))
            session.starting = nil
            terminate(session)
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                self.waitForSocket(session, until: deadline)
            }
        }
    }

    private func stop(owner: UUID) {
        queue.async {
            guard let active = self.active, active.owner == owner else { return }
            self.terminate(active)
        }
    }

    private func terminate(_ session: TunnelProcess) {
        if session.process.isRunning { session.process.terminate() }
        queue.asyncAfter(deadline: .now() + 5) {
            guard self.active === session, session.process.isRunning else { return }
            kill(session.process.processIdentifier, SIGKILL)
        }
    }

    private func finish(_ session: TunnelProcess, status: Int32) {
        guard active === session else { return }
        active = nil
        session.output.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: session.directory)
        let diagnostics = String(decoding: session.diagnostics, as: UTF8.self)
        if let reply = session.starting {
            reply(nil, nil, diagnostics.isEmpty ? session.language.text("OpenVPN 启动失败（\(status)）。", "OpenVPN failed to start (exit code \(status)).") : diagnostics)
        } else {
            session.events.tunnelExited(status, diagnostics: diagnostics)
        }
    }
}

let installation = URL(fileURLWithPath: TunnelService.installation, isDirectory: true)
let runtime = URL(fileURLWithPath: TunnelService.runtime, isDirectory: true)
let arguments = CommandLine.arguments
guard geteuid() == 0, arguments.count == 3, let uid = uid_t(arguments[1]), uid != 0,
      let record = getpwuid(uid), arguments[2].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
    exit(1)
}
let username = String(cString: record.pointee.pw_name)
umask(0o077)
// 服务重启时复用运行目录，创建后统一检查所有者、类型和权限。
guard mkdir(runtime.path, 0o711) == 0 || errno == EEXIST else {
    let reason = String(cString: strerror(errno))
    NSLog("无法创建 MacVPN 运行目录：%@", reason)
    exit(1)
}
var metadata = stat()
guard lstat(runtime.path, &metadata) == 0, metadata.st_uid == 0,
      metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o022 == 0,
      chmod(runtime.path, 0o711) == 0 else {
    NSLog("无法验证 MacVPN 运行目录的所有者、类型或权限：%@", runtime.path)
    exit(1)
}
private let delegate = TunnelListener(uid: uid, username: username, hash: arguments[2], installation: installation, runtime: runtime)
let listener = NSXPCListener(machServiceName: TunnelService.name)
listener.delegate = delegate
listener.resume()
dispatchMain()
