import Foundation

/// 复用服务端已有的 SSE 实时通道。
///
/// 结构参照 `web/realtime.js`：申请一次性 ticket → 建流 → 按帧收事件 → 断线重连
/// （携带 `last_event_id` 游标）→ 指数退避。
///
/// 底层用 `SSETransport`（`URLSessionDataDelegate`）而不是 `URLSession.bytes`，
/// 原因见那个文件的注释：`AsyncBytes` 会被 CFNetwork 输出缓冲，事件要等心跳
/// 才会一起冲出，对 3 秒租约的 typing 来说等于永远失效。
///
/// 对外汇报**两个**状态，不能混用一个布尔值：
/// 1. `connected` —— 流已握手成功（HTTP 200）。只代表连接建立了。
/// 2. `healthy`   —— 流打开**且**最近还在吐字节。
///
/// 两者都**不等于**「业务事件一定送得到」（代理仍可能吞掉事件而心跳照常）。
/// 所以轮询兜底永远常开，只按健康度调频率。
@MainActor
final class RealtimeClient {
    private var transport: SSETransport?
    private var lastEventId: String?
    private var isConnected = false
    private var isHealthy = false
    /// 最后一次收到任意字节的时间。服务端每 15 秒一次心跳，落后太多就说明流死了。
    private var lastActivity = Date()
    private var api: APIClient?
    /// 每次 start / stop 自增。旧连接的收尾回调凭它判断自己是否已被替换。
    private var generation = 0
    private var retryTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var backoff: UInt64 = 1_500_000_000

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
        retryTask?.cancel()
        retryTask = nil
        backoff = 1_500_000_000
        lastActivity = Date()
        connect(api: api, generation: current)
        startWatchdog(generation: current)
    }

    func stop() {
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        watchdog?.cancel()
        watchdog = nil
        transport?.stop()
        transport = nil
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
        guard current == generation else { return }
        if value != isConnected {
            isConnected = value
            onConnectionChange(value)
        }
        updateHealth(value && Date().timeIntervalSince(lastActivity) < Self.staleAfter, generation: current)
    }

    private func updateHealth(_ value: Bool, generation current: Int) {
        guard current == generation, value != isHealthy else { return }
        isHealthy = value
        onHealthChange(value)
    }

    // MARK: 连接

    private func connect(api: APIClient, generation current: Int) {
        transport?.stop()
        let transport = SSETransport()
        self.transport = transport

        transport.onActivity = { [weak self] in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.lastActivity = Date()
            }
        }
        transport.onOpen = { [weak self] in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.lastActivity = Date()
                self.backoff = 1_500_000_000
                self.updateConnection(true, generation: current)
            }
        }
        transport.onEvent = { [weak self] name, data, id in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.handle(event: name, data: data, id: id)
            }
        }
        transport.onClose = { [weak self] clean in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.updateConnection(false, generation: current)
                self.scheduleReconnect(api: api, generation: current, clean: clean)
            }
        }

        // 一次性 ticket 必须带同源 Origin；事件流本身靠 ticket 授权，不再需要认证头。
        Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await api.realtimeTicket()
                guard current == self.generation else { return }
                let request = try api.realtimeStreamRequest(
                    ticket: ticket.ticket,
                    lastEventId: self.lastEventId
                )
                transport.start(request)
            } catch let error as APIError {
                guard current == self.generation else { return }
                if error.isAuthFailure {
                    self.onAuthFailure()
                    return
                }
                // 拿不到 ticket 也必须落回「未连接」，让兜底轮询继续兜住。
                self.updateConnection(false, generation: current)
                self.scheduleReconnect(api: api, generation: current, clean: false)
            } catch {
                guard current == self.generation else { return }
                self.updateConnection(false, generation: current)
                self.scheduleReconnect(api: api, generation: current, clean: false)
            }
        }
    }

    /// 断了就退避重连。参照 realtime.js：正常收尾 0.6 秒即重连，异常按指数退避。
    private func scheduleReconnect(api: APIClient, generation current: Int, clean: Bool) {
        guard current == generation else { return }
        retryTask?.cancel()
        let delay = clean ? UInt64(600_000_000) : backoff
        if !clean {
            backoff = min(backoff * 2, 30_000_000_000)
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, current == self.generation else { return }
            self.connect(api: api, generation: current)
        }
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
                guard let api = self.api else { return }
                guard self.isConnected else { continue }
                let idle = Date().timeIntervalSince(self.lastActivity)
                self.updateHealth(idle < Self.staleAfter, generation: current)
                if idle > Self.reconnectAfter {
                    self.connect(api: api, generation: current)
                    return
                }
            }
        }
    }

    // MARK: 事件分发

    private func handle(event: String, data: String, id: String?) {
        // 事件 ID 格式为 "<序号>:<后缀>"，不能用 message_id 代替。
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
