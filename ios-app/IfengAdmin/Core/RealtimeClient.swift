import Foundation

/// 复用服务端已有的 SSE 实时通道。
/// - 每次连接先申请一次性 ticket（带 Origin 头，通过同源校验）。
/// - 事件 ID 完整保留，重连时作为 last_event_id 游标，避免漏消息。
/// - 断线使用指数退避；进入后台由 AppState 主动断开，回前台重连并补拉快照。
/// - 额外有一个「假死看门狗」：服务端每 15 秒发一次心跳，连续 40 秒收不到任何
///   字节就认为连接已经死了（NAT 超时、代理缓冲都不会抛错），主动断开重连。
///   没有它的话，`connected` 会一直是 true，轮询兜底就不会启动，界面彻底静止。
@MainActor
final class RealtimeClient {
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastEventId: String?
    private var isConnected = false
    /// 最后一次收到任意字节的时间，供看门狗判断连接是否假死。
    private var lastActivity = Date()
    private var api: APIClient?

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
        self.api = api
        // 只取消旧连接，不清 isConnected：前后台切换时重连，
        // 状态先 false 再 true 会让聊天页白开一轮轮询。
        task?.cancel()
        task = nil
        lastActivity = Date()
        let session = api.streamSession()
        task = Task { [weak self] in
            await self?.run(api: api, session: session)
        }
        startWatchdog()
    }

    func stop() {
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        updateConnection(false)
        // 保留 lastEventId：同一会话内重连可继续补事件。
    }

    /// 完全重置游标（退出登录或切换服务器时）。
    func reset() {
        stop()
        lastEventId = nil
        api = nil
    }

    private func updateConnection(_ value: Bool) {
        guard value != isConnected else { return }
        isConnected = value
        onConnectionChange(value)
    }

    // MARK: 假死检测

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.isConnected else { continue }
                // 服务端 15 秒一次心跳，40 秒还没有任何字节 = 连接已经不可用。
                guard Date().timeIntervalSince(self.lastActivity) > 40 else { continue }
                self.reconnectStale()
            }
        }
    }

    private func reconnectStale() {
        guard let api else { return }
        // stop() 会把状态置为断开，客户端随即启动轮询兜底；
        // 重连成功后状态回到已连接，轮询立刻停掉。
        stop()
        start(api: api)
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
            // 任何一行都算「连接还活着」，看门狗据此判断是否假死。
            lastActivity = Date()
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
        // resync 只走 onResync 一条路：AppState 会在那里合成一个同类型事件广播出去，
        // 再调 onEvent 会让聊天页 / 列表各做两遍全量刷新。
        if parsed.kind == .resyncRequired {
            onResync()
            return
        }
        onEvent(parsed)
    }
}
