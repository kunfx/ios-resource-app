import Foundation

/// 全局配置：服务器地址允许在 App 内修改，方便切换测试环境。
enum AppConfig {
    static let defaultBaseURL = "https://ifeng.app"
    private static let storageKey = "appku.base_url"

    static var baseURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: storageKey) ?? ""
            return stored.isEmpty ? defaultBaseURL : stored
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      forKey: storageKey)
        }
    }

    /// 去掉结尾斜杠，避免拼出 `//api/apps`
    static var normalizedBaseURLString: String {
        var value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { value = defaultBaseURL }
        return value
    }

    static let appName = "AppKu"
    static let pageSize = 20
}
