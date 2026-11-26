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

/// 单个会话的聊天数据源：历史分页、发送、已读、访客屏蔽/会话状态、SSE 增量。
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

    let conversationId: Int
    private let api: APIClient
    private var didLoad = false
    private var oldestId: Int?
    private var newestId: Int?
    private var lastReceiptBatch: Set<Int> = []

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

    /// 重新拉取最近一页（用于消息已读/状态更新的摘要事件）。
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
                messages[index] = message
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
        try? await api.markSeen(conversationId: conversationId)
        let ids = unreadIncoming.map { $0.id }.filter { !lastReceiptBatch.contains($0) }
        guard !ids.isEmpty else { return }
        do {
            try await api.markReceipts(conversationId: conversationId, messageIds: Array(ids.prefix(100)))
            lastReceiptBatch.formUnion(ids.prefix(100))
        } catch {
            // 回执失败不影响聊天展示。
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

    func clearActionMessage() {
        actionError = nil
        actionNotice = nil
    }

    // MARK: 实时事件

    func handle(event: RealtimeEvent) async {
        switch event.kind {
        case .messageCreated:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            await fetchNewer()
        case .messageRead, .messageUpdated:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            await refreshLatestWindow()
        case .conversationUpdated, .conversationStatusChanged:
            guard event.conversationId == nil || event.conversationId == conversationId else { return }
            await refreshConversation()
        case .resyncRequired:
            await loadAll()
        default:
            break
        }
    }
}
