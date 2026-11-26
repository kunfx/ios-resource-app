import Foundation
import SwiftUI
import Combine

/// 会话列表数据源：真实分页 + SSE 增量合并，筛选走服务端参数。
@MainActor
final class ConversationListModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case open
        case resolved
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .open: return "待处理"
            case .resolved: return "已完成"
            case .all: return "全部"
            }
        }
    }

    @Published private(set) var items: [Conversation] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published var filter: Filter = .all {
        didSet {
            guard oldValue != filter else { return }
            Task { await reload() }
        }
    }

    private let api: APIClient
    private let inboxId: Int?
    /// 当前登录用户。conversation.read 事件带 user_id，只认自己那条。
    private let userId: Int
    private var page = 1
    private var didLoad = false
    /// SSE 连接状态。nil = 还没收到过，用来区分「首次连接」和「断线恢复」。
    private var realtimeHealthy: Bool?
    /// 事件串行队列。
    private var eventQueue: [RealtimeEvent] = []
    private var isDrainingEvents = false
    /// 聊天页 / 网页后台改动的会话会通过缓存广播过来，这里订阅后直接改本地数组，
    /// 不需要重新请求整个列表。
    private var cacheObserver: AnyCancellable?

    init(session: AppSession, inboxId: Int? = nil) {
        self.api = session.api
        self.inboxId = inboxId
        self.userId = session.profile.id
        cacheObserver = ConversationCache.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }
                Task { @MainActor in self.applyCached(update) }
            }
    }

    // MARK: 加载

    /// 首次进入加载；从聊天页返回时强制拉一次真实数据。
    ///
    /// 返回列表这一步尤其重要：离开时列表可能停在旧未读数上，
    /// 而「把未读直接改成 0」是错的（服务端才是唯一依据），所以这里重新取一次。
    func activate() async {
        // 首次进工作台就申请角标权限（只申请 .badge，不弹任何通知）。
        AppBadge.requestAuthorizationIfNeeded()
        guard !didLoad else {
            await refresh()
            await refreshBadgeTotal()
            return
        }
        didLoad = true
        await reload()
        // 首屏拿到的是当前筛选的一页；角标要的是全账号总数，单独补一次。
        await refreshBadgeTotal()
    }

    /// 视图把 `app.realtimeHealthy` 同步进来。
    ///
    /// 和 `ChatModel` 同样的理由：这里只是**调整兜底频率**，不是开关。
    /// 网页端 `schedulePoll` 在 SSE 正常时仍然每 30 秒刷一次列表，
    /// 所以未读角标不会因为某个 SSE 事件被吞就永久停在旧值。
    /// - 健康 → 15 秒
    /// - 不健康 → 3 秒
    func setRealtimeHealthy(_ healthy: Bool) async {
        guard realtimeHealthy != healthy else { return }
        let wasHealthy = realtimeHealthy
        realtimeHealthy = healthy
        pollInterval = healthy ? Self.steadyPollInterval : Self.fallbackPollInterval
        guard healthy, wasHealthy == false, didLoad else { return }
        await refresh()
    }

    /// 兜底间隔（秒）。由视图的 task 使用。
    private(set) var pollInterval: UInt64 = 15_000_000_000
    static let steadyPollInterval: UInt64 = 15_000_000_000
    static let fallbackPollInterval: UInt64 = 3_000_000_000

    /// 当前展示的全部会话数据变化后，刷新桌面角标。
    ///
    /// 角标要求「列表中所有未读消息的总和」。这里刻意用**全量未读**而不是
    /// `items` 的合计：`items` 只装了当前筛选条件（待处理/已完成/全部）
    /// 的那一页，切到「已完成」时合计会掉下来，但用户心里的未读总数没变。
    func syncBadge(total: Int? = nil) {
        if let total {
            AppBadge.set(total)
            return
        }
        AppBadge.update(conversations: items)
    }

    /// 单独问一次「全账号未读总数」，用于角标。
    ///
    /// 服务端固定每页 20 条，所以需要翻页累加。这里限制最多 3 页（60 条会话）：
    /// - 未读几乎都集中在最近的会话里，翻三页足以覆盖；
    /// - 角标本身超过 99 就显示 99+，没必要为了精确值打出十几个请求。
    ///
    /// 只在「全量数据可能变化」的时机调用（首屏、下拉刷新、回到前台），
    /// 不在每个 SSE 事件后调用——事件路径用 `syncBadge()` 走本地增量。
    func refreshBadgeTotal() async {
        var total = 0
        var page = 1
        while page <= 3 {
            guard let result = try? await api.conversations(status: "all", page: page, inboxId: nil) else {
                // 请求失败就不要清零角标，保留上一次的值。
                return
            }
            let payload = result.data.payload
            total += AppBadge.totalUnread(payload)
            if payload.count < AppConfig.pageSize { break }
            page += 1
        }
        AppBadge.set(total)
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        let requestedFilter = filter
        do {
            let page = try await api.conversations(status: requestedFilter.rawValue, page: 1, inboxId: inboxId)
            guard requestedFilter == filter else { return }
            self.page = 1
            items = page.data.payload
            ConversationCache.store(items)
            hasMore = page.data.payload.count >= AppConfig.pageSize
            errorMessage = nil
            syncBadge()
        } catch let error as APIError {
            if error.kind == .cancelled { return }
            errorMessage = error.message
        } catch {
            errorMessage = "加载会话失败。"
        }
        isLoading = false
    }

    func refresh() async {
        // 下拉刷新只取第一页，避免把用户已加载的历史页打乱。
        let requestedFilter = filter
        do {
            let page = try await api.conversations(status: requestedFilter.rawValue, page: 1, inboxId: inboxId)
            guard requestedFilter == filter else { return }
            var merged = page.data.payload
            let ids = Set(merged.map { $0.id })
            for item in items where !ids.contains(item.id) {
                merged.append(item)
            }
            items = merged.sorted { $0.activityTimestamp > $1.activityTimestamp }
            ConversationCache.store(items)
            self.page = max(self.page, 1)
            hasMore = page.data.payload.count >= AppConfig.pageSize
            errorMessage = nil
            syncBadge()
        } catch let error as APIError {
            if error.kind != .cancelled { errorMessage = error.message }
        } catch {
            errorMessage = "刷新失败。"
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let nextPage = page + 1
        let requestedFilter = filter
        do {
            let result = try await api.conversations(status: requestedFilter.rawValue, page: nextPage, inboxId: inboxId)
            guard requestedFilter == filter else { return }
            page = nextPage
            let existing = Set(items.map { $0.id })
            let fresh = result.data.payload.filter { !existing.contains($0.id) }
            items.append(contentsOf: fresh)
            ConversationCache.store(fresh)
            hasMore = result.data.payload.count >= AppConfig.pageSize
        } catch let error as APIError {
            if error.kind != .cancelled { errorMessage = error.message }
        } catch {
            errorMessage = "加载更多失败。"
        }
        isLoadingMore = false
    }

    // MARK: 实时事件

    /// 串行事件队列（与 `ChatModel.enqueue` 同理，保证到达顺序 = 处理顺序）。
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
            guard let conversationId = event.conversationId else { return }
            await refreshConversation(id: conversationId)
        case .conversationUpdated, .conversationStatusChanged:
            guard let conversationId = event.conversationId else { return }
            await refreshConversation(id: conversationId)
        case .conversationRead:
            guard let conversationId = event.conversationId else { return }
            // 未读数是按用户算的：别人的已读事件跟我们无关。
            if let owner = event.userId, owner != userId { return }
            if let unread = event.unreadCount {
                applyUnread(id: conversationId, unread: unread)
            } else {
                await refreshConversation(id: conversationId)
            }
        case .resyncRequired:
            await reload()
        default:
            break
        }
    }

    func refreshConversation(id: Int) async {
        do {
            let conversation = try await api.conversation(id: id)
            if matchesFilter(conversation) {
                upsert(conversation)
            } else {
                items.removeAll { $0.id == id }
            }
        } catch let error as APIError {
            // 404 = 无权限或已删除；直接移除，不弹错。
            if error.kind == .notFound {
                items.removeAll { $0.id == id }
            }
        } catch {
            // 忽略单条刷新失败，等待下一次事件或下拉刷新。
        }
    }

    /// SSE 直接推来了未读数，不用再请求会话详情。
    private func applyUnread(id: Int, unread: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            syncBadge()
            return
        }
        guard items[index].unreadCount != unread else { return }
        items[index].unreadCount = unread
        ConversationCache.store(items[index])
        syncBadge()
    }

    /// 缓存广播：聊天页刷新了会话详情 / 清零了未读，列表跟着变。
    private func applyCached(_ update: ConversationCache.ConversationUpdate) {
        let conversation = update.conversation
        guard let index = items.firstIndex(where: { $0.id == conversation.id }) else {
            syncBadge()
            return
        }
        guard items[index] != conversation else { return }

        // 未读数是按用户算的最新值，只有权威来源（markSeen 返回值 / conversation.read
        // 事件）才允许覆盖；普通详情快照可能比它旧，覆盖会让刚清零的角标跳回来。
        guard update.unreadAuthoritative else {
            applyCachedWithoutUnread(conversation)
            return
        }
        if matchesFilter(conversation) {
            items[index] = conversation
            items.sort { lhs, rhs in
                if lhs.activityTimestamp == rhs.activityTimestamp { return lhs.id > rhs.id }
                return lhs.activityTimestamp > rhs.activityTimestamp
            }
        } else {
            items.removeAll { $0.id == conversation.id }
        }
        syncBadge()
    }

    /// 非权威快照：只同步预览内容 / 状态 / 时间，未读数保留本地的。
    private func applyCachedWithoutUnread(_ conversation: Conversation) {
        guard let index = items.firstIndex(where: { $0.id == conversation.id }) else { return }
        if conversation.activityTimestamp < items[index].activityTimestamp {
            // 更旧的快照连预览都不该覆盖。
            return
        }
        var merged = conversation
        merged.unreadCount = items[index].unreadCount
        if matchesFilter(merged) {
            items[index] = merged
            items.sort { lhs, rhs in
                if lhs.activityTimestamp == rhs.activityTimestamp { return lhs.id > rhs.id }
                return lhs.activityTimestamp > rhs.activityTimestamp
            }
        } else {
            items.removeAll { $0.id == conversation.id }
        }
        syncBadge()
    }

    private func matchesFilter(_ conversation: Conversation) -> Bool {
        switch filter {
        case .all: return true
        case .open: return conversation.status == "open"
        case .resolved: return conversation.status == "resolved"
        }
    }

    private func upsert(_ conversation: Conversation) {
        ConversationCache.store(conversation)
        if let index = items.firstIndex(where: { $0.id == conversation.id }) {
            items[index] = conversation
        } else {
            items.append(conversation)
        }
        items.sort { lhs, rhs in
            if lhs.activityTimestamp == rhs.activityTimestamp { return lhs.id > rhs.id }
            return lhs.activityTimestamp > rhs.activityTimestamp
        }
    }
}
