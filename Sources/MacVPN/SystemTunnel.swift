import CryptoKit
import Darwin
import Foundation
import MacVPNCore
import Security

/// GUI 通过受限 XPC 接口请求隧道服务，不向服务传递可执行路径或启动命令。
final class SystemTunnelEvents: NSObject, TunnelEvents {
    private let onExit: (Int32, String) -> Void

    init(onExit: @escaping (Int32, String) -> Void) {
        self.onExit = onExit
    }

    func tunnelExited(_ status: Int32, diagnostics: String) {
        onExit(status, diagnostics)
    }
}

enum SystemTunnel {
    private static let base = URL(fileURLWithPath: TunnelService.installation, isDirectory: true)
    private static let helper = Bundle.main.url(forAuxiliaryExecutable: "MacVPNTunnelHelper")
    private static let engine = Bundle.main.url(forAuxiliaryExecutable: "openvpn")
    private static let dns = Bundle.main.url(forResource: "dns-updown", withExtension: nil)

    static var isBundled: Bool { helper != nil && engine != nil && dns != nil }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: TunnelService.launchDaemon) }

    /// 只在首次使用或 GUI 的已授权签名变化时安装。安装后由 launchd 按需启动服务。
    static func prepare() async throws {
        let language = AppLanguage.current
        guard let helper, let engine, let dns else {
            throw ProfileError.invalid(language.text("应用中缺少连接服务文件。", "The app is missing connection service files."))
        }
        var app: SecCode?
        var staticApp: SecStaticCode?
        var signingInfo: CFDictionary?
        guard SecCodeCopySelf([], &app) == errSecSuccess, let app,
              SecCodeCopyStaticCode(app, [], &staticApp) == errSecSuccess, let staticApp,
              SecCodeCopySigningInformation(staticApp, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let cdHash = (signingInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              cdHash.count == 20 else {
            throw ProfileError.invalid(language.text(
                "无法验证 MacVPN 签名。请从打包的 MacVPN.app 启动。",
                "Could not verify the MacVPN signature. Open the packaged MacVPN.app."
            ))
        }
        let hash = cdHash.map { String(format: "%02x", $0) }.joined()
        let identity = base.appending(path: "authorized-client")
        if isInstalled, (try? String(contentsOf: identity, encoding: .utf8)) == "\(getuid()) \(hash)\n" { return }

        let artifacts = try [helper, engine, dns].flatMap { url in
            [url.path, SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()]
        }
        let changedFiles = language.text("MacVPN 安装文件在授权期间发生变化。",
                                        "The MacVPN installation files changed during authorization.")
        try await authorize(script: installScript, arguments: [String(getuid()), hash] + artifacts + [changedFiles])
    }

    static func remove() async throws {
        guard isInstalled else { return }
        try await authorize(script: #"""
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        lock="/Library/Application Support/.macvpn-install-lock"
        /bin/mkdir "$lock"
        trap '/bin/rmdir "$lock"' EXIT
        if /bin/launchctl print system/local.macvpn.tunnel >/dev/null 2>&1; then
            /bin/launchctl bootout system/local.macvpn.tunnel
        fi
        /bin/rm -f "/Library/LaunchDaemons/local.macvpn.tunnel.plist"
        /bin/rm -rf "/Library/Application Support/MacVPN" "/private/var/run/macvpn"
        """#, arguments: [])
    }

    static let authorizationScript = """
    use scripting additions

    on run argv
        with timeout of 2592000 seconds
            do shell script (item 1 of argv) with administrator privileges
        end timeout
    end run
    """

    private static func authorize(script: String, arguments: [String]) async throws {
        let quoted = ([script, "macvpn"] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -c " + quoted.joined(separator: " ")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", authorizationScript, command]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { process in
                let details = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if details.contains("(-128)") {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let reason = details.isEmpty
                        ? AppLanguage.current.text("无法完成连接服务的系统授权。", "Could not authorize the connection service.")
                        : details
                    continuation.resume(throwing: ProfileError.invalid(reason))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// 先在 root 私有目录校验三份发行文件，再切换 launchd 配置。失败时恢复原服务。
    private static let installScript = #"""
    set -euo pipefail
    umask 077
    uid="$1"
    hash="$2"
    [[ "$uid" =~ ^[1-9][0-9]*$ && "$hash" =~ ^[0-9a-f]{40}$ ]]
    parent="/Library/Application Support"
    base="$parent/MacVPN"
    plist="/Library/LaunchDaemons/local.macvpn.tunnel.plist"
    service="system/local.macvpn.tunnel"
    lock="$parent/.macvpn-install-lock"
    /bin/mkdir "$lock"
    stage=""
    switched=0
    moved=0
    had_service=0
    cleanup() {
        local status=$?
        if [[ "$status" != 0 && "$switched" == 1 ]]; then
            /bin/launchctl bootout "$service" >/dev/null 2>&1 || true
            if [[ "$moved" == 1 ]]; then /bin/rm -rf "$base"; fi
            if [[ -e "$stage/previous" ]]; then /bin/mv "$stage/previous" "$base"; fi
            if [[ -e "$stage/previous.plist" ]]; then
                /bin/mv -f "$stage/previous.plist" "$plist"
            else
                /bin/rm -f "$plist"
            fi
            if [[ "$had_service" == 1 ]]; then /bin/launchctl bootstrap system "$plist" || true; fi
        fi
        if [[ -n "$stage" ]]; then /bin/rm -rf "$stage"; fi
        /bin/rmdir "$lock"
    }
    trap cleanup EXIT
    stage=$(/usr/bin/mktemp -d "$parent/.macvpn-install.XXXXXXXX")
    /bin/mkdir "$stage/current"
    copy_verified() {
        /bin/cat "$1" > "$3"
        local actual
        actual=$(/usr/bin/shasum -a 256 "$3")
        if [[ "${actual%% *}" != "$2" ]]; then
            /usr/bin/printf '%s\n' "${9}" >&2
            exit 1
        fi
        /bin/chmod 755 "$3"
    }
    copy_verified "$3" "$4" "$stage/current/MacVPNTunnelHelper"
    copy_verified "$5" "$6" "$stage/current/openvpn"
    copy_verified "$7" "$8" "$stage/current/dns-updown"
    /usr/bin/printf '%s %s\n' "$uid" "$hash" > "$stage/current/authorized-client"
    /bin/chmod 644 "$stage/current/authorized-client"
    /bin/chmod 755 "$stage/current"
    /bin/cat > "$stage/current.plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
        <key>Label</key><string>local.macvpn.tunnel</string>
        <key>ProgramArguments</key><array>
            <string>/Library/Application Support/MacVPN/MacVPNTunnelHelper</string>
            <string>$uid</string><string>$hash</string>
        </array>
        <key>MachServices</key><dict><key>local.macvpn.tunnel</key><true/></dict>
    </dict></plist>
    PLIST
    /usr/bin/plutil -lint "$stage/current.plist" >/dev/null
    /usr/sbin/chown -R root:wheel "$stage/current" "$stage/current.plist"
    /bin/chmod 644 "$stage/current.plist"
    if [[ -e "$plist" ]]; then /bin/cp -p "$plist" "$stage/previous.plist"; fi
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
        /bin/launchctl bootout "$service"
        had_service=1
    fi
    switched=1
    if [[ -e "$base" ]]; then /bin/mv "$base" "$stage/previous"; fi
    /bin/mv "$stage/current" "$base"
    moved=1
    /bin/mv -f "$stage/current.plist" "$plist"
    /bin/launchctl bootstrap system "$plist"
    """#
}
