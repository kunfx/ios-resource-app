import Foundation

struct ConversationTarget: Equatable {
    let conversationID: Int64
    let accountID: Int64?

    // ID 必须同时落在 JavaScript 安全整数范围内，避免网页路由精度丢失。
    static func positiveID(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int64(value), number > 0, number <= 9_007_199_254_740_991 else { return nil }
        return number
    }

    static func parse(_ url: URL, scheme: String) throws -> ConversationTarget {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { throw LinkError.invalid }
        if (parts.host == nil || parts.host == "") && parts.path.isEmpty && parts.query == nil {
            throw LinkError.openHome
        }
        guard parts.host?.lowercased() == "conversation" else { throw LinkError.invalid }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty, let cid = positiveID(String(path[1])) else {
            throw LinkError.invalid
        }
        let query = parts.queryItems ?? []
        guard query.allSatisfy({ $0.name == "account_id" }), query.count <= 1 else { throw LinkError.invalid }
        var aid: Int64?
        if let item = query.first {
            guard let value = positiveID(item.value) else { throw LinkError.invalid }
            aid = value
        }
        return ConversationTarget(conversationID: cid, accountID: aid)
    }
}

enum LinkError: LocalizedError {
    case invalid, openHome
    var errorDescription: String? { "通知链接格式不正确，请检查会话编号和账户编号。" }
}
