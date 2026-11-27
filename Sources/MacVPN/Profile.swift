import Foundation
import MacVPNCore

/// 保存在本机的连接名称及服务器摘要。证书和配置单独存放。
struct Profile: Codable, Identifiable {
    let id: UUID
    var name: String
    let server: String
    let transport: String
}

struct ProfileStore {
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "MacVPN/Profiles", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load() throws -> [Profile] {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url.appending(path: "Profile.json")))
                guard profile.id == id else { throw ProfileError.invalid(AppLanguage.current.text("配置索引的标识无效。", "The profile index contains an invalid identifier.")) }
                return profile
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importFile(_ file: URL) throws -> Profile {
        let configuration = try OpenVPNProfile(file: file)
        let profile = Profile(id: UUID(), name: file.deletingPathExtension().lastPathComponent,
                              server: configuration.server, transport: configuration.transport)
        let files = FileManager.default
        let staging = directory.appending(path: ".\(profile.id)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let config = staging.appending(path: "client.ovpn")
        try configuration.data.write(to: config)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        try JSONEncoder().encode(profile).write(to: staging.appending(path: "Profile.json"))
        try files.moveItem(at: staging, to: folder(for: profile.id))
        return profile
    }

    func rename(_ profile: Profile) throws {
        try JSONEncoder().encode(profile).write(to: folder(for: profile.id).appending(path: "Profile.json"), options: .atomic)
    }

    func remove(_ profile: Profile) throws {
        try FileManager.default.removeItem(at: folder(for: profile.id))
    }

    func configuration(for id: UUID) throws -> Data {
        let original = folder(for: id).appending(path: "client.ovpn")
        // 每次连接重新校验，覆盖导入后配置被手动修改的情况。
        return try OpenVPNProfile(file: original, allowExternalFiles: false).data
    }

    private func folder(for id: UUID) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}
