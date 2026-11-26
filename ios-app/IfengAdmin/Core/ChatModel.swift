import Foundation
import SwiftUI
import Combine

/// 列表已经加载过的会话快照，供聊天页首帧直接复用，避免先闪一下「访客 #123」。
/// 只做内存缓存，不持久化；真实数据仍以会话详情接口为准。
///
/// `publish` 与 `store` 的区别：前者会广播变更。聊天页在收到
/// `conversation.read` / 详情刷新后调用 `publish`，会话列表即使正被聊天页盖住、
/// 收不到自己的 `onReceive`，也能通过这条通道立刻更新未读角标。
///
/// `unreadAuthoritative` 用来区分未读数的可信程度，这一位很关键：
/// - `true`：来自 `update_last_seen` 的返回值或 `conversation.read` 事件，
///   是服务端刚刚算出来的**当前**未读数，列表必须采信（含清零）。
/// - `false`：来自会话详情快照，可能是几秒前的旧值，列表**不能**用它覆盖
///   未读数，否则刚清零的角标会跳回来。
@MainActor
enum ConversationCache {
    private static var storage: [Int: Conversation] = [:]
    static let changes = PassthroughSubject<ConversationUpdate, Never>()

    struct ConversationUpdate {
        let conversation: Conversation
        let unreadAuthoritative: Bool
    }

    static func store(_ conversations: [Conversation]) {
        // 简单上限，避免长时间使用后无限增长；先清空再写入，保证当前这批一定留下。
        if storage.count + conversations.count > 400 {
            storage.removeAll(keepingCapacity: true)
        }
        for conversation in conversations {
            storage[conversation.id] = conversation
        }
    }

    static func store(_ conversation: Conversation) {
        storage[conversation.id] = conversation
    }

    /// 写入并广播。只给「单条会话状态发生变化」的路径用，避免批量加载时刷屏。
    static func publish(_ conversation: Conversation, unreadAuthoritative: Bool = false) {
        storage[conversation.id] = conversation
        changes.send(ConversationUpdate(conversation: conversation, unreadAuthoritative: unreadAuthoritative))
    }

    static func conversation(id: Int) -> Conversation? {
        storage[id]
    }
}

/// 单个会话的聊天数据源：历史分页、发送、已读、正在输入、访客屏蔽/会话状态、SSE 增量。
///
/// 实时策略是「SSE 主 + 轮询兜底」，且兜底是**条件触发**的：
/// - SSE 已连接时完全不轮询，已读回执和正在输入都靠事件推送；
/// - 只有 `realtimeHealthy == false`（断线、重连失败、静默死流）
///   才启动 2 秒轮询；连接恢复的瞬间立刻停掉，并补一次全量同步。
@MainActor
final class ChatModel: ObservableObject {
    struct PendingMessage: Identifiable, Equatable {
        enum SendState: Equatable {
            case sending
            case failed
        }

        let id: String          // echo_id，重试时保持不变
        var text: String
        var jpegData: Data?
        var createdAt: Int
        var state: SendState
        var errorText: String?

        var hasImage: Bool { jpegData != nil }
    }

