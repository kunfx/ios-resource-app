import SwiftUI
import UIKit

/// 收件箱列表。点击进入该收件箱下的会话列表（真实 inbox_id 过滤）。
struct InboxScreen: View {
    let session: AppSession

    @State private var inboxes: [Inbox] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && inboxes.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载收件箱…")
                        .font(.app(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, inboxes.isEmpty {
                errorState(errorMessage)
            } else if inboxes.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle("收件箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ToolbarIconButton(name: "refresh-cw", label: "刷新", size: 19) {
                    Task { await load() }
                }
            }
        }
        .task {
            if inboxes.isEmpty { await load() }
        }
    }

    private var list: some View {
        List {
            ForEach(inboxes) { inbox in
                NavigationLink(value: InboxRoute(id: inbox.id, name: inbox.displayName)) {
                    row(inbox)
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screenBackground)
        .refreshable { await load() }
    }

    private func row(_ inbox: Inbox) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                if let avatar = inbox.avatarUrl, let url = URL(string: avatar) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            LucideIcon(name: "inbox", size: 20, color: Theme.accent)
                        }
                    }
                } else {
                    LucideIcon(name: "inbox", size: 20, color: Theme.accent)
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(inbox.displayName)
                    .font(.app(size: 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let host = inbox.websiteHost {
                        LucideIcon(name: "globe", size: 10, color: .secondary)
                        Text(host)
                            .font(.app(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let channel = inbox.channelType, !channel.isEmpty {
                        Text(channel)
                            .font(.app(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("收件箱 #\(inbox.id)")
                            .font(.app(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            LucideIcon(name: "chevron-right", size: 13, color: Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(name: "inbox", size: 40, color: Color.secondary.opacity(0.5))
            Text("暂无收件箱")
                .font(.app(size: 15, weight: .medium))
            Text("在网页后台创建收件箱后会显示在这里。")
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
                Task { await load() }
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

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            inboxes = try await session.api.inboxes()
        } catch let error as APIError {
            if error.kind != .cancelled { errorMessage = error.message }
        } catch {
            errorMessage = "加载收件箱失败。"
        }
        isLoading = false
    }
}
