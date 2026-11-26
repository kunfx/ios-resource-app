import Foundation

// MARK: - 错误

enum APIErrorKind {
    case unauthorized      // 401 认证失效
    case forbidden         // 403 权限不足 / Origin 不符
    case notFound          // 404 资源不存在或不可见
    case conflict          // 409 echo_id 冲突
    case validation        // 415 / 422 参数问题
    case rateLimited       // 429
    case notImplemented    // 501
    case unavailable       // 503 / 服务端忙
    case server            // 其它 5xx
    case offline           // 网络不可达
    case timeout
    case cancelled
    case decoding
    case invalidResponse
}

struct APIError: LocalizedError {
    let kind: APIErrorKind
    let status: Int
    let message: String

    var errorDescription: String? { message }

    var isRetryable: Bool {
        switch kind {
        case .offline, .timeout, .unavailable, .server: return true
        default: return false
        }
    }

    var isAuthFailure: Bool { kind == .unauthorized }
}

// MARK: - 解码策略

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ text: String) {
        stringValue = text
        intValue = nil
    }
    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func snakeToCamel(_ text: String) -> String {
    guard text.contains("_") else { return text }
    let parts = text.split(separator: "_", omittingEmptySubsequences: true)
    guard let first = parts.first else { return text }
    var output = String(first)
    for part in parts.dropFirst() {
        output += part.prefix(1).uppercased() + part.dropFirst()
    }
    return output
}

// MARK: - 客户端

struct APIClient {
    let server: ServerAddress
    let credentials: Credentials?
    /// 当前账户 ID；登录后由 withAccount(_:) 注入。
    let accountId: Int
    private let session: URLSession

