import SwiftUI
import UIKit

struct MessageRow: View {
    let message: Message
    let showsHeader: Bool
    let onTapImage: (Attachment) -> Void

    private var isIncoming: Bool {
        message.type == .incoming || message.type == .template
    }

    private var isPrivateNote: Bool { message.isPrivateNote }

    var body: some View {
        if message.type == .activity {
            Text(message.text.isEmpty ? "系统消息" : message.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if isIncoming {
                    if showsHeader {
                        InitialsAvatar(name: message.sender?.name ?? "访客", size: 28)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }
                } else {
                    Spacer(minLength: 48)
                }

                VStack(alignment: isIncoming ? .leading : .trailing, spacing: 4) {
                    if isPrivateNote && showsHeader {
                        Text("内部备注")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .padding(.leading, 2)
                    }
                    bubble
                    if showsHeader {
                        footer
                    }
                }

                if isIncoming {
                    Spacer(minLength: 36)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.images) { attachment in
                Button {
                    onTapImage(attachment)
                } label: {
                    AsyncImage(url: URL(string: attachment.thumbUrl ?? attachment.dataUrl ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            ZStack {
                                Color(uiColor: .tertiarySystemFill)
                                Image(systemName: "photo")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                        default:
                            ZStack {
                                Color(uiColor: .tertiarySystemFill)
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                    .frame(width: 200, height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(bubbleColor)
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("复制文字", systemImage: "doc.on.doc")
            }
        }
    }

    private var bubbleColor: Color {
        if isPrivateNote { return Theme.bubblePrivate }
        return isIncoming ? Theme.bubbleIncoming : Theme.bubbleOutgoing
    }

    private var textColor: Color {
        if isPrivateNote { return Color(uiColor: .label) }
        return isIncoming ? Color(uiColor: .label) : .white
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(TimeFormat.clock(message.createdAt))
            if !isIncoming && !isPrivateNote {
                if message.readAt != nil || message.status == "read" {
                    Text("已读")
                } else {
                    Text("已发送")
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}

struct PendingMessageRow: View {
    let item: ChatModel.PendingMessage
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if let data = item.jpegData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 200, height: 150)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.bubbleOutgoing)
                )
                .opacity(item.state == .sending ? 0.65 : 0.9)

                statusLine
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .sending:
            Text("发送中…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 8) {
                Text(item.errorText ?? "发送失败")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                Button("重试", action: onRetry)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Button("删除", action: onDiscard)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