    @Published private(set) var conversation: Conversation
    @Published private(set) var messages: [Message] = []
    @Published private(set) var pending: [PendingMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var hasMoreOlder = false
    @Published private(set) var loadError: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var actionError: String?
    @Published private(set) var actionNotice: String?
    @Published var justSent = false

    /// 对方（访客）正在输入。
    @Published private(set) var peerTyping = false

    let conversationId: Int
    private let api: APIClient
    /// 当前登录用户 ID。conversation.read 事件带 user_id，只有属于自己的才生效。
    private let userId: Int
    /// 是否已经开始过首次加载（防重复进入）。
    private var didStart = false
    /// 首次加载是否已经完成。SSE 事件的增量补拉、断线重连的补偿同步都以它为门槛，
    /// 避免和 `loadAll()` 撞在一起打出两份一样的请求。
    private var didLoad = false
    private var oldestId: Int?
    private var newestId: Int?
    private var lastReceiptBatch: Set<Int> = []
    /// update_last_seen 的节流时间戳。
    private var lastSeenSentAt = Date.distantPast

    // 正在输入：自己这一侧
    private var typingOn = false
    private var lastTypingSentAt = Date.distantPast
    private var typingIdleTask: Task<Void, Never>?

    // 正在输入：对方这一侧
    private var peerTypingExpiry: Date?
    private var peerTypingTask: Task<Void, Never>?

    // 兜底轮询：永远开启，只是频率随通道健康度变化
    private var pollTask: Task<Void, Never>?
    /// 当前兜底间隔（0 表示没在跑）。用来避免重复启动同样间隔的循环。
    private var pollInterval: UInt64 = 0
    /// nil 表示还没收到过健康状态。
    private var realtimeHealthy: Bool?
    /// 事件串行队列（见 `enqueue(event:)`）。
    private var eventQueue: [RealtimeEvent] = []
    private var isDrainingEvents = false

    init(session: AppSession, conversationId: Int, seed: Conversation? = nil) {
        self.api = session.api
        self.userId = session.profile.id
        self.conversationId = conversationId
        self.conversation = seed
            ?? ConversationCache.conversation(id: conversationId)
            ?? Conversation(id: conversationId)
    }

    var isSending: Bool { pending.contains { $0.state == .sending } }

    var canReply: Bool { conversation.canReply ?? true }

    var isBlocked: Bool { conversation.isBlocked }

    // MARK: 初次加载

    func start() async {
        guard !didStart else { return }
        didStart = true
        await loadAll()
        didLoad = true
    }

    func loadAll() async {
        isLoading = true
        loadError = nil
        do {
            async let detail = api.conversation(id: conversationId)
            async let page = api.messages(conversationId: conversationId)
            let loadedConversation = try await detail
            let loadedPage = try await page
            conversation = loadedConversation
            ConversationCache.publish(loadedConversation)
            messages = loadedPage.payload.sorted { $0.id < $1.id }
            oldestId = messages.first?.id
            newestId = messages.last?.id
            hasMoreOlder = loadedPage.payload.count >= AppConfig.pageSize
            loadError = nil
            await markVisibleAsRead(force: true)
            // 首屏同时补一次「我发出的消息被读了没有」，历史消息也能一次对上。
            await refreshOutgoingReceipts()
            // 进页面立刻问一次访客在不在打字：不能等十几秒后的兜底心跳，
            // 否则「刚进来时对方正在输入」这个状态会被漏掉。
            await refreshPeerTyping()
        } catch let error as APIError {
            if error.kind != .cancelled {
                loadError = error.message
            }
        } catch {
            loadError = "加载会话失败。"
        }
        isLoading = false
    }

    // MARK: 历史分页

    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, let oldest = oldestId else { return }
        isLoadingOlder = true
        do {
            let page = try await api.messages(conversationId: conversationId, before: oldest)
            let existing = Set(messages.map { $0.id })
            let older = page.payload.filter { !existing.contains($0.id) }
            messages.insert(contentsOf: older, at: 0)
            messages.sort { $0.id < $1.id }
            oldestId = messages.first?.id
            hasMoreOlder = page.payload.count >= AppConfig.pageSize
        } catch let error as APIError {
            if error.kind != .cancelled { actionError = error.message }
        } catch {
            actionError = "加载更早消息失败。"
        }
        isLoadingOlder = false
    }

