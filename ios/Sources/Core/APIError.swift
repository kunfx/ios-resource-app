import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case network(String)
    case server(status: Int, message: String)
    case decoding(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址不正确"
        case .network(let message):
            return message
        case .server(_, let message):
            return message
        case .decoding:
            return "数据解析失败，请稍后重试"
        case .cancelled:
            return nil
        }
    }

    var isUnauthorized: Bool {
        if case .server(let status, _) = self {
            return status == 401
        }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var statusCode: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }
}

extension Error {
    var readableMessage: String {
        if let api = self as? APIError, let text = api.errorDescription {
            return text
        }
        if (self as NSError).domain == NSURLErrorDomain {
            return "网络连接失败，请检查网络或服务器地址"
        }
        return localizedDescription
    }
}