    init(server: ServerAddress, credentials: Credentials? = nil, accountId: Int = 0) {
        self.server = server
        self.credentials = credentials
        self.accountId = accountId
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = AppConfig.requestTimeout
        configuration.timeoutIntervalForResource = AppConfig.uploadTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            guard let last = keys.last?.stringValue else { return AnyCodingKey("") }
            // "private" 是 Swift 关键字，模型里用 isPrivate 承载。
            if last == "private" { return AnyCodingKey("isPrivate") }
            return AnyCodingKey(snakeToCamel(last))
        }
        return decoder
    }()

    // MARK: 基础请求

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?,
        requiresAuth: Bool,
        originHeader: Bool,
        timeout: TimeInterval?
    ) throws -> URLRequest {
        guard var components = URLComponents(url: server.url, resolvingAgainstBaseURL: false) else {
            throw APIError(kind: .invalidResponse, status: 0, message: "服务器地址无效。")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw APIError(kind: .invalidResponse, status: 0, message: "请求地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            request.httpBody = body
        }
        if requiresAuth, let credentials {
            request.setValue(credentials.accessToken, forHTTPHeaderField: "access-token")
            request.setValue(credentials.uid, forHTTPHeaderField: "uid")
            request.setValue(credentials.client, forHTTPHeaderField: "client")
        }
        if originHeader {
            // SSE ticket 与事件流有同源校验，必须携带与服务端 public_url 完全一致的 Origin。
            request.setValue(server.origin, forHTTPHeaderField: "Origin")
        }
        if let timeout {
            request.timeoutInterval = timeout
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(kind: .invalidResponse, status: 0, message: "服务器响应异常。")
            }
            if http.statusCode >= 400 {
                throw APIClient.makeError(status: http.statusCode, data: data)
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                throw APIError(kind: .cancelled, status: 0, message: "请求已取消。")
            }
            if error.code == .timedOut {
                throw APIError(kind: .timeout, status: 0, message: "请求超时，请检查网络后重试。")
            }
            throw APIError(kind: .offline, status: 0, message: "无法连接服务器，请检查网络。")
        } catch {
            throw APIError(kind: .offline, status: 0, message: "无法连接服务器，请检查网络。")
        }
    }

    /// 带**硬性截止时间**的请求。
    ///
    /// 只靠 `URLRequest.timeoutInterval` 是不可靠的：那个值约束的是「连接建立后的
    /// 数据空闲时间」，DNS 解析卡住、TCP 握手反复重试时它并不会按时触发。
    /// 服务器整个关掉时，实测能拖二三十秒。
    ///
    /// 这里用 `withThrowingTaskGroup` 跟一个 `sleep` 赛跑，谁先完成用谁：
    /// 超时那一侧直接抛 `.timeout`，调用方立刻切到「无法连接」界面。
    /// 只给探针用（`restore` / 登录），正常接口不加，免得慢网下误杀。
    ///
    /// 闭包里只捕获 `URLSession`（本身是 Sendable）和 `URLRequest`（值类型），
    /// 不整体捕获 `APIClient`，避免 Swift 并发检查的 Sendable 警告。
    private func performWithDeadline(
        _ request: URLRequest,
        deadline: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let session = self.session
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            // 无论正常返回还是抛出超时，都要把另一侧的任务取消掉。
            // 少了这句，超时分支抛错后 URLSession 那边还会继续挂着，
            // 直到 timeoutIntervalForResource（70 秒）才释放——探测「成功返回」
            // 但底层连接不回收，重试几次就堆一堆僵尸请求。
            defer { group.cancelAll() }

            group.addTask {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError(kind: .invalidResponse, status: 0, message: "服务器响应异常。")
                }
                if http.statusCode >= 400 {
                    throw APIClient.makeError(status: http.statusCode, data: data)
                }
                return (data, http)
            }
            group.addTask {
                // 纳秒级 sleep；取消时会抛 CancellationError。
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw APIError(
                    kind: .timeout,
                    status: 0,
                    message: "连接服务器超时（\(Int(deadline)) 秒无响应），请检查地址或网络。"
                )
            }
            // 先完成的那个就是结果；剩下那个由 defer 取消。
            guard let first = try await group.next() else {
                throw APIError(kind: .timeout, status: 0, message: "连接服务器超时，请检查地址或网络。")
            }
            return first
        }
    }

    /// 把 HTTP 错误码翻译成 `APIError`。**static** 是因为
    /// `performWithDeadline` 的并发闭包里不能捕获实例。
    private static func makeError(status: Int, data: Data) -> APIError {
        var message: String?
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            message = object["error"] as? String
            if message == nil, let list = object["errors"] as? [String] {
                message = list.first
            }
        }
        let fallback: String
        let kind: APIErrorKind
        switch status {
        case 401:
            kind = .unauthorized
            fallback = "登录已失效，请重新登录。"
        case 403:
            kind = .forbidden
            fallback = "没有权限执行该操作。"
        case 404:
            kind = .notFound
            fallback = "会话不存在或没有访问权限。"
        case 409:
            kind = .conflict
            fallback = "该消息已发送过，内容不一致。"
        case 415, 422:
            kind = .validation
            fallback = "请求参数不符合服务器要求。"
        case 429:
            kind = .rateLimited
            fallback = "操作过于频繁，请稍后再试。"
        case 501:
            kind = .notImplemented
            fallback = "当前服务器未实现该功能。"
        case 503:
            kind = .unavailable
            fallback = "服务器繁忙，请稍后再试。"
        default:
            kind = .server
            fallback = "服务器返回错误（\(status)）。"
        }
        let text = (message?.isEmpty == false ? message! : fallback)
        return APIError(kind: kind, status: status, message: text)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw APIError(kind: .decoding, status: 0, message: "无法解析服务器返回的数据。")
        }
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            throw APIError(kind: .validation, status: 0, message: "请求内容生成失败。")
        }
    }

    private func accountPath(_ suffix: String) -> String {
        "/api/v1/accounts/\(accountId)\(suffix)"
    }

    // MARK: 认证

    static func login(server: ServerAddress, email: String, password: String) async throws -> (Credentials, Profile) {
        let client = APIClient(server: server)
        let body = try client.jsonBody(["email": email, "password": password])
        let request = try client.makeRequest(
            path: "/auth/sign_in",
            method: "POST",
            query: [],
            body: body,
            contentType: "application/json",
            requiresAuth: false,
            originHeader: false,
            timeout: nil
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            // 登录也要硬性截止。用 `probeTimeout * 2`（10 秒）比探针宽一点：
            // 登录要跑密码哈希，慢网 + 弱手机确实需要余量；但服务器整个关掉时
            // 10 秒也远短于原来的 20～70 秒，不会让用户对着「登录中…」干等。
            (data, response) = try await client.performWithDeadline(request, deadline: AppConfig.probeTimeout * 2)
        } catch let error as APIError where error.kind == .unauthorized {
            throw APIError(kind: .unauthorized, status: 401, message: "用户名或密码不正确，或账号已被停用。")
        }
        guard let accessToken = response.value(forHTTPHeaderField: "access-token"),
              let uid = response.value(forHTTPHeaderField: "uid"),
              let clientToken = response.value(forHTTPHeaderField: "client"),
              !accessToken.isEmpty, !uid.isEmpty, !clientToken.isEmpty else {
            throw APIError(kind: .invalidResponse, status: response.statusCode, message: "登录响应缺少认证信息。")
        }
        struct Envelope: Decodable { let data: Profile }
        let envelope = try client.decode(Envelope.self, from: data)
        let credentials = Credentials(accessToken: accessToken, uid: uid, client: clientToken)
        return (credentials, envelope.data)
    }

    /// 取当前登录用户。`timeout` 只在「探测服务器是否活着」时传入短值
    /// （见 `AppConfig.probeTimeout`），平时走默认超时。
    ///
    /// 传了 `timeout` 就走 `performWithDeadline`：那个是**硬性截止**，
    /// DNS 卡住 / TCP 反复重试也会在 5 秒内返回失败，不会让启动页一直转。
    func profile(timeout: TimeInterval? = nil) async throws -> Profile {
        let request = try makeRequest(path: "/api/v1/profile", method: "GET", query: [], body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: timeout)
        let result: (Data, HTTPURLResponse)
        if let timeout {
            result = try await performWithDeadline(request, deadline: timeout)
        } else {
            result = try await perform(request)
        }
        return try decode(Profile.self, from: result.0)
    }

    func logout() async throws {
        let request = try makeRequest(path: "/auth/sign_out", method: "DELETE", query: [], body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        _ = try await perform(request)
    }

    // MARK: 会话

    func conversations(status: String, page: Int, inboxId: Int?, query: String? = nil) async throws -> ConversationPage {
        var items = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "assignee_type", value: "all"),
            URLQueryItem(name: "sort_by", value: "latest"),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let inboxId, inboxId > 0 {
            items.append(URLQueryItem(name: "inbox_id", value: String(inboxId)))
        }
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        let request = try makeRequest(path: accountPath("/conversations"), method: "GET", query: items, body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(ConversationPage.self, from: data)
    }

    func conversation(id: Int) async throws -> Conversation {
        let request = try makeRequest(path: accountPath("/conversations/\(id)"), method: "GET", query: [], body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(Conversation.self, from: data)
    }

    func messages(conversationId: Int, before: Int? = nil, after: Int? = nil) async throws -> MessagePage {
        var items: [URLQueryItem] = []
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        if let after { items.append(URLQueryItem(name: "after", value: String(after))) }
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/messages"), method: "GET", query: items, body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(MessagePage.self, from: data)
    }

    func sendText(conversationId: Int, content: String, echoId: String) async throws -> Message {
        let body = try jsonBody([
            "content": content,
            "private": false,
            "echo_id": echoId,
            "content_attributes": [:]
        ])
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/messages"), method: "POST", query: [], body: body, contentType: "application/json", requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(Message.self, from: data)
    }

    /// 每次请求只允许一张图；字段为 attachments[]、content、private、echo_id、content_attributes。
    func sendImage(conversationId: Int, jpegData: Data, caption: String, echoId: String) async throws -> Message {
        let boundary = "ifeng-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) {
            if let data = text.data(using: .utf8) { body.append(data) }
        }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("content", caption)
        field("private", "false")
        field("echo_id", echoId)
        field("content_attributes", "{}")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"attachments[]\"; filename=\"image.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpegData)
        append("\r\n--\(boundary)--\r\n")

        let request = try makeRequest(
            path: accountPath("/conversations/\(conversationId)/messages"),
            method: "POST",
            query: [],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            requiresAuth: true,
            originHeader: false,
            timeout: AppConfig.uploadTimeout
        )
        let (data, _) = try await perform(request)
        return try decode(Message.self, from: data)
    }

    /// 编辑自己发出的文本消息。服务端只接受纯文本，带图片的消息返回 422。
    /// 返回的 Message 已带 edited_at，可以直接替换本地那条消息。
    func editMessage(conversationId: Int, messageId: Int, content: String) async throws -> Message {
        let body = try jsonBody(["content": content])
        let request = try makeRequest(
            path: accountPath("/conversations/\(conversationId)/messages/\(messageId)"),
            method: "PATCH",
            query: [],
            body: body,
            contentType: "application/json",
            requiresAuth: true,
            originHeader: false,
            timeout: nil
        )
        let (data, _) = try await perform(request)
        return try decode(Message.self, from: data)
    }

    /// 撤回自己发出的消息（文本或图片）。服务端清空正文并打上 recalled_at，
    /// 附件也不再返回；重复撤回返回 422。
    func recallMessage(conversationId: Int, messageId: Int) async throws -> Message {
        let request = try makeRequest(
            path: accountPath("/conversations/\(conversationId)/messages/\(messageId)"),
            method: "DELETE",
            query: [],
            body: nil,
            contentType: nil,
            requiresAuth: true,
            originHeader: false,
            timeout: nil
        )
        let (data, _) = try await perform(request)
        return try decode(Message.self, from: data)
    }

    /// 上报会话查看水位。返回服务端算出的最新未读数（`unread_count`），
    /// 这是「这个用户此刻真实的未读数」，客户端直接拿来刷新角标，不用本地推算。
    @discardableResult
    func markSeen(conversationId: Int) async throws -> Int? {
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/update_last_seen"), method: "POST", query: [], body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        struct SeenResult: Decodable {
            var unreadCount: Int?

            enum CodingKeys: String, CodingKey {
                case unreadCount = "unread_count"
            }
        }
        return (try? JSONDecoder().decode(SeenResult.self, from: data))?.unreadCount
    }

    /// 逐条已读回执：仅提交当前可见的访客公开消息（message_type=0）。
    func markReceipts(conversationId: Int, messageIds: [Int]) async throws {
        guard !messageIds.isEmpty else { return }
        let body = try jsonBody(["message_ids": Array(messageIds.prefix(100))])
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/message_receipts"), method: "POST", query: [], body: body, contentType: "application/json", requiresAuth: true, originHeader: false, timeout: nil)
        _ = try await perform(request)
    }

    /// 查询自己发出的消息有没有被对方读（GET 不会把消息标记成已读）。
    /// 这是 SSE 之外的兜底：即使实时通道短暂断开，勾选状态也能靠轮询追上。
    func messageReceipts(conversationId: Int, messageIds: [Int]) async throws -> [MessageReceipt] {
        guard !messageIds.isEmpty else { return [] }
        let items = Array(messageIds.prefix(100)).map { URLQueryItem(name: "message_ids[]", value: String($0)) }
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/message_receipts"), method: "GET", query: items, body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        let page = try decode(MessageReceiptPage.self, from: data)
        return page.payload
    }

    func setStatus(conversationId: Int, status: String) async throws {
        let body = try jsonBody(["status": status, "snoozed_until": NSNull()])
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/toggle_status"), method: "POST", query: [], body: body, contentType: "application/json", requiresAuth: true, originHeader: false, timeout: nil)
        _ = try await perform(request)
    }

    func setBlocked(conversationId: Int, blocked: Bool) async throws -> Conversation {
        let body = try jsonBody(["blocked": blocked])
        let request = try makeRequest(path: accountPath("/conversations/\(conversationId)/visitor_block"), method: "PATCH", query: [], body: body, contentType: "application/json", requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(Conversation.self, from: data)
    }

    // MARK: 正在输入

    /// 管理员侧的「正在输入」。字段与网页后台一致：
    /// typing_status on/off、is_private false、typing_mode heartbeat（服务端 lease 3 秒）。
    func setTyping(conversationId: Int, on: Bool) async throws {
        let body = try jsonBody([
            "typing_status": on ? "on" : "off",
            "is_private": false,
            "typing_mode": "heartbeat"
        ])
        let request = try makeRequest(
            path: accountPath("/conversations/\(conversationId)/toggle_typing_status"),
            method: "POST",
            query: [],
            body: body,
            contentType: "application/json",
            requiresAuth: true,
            originHeader: false,
            timeout: nil
        )
        _ = try await perform(request)
    }

    /// 查询访客是否正在输入（SSE 断开时的兜底，也是进入会话时的初始状态）。
    func typingStatus(conversationId: Int) async throws -> TypingStatus {
        let request = try makeRequest(
            path: accountPath("/conversations/\(conversationId)/typing_status"),
            method: "GET",
            query: [],
            body: nil,
            contentType: nil,
            requiresAuth: true,
            originHeader: false,
            timeout: nil
        )
        let (data, _) = try await perform(request)
        return try decode(TypingStatus.self, from: data)
    }

    // MARK: 收件箱与 Bark

    func inboxes() async throws -> [Inbox] {
        let request = try makeRequest(path: accountPath("/inboxes"), method: "GET", query: [], body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        let envelope = try decode(InboxListEnvelope.self, from: data)
        return envelope.payload
    }

    func barkSettings() async throws -> BarkSettings {
        let request = try makeRequest(path: accountPath("/bark_settings"), method: "GET", query: [], body: nil, contentType: nil, requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(BarkSettings.self, from: data)
    }

    /// 不传 key 时服务端保留已有 KEY；启用但无 KEY 会返回 422。
    func updateBark(enabled: Bool) async throws -> BarkSettings {
        let body = try jsonBody(["enabled": enabled])
        let request = try makeRequest(path: accountPath("/bark_settings"), method: "PUT", query: [], body: body, contentType: "application/json", requiresAuth: true, originHeader: false, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(BarkSettings.self, from: data)
    }

    // MARK: 实时

    func realtimeTicket() async throws -> RealtimeTicket {
        let body = try jsonBody(["account_id": accountId])
        let request = try makeRequest(path: "/api/v1/realtime/ticket", method: "POST", query: [], body: body, contentType: "application/json", requiresAuth: true, originHeader: true, timeout: nil)
        let (data, _) = try await perform(request)
        return try decode(RealtimeTicket.self, from: data)
    }

    func realtimeStreamRequest(ticket: String, lastEventId: String?) throws -> URLRequest {
        var query = [URLQueryItem(name: "ticket", value: ticket)]
        if let lastEventId, !lastEventId.isEmpty {
            query.append(URLQueryItem(name: "last_event_id", value: lastEventId))
        }
        var request = try makeRequest(path: "/api/v1/realtime/events", method: "GET", query: query, body: nil, contentType: nil, requiresAuth: false, originHeader: true, timeout: nil)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // 流式响应的空闲超时。实际数据接收由 SSETransport 的 delegate 负责，
        // 这里的 request timeout 只约束「建流握手」阶段。
        request.timeoutInterval = AppConfig.streamIdleTimeout
        return request
    }
}

extension APIClient {
    /// 生成带账户 ID 的副本（登录后才确定 account_id）。
    func withAccount(_ accountId: Int) -> APIClient {
        APIClient(server: server, credentials: credentials, accountId: accountId)
    }
}
