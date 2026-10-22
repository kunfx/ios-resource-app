import Foundation

/// 统一的 HTTP 客户端。
/// App 只和 Laravel 的 /api/* 通信，永远不直连数据库。
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var storedToken: String?

    /// 收到 401 时回调（由 SessionStore 负责清空登录态）
    var onUnauthorized: (() -> Void)?

    var token: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedToken
        }
        set {
            lock.lock()
            storedToken = newValue
            lock.unlock()
        }
    }

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    // MARK: - 公开方法

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await perform(path, method: "GET", query: query, body: nil)
        return try decodeEnvelope(data)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        let data = try await perform(path, method: "POST", query: [:], body: body)
        return try decodeEnvelope(data)
    }

    func postIgnoringData(_ path: String, body: [String: Any]? = nil) async throws {
        _ = try await perform(path, method: "POST", query: [:], body: body)
    }

    // MARK: - 内部实现

    private func perform(_ path: String,
                         method: String,
                         query: [String: String],
                         body: [String: Any]?) async throws -> Data {
        let full = AppConfig.normalizedBaseURLString + path

        guard var components = URLComponents(string: full) else {
            throw APIError.invalidURL
        }

        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AppKu-iOS/1.0", forHTTPHeaderField: "User-Agent")

        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw APIError.network("服务器响应异常")
            }

            if http.statusCode == 401 {
                onUnauthorized?()
            }

            guard (200..<300).contains(http.statusCode) else {
                let message = (try? decoder.decode(ServerErrorBody.self, from: data))?.message
                let fallback = "请求失败（\(http.statusCode)）"
                throw APIError.server(status: http.statusCode,
                                      message: (message?.isEmpty == false ? message! : fallback))
            }

            return data
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            throw APIError.network("网络连接失败，请检查网络或服务器地址")
        }
    }

    private func decodeEnvelope<T: Decodable>(_ data: Data) throws -> T {
        do {
            let envelope = try decoder.decode(APIEnvelope<T>.self, from: data)

            if let payload = envelope.data {
                return payload
            }

            throw APIError.server(status: 200, message: envelope.message ?? "服务器没有返回数据")
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding("")
        }
    }
}
