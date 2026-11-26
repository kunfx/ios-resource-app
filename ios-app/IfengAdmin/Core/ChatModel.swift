import Foundation
import SwiftUI

/// 列表已经加载过的会话快照，供聊天页首帧直接复用，避免先闪一下「访客 #123」。
/// 只做内存缓存，不持久化；真实数据仍以会话详情接口为准。
@MainActor
enum ConversationCache {
    private static var storage: [Int: Conversation] = [:]

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

    static func conversation(id: Int) -> Conversation? {
        storage[id]
    }
}

/// 单个会话的聊天数据源：历史分页、发送、已读、正在输入、访客屏蔽/会话状态、SSE 增量。
///
/// 实时策略是「SSE 主 + 轮询兜底」：
/// - SSE 正常时，已读回执和正在输入都是毫秒级；
/// - 万一实时通道断掉，轮询会以 2 秒间隔把两个状态追上，界面上不会出现"永远单勾"。
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

    // 轮询兜底
    private var pollTask: Task<Void, Never>?

    init(session: AppSession, conversationId: Int, seed: Conversation? = nil) {
        self.api = session.api
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
        guard !didLoad else { return }
        didLoad = true
        await loadAll()
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
            ConversationCache.store(loadedConversation)
            messages = loadedPage.payload.sorted { $0.id < $1.id }
            oldestId = messages.first?.id
            newestId = messages.last?.id
            hasMoreOlder = loadedPage.payload.count >= AppConfig.pageSize
            loadError = nil
            await markVisibleAsRead()
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
        for _ in 0..<5 {
            do {
                let page = try await api.messages(conversationId: conversationId, after: cursor)
                if page.payload.isEmpty { break }
                merge(page.payload)
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
        await markVisibleAsRead()
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
                // 已读时间只前进不后退，避免较旧快照把蓝色双勾打回灰色单勾。
                var merged = message
                if let existing = messages[index].readAt, existing > (message.readAt ?? 0) {
                    merged.readAt = existing
                    if messages[index].status == "read" { merged.status = "read" }
                }
                messages[index] = merged
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
    func markVisibleAsRead() async {
        guard !messages.isEmpty else { return }
        let unreadIncoming = messages.filter {
            $0.type == .incoming && !$0.isPrivateNote && $0.readAt == nil
        }
        // 轮询每 2 秒会调到这里，update_last_seen 节流到 8 秒一次，避免刷接口。
        if Date().timeIntervalSince(lastSeenSentAt) >= 8 {
            lastSeenSentAt = Date()
            try? await api.markSeen(conversationId: conversationId)
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

    /// 把服务端回执合并进本地消息（只让已读时间前进）。
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
            if stamp > 0, stamp >= current {
                if messages[index].status != "read" || messages[index].readAt != stamp {
                    messages[index].status = "read"
                    messages[index].readAt = stamp
                }
            } else if current == 0, let status = receipt.status, messages[index].status != status {
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

    /// 收到 typing_on 时刷新过期时间。lease 与网页保持一致：最多 8 秒。
    private func markPeerTyping(leaseMs: Int?, typingMode: String?) {
        let fallback = 3000
        let lease = leaseMs ?? fallback
        // state 模式是原生客户端用的长租约；管理员这边看到访客打字，仍是短租约。
        let capped = min(max(lease, 1000), typingMode == "state" ? 120_000 : 8000)
        peerTypingExpiry = Date().addingTimeInterval(Double(capped) / 1000)
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

    /// 聊天页可见时启动。SSE 通的时候它只是冗余校验，SSE 断了它就是唯一来源。
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollOnce()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        // 0) 先拉新消息。
        //
        // 这一步是「实时」的真正保险：SSE 在某些代理/CDN 后面会被缓冲甚至直接掐断，
        // 一旦断掉，旧实现只轮询回执和输入状态，新消息要等用户退出再进来才会出现。
        // 这里每 2 秒补一次增量，即使实时通道完全不通，聊天页也能自己追上。
        if newestId != nil {
            await fetchNewer()
        } else if messages.isEmpty {
            await refreshLatestWindow()
        }
        // 1) 自己发出的、还没被读的消息，问服务端有没有回执。
        let outgoing = messages
            .filter { $0.type == .agent && !$0.isPrivateNote && ($0.readAt ?? 0) == 0 }
            .suffix(100)
            .map { $0.id }
        if !outgoing.isEmpty {
            if let receipts = try? await api.messageReceipts(conversationId: conversationId, messageIds: Array(outgoing)) {
                applyReceipts(receipts)
            }
        }
        // 2) 访客是否正在输入。
        if let status = try? await api.typingStatus(conversationId: conversationId) {
            if status.typing {
                if !peerTyping {
                    markPeerTyping(leaseMs: 4000, typingMode: nil)
                } else if let expiry = peerTypingExpiry, expiry.timeIntervalSinceNow < 1.5 {
                    // 还在打字就顺延，避免气泡每两秒闪一下。
                    markPeerTyping(leaseMs: 4000, typingMode: nil)
                }
            } else if peerTyping {
                clearPeerTyping()
            }
        }
    }

    // MARK: 会话操作

    func refreshConversation() async {
        do {
            let updated = try await api.conversation(id: conversationId)
            conversation = updated
            ConversationCache.store(updated)
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
            ConversationCache.store(updated)
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

    func handle(event: RealtimeEvent) async {
        switch event.kind {
        case .messageCreated:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            // 对方发来消息，说明已经不在打字了。
            if event.messageType == 0 { clearPeerTyping() }
            await fetchNewer()
        case .messageRead:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
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
