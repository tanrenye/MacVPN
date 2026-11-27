import Foundation
import MacVPNCore
import Security

/// 一条连接的账号和密码。只在提交认证或写入钥匙串时使用。
struct VPNLogin: Codable {
    let username: String
    let password: String
}

enum CredentialsVault {
    private static let service = "local.macvpn.client.vpn-login"

    static func read(for profile: UUID) throws -> VPNLogin? {
        var attributes = query(profile)
        attributes[kSecReturnData] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { return nil }
        return try JSONDecoder().decode(VPNLogin.self, from: data)
    }

    static func save(_ login: VPNLogin, for profile: UUID) throws {
        let identity = query(profile)
        let data = try JSONEncoder().encode(login)
        var attributes = identity
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = AppLanguage.current.text("MacVPN VPN 登录", "MacVPN VPN Login")
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary))
        } else {
            try check(status)
        }
    }

    static func remove(for profile: UUID) throws {
        let status = SecItemDelete(query(profile) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func query(_ profile: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: profile.uuidString]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? AppLanguage.current.text("错误 \(status)", "Error \(status)")
            throw ProfileError.invalid(AppLanguage.current.text("无法访问 macOS 钥匙串。\(detail)", "Could not access macOS Keychain. \(detail)"))
        }
    }
}
