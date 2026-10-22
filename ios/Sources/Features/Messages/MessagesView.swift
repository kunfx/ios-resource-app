import SwiftUI
import UIKit

struct MessagesView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var items: [Message] = []
    @State private var readIDs: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var lastPage = 1
    @State private var isLoadingMore = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    LoadingView(text: "加载消息")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load(reset: true) }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "bell.slash", title: "暂时没有新消息",
                                   message: "评论回复、系统通知会出现在这里")
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            messageCard(item)
                                .task {
                                    if item.id == items.last?.id {
                                        await load(reset: false)
                                    }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("站内消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") {
                    Task { await markAllRead() }
                }
                .font(.system(size: 13))
                .disabled(items.isEmpty)
            }
        }
        .refreshable { await load(reset: true) }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
    }

    private func messageCard(_ item: Message) -> some View {
        let isRead = item.isRead || readIDs.contains(item.id)

        return Button {
            Task { await open(item) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if !isRead {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    }

                    Text(item.title)
                        .font(.system(size: 14, weight: isRead ? .medium : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    Text(DateText.relative(item.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }

                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                if item.url != nil {
                    HStack(spacing: 3) {
                        Text("查看详情")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 14, radius: 16)
            .opacity(isRead ? 0.72 : 1)
        }
        .buttonStyle(.plain)
    }

    private func load(reset: Bool) async {
        if reset {
            page = 1
            isLoading = items.isEmpty
        } else {
            guard page < lastPage, !isLoadingMore else { return }
            isLoadingMore = true
        }

        do {
            let result: Page<Message> = try await APIClient.shared.get("/api/messages", query: [
                "page": "\(page)",
                "per_page": "20"
            ])

            lastPage = result.lastPage

            if reset {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
                page += 1
            }

            errorMessage = nil
        } catch {
            if reset { errorMessage = error.readableMessage }
        }

        isLoading = false
        isLoadingMore = false
    }

    private func open(_ item: Message) async {
        if !item.isRead && !readIDs.contains(item.id) {
            readIDs.insert(item.id)
            try? await APIClient.shared.postIgnoringData("/api/messages/\(item.id)/read")
            await session.refreshProfile(silent: true)
        }

        if let urlString = item.url, let url = URL(string: urlString) {
            _ = await UIApplication.shared.open(url)
        }
    }

    private func markAllRead() async {
        try? await APIClient.shared.postIgnoringData("/api/messages/read-all")
        readIDs = Set(items.map { $0.id })
        await session.refreshProfile(silent: true)
    }
}

struct PointsLogView: View {
    @State private var items: [PointLog] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var lastPage = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    LoadingView(text: "加载积分记录")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load(reset: true) }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "creditcard", title: "还没有积分记录")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                                .task {
                                    if item.id == items.last?.id {
                                        await load(reset: false)
                                    }
                                }
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("积分明细")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(reset: true) }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
    }

    private func row(_ item: PointLog) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.description ?? item.type)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(DateText.relative(item.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(item.isIncome ? "+" : "-")\(item.points)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(item.isIncome ? Theme.accent : Color.orange)

                Text("余额 \(item.afterPoints)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func load(reset: Bool) async {
        if reset {
            page = 1
            isLoading = items.isEmpty
        } else {
            guard page < lastPage else { return }
        }

        do {
            let result: Page<PointLog> = try await APIClient.shared.get("/api/points/logs", query: [
                "page": "\(page)",
                "per_page": "20"
            ])

            lastPage = result.lastPage

            if reset {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
                page += 1
            }

            errorMessage = nil
        } catch {
            if reset { errorMessage = error.readableMessage }
        }

        isLoading = false
    }
}
