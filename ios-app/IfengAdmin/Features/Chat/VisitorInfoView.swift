import SwiftUI
import UIKit

/// 访客资料 / 会话操作面板。
/// 所有字段都来自 `conversation.visitor_details`，是会话建立时采集的快照，
/// 不是实时 GPS，也不代表访客身份凭据。
struct VisitorInfoView: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    @State private var copiedText: String?
    @State private var confirmingBlock = false

    private var conversation: Conversation { model.conversation }
    private var details: VisitorDetails? { conversation.visitorDetails }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profileCard
                    if let details {
                        sourceCard(details)
                        locationCard(details)
                        deviceCard(details)
                    } else {
                        emptyHint
                    }
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Theme.screenBackground)
            .navigationTitle("访客资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ToolbarIconButton(name: "x", label: "关闭", size: 18, diameter: 30) {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .top) {
                if let copiedText {
                    Text("已复制\(copiedText)")
                        .font(.app(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            .confirmationDialog(
                "屏蔽后该访客将无法继续发送消息。",
                isPresented: $confirmingBlock,
                titleVisibility: .visible
            ) {
                Button("屏蔽访客", role: .destructive) {
                    Task { await model.setBlocked(true) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: 头部

    private var profileCard: some View {
        VStack(spacing: 12) {
            InitialsAvatar(name: conversation.visitorName, size: 66)

            VStack(spacing: 5) {
                Text(conversation.visitorName)
                    .font(.app(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    statusTag
                    if conversation.isBlocked {
                        tag("已屏蔽", color: Theme.danger)
                    }
                }
            }

            if let sender = conversation.meta?.sender {
                VStack(spacing: 4) {
                    if let identifier = sender.identifier, !identifier.isEmpty {
                        infoLine(icon: "user-round", text: identifier)
                    }
                    if let email = sender.email, !email.isEmpty {
                        infoLine(icon: "envelope", text: email, copyLabel: "邮箱")
                    }
                    if let phone = sender.phoneNumber, !phone.isEmpty {
                        infoLine(icon: "network", text: phone, copyLabel: "电话")
                    }
                }
            }

            HStack(spacing: 16) {
                statItem(title: "会话", value: "#\(conversation.id)")
                statItem(title: "未读", value: "\(conversation.unreadCount ?? 0)")
                statItem(title: "建立于", value: TimeFormat.listLabel(conversation.createdAt))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(cardBackground)
    }

    private var statusTag: some View {
        let resolved = conversation.isResolved
        return tag(resolved ? "已完成" : "待处理", color: resolved ? Color.secondary : Theme.accent)
    }

    // MARK: 来源

    private func sourceCard(_ details: VisitorDetails) -> some View {
        card(title: "来源", icon: "compass") {
            if let raw = details.sourceUrl, !raw.isEmpty {
                Button {
                    if let url = URL(string: raw) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        LucideIcon(name: "external-link", size: 14, color: Theme.accent)
                            .padding(.top, 1)
                        Text(raw)
                            .font(.app(size: 13))
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("复制链接") { copy(raw, label: "链接") }
                }
            } else {
                Text("访客没有携带来源地址（可能是直接访问）。")
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 位置

    private func locationCard(_ details: VisitorDetails) -> some View {
        card(title: "位置", icon: "map-pin") {
            VStack(spacing: 10) {
                row(label: "地区") {
                    HStack(spacing: 5) {
                        if let flag = details.flagEmoji {
                            Text(flag).font(.app(size: 14))
                        }
                        Text(details.locationText)
                            .font(.app(size: 13))
                            .foregroundStyle(.primary)
                    }
                }
                if let ip = details.ipAddress, !ip.isEmpty {
                    row(label: "IP") {
                        Button {
                            copy(ip, label: "IP")
                        } label: {
                            HStack(spacing: 5) {
                                Text(ip)
                                    .font(.app(size: 13, design: .monospaced))
                                    .foregroundStyle(.primary)
                                LucideIcon(name: "copy", size: 11, color: .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 设备

    private func deviceCard(_ details: VisitorDetails) -> some View {
        card(title: "设备与环境", icon: "monitor") {
            VStack(spacing: 10) {
                row(label: "系统") {
                    Text(details.operatingSystem?.nonEmpty ?? "未知")
                        .font(.app(size: 13))
                        .foregroundStyle(.primary)
                }
                row(label: "浏览器") {
                    Text(details.browser?.nonEmpty ?? "未知")
                        .font(.app(size: 13))
                        .foregroundStyle(.primary)
                }
                row(label: "语言") {
                    Text(details.language?.nonEmpty ?? "未知")
                        .font(.app(size: 13))
                        .foregroundStyle(.primary)
                }
                if let recordedAt = details.recordedAt, recordedAt > 0 {
                    row(label: "采集时间") {
                        Text(TimeFormat.full(recordedAt))
                            .font(.app(size: 13))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var emptyHint: some View {
        HStack(spacing: 8) {
            LucideIcon(name: "circle-help", size: 15, color: .secondary)
            Text("该会话没有采集到访客环境信息。")
                .font(.app(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: 操作

    private var actionsCard: some View {
        card(title: "会话操作", icon: "settings") {
            VStack(spacing: 10) {
                actionRow(
                    icon: conversation.isResolved ? "message-circle" : "check",
                    title: conversation.isResolved ? "重新打开会话" : "标记为已完成",
                    tint: conversation.isResolved ? Theme.accent : Color.green
                ) {
                    Task {
                        await model.setStatus(conversation.isResolved ? "open" : "resolved")
                    }
                }

                actionRow(
                    icon: conversation.isBlocked ? "shield-off" : "ban",
                    title: conversation.isBlocked ? "解除屏蔽" : "屏蔽访客",
                    tint: conversation.isBlocked ? Theme.accent : Theme.danger
                ) {
                    if conversation.isBlocked {
                        Task { await model.setBlocked(false) }
                    } else {
                        confirmingBlock = true
                    }
                }

                if model.isUpdating {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("正在提交…")
                            .font(.app(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let notice = model.actionNotice {
                    Text(notice)
                        .font(.app(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = model.actionError {
                    HStack(alignment: .top, spacing: 5) {
                        LucideIcon(name: "circle-alert", size: 12, color: Theme.danger)
                            .padding(.top, 1)
                        Text(error)
                            .font(.app(size: 12))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                LucideIcon(name: icon, size: 16, color: tint)
                Text(title)
                    .font(.app(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                LucideIcon(name: "chevron-right", size: 12, color: Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isUpdating)
    }

    // MARK: 组件

    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // 分节标题（来源 / 位置 / 设备与环境 / 会话操作）比正文再大 2pt。
                LucideIcon(name: icon, size: 15, color: .secondary)
                Text(title)
                    .font(.app(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func row<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.app(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoLine(icon: String, text: String, copyLabel: String? = nil) -> some View {
        Button {
            if let copyLabel { copy(text, label: copyLabel) }
        } label: {
            HStack(spacing: 6) {
                LucideIcon(name: icon, size: 12, color: .secondary)
                Text(text)
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if copyLabel != nil {
                    LucideIcon(name: "copy", size: 10, color: Color.secondary.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(copyLabel == nil)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.app(size: 14, weight: .semibold))
            Text(title)
                .font(.app(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.app(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        withAnimation(.easeOut(duration: 0.15)) { copiedText = label }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.2)) { copiedText = nil }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
