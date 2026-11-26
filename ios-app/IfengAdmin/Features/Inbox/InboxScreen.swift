import SwiftUI
import UIKit

@MainActor
final class InboxModel: ObservableObject {
    @Published private(set) var inboxes: [Inbox] = []
    @Published private(set) var openCounts: [Int: Int] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private let api: APIClient
    private var didLoad = false

    init(session: AppSession) {
        self.api = session.api
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let list = try await api.inboxes()
            inboxes = list
            // 待处理数量来自会话列表的 meta.all_count（assignee 过滤前统计）。
            for inbox in list {
                if let page = try? await api.conversations(status: "open", page: 1, inboxId: inbox.id) {
                    openCounts[inbox.id] = page.data.meta?.allCount ?? 0
                }
            }
        } catch let error as APIError {
            if error.kind != .cancelled { errorMessage = error.message }
        } catch {
            errorMessage = "加载收件箱失败。"
        }
        isLoading = false
    }
}

struct InboxScreen: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: InboxModel

    init(session: AppSession) {
        _model = StateObject(wrappedValue: InboxModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 76)
        }
        .task {
            await model.loadIfNeeded()
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("收件箱")
                .font(.system(size: 17, weight: .semibold))
            Text("按渠道查看待处理会话")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.inboxes.isEmpty {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorMessage = model.errorMessage, model.inboxes.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("无法加载收件箱")
                    .font(.system(size: 15, weight: .medium))
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("重试") {
                    Task { await model.load() }
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                .foregroundStyle(Theme.accent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.inboxes.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("暂无收件箱")
                    .font(.system(size: 15, weight: .medium))
                Text("后台还没有创建网站渠道")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.inboxes) { inbox in
                        NavigationLink(value: InboxRoute(id: inbox.id, name: inbox.displayName)) {
                            InboxRow(inbox: inbox, openCount: model.openCounts[inbox.id])
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 66)
                    }
                }
            }
            .refreshable {
                await model.load()
            }
        }
    }
}

struct InboxRow: View {
    let inbox: Inbox
    let openCount: Int?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(uiColor: .secondarySystemBackground))
                LucideIcon(name: "inbox", size: 20, color: Theme.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(inbox.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let host = inbox.websiteHost {
                        Image(systemName: "globe")
                            .font(.system(size: 9))
                        Text(host)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    } else {
                        Text("网站渠道")
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let openCount {
                if openCount > 0 {
                    Text("\(openCount) 待处理")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent.opacity(0.10)))
                } else {
                    Text("无待处理")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
