import SwiftUI
import UIKit

/// 单条消息气泡。
///
/// 投递状态严格按网页 `web/messages.js` 的 `deliveryStatus()` 判定：
/// - `status == "failed"` → 红色 `circle-alert`
/// - `sending` → 灰色 `clock`
/// - 公开消息且 `status == "read" && read_at > 0` → **蓝色双勾** `check-check`
/// - 其余 `sent / delivered / read` → **灰色单勾** `check`
struct ChatMessageRow: View {
    let message: Message
    /// 点击图片时回调（用于全屏预览）。
    var onImageTap: ((URL) -> Void)? = nil

    private var isOutgoing: Bool { message.type == .agent }
    private var isSystem: Bool { message.type == .activity || message.type == .template }

    var body: some View {
        if isSystem {
            systemRow
        } else {
            bubbleRow
        }
    }

    // MARK: 系统消息

    private var systemRow: some View {
        HStack {
            Spacer(minLength: 0)
            Text(message.text.isEmpty ? "会话状态更新" : message.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: 普通气泡

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOutgoing {
                Spacer(minLength: 44)
                column
            } else {
                column
                Spacer(minLength: 44)
            }
        }
        .padding(.vertical, 3)
    }

    private var column: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
            if !message.images.isEmpty {
                imageGrid
            }
            if !trimmedText.isEmpty {
                Text(trimmedText)
                    .font(.system(size: 15))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(bubbleShape.fill(bubbleFill))
                    .overlay(bubbleShape.strokeBorder(borderColor, lineWidth: 1))
            }
            metaLine
        }
        .frame(maxWidth: 282, alignment: isOutgoing ? .trailing : .leading)
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            if message.isPrivateNote {
                LucideIcon(name: "lock", size: 10, color: .secondary)
                Text("内部备注")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(TimeFormat.clock(message.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // 只有自己发出的消息才有投递状态。
            if let state = message.deliveryState {
                LucideIcon(
                    name: state.iconName,
                    size: 12,
                    color: state.isRead ? Theme.receiptRead : Theme.receiptSent
                )
                .accessibilityLabel(state.label)
            }
        }
        .padding(.horizontal, 3)
    }

    // MARK: 图片

    private var imageGrid: some View {
        let images = message.images
        return Group {
            if images.count == 1, let only = images.first {
                imageCell(only, width: 216, height: 216)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(102), spacing: 4),
                        GridItem(.fixed(102), spacing: 4)
                    ],
                    spacing: 4
                ) {
                    ForEach(images) { attachment in
                        imageCell(attachment, width: 102, height: 102)
                    }
                }
                .frame(width: 208)
            }
        }
    }

    private func imageCell(_ attachment: Attachment, width: CGFloat, height: CGFloat) -> some View {
        let thumbURL = URL(string: attachment.thumbUrl ?? attachment.dataUrl ?? "")
        let fullURL = URL(string: attachment.dataUrl ?? attachment.thumbUrl ?? "")
        return Button {
            if let fullURL {
                onImageTap?(fullURL)
            }
        } label: {
            AsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    ZStack {
                        Color(uiColor: .tertiarySystemBackground)
                        LucideIcon(name: "image", size: 20, color: .secondary)
                    }
                default:
                    ZStack {
                        Color(uiColor: .tertiarySystemBackground)
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(fullURL == nil)
    }

    // MARK: 样式

    private var trimmedText: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var textColor: Color {
        if message.isPrivateNote { return .primary }
        return isOutgoing ? .white : .primary
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var bubbleFill: Color {
        if message.isPrivateNote { return Theme.bubblePrivate }
        return isOutgoing ? Theme.bubbleOutgoing : Theme.bubbleIncoming
    }

    private var borderColor: Color {
        message.isPrivateNote ? Color.orange.opacity(0.35) : Color.primary.opacity(0.05)
    }
}
