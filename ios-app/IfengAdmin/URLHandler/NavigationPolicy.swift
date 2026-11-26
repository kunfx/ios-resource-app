import Foundation

enum NavigationDestination: Equatable {
    case internalPage, externalBrowser, externalApplication, localPreview, blocked
}

struct NavigationPolicy {
    let configuration: AppConfiguration

    func destination(for url: URL, userInitiated: Bool) -> NavigationDestination {
        guard url.user == nil, url.password == nil else { return .blocked }
        if configuration.owns(url) { return .internalPage }
        switch url.scheme?.lowercased() {
        case "https", "http":
            // 不允许主站悄悄降级为明文 HTTP；外站链接仅在用户操作时打开。
            if url.scheme?.lowercased() == "http", url.host?.lowercased() == configuration.origin.host?.lowercased() {
                return .blocked
            }
            return userInitiated ? .externalBrowser : .blocked
        case "mailto", "tel", "sms": return userInitiated ? .externalApplication : .blocked
        case "blob":
            let raw = String(url.absoluteString.dropFirst(5))
            return URL(string: raw).map { configuration.owns($0) } == true ? .localPreview : .blocked
        case "about": return url.absoluteString == "about:blank" ? .localPreview : .blocked
        default: return .blocked
        }
    }
}