    /// 补拉新消息：SSE 只给摘要，需用 after 游标循环补齐。
    func fetchNewer() async {
        guard let newest = newestId else {
            await loadAll()
            return
        }
        var cursor = newest
        var mergedAny = false
        for _ in 0..<5 {
            do {
                let page = try await api.messages(conversationId: conversationId, after: cursor)
                if page.payload.isEmpty { break }
                merge(page.payload)
                mergedAny = true
                if let maxId = page.payload.map({ $0.id }).max(), maxId > cursor {
                    cursor = maxId
                }
                if page.payload.count < AppConfig.pageSize { break }
            } catch let error as APIError {
                if error.kind != .cancelled { loadError = error.message }
                break
            } catch {
                break
            }
        }
        // 有新消息就必须立刻上报水位，否则会话列表的未读角标要等节流窗口过去才清。
        await markVisibleAsRead(force: mergedAny)
    }

    /// 重新拉取最近一页（用于内容被修改的摘要事件）。
    private func refreshLatestWindow() async {
        do {
            let page = try await api.messages(conversationId: conversationId)
            merge(page.payload)
            if newestId == nil { newestId = messages.last?.id }
        } catch {
            // 静默失败，下一次事件或下拉刷新会补齐。
        }
    }

    private func merge(_ incoming: [Message]) {
        guard !incoming.isEmpty else { return }
        var indexByID: [Int: Int] = [:]
        for (index, message) in messages.enumerated() {
            indexByID[message.id] = index
        }
        for message in incoming {
            if let index = indexByID[message.id] {
                messages[index] = Self.merged(local: messages[index], remote: message)
            } else {
                messages.append(message)
                indexByID[message.id] = messages.count - 1
            }
            if let echoId = message.echoId {
                pending.removeAll { $0.id == echoId }
            }
        }
        messages.sort { $0.id < $1.id }
        if let first = messages.first { oldestId = min(oldestId ?? first.id, first.id) }
        if let last = messages.last { newestId = max(newestId ?? last.id, last.id) }
    }

    /// 合并一条本地已有的消息与服务端返回的同一条。
    ///
    /// 已读相关的两个字段**只允许前进**，绝不回退：
    /// - `read_at`：取较大值。
    /// - `status`：一旦变成 `read` 就锁定，除非服务端明确说 `failed`。
    ///
    /// 之前只比较了 `read_at`，当服务端快照的 `read_at` 与本地**相等**时
    /// 会整条覆盖，把刚收到的 `read` 又改回 `sent`——这正是「访客已经读了、
    /// APP 却一直灰色单勾」的原因之一：`loadAll` / `refreshLatestWindow`
    /// 的旧快照随时可能把蓝色双勾打回去。
    private static func merged(local: Message, remote: Message) -> Message {
        var result = remote
        // 撤回与编辑是单向的，本地已经知道就不要被旧快照抹掉。
        if (local.recalledAt ?? 0) > (remote.recalledAt ?? 0) {
            result.recalledAt = local.recalledAt
        }
        if (local.editedAt ?? 0) > (remote.editedAt ?? 0) {
            result.editedAt = local.editedAt
        }
        // 服务端明确失败时以服务端为准，不用本地状态回填。
        if remote.status == "failed" { return result }

        let localReadAt = local.readAt ?? 0
        let remoteReadAt = remote.readAt ?? 0
        if localReadAt > remoteReadAt {
            result.readAt = localReadAt
        }
        // 已读是不可逆的：本地已经是 read，就保持 read。
        if local.status == "read", (localReadAt > 0 || remoteReadAt > 0), result.status != "read" {
            result.status = "read"
        }
        if result.status == "read", (result.readAt ?? 0) <= 0 {
            // read 但缺 read_at 的快照不可信，退回本地的时间戳。
            result.readAt = localReadAt > 0 ? localReadAt : nil
            if result.readAt == nil { result.status = local.status == "read" ? "sent" : local.status }
        }
        return result
    }

    // MARK: 发送

