import Foundation

/// 应用内语言偏好，同时供界面和连接服务选择文案。
package enum AppLanguage: String {
    package static let preferenceKey = "appLanguage"

    case chinese = "zh-Hans"
    case english = "en"

    package static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .chinese
    }

    package func text(_ chinese: String, _ english: String) -> String {
        self == .english ? english : chinese
    }
}
