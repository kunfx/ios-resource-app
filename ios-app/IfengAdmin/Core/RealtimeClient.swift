import Foundation

/// 复用服务端已有的 SSE 实时通道。
///
/// 对外汇报**两个**状态，不能混用一个布尔值：
/// 1. `connected` —— 流已握手成功（HTTP 200）。只代表连接建立了。
/// 2. `healthy`   —— 流打开**且**最近还在吐字节。它才代表「真的收得到事件」。
///
/// 1.2.0 的回归就出在这里：只用了 `connected`，而且重连时特意保留了它的旧值。
/// 结果重连一旦失败、或者流被代理缓冲住（连接不断、但一个事件都不来），
/// `connected` 会一直是 true，轮询兜底按它关闭，于是已读回执和未读角标一起失效。
/// 现在用 `healthy` 做兜底门槛，静默死流会自动降级。
@MainActor
final class RealtimeClient {
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastEventId: String?
    private var isConnected = false
    private var isHealthy = false
    /// 最后一次收到任意字节的时间。服务端每 15 秒一次心跳，落后太多就说明流死了。
    private var lastActivity = Date()
    private var api: APIClient?
    /// 每次 start / stop 自增。旧连接的收尾回调凭它判断自己是否已被替换，
    /// 否则旧任务会把新连接刚设好的状态改回 false（或 true），状态就再也不可信。
    private var generation = 0

    private let onEvent: @MainActor (RealtimeEvent) -> Void
    private let onResync: @MainActor () -> Void
    private let onAuthFailure: @MainActor () -> Void
    private let onConnectionChange: @MainActor (Bool) -> Void
    private let onHealthChange: @MainActor (Bool) -> Void

    init(
        onEvent: @escaping @MainActor (RealtimeEvent) -> Void,
        onResync: @escaping @MainActor () -> Void,
        onAuthFailure: @escaping @MainActor () -> Void,
        onConnectionChange: @escaping @MainActor (Bool) -> Void,
        onHealthChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.onEvent = onEvent
        self.onResync = onResync
        self.onAuthFailure = onAuthFailure
        self.onConnectionChange = onConnectionChange
        self.onHealthChange = onHealthChange
    }

    var connected: Bool { isConnected }

    func start(api: APIClient) {
        self.api = api
        generation &+= 1
        let current = generation
        task?.cancel()
        task = nil
        lastActivity = Date()
        let session = api.streamSession()
        task = Task { [weak self] in
            await self?.run(api: api, session: session, generation: current)
        }
        startWatchdog(generation: current)
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        updateConnection(false, generation: generation)
        // 保留 lastEventId：同一会话内重连可继续补事件。
    }

    /// 完全重置游标（退出登录或切换服务器时）。
    func reset() {
        stop()
        lastEventId = nil
        api = nil
    }

    // MARK: 状态

    private func updateConnection(_ value: Bool, generation current: Int) {
        // 旧连接（含被替换掉的 run 循环）的收尾回调直接丢弃。
        guard current == generation else { return }
        if value != isConnected {
            isConnected = value
            onConnectionChange(value)
        }
        // 握手成功即视为健康；断开则立刻不健康。
        updateHealth(value && Date().timeIntervalSince(lastActivity) < Self.staleAfter, generation: current)
    }

    private func updateHealth(_ value: Bool, generation current: Int) {
        guard current == generation, value != isHealthy else { return }
        isHealthy = value
        onHealthChange(value)
    }

    // MARK: 静默死流检测

    /// 心跳 15 秒一次；超过 25 秒没有任何字节就不再算「健康」。
    private static let staleAfter: TimeInterval = 25
    /// 连续 40 秒没有字节，直接断开重连。
    private static let reconnectAfter: TimeInterval = 40

    private func startWatchdog(generation current: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, current == self.generation else { return }
                guard self.isConnected else { continue }
                let idle = Date().timeIntervalSince(self.lastActivity)
                self.updateHealth(idle < Self.staleAfter, generation: current)
                if idle > Self.reconnectAfter {
                    self.reconnectStale()
                    return
                }
            }
        }
    }

    private func reconnectStale() {
        guard let api else { return }
        // stop() 会把 connected / healthy 都置为 false，视图随即启用轮询兜底；
        // 重连成功后回到健康，轮询立刻停掉并补一次同步。
        let cursor = lastEventId
        stop()
        lastEventId = cursor
        start(api: api)
    }

    // MARK: 连接循环

    private func run(api: APIClient, session: URLSession, generation current: Int) async {
        var backoff: UInt64 = 1_500_000_000
        while !Task.isCancelled {
            var endedCleanly = false
            do {
                let ticket = try await api.realtimeTicket()
                guard current == generation else { return }
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
                lastActivity = Date()
                updateConnection(true, generation: current)
                backoff = 1_500_000_000
                try await consume(bytes: bytes, generation: current)
                endedCleanly = true
            } catch is CancellationError {
                updateConnection(false, generation: current)
                return
            } catch let error as APIError {
                // 关键：重连失败必须显式落到「未连接」，否则客户端会以为还活着，
                // 轮询兜底永远不会启动——这正是 1.2.0 实时功能全失效的原因。
                updateConnection(false, generation: current)
                if error.isAuthFailure {
                    onAuthFailure()
                    return
                }
            } catch {
                updateConnection(false, generation: current)
            }
            updateConnection(false, generation: current)
            if Task.isCancelled { return }
            // 服务端每 20 分钟主动续连；正常结束立即重连，异常按指数退避。
            let delay = endedCleanly ? UInt64(600_000_000) : backoff
            try? await Task.sleep(nanoseconds: delay)
            if !endedCleanly {
                backoff = min(backoff * 2, 30_000_000_000)
            }
        }
    }

    private func consume(bytes: URLSession.AsyncBytes, generation current: Int) async throws {
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
            // 任何一行都算「连接还活着」，看门狗据此判断是否静默死流。
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
