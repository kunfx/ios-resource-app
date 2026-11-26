import Foundation

struct AppConfiguration {
    let origin: URL
    let scheme: String

    init(baseURL: String, scheme: String) throws {
        guard let parts = URLComponents(string: baseURL),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let url = parts.url else { throw ConfigurationError.invalidOrigin }
        let legalScheme = scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil
        guard legalScheme, !["https", "http", "file", "javascript", "data"].contains(scheme) else {
            throw ConfigurationError.invalidScheme
        }
        self.origin = url
        self.scheme = scheme
    }

    static func load() throws -> AppConfiguration {
        try AppConfiguration(
            baseURL: Bundle.main.object(forInfoDictionaryKey: "AdminBaseURL") as? String ?? "",
            scheme: Bundle.main.object(forInfoDictionaryKey: "AdminURLScheme") as? String ?? ""
        )
    }

    // 后端 web/embed.go 中真实存在的入口，不使用 Chatwoot Rails 的路径。
    var adminURL: URL { origin.appendingPathComponent("app", isDirectory: true) }

    func owns(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? 443) == (origin.port ?? 443)
            && url.user == nil && url.password == nil
    }

    func isAdminPage(_ url: URL) -> Bool {
        owns(url) && ["/", "/app", "/app/"].contains(url.path)
    }

    func conversationURL(accountID: Int64, conversationID: Int64) -> URL {
        var parts = URLComponents(url: adminURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "account_id", value: String(accountID)),
                            URLQueryItem(name: "conversation_id", value: String(conversationID))]
        return parts.url!
    }
}

enum ConfigurationError: LocalizedError {
    case invalidOrigin, invalidScheme
    var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "后台地址配置无效。请在 App.xcconfig 中填写 HTTPS 域名，不包含路径、账号或密码。"
        case .invalidScheme: return "URL Scheme 配置无效。请使用独立的英文协议名称。"
        }
    }
}
