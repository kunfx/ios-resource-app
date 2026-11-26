import Foundation

/// 复用服务端已有的 SSE 实时通道。
/// - 每次连接先申请一次性 ticket（带 Origin 头，通过同源校验）。
/// - 事件 ID 完整保留，重连时作为 last_event_id 游标，避免漏消息。
/// - 断线使用指数退避；进入后台由 AppState 主动断开，回前台重连并补拉快照。
@MainActor
final class RealtimeClient {
    private var task: Task<Void, Never>?
    private var lastEventId: String?
    private var isConnected = false

    private let onEvent: @MainActor (RealtimeEvent) -> Void
    private let onResync: @MainActor () -> Void
    private let onAuthFailure: @MainActor () -> Void
    private let onConnectionChange: @MainActor (Bool) -> Void

    init(
        onEvent: @escaping @MainActor (RealtimeEvent) -> Void,
        onResync: @escaping @MainActor () -> Void,
        onAuthFailure: @escaping @MainActor () -> Void,
        onConnectionChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.onEvent = onEvent
        self.onResync = onResync
        self.onAuthFailure = onAuthFailure
        self.onConnectionChange = onConnectionChange
    }

    var connected: Bool { isConnected }

    func start(api: APIClient) {
        stop()
        let session = api.streamSession()
        task = Task { [weak self] in
            await self?.run(api: api, session: session)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        updateConnection(false)
        // 保留 lastEventId：同一会话内重连可继续补事件。
    }

    /// 完全重置游标（退出登录或切换服务器时）。
    func reset() {
        stop()
        lastEventId = nil
    }

    private func updateConnection(_ value: Bool) {
        guard value != isConnected else { return }
        isConnected = value
        onConnectionChange(value)
    }

    private func run(api: APIClient, session: URLSession) async {
        var backoff: UInt64 = 1_500_000_000
        while !Task.isCancelled {
            var endedCleanly = false
            do {
                let ticket = try await api.realtimeTicket()
                let request = try api.realtimeStreamRequest(ticket: ticket.ticket, lastEventId: lastEventId)
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError(kind: .invalidResponse, status: 0, message: "实时连接响应异常。")
                }
                if http.statusCode == 204 {
                    // ticket 已被消费，服务端要求客户端重新申请。
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                if http.statusCode == 401 {
                    onAuthFailure()
                    return
                }
                guard http.statusCode == 200 else {
                    throw APIError(kind: .unavailable, status: http.statusCode, message: "实时连接失败（\(http.statusCode)）。")
                }
                updateConnection(true)
                backoff = 1_500_000_000
                try await consume(bytes: bytes)
                endedCleanly = true
            } catch is CancellationError {
                updateConnection(false)
                return
            } catch let error as APIError {
                updateConnection(false)
                if error.isAuthFailure {
                    onAuthFailure()
                    return
                }
            } catch {
                updateConnection(false)
            }
            updateConnection(false)
            if Task.isCancelled { return }
            // 服务端每 20 分钟主动续连；正常结束立即重连，异常按指数退避。
            let delay = endedCleanly ? UInt64(600_000_000) : backoff
            try? await Task.sleep(nanoseconds: delay)
            if !endedCleanly {
                backoff = min(backoff * 2, 30_000_000_000)
            }
        }
    }

    private func consume(bytes: URLSession.AsyncBytes) async throws {
        var eventName = ""
        var dataLines: [String] = []
        var eventId: String?

        func flush() {
            guard !eventName.isEmpty || !dataLines.isEmpty else {
                eventId = nil
                return
            }
            let name = eventName.isEmpty ? "message" : eventName
            handle(event: name, data: dataLines.joined(separator: "\n"), id: eventId)
            eventName = ""
            dataLines = []
            eventId = nil
        }

        for try await rawLine in bytes.lines {
            if Task.isCancelled { return }
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix(":") { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let field = String(line[line.startIndex..<separator])
            var value = String(line[line.index(after: separator)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event": eventName = value
            case "data": dataLines.append(value)
            case "id": eventId = value
            default: break
            }
        }
        flush()
    }

    private func handle(event: String, data: String, id: String?) {
        // 事件 ID 格式为 "<序号>:<后缀>"，不能用 message_id 代替。
        // 持久化事件的后缀是 "d"；控制事件（心跳、resync）也带游标，可安全推进。
        if let id, !id.isEmpty {
            lastEventId = id
        }
        let parsed = RealtimeEvent(kind: event, payload: Data(data.utf8))
        if parsed.kind == .error, parsed.errorCode == "session_expired" {
            onAuthFailure()
            return
        }
        if parsed.kind == .resyncRequired {
            onResync()
        }
        onEvent(parsed)
    }
}
