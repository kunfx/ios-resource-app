import SwiftUI
import UIKit
import Combine

struct ConversationListScreen: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ConversationListModel

    private let title: String
    private let showsFilter: Bool
    private let showsBackButton: Bool
    private let reservesDockSpace: Bool

    init(
        session: AppSession,
        title: String,
        inboxId: Int? = nil,
        showsFilter: Bool = true,
        showsBackButton: Bool = false,
        reservesDockSpace: Bool = true
    ) {
        self.title = title
        self.showsFilter = showsFilter
        self.showsBackButton = showsBackButton
        self.reservesDockSpace = reservesDockSpace && !showsBackButton
        _model = StateObject(wrappedValue: ConversationListModel(session: session, inboxId: inboxId))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: reservesDockSpace ? 76 : 0)
        }
        .task {
            await model.loadIfNeeded()
        }
        .onReceive(app.events) { event in
            Task { await model.handle(event: event) }
        }
    }

    // MARK: 顶部

    private var header: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            HStack {
                if showsBackButton {
                    CircleIconButton(systemName: "chevron.left", size: 34, iconSize: 15) {
                        dismiss()
                    }
                } else {
                    Color.clear.frame(width: 34, height: 34)
                }
                Spacer()
                if showsFilter {
                    filterMenu
                } else {
                    Color.clear.frame(width: 34, height: 34)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var filterMenu: some View {
        Menu {
            Picker("筛选", selection: $model.filter) {
                ForEach(ConversationListModel.Filter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        } label: {
            ZStack {
                Circle().fill(Color(uiColor: .secondarySystemBackground))
                Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                VStack(spacing: 3.5) {
                    Capsule().frame(width: 15, height: 1.6)
                    Capsule().frame(width: 10, height: 1.6)
                    Capsule().frame(width: 5, height: 1.6)
                }
                .foregroundStyle(Color.primary)
            }
            .frame(width: 34, height: 34)
        }
        .accessibilityLabel("筛选会话")
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorMessage = model.errorMessage, model.items.isEmpty {
            emptyState(
                icon: "wifi.exclamationmark",
                title: "无法加载会话",
                message: errorMessage,
                actionTitle: "重试"
            ) {
                Task { await model.reload() }
            }
        } else if model.items.isEmpty {
            emptyState(
                icon: "tray",
                title: "暂无会话",
                message: filterHint,
                actionTitle: nil,
                action: nil
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { conversation in
                        NavigationLink(value: ChatRoute(id: conversation.id)) {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if conversation.id == model.items.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                        Divider()
                            .padding(.leading, 72)
                    }
                    if model.isLoadingMore {
                        ProgressView()
                            .padding(.vertical, 14)
                    }
                }
            }
            .refreshable {
                await model.refresh()
            }
        }
    }

    private var filterHint: String {
        switch model.filter {
        case .open: return "当前没有待处理的会话"
        case .resolved: return "当前没有已完成的会话"
        case .all: return "有新访客消息时会显示在这里"
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 会话行

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            InitialsAvatar(name: conversation.visitorName, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(conversation.visitorName) #\(conversation.id)")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if conversation.isResolved {
                        Text("已完成")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                    }
                }

                HStack(spacing: 4) {
                    if isOutgoingPreview {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text(previewText)
                        .lineLimit(1)
                        .font(.system(size: 14))
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(TimeFormat.listLabel(conversation.activityTimestamp))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let unread = conversation.unreadCount, unread > 0 {
                    UnreadBadge(count: unread)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var isOutgoingPreview: Bool {
        guard let message = conversation.previewMessage else { return false }
        return message.type == .agent
    }

    private var previewText: String {
        guard let message = conversation.previewMessage else { return "暂无消息" }
        let text = message.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.images.isEmpty {
            return text.isEmpty ? "[图片]" : "[图片] \(text)"
        }
        return text.isEmpty ? "[非文本消息]" : text
    }
}
