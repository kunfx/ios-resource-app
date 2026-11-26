import Foundation

/// 服务端根地址。只接受 http(s) 的 origin：不带凭据、query、fragment 和业务路径。
struct ServerAddress: Hashable {
    let url: URL
    let host: String

    /// 归一化后的 origin 字符串，用作 Origin 请求头（SSE 同源校验要求完全一致）。
    var origin: String {
        var text = "\(url.scheme ?? "https")://\(host)"
        if let port = url.port, port != 443, port != 80 {
            text += ":\(port)"
        }
        return text
    }

    var displayHost: String { host }

    static func parse(_ raw: String) -> ServerAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard components.query == nil, components.fragment == nil else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        let path = components.path
        guard path.isEmpty || path == "/" else { return nil }
        // 生产环境只接受 HTTPS；本机调试例外。
        if scheme == "http" && !isLocalHost(host) { return nil }
        components.path = ""
        guard let url = components.url else { return nil }
        return ServerAddress(url: url, host: host.lowercased())
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
            || h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("172.16.")
    }
}

/// 服务端三个认证头：access-token / uid / client。
struct Credentials: Codable, Hashable {
    var accessToken: String
    var uid: String
    var client: String
}

/// 一次登录会话的不可变快照，可安全传入各页面的 Model。
struct AppSession {
    let server: ServerAddress
    let credentials: Credentials
    let profile: Profile
    let api: APIClient

    var accountId: Int { profile.accountId }
    var displayName: String {
        let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (profile.email ?? "管理员") : name
    }
    var isAdministrator: Bool { profile.role == "administrator" }
}
