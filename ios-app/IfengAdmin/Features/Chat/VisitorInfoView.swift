import SwiftUI
import UIKit

struct VisitorInfoView: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    @State private var showBlockConfirm = false
    @State private var desiredBlocked = false

    private var details: VisitorDetails? { model.conversation.visitorDetails }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profileCard
                    detailsCard
                    statusCard
                    blockCard
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Theme.screenBackground)
            .navigationTitle("访客信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear {
            // 关闭信息页时清掉提示，避免返回聊天页后重复弹窗。
            model.clearActionMessage()
        }
        .alert(desiredBlocked ? "屏蔽该访客？" : "解除屏蔽？", isPresented: $showBlockConfirm) {
            Button("取消", role: .cancel) {}
            Button(desiredBlocked ? "屏蔽" : "解除", role: desiredBlocked ? .destructive : nil) {
                let target = desiredBlocked
                Task { await model.setBlocked(target) }
            }
        } message: {
            Text(desiredBlocked
                 ? "屏蔽后该访客在这个会话中无法继续发送消息；可随时解除。不会影响其他会话。"
                 : "解除后该访客可以继续在这个会话中发送消息。")
        }
    }

    // MARK: 资料

    private var profileCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                InitialsAvatar(name: model.conversation.visitorName, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.conversation.visitorName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text("会话 #\(model.conversation.id)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let identifier = model.conversation.meta?.sender?.identifier, !identifier.isEmpty {
                        Text(identifier)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }

            if let email = model.conversation.meta?.sender?.email, !email.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "envelope")
                        .font(.system(size: 11))
                    Text(email)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 访客信息

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("访客资料")
            VStack(spacing: 0) {
                sourceRow
                Divider().padding(.leading, 14)
                InfoLine(label: "位置", value: locationValue, leadingIcon: details?.flagEmoji)
                Divider().padding(.leading, 14)
                InfoLine(label: "IP 地址", value: valueOrUnknown(details?.ipAddress))
                Divider().padding(.leading, 14)
                InfoLine(label: "设备", value: valueOrUnknown(details?.operatingSystem))
                Divider().padding(.leading, 14)
                InfoLine(label: "浏览器", value: valueOrUnknown(details?.browser))
                Divider().padding(.leading, 14)
                InfoLine(label: "语言", value: valueOrUnknown(details?.language))
                Divider().padding(.leading, 14)
                InfoLine(label: "首次会话", value: TimeFormat.full(model.conversation.createdAt))
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var sourceRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("来源")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            if let raw = details?.sourceUrl, let url = URL(string: raw), !raw.isEmpty {
                Link(destination: url) {
                    Text(raw)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
            } else {
                Text("未知")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var locationValue: String {
        let text = details?.locationText ?? "位置未知"
        return text
    }

    private func valueOrUnknown(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未知" }
        return value
    }

    // MARK: 会话状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("会话")
            VStack(spacing: 0) {
                InfoLine(label: "状态", value: model.conversation.isResolved ? "已完成" : "待处理")
                Divider().padding(.leading, 14)
                Button {
                    let target = model.conversation.isResolved ? "open" : "resolved"
                    Task { await model.setStatus(target) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.conversation.isResolved ? "arrow.uturn.backward" : "checkmark.circle")
                            .font(.system(size: 14))
                        Text(model.conversation.isResolved ? "重新打开会话" : "标记为已完成")
                            .font(.system(size: 14))
                        Spacer()
                        if model.isUpdating {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isUpdating)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: 屏蔽

    private var blockCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("访客屏蔽")
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: blockBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("屏蔽该访客")
                            .font(.system(size: 14))
                        Text(model.conversation.isBlocked ? "当前已屏蔽，访客无法发送消息" : "当前未屏蔽")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isUpdating)

                Text("屏蔽只作用于当前会话，不会封禁 IP，也不影响其他会话；需要管理员权限。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let notice = model.actionNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
                if let error = model.actionError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var blockBinding: Binding<Bool> {
        Binding(
            get: { model.conversation.isBlocked },
            set: { newValue in
                guard newValue != model.conversation.isBlocked else { return }
                desiredBlocked = newValue
                showBlockConfirm = true
            }
        )
    }

    private var footnote: some View {
        Text("地理位置与来源是访客进入会话时的采集快照，不是实时定位，也不能作为身份凭据。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.bottom, 6)
    }
}

struct InfoLine: View {
    let label: String
    let value: String
    var leadingIcon: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            HStack(spacing: 4) {
                if let leadingIcon, !leadingIcon.isEmpty {
                    Text(leadingIcon)
                        .font(.system(size: 13))
                }
                Text(value)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
