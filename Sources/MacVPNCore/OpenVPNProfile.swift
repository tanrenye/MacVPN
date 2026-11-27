import Foundation

package enum ProfileError: LocalizedError {
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// 将配置规范化为可交给 OpenVPN 的独立文件。
package struct OpenVPNProfile {
    package let data: Data
    package let server: String
    package let transport: String

    private static let certificates: Set<String> = [
        "ca", "cert", "key", "extra-certs", "pkcs12", "tls-auth", "tls-crypt", "tls-crypt-v2"
    ]
    private static let directives: Set<String> = [
        "client", "tls-client", "pull", "dev", "dev-type", "proto", "remote", "port", "rport",
        "remote-random", "remote-random-hostname", "resolv-retry", "nobind", "bind", "local", "lport",
        "connect-retry", "connect-retry-max", "connect-timeout", "server-poll-timeout",
        "persist-key", "persist-tun", "ping", "ping-restart", "ping-exit", "keepalive",
        "hand-window", "tran-window", "reneg-sec", "reneg-bytes", "reneg-pkts",
        "tls-version-min", "tls-version-max", "tls-cipher", "tls-ciphersuites", "tls-cert-profile",
        "remote-cert-tls", "remote-cert-ku", "remote-cert-eku", "verify-x509-name", "peer-fingerprint",
        "auth", "auth-nocache", "auth-token", "auth-user-pass", "static-challenge",
        "cipher", "data-ciphers", "data-ciphers-fallback", "compat-mode", "key-direction",
        "allow-compression", "compress", "comp-lzo", "comp-noadapt", "disable-dco",
        "tun-mtu", "tun-mtu-extra", "mssfix", "fragment", "explicit-exit-notify",
        "sndbuf", "rcvbuf", "txqueuelen", "fast-io", "socket-flags", "float",
        "topology", "ifconfig", "ifconfig-ipv6", "ifconfig-nowarn",
        "route", "route-ipv6", "route-gateway", "route-ipv6-gateway", "route-metric",
        "route-delay", "route-nopull", "redirect-gateway", "redirect-private", "block-ipv6",
        "dhcp-option", "dns", "pull-filter", "push-peer-info",
        "http-proxy", "http-proxy-option", "http-proxy-retry", "socks-proxy", "socks-proxy-retry",
        "verb", "mute", "mute-replay-warnings", "ignore-unknown-option", "auth-retry"
    ]
    private static let platformOptions: Set<String> = [
        "block-outside-dns", "register-dns", "windows-driver", "ip-win32", "route-method",
        "dhcp-renew", "dhcp-release", "windows-disable-def1", "machine-readable-output"
    ]
    private static let connectionOptions: Set<String> = [
        "remote", "proto", "port", "rport", "nobind", "bind", "local", "lport", "connect-retry",
        "connect-retry-max", "connect-timeout", "http-proxy", "http-proxy-option", "http-proxy-retry",
        "socks-proxy", "socks-proxy-retry", "explicit-exit-notify", "mssfix", "fragment", "tun-mtu"
    ]

    /// 只生成已识别的客户端指令，禁止配置加载脚本、插件或其他配置文件。
    package init(file: URL, allowExternalFiles: Bool = true, language: AppLanguage = .current) throws {
        let source = try Self.read(file, language: language)
        guard var configuration = String(data: source, encoding: .utf8) else {
            throw ProfileError.invalid(language.text("配置文件需要使用 UTF-8 编码。", "The profile must use UTF-8 encoding."))
        }
        if configuration.hasPrefix("\u{FEFF}") { configuration.removeFirst() }
        guard !configuration.unicodeScalars.contains(where: {
            $0.value < 32 && ![9, 10, 13].contains($0.value) || $0.value == 127
        }) else {
            throw ProfileError.invalid(language.text("配置文件包含无效控制字符。", "The profile contains invalid control characters."))
        }
        let lines = configuration.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        var inConnection = false
        var inlineFile: String?
        var hasClient = false
        var pullsOptions = false
        var hasDevice = false
        var configuredCipher: String?
        var hasCipherPolicy = false
        var firstRemote: [String]?
        var protocolName = "udp"

        for (index, sourceLine) in lines.enumerated() {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1

            if let tag = inlineFile {
                if line == "</\(tag)>" {
                    if tag != "auth-user-pass" { output.append(line) }
                    inlineFile = nil
                } else if line.hasPrefix("</\(tag)>") {
                    throw ProfileError.invalid(language.text("第 \(lineNumber) 行的内嵌文件结束标记无效。", "Line \(lineNumber): Invalid closing tag for an inline file."))
                } else if tag != "auth-user-pass" {
                    guard sourceLine.utf8.count < 240 else {
                        throw ProfileError.invalid(language.text("第 \(lineNumber) 行的内嵌证书内容过长。", "Line \(lineNumber): Inline certificate data is too long."))
                    }
                    output.append(sourceLine)
                }
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line == "</connection>", inConnection {
                inConnection = false
                output.append(line)
                continue
            }
            if line.first == "<", line.last == ">", !inConnection {
                let tag = String(line.dropFirst().dropLast())
                if tag == "connection" {
                    inConnection = true
                    output.append(line)
                    continue
                }
                guard Self.certificates.contains(tag) || tag == "auth-user-pass" else {
                    throw ProfileError.invalid(language.text("第 \(lineNumber) 行的内嵌区块 \(line) 暂不支持。", "Line \(lineNumber): Inline block \(line) is unsupported."))
                }
                inlineFile = tag
                output.append(tag == "auth-user-pass" ? "auth-user-pass" : line)
                continue
            }

            var fields = try Self.tokens(line, language: language)
            guard !fields.isEmpty else { continue }
            if fields.starts(with: ["setenv", "opt"]) { fields.removeFirst(2) }
            guard let option = fields.first else { continue }
            if Self.platformOptions.contains(option) { continue }
            if Self.certificates.contains(option), !inConnection {
                let supportsDirection = option == "tls-auth" && fields.count == 3
                guard allowExternalFiles, fields.count == 2 || supportsDirection else {
                    throw ProfileError.invalid(language.text("第 \(lineNumber) 行的 \(option) 文件参数无效。", "Line \(lineNumber): Invalid file argument for \(option)."))
                }
                let contents = try Self.readReference(fields[1], from: file, line: lineNumber, language: language)
                let encoded: String
                if option == "pkcs12" {
                    encoded = contents.base64EncodedString(options: .lineLength64Characters)
                } else {
                    guard let pem = String(data: contents, encoding: .utf8),
                          !pem.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }),
                          !pem.split(whereSeparator: \.isNewline).contains(where: {
                              $0.utf8.count >= 240 || $0.trimmingCharacters(in: .whitespaces).hasPrefix("</\(option)>")
                          }) else {
                        throw ProfileError.invalid(language.text("第 \(lineNumber) 行引用的 \(option) 文件格式无效。", "Line \(lineNumber): The referenced \(option) file has an invalid format."))
                    }
                    encoded = pem.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                }
                output += ["<\(option)>", encoded, "</\(option)>"]
                if supportsDirection {
                    guard ["0", "1"].contains(fields[2]) else {
                        throw ProfileError.invalid(language.text("第 \(lineNumber) 行的密钥方向必须是 0 或 1。", "Line \(lineNumber): Key direction must be 0 or 1."))
                    }
                    output.append("key-direction \(fields[2])")
                }
                continue
            }

            let allowed = inConnection ? Self.connectionOptions : Self.directives
            guard allowed.contains(option) else {
                throw ProfileError.invalid(language.text("第 \(lineNumber) 行的 OpenVPN 指令 \(option) 暂不支持。", "Line \(lineNumber): OpenVPN directive \(option) is unsupported."))
            }
            switch option {
            case "dev", "dev-type":
                guard fields.count == 2,
                      fields[1].range(of: option == "dev" ? "^u?tun[0-9]*$" : "^tun$",
                                      options: .regularExpression) != nil else {
                    throw ProfileError.invalid(language.text("此版本支持 TUN 配置。", "This version requires a TUN profile."))
                }
                if option == "dev" {
                    hasDevice = true
                    fields = ["dev", "tun"]
                }
            case "client":
                pullsOptions = true
                hasClient = true
            case "tls-client":
                hasClient = true
            case "pull":
                pullsOptions = true
            case "cipher":
                if fields.count == 2 { configuredCipher = fields[1].uppercased() }
            case "data-ciphers", "data-ciphers-fallback", "compat-mode":
                hasCipherPolicy = true
            case "remote":
                guard fields.count >= 2, !fields[1].isEmpty else {
                    throw ProfileError.invalid(language.text("第 \(lineNumber) 行缺少服务器地址。", "Line \(lineNumber): Missing VPN server address."))
                }
                if firstRemote == nil { firstRemote = fields }
            case "proto":
                if fields.count == 2, !inConnection { protocolName = fields[1] }
            case "auth-user-pass":
                fields = ["auth-user-pass"]
            case "auth-retry":
                continue
            case "http-proxy":
                guard fields.count <= 3 || ["auto", "auto-nct"].contains(fields[3]) else {
                    throw ProfileError.invalid(language.text("暂不支持从文件读取 HTTP 代理凭据。", "Loading HTTP proxy credentials from a file is unsupported."))
                }
            case "socks-proxy":
                guard fields.count <= 3 else {
                    throw ProfileError.invalid(language.text("暂不支持从文件读取 SOCKS 代理凭据。", "Loading SOCKS proxy credentials from a file is unsupported."))
                }
            default: break
            }
            let normalized = ([option] + fields.dropFirst().map(Self.quote)).joined(separator: " ")
            guard normalized.utf8.count < 240 else {
                throw ProfileError.invalid(language.text("第 \(lineNumber) 行的指令过长。", "Line \(lineNumber): The directive is too long."))
            }
            output.append(normalized)
        }

        guard inlineFile == nil, !inConnection else {
            throw ProfileError.invalid(language.text("配置中的内嵌区块没有关闭。", "An inline block in the profile is missing its closing tag."))
        }
        guard hasClient, let remote = firstRemote else {
            throw ProfileError.invalid(language.text("配置必须包含 client 或 tls-client，以及 remote 服务器。", "The profile must specify client or tls-client and a remote server."))
        }
        if !hasDevice { output.insert("dev tun", at: 0) }
        // 旧配置用 cipher 指定数据通道算法。保留现代协商顺序，并兼容其明确指定的 AES-CBC。
        if pullsOptions, !hasCipherPolicy, let cipher = configuredCipher,
           ["AES-128-CBC", "AES-192-CBC", "AES-256-CBC"].contains(cipher) {
            output.append("data-ciphers AES-256-GCM:AES-128-GCM:?CHACHA20-POLY1305:\(cipher)")
            output.append("data-ciphers-fallback \(cipher)")
        }
        let host = remote[1]
        let port = remote.count > 2 ? ":\(remote[2])" : ""
        server = host.contains(":") && !port.isEmpty ? "[\(host)]\(port)" : host + port
        transport = (remote.count > 3 ? remote[3] : protocolName).hasPrefix("tcp") ? "TCP" : "UDP"
        data = Data((output.joined(separator: "\n") + "\n").utf8)
        guard data.count <= 4_000_000 else { throw ProfileError.invalid(language.text("导入后的配置超过 4 MB。", "The imported profile exceeds 4 MB.")) }
    }

    /// 按 OpenVPN 的引号规则读取参数，再逐项重新编码。
    private static func tokens(_ line: String, language: AppLanguage) throws -> [String] {
        var result: [String] = []
        var value = ""
        var delimiter: Character?
        var started = false
        var escaped = false
        for character in line {
            if escaped {
                guard ["\\", "\"", " ", "\t"].contains(character) else {
                    throw ProfileError.invalid(language.text("配置包含无效的反斜杠转义。", "The profile contains an invalid backslash escape."))
                }
                value.append(character)
                escaped = false
            } else if character == "\\", delimiter != "'" {
                escaped = true
                started = true
            } else if let current = delimiter {
                if character == current { delimiter = nil } else { value.append(character) }
            } else if character == "\"" || character == "'" {
                guard !started else {
                    throw ProfileError.invalid(language.text("配置参数的引号位置无效。", "A profile argument has a misplaced quotation mark."))
                }
                delimiter = character
                started = true
            } else if character == " " || character == "\t" {
                if started { result.append(value) }
                value = ""
                started = false
            } else if !started, character == "#" || character == ";" {
                break
            } else {
                started = true
                value.append(character)
            }
        }
        guard !escaped, delimiter == nil else { throw ProfileError.invalid(language.text("配置参数的引号或转义不完整。", "A profile argument has an unclosed quote or an incomplete escape.")) }
        if started { result.append(value) }
        return result
    }

    package static func quote(_ argument: String) -> String {
        "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 配置从旧安装目录迁移时，绝对路径失效后可以使用配置旁边的同名文件。
    private static func readReference(_ path: String, from config: URL, line lineNumber: Int,
                                      language: AppLanguage) throws -> Data {
        let directory = config.deletingLastPathComponent()
        let reference = URL(fileURLWithPath: path, relativeTo: directory)
        var candidates = [reference]
        if path.hasPrefix("/") {
            let sibling = directory.appendingPathComponent(reference.lastPathComponent)
            if reference.standardizedFileURL != sibling.standardizedFileURL { candidates.append(sibling) }
        }
        for candidate in candidates {
            do {
                return try read(candidate, language: language)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                continue
            }
        }
        throw ProfileError.invalid(language.text("第 \(lineNumber) 行找不到「\(reference.lastPathComponent)」。请检查配置中的引用路径，或将文件放在配置旁边。", "Line \(lineNumber): Could not find “\(reference.lastPathComponent)”. Check the path in the profile or put the file next to the profile."))
    }

    private static func read(_ url: URL, language: AppLanguage) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 4_000_000 else {
            throw ProfileError.invalid(language.text("只能导入小于 4 MB 的普通配置或证书文件。", "Only regular profile or certificate files up to 4 MB can be imported."))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_000_001) ?? Data()
        guard data.count <= 4_000_000 else { throw ProfileError.invalid(language.text("文件超过 4 MB。", "The file exceeds 4 MB.")) }
        return data
    }
}