    func send(text rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 16000 else {
            actionError = "消息过长：服务器上限为 16000 字节。"
            return
        }
        let item = PendingMessage(
            id: "ios-\(UUID().uuidString)",
            text: text,
            jpegData: nil,
            createdAt: Int(Date().timeIntervalSince1970),
            state: .sending,
            errorText: nil
        )
        pending.append(item)
        justSent = true
        publishTyping(false)
        Task { await performSend(pendingId: item.id) }
    }

    func sendImage(jpegData: Data, caption rawCaption: String) {
        let caption = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard caption.utf8.count <= 16000 else {
            actionError = "说明文字过长：服务器上限为 16000 字节。"
            return
        }
        let item = PendingMessage(
            id: "ios-\(UUID().uuidString)",
            text: caption,
            jpegData: jpegData,
            createdAt: Int(Date().timeIntervalSince1970),
            state: .sending,
            errorText: nil
        )
        pending.append(item)
        justSent = true
        publishTyping(false)
        Task { await performSend(pendingId: item.id) }
    }

    func retry(pendingId: String) async {
        await performSend(pendingId: pendingId)
    }

    func discard(pendingId: String) {
        pending.removeAll { $0.id == pendingId }
    }

    private func performSend(pendingId: String) async {
        guard let index = pending.firstIndex(where: { $0.id == pendingId }) else { return }
        pending[index].state = .sending
        pending[index].errorText = nil
        let item = pending[index]
        do {
            let message: Message
            if let data = item.jpegData {
                message = try await api.sendImage(
                    conversationId: conversationId,
                    jpegData: data,
                    caption: item.text,
                    echoId: item.id
                )
            } else {
                message = try await api.sendText(
                    conversationId: conversationId,
                    content: item.text,
                    echoId: item.id
                )
            }
            merge([message])
            pending.removeAll { $0.id == pendingId }
            await refreshConversation()
        } catch let error as APIError {
            if let index = pending.firstIndex(where: { $0.id == pendingId }) {
                pending[index].state = .failed
                pending[index].errorText = error.message
            }
        } catch {
            if let index = pending.firstIndex(where: { $0.id == pendingId }) {
                pending[index].state = .failed
                pending[index].errorText = "发送失败，请重试。"
            }
        }
    }

    /// 供图片处理等界面侧失败使用。
    func presentError(_ text: String) {
        actionError = text
    }

    // MARK: 已读

    /// 会话查看水位 + 逐条回执（只标访客公开消息）。
    ///
    /// `force` 用于「刚拉到新消息」的场景：这时候必须立刻把水位推到最新，
    /// 否则服务端 unread_count 不会变，会话列表的红色角标会一直挂着。
    func markVisibleAsRead(force: Bool = false) async {
        guard !messages.isEmpty else { return }
        let unreadIncoming = messages.filter {
            $0.type == .incoming && !$0.isPrivateNote && $0.readAt == nil
        }
        // 平时节流 2 秒（轮询兜底时会频繁调到这里），有新消息则强制上报。
        if force || Date().timeIntervalSince(lastSeenSentAt) >= 2 {
            lastSeenSentAt = Date()
            // 服务端返回的就是「这个用户此刻的真实未读数」，比本地推算可靠。
            if let unread = try? await api.markSeen(conversationId: conversationId) {
                applyUnread(unread)
            }
        }
        let ids = unreadIncoming.map { $0.id }.filter { !lastReceiptBatch.contains($0) }
        guard !ids.isEmpty else { return }
        let batch = Array(ids.prefix(100))
        do {
            try await api.markReceipts(conversationId: conversationId, messageIds: batch)
            lastReceiptBatch.formUnion(batch)
        } catch {
            // 回执失败不影响聊天展示。
        }
    }

