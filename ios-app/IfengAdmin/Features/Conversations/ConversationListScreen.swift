import SwiftUI
import UIKit
import Combine

/// 会话列表。同一个视图被复用三处：
/// 1. 底部「会话」Tab（全部会话）；
/// 2. 收件箱下钻（带 inbox_id 过滤）；
/// 3. 深链跳转后的返回栈。
struct ConversationListScreen: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let session: AppSession
    let title: String
    let inboxId: Int?
    let showsBackButton: Bool

    @StateObject private var model: ConversationListModel

    init(session: AppSession, title: String, inboxId: Int? = nil, showsBackButton: Bool) {
        self.session = session
        self.title = title
        self.inboxId = inboxId
        self.showsBackButton = showsBackButton
        _model = StateObject(wrappedValue: ConversationListModel(session: session, inboxId: inboxId))
    }

    var body: some View {
        content
            .background(Theme.screenBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if showsBackButton {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ToolbarIconButton(name: "chevron-left", label: "返回", size: 21, diameter: 32) {
                            dismiss()
                        }
                    }
                }
                // 只保留筛选图标。
                // 列表本来就是实时的（SSE + 常驻兜底），再放一个手动刷新既多余又占位置；
                // 真想手动刷新，下拉即可（`refreshable`）。
                ToolbarItem(placement: .navigationBarTrailing) {
                    filterMenu
                }
            }
            .task {
                // 首次进入加载；从聊天页返回时强制拉一次真实未读数，
                // 不能把离开时的缓存当成最新状态。
                await model.activate()
                // 持续兜底：不依赖 SSE 状态先回传，健康时自动降到 15 秒一次。
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: model.pollInterval)
                    guard !Task.isCancelled else { return }
                    await model.refresh()
                }
            }
            .task(id: app.realtimeHealthy) {
                // 只调整兜底频率：健康 15 秒 / 不健康 3 秒。参照网页端
                // schedulePoll(30s / 5s) —— SSE 正常时也保留低频兜底，
                // 这样即使某个事件被静默吞掉，角标也会在十几秒内自愈。
                await model.setRealtimeHealthy(app.realtimeHealthy)
            }
            .onReceive(app.events) { event in
                // 串行入队，保证事件顺序。
                model.enqueue(event: event)
            }
    }

    // MARK: 筛选菜单

    private var filterMenu: some View {
        Menu {
            ForEach(ConversationListModel.Filter.allCases) { item in
                Button {
                    guard model.filter != item else { return }
                    model.filter = item
                } label: {
                    if model.filter == item {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            // 与其他工具栏图标一致：正圆底 + 图标，热区 44×44。
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.055))
                        .frame(width: 32, height: 32)
                    LucideIcon(name: "list-filter", size: 19, color: Theme.accent)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                if model.filter != .all {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: -10, y: 10)
                }
            }
        }
        .accessibilityLabel("筛选：\(model.filter.title)")
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载会话…")
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.errorMessage, model.items.isEmpty {
            errorState(message)
        } else if model.items.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(model.items) { conversation in
                NavigationLink(value: ChatRoute(id: conversation.id)) {
                    ConversationRow(conversation: conversation)
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    // 滚到最后一行时再取下一页，避免一次性拉太多。
                    guard conversation.id == model.items.last?.id else { return }
                    Task { await model.loadMore() }
                }
            }

            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, 10)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screenBackground)
        .refreshable {
            await model.refresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(name: "message-circle", size: 40, color: Color.secondary.opacity(0.5))
            Text(model.filter == .resolved ? "暂无已完成的会话" : "暂无会话")
                .font(.app(size: 15, weight: .medium))
            Text("访客发起咨询后会出现在这里。")
                .font(.app(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            LucideIcon(name: "circle-alert", size: 38, color: Theme.danger.opacity(0.8))
            Text("加载失败")
                .font(.app(size: 16, weight: .semibold))
            Text(message)
                .font(.app(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                Task { await model.reload() }
            } label: {
                HStack(spacing: 6) {
                    LucideIcon(name: "refresh-cw", size: 14, color: .white)
                    Text("重试")
                        .font(.app(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

// MARK: - 会话行

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.visitorName)
                        .font(.app(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if conversation.isResolved {
                        tag("已完成", color: Color.secondary)
                    } else if conversation.isBlocked {
                        tag("已屏蔽", color: Theme.danger)
                    }

                    Spacer(minLength: 4)

                    Text(TimeFormat.listLabel(conversation.activityTimestamp))
                        .font(.app(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(previewText)
                        .font(.app(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    if let unread = conversation.unreadCount, unread > 0 {
                        UnreadBadge(count: unread)
                            .padding(.top, 1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            InitialsAvatar(name: conversation.visitorName, size: 44)
            if conversation.isBlocked {
                ZStack {
                    Circle().fill(Theme.danger)
                    LucideIcon(name: "ban", size: 9, color: .white)
                }
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
                .offset(x: 2, y: 2)
            }
        }
    }

    private var previewText: String {
        guard let message = conversation.previewMessage else {
            return conversation.visitorDetails?.sourceUrl ?? "暂无消息"
        }
        var prefix = ""
        if message.type == .agent {
            prefix = "我："
        } else if message.type == .activity || message.type == .template {
            prefix = ""
        }
        if !message.images.isEmpty && message.text.isEmpty {
            return prefix + "[图片]"
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + (text.isEmpty ? "[图片]" : text)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.app(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
