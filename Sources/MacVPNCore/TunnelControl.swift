import Foundation

/// GUI 只能提交配置和接收状态。隧道服务自行选择引擎、路径及启动参数。
@objc package protocol TunnelControl {
    func start(_ configuration: Data, language: String, reply: @escaping (String?, String?, String?) -> Void)
}

@objc package protocol TunnelEvents {
    func tunnelExited(_ status: Int32, diagnostics: String)
}

package enum TunnelService {
    package static let name = "local.macvpn.tunnel"
    package static let installation = "/Library/Application Support/MacVPN"
    package static let runtime = "/private/var/run/macvpn"
    package static let launchDaemon = "/Library/LaunchDaemons/\(name).plist"
}