    /// 主动补问「我发出的消息被访客读了没有」。
    ///
    /// `message.read` 事件是不可靠通道：断线、重连、切前后台、被代理缓冲
    /// 都可能漏掉，而漏掉的表现就是「访客明明看了，APP 永远是灰色单勾」。
    /// 进入会话、SSE 恢复、回到前台时各问一次，把这段空窗补齐。
    /// 用 GET 不会把消息标成已读，纯读取，安全。
    func refreshOutgoingReceipts() async {
        let pendingRead = messages
            .filter { $0.type == .agent && !$0.isPrivateNote && ($0.readAt ?? 0) == 0 && $0.status != "failed" }
            .suffix(100)
            .map { $0.id }
        guard !pendingRead.isEmpty else { return }
        guard let receipts = try? await api.messageReceipts(
            conversationId: conversationId,
            messageIds: Array(pendingRead)
        ) else { return }
        applyReceipts(receipts)
    }

    /// 用服务端给的未读数刷新本地会话对象，并广播给会话列表。
    /// 这个值来自 `update_last_seen` 的返回值，是当前这一刻的真实未读数，
    /// 所以标记为 authoritative——列表必须采信，包括清零。
    private func applyUnread(_ count: Int) {
        guard conversation.unreadCount != count else { return }
        conversation.unreadCount = count
        ConversationCache.publish(conversation, unreadAuthoritative: true)
    }

    /// 把服务端回执合并进本地消息（只让已读状态前进）。
    ///
    /// 图标规则与 `Message.deliveryState` 一致：只有 `status == "read"` 且
    /// `read_at > 0` 且非私密备注才显示蓝色双勾。所以这里必须把两个字段
    /// **一起**写成 `read`，只写 status 而不写 readAt 是不会变蓝的
    /// （反之亦然）——`conversation.read` 事件里没有 `read_at` 时就走重拉详情，
    /// 绝不拿"未读"去猜。
    private func applyReceipts(_ receipts: [MessageReceipt]) {
        guard !receipts.isEmpty else { return }
        var indexByID: [Int: Int] = [:]
        for (index, message) in messages.enumerated() {
            indexByID[message.id] = index
        }
        for receipt in receipts {
            guard let index = indexByID[receipt.id] else { continue }
            let stamp = receipt.readAt ?? 0
            let current = messages[index].readAt ?? 0
            if stamp > 0 {
                // 时间戳只前进；相等时也要补写 status，否则服务端回执
                // 带了同样的 read_at、但本地还停在 sent 的情况会漏掉。
                if stamp >= current {
                    messages[index].readAt = max(stamp, current)
                    messages[index].status = "read"
                }
                continue
            }
            // 没有 read_at：只在本地本来就没读过时采纳状态，且绝不把 read 降级。
            if current == 0, let status = receipt.status, messages[index].status != "read" {
                messages[index].status = status
            }
        }
    }

    // MARK: 正在输入

