import Foundation
import SwiftUI

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
    private var page = 1
    private var didLoad = false

    init(session: AppSession, inboxId: Int? = nil) {
        self.api = session.api
        self.inboxId = inboxId
    }

    // MARK: 加载

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await reload()
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

    func handle(event: RealtimeEvent) async {
        switch event.kind {
        case .messageCreated, .conversationUpdated, .conversationStatusChanged, .messageRead:
            guard let conversationId = event.conversationId else { return }
            await refreshConversation(id: conversationId)
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