    /// 输入框内容变化时调用。仿网页 typing.js：300ms 节流、空闲 2 秒发 off。
    func userIsTyping(hasText: Bool) {
        guard canReply else { return }
        typingIdleTask?.cancel()
        guard hasText else {
            publishTyping(false)
            return
        }
        publishTyping(true)
        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.publishTyping(false)
        }
    }

    /// 离开聊天页 / 进后台时调用，确保对方不会一直看到「正在输入」。
    func stopTyping() {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        publishTyping(false)
    }

    private func publishTyping(_ on: Bool) {
        if on {
            let now = Date()
            guard !typingOn || now.timeIntervalSince(lastTypingSentAt) >= 0.3 else { return }
            typingOn = true
            lastTypingSentAt = now
        } else {
            guard typingOn else { return }
            typingOn = false
            lastTypingSentAt = Date()
        }
        let target = on
        Task { try? await api.setTyping(conversationId: conversationId, on: target) }
    }

    /// 收到 typing_on 时刷新过期时间。
    ///
    /// 服务端租约 3 秒（`typing_mode: heartbeat`），访客持续输入时每 300ms 续租
    /// 并推一次 `typing_on`。所以：
    /// - 过期时间按 `lease_ms` 算，**不要**盲目放大到 8 秒。放大会让「访客已经停下」
    ///   之后气泡还挂着好几秒，看起来像卡住。
    /// - 加一点冗余（+1 秒）抵消网络抖动，避免续租事件路上慢半拍导致气泡闪烁。
    /// - 上限仍保留 8 秒，挡住异常大的 lease 值。
    private func markPeerTyping(leaseMs: Int?, typingMode: String?) {
        let lease = leaseMs ?? 3000
        // state 模式是原生客户端的长租约；管理员看到的访客打字是短租约。
        let upper: Int = typingMode == "state" ? 120_000 : 8000
        let capped = min(max(lease, 1000) + 1000, upper)
        let expiry = Date().addingTimeInterval(Double(capped) / 1000)
        // 只往后延，不往回缩：乱序到达的旧事件不能把气泡提前掐掉。
        if let current = peerTypingExpiry, current > expiry {
            return
        }
        peerTypingExpiry = expiry
        if !peerTyping { peerTyping = true }
        schedulePeerTypingExpiry()
    }

    private func clearPeerTyping() {
        peerTypingTask?.cancel()
        peerTypingTask = nil
        peerTypingExpiry = nil
        if peerTyping { peerTyping = false }
    }

    private func schedulePeerTypingExpiry() {
        peerTypingTask?.cancel()
        guard let expiry = peerTypingExpiry else { return }
        let delay = max(0, expiry.timeIntervalSinceNow)
        peerTypingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let expiry = self.peerTypingExpiry, expiry <= Date() {
                self.clearPeerTyping()
            }
        }
    }

    // MARK: 轮询兜底

    /// 由视图把 `app.realtimeHealthy` 同步进来。
    ///
    /// **注意这里刻意不再「连上就彻底停掉轮询」。**
    ///
    /// 网页端的做法是 `setTimeout(poll, realtime.isConnected() ? 30000 : 5000)`
    /// ——SSE 正常时是 30 秒的极低频兜底，断开时才 5 秒。它从不把轮询关到 0，
    /// 因为 `EventSource` 的 `isConnected` 同样只是「握手成功」，代理缓冲时也骗人。
    ///
    /// 我上一版把「连上」直接当成「不必兜底」，一旦 SSE 的某个事件被吞
    /// （代理缓冲、事件名不匹配、连接半死），就再也没有第二条通道把状态追回来，
    /// 表现就是「必须手动返回再进入」。
    ///
    /// 现在改成两档：健康 → 15 秒淡兜底；不健康 → 2 秒快兜底。
    /// 两者都保留，只是频率不同。
    func setRealtimeHealthy(_ healthy: Bool) {
        guard realtimeHealthy != healthy else { return }
        realtimeHealthy = healthy
        // 无论切到哪一档都要重建循环，间隔不同。
        stopPolling()
        startPolling(interval: healthy ? Self.steadyPollInterval : Self.fallbackPollInterval)
        if healthy {
            Task { [weak self] in
                guard let self, self.didLoad else { return }
                // 恢复实时后立刻补齐断线期间可能漏掉的三类状态。
                await self.pollOnce()
                await self.refreshOutgoingReceipts()
            }
        }
    }

    /// 健康时 15 秒、断开时 2 秒。网页端是 30s / 5s，移动端用户更在意即时性，
    /// 但 15 秒一次只查增量（after_id + 回执），负载可以忽略。
    private static let steadyPollInterval: UInt64 = 15_000_000_000
    private static let fallbackPollInterval: UInt64 = 2_000_000_000

    /// 开始兜底循环。**重复调用是安全的**：已在跑且间隔相同时直接返回。
    func startPolling(interval: UInt64 = ChatModel.fallbackPollInterval) {
        if let pollTask, pollInterval == interval { return }
        self.pollTask?.cancel()
        pollInterval = interval
        self.pollTask = Task { [weak self] in
            // 先立刻补一次，进入页面 / 刚断线都不用等。
            if let self, self.didLoad, !Task.isCancelled {
                await self.pollOnce()
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.pollOnce()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollInterval = 0
    }

    private func pollOnce() async {
        // 0) 先拉新消息。
        //
        // 这一步是「实时」的真正保险：SSE 在某些代理/CDN 后面会被缓冲甚至直接掐断，
        // 一旦断掉，只轮询回执和输入状态的话，新消息要等用户退出再进来才会出现。
        // 兜底生效期间每 2 秒补一次增量，实时通道完全不通时聊天页也能自己追上。
        if newestId != nil {
            await fetchNewer()
        } else if messages.isEmpty {
            await refreshLatestWindow()
        }
        // 1) 自己发出的、还没被读的消息，问服务端有没有回执。
        await refreshOutgoingReceipts()
        // 2) 访客是否正在输入。
        await refreshPeerTyping()
    }

    /// 主动查一次「访客在不在打字」。GET 无副作用，可随时调用。
    func refreshPeerTyping() async {
        guard !isBlocked else {
            clearPeerTyping()
            return
        }
        guard let status = try? await api.typingStatus(conversationId: conversationId) else { return }
        if status.typing {
            if !peerTyping {
                markPeerTyping(leaseMs: 4000, typingMode: nil)
            } else if let expiry = peerTypingExpiry, expiry.timeIntervalSinceNow < 1.5 {
                // 还在打字就顺延，避免气泡每次兜底都闪一下。
                markPeerTyping(leaseMs: 4000, typingMode: nil)
            }
        } else if peerTyping {
            clearPeerTyping()
        }
    }

    // MARK: 会话操作

    func refreshConversation() async {
        do {
            let updated = try await api.conversation(id: conversationId)
            conversation = updated
            ConversationCache.publish(updated)
        } catch {
            // 静默：界面继续使用旧数据。
        }
    }

    func setBlocked(_ blocked: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        actionError = nil
        actionNotice = nil
        do {
            let updated = try await api.setBlocked(conversationId: conversationId, blocked: blocked)
            conversation = updated
            ConversationCache.publish(updated)
            actionNotice = blocked ? "已屏蔽该访客，访客将无法继续发送消息。" : "已解除屏蔽。"
        } catch let error as APIError {
            actionError = error.message
        } catch {
            actionError = "操作失败，请重试。"
        }
        isUpdating = false
    }

    func setStatus(_ status: String) async {
        guard !isUpdating else { return }
        isUpdating = true
        actionError = nil
        actionNotice = nil
        do {
            try await api.setStatus(conversationId: conversationId, status: status)
            await refreshConversation()
            actionNotice = status == "resolved" ? "已标记为已完成。" : "已重新打开会话。"
        } catch let error as APIError {
            actionError = error.message
        } catch {
            actionError = "操作失败，请重试。"
        }
        isUpdating = false
    }

    // MARK: 编辑与撤回

    /// 编辑自己发出的文本消息。成功返回 true，本地那条消息直接替换成服务端版本。
    /// 服务端规则：只能改自己发的、未撤回的纯文本消息；带图片返回 422。
    func edit(message: Message, content rawContent: String) async -> Bool {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            actionError = "消息内容不能为空。"
            return false
        }
        guard content.utf8.count <= 16000 else {
            actionError = "消息过长：服务器上限为 16000 字节。"
            return false
        }
        guard content != message.text else { return true }
        guard !isUpdating else { return false }
        isUpdating = true
        actionError = nil
        actionNotice = nil
        do {
            let updated = try await api.editMessage(
                conversationId: conversationId,
                messageId: message.id,
                content: content
            )
            merge([updated])
            isUpdating = false
            return true
        } catch let error as APIError {
            actionError = error.message
        } catch {
            actionError = "编辑失败，请重试。"
        }
        isUpdating = false
        return false
    }

    /// 撤回自己发出的消息。撤回后正文与图片都会被服务端清空，无法恢复。
    func recall(message: Message) async -> Bool {
        guard !isUpdating else { return false }
        isUpdating = true
        actionError = nil
        actionNotice = nil
        do {
            let updated = try await api.recallMessage(
                conversationId: conversationId,
                messageId: message.id
            )
            merge([updated])
            actionNotice = "消息已撤回。"
            isUpdating = false
            return true
        } catch let error as APIError {
            actionError = error.message
        } catch {
            actionError = "撤回失败，请重试。"
        }
        isUpdating = false
        return false
    }

    func clearActionMessage() {
        actionError = nil
        actionNotice = nil
    }

    // MARK: 实时事件

    /// 串行事件队列。
    ///
    /// 网页端 `realtime.js` 用 `chain = chain.then(...)` 把事件排成一条队列，
    /// 因为 `message.created` 后紧接 `message.read` 是常态：并发处理会让
    /// 「刚读过的消息」被「创建」快照覆盖回未读，然后表现为永久单勾。
    ///
    /// 视图侧原先写 `Task { await model.handle(event:) }`，每个事件各起一个 task，
    /// 顺序完全随机。现在统一走这里：入队后按顺序 `await`。
    func enqueue(event: RealtimeEvent) {
        eventQueue.append(event)
        guard !isDrainingEvents else { return }
        isDrainingEvents = true
        Task { [weak self] in
            guard let self else { return }
            while !self.eventQueue.isEmpty {
                let next = self.eventQueue.removeFirst()
                await self.handle(event: next)
            }
            self.isDrainingEvents = false
        }
    }

    func handle(event: RealtimeEvent) async {
        switch event.kind {
        case .messageCreated:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            // 对方发来消息，说明已经不在打字了。
            if event.messageType == 0 { clearPeerTyping() }
            // 首次加载还没结束时不必补拉：loadAll 拿到的就是最新一页。
            guard didLoad else { return }
            await fetchNewer()
        case .messageRead:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            // 只有「我们发出的消息被对方读了」才会改变本页的勾选状态。
            // 事件里的 reader_type 说明是谁读的：管理员侧发出去的消息，
            // 应该由 visitor 读；agent 读的是访客消息，和我们的勾选无关。
            if let reader = event.readerType, reader == "agent" {
                // 自己（或另一位客服）读掉了访客消息，只会影响未读数。
                return
            }
            if let messageId = event.messageId {
                // 直接用事件里的 read_at 更新那一条，比重拉整页更快也不会漏。
                applyReceipts([
                    MessageReceipt(id: messageId, status: event.status ?? "read", readAt: event.readAt)
                ])
            } else {
                await refreshLatestWindow()
            }
        case .messageUpdated:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            await refreshLatestWindow()
        case .conversationRead:
            // 已读水位变化（自己这台设备、自己的另一台设备，或网页后台读的）。
            // 事件里的未读数是按 user 算的，只有属于当前用户才可以直接采信。
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            if let owner = event.userId, owner != userId { return }
            // 注意：这是「管理员已读访客消息」的水位，不含访客读我们消息的状态。
            // 所以它只更新未读数，**不能**顺手把本页的 outgoing 消息标成已读。
            if let unread = event.unreadCount {
                applyUnread(unread)
            } else {
                await refreshConversation()
            }
        case .conversationUpdated, .conversationStatusChanged:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            await refreshConversation()
        case .typingOn:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            // 只关心访客的输入状态；自己的 typing 服务端不会回推。
            guard event.actorType == "visitor", !isBlocked else { return }
            markPeerTyping(leaseMs: event.leaseMs, typingMode: event.typingMode)
        case .typingOff:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            guard event.actorType == "visitor" else { return }
            clearPeerTyping()
        case .resyncRequired:
            await loadAll()
            await pollOnce()
        default:
            break
        }
    }
}
