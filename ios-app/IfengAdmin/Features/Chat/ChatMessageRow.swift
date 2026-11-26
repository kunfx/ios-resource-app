import SwiftUI
import UIKit

/// 单条消息气泡。
///
/// 投递状态严格按网页 `web/messages.js` 的 `deliveryStatus()` 判定：
/// - `status == "failed"` → 红色 `circle-alert`
/// - `sending` → 灰色 `clock`
/// - 公开消息且 `status == "read" && read_at > 0` → **蓝色双勾** `check-check`
/// - 其余 `sent / delivered / read` → **灰色单勾** `check`
///
/// 长按菜单挂在这一列的**气泡上**（不是整行）。iOS 的 `contextMenu` 会把被附加的
/// 视图当成预览底板，挂在整行上就会得到一条横贯全宽的矩形高亮；挂在气泡上，
/// 高亮范围自然等于气泡本身。菜单内容由 `ChatView` 通过 `menu` 闭包注入，
/// 传 nil 时不注册（避免弹出空菜单）。
struct ChatMessageRow: View {
    let message: Message
    /// 点击图片时回调（用于全屏预览）。
    var onImageTap: ((URL) -> Void)? = nil
    /// 长按菜单内容。nil 表示这条消息没有任何可执行操作。
    var menu: (() -> AnyView)? = nil

    @Environment(\.colorScheme) private var scheme

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
                .font(.app(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: 普通气泡

    /// 整行只负责「靠左 / 靠右 + 留白」，所有视觉和手势都落在 `contentColumn` 上。
    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOutgoing {
                Spacer(minLength: 44)
                menuableColumn
            } else {
                menuableColumn
                Spacer(minLength: 44)
            }
        }
        .padding(.vertical, 3)
    }

    /// 气泡列。只有这里挂 contextMenu，长按高亮的范围就正好是气泡 + 时间行。
    @ViewBuilder
    private var menuableColumn: some View {
        if let menu {
            contentColumn.contextMenu { menu() }
        } else {
            contentColumn
        }
    }

    private var contentColumn: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
            if message.isRecalled {
                // 撤回后服务端不再返回正文与附件，只保留发送者、时间和这条提示。
                recalledPlaceholder
            } else {
                if !message.images.isEmpty {
                    imageGrid
                }
                if !trimmedText.isEmpty {
                    bubble
                }
            }
            metaLine
        }
        // 只限制最大宽度，**不要**加 maxWidth: .infinity。
        // 撑满会让长按预览底板变成整行宽的矩形。
        .frame(maxWidth: 282, alignment: isOutgoing ? .trailing : .leading)
    }

    /// 正文气泡。
    ///
    /// 尺寸与配色照抄网页，**四周各比网页多 2pt**（用户实测网页间距偏挤）：
    /// 左侧 `border-radius: 3px 14px 14px 14px; padding: 8px 15px 8px 14px;` → 10/17/10/16
    /// 右侧 `border-radius: 14px 3px 14px 14px; padding: 8px 14px 8px 15px;` → 10/16/10/17
    ///
    /// 这里刻意不使用 `.textSelection(.enabled)`：iOS 上长按选中文字的手势会抢走
    /// 长按手势，导致「复制 / 编辑 / 撤销」悬浮菜单弹不出来。复制统一走菜单里的「复制」。
    private var bubble: some View {
        Text(trimmedText)
            .font(.app(size: 15))
            .lineSpacing(2)
            .foregroundStyle(textColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .padding(.leading, isOutgoing ? 17 : 16)
            .padding(.trailing, isOutgoing ? 16 : 17)
            .background(bubbleShape.fill(bubbleFill))
    }

    private var recalledPlaceholder: some View {
        Text("该消息已撤回")
            .font(.app(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleShape.fill(Color.primary.opacity(0.03)))
            .overlay(
                bubbleShape.strokeBorder(
                    Color.primary.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            if message.isPrivateNote {
                LucideIcon(name: "lock", size: 10, color: .secondary)
                Text("内部备注")
                    .font(.app(size: 10))
                    .foregroundStyle(.secondary)
            }
            if message.isEdited {
                Text("已编辑")
                    .font(.app(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(TimeFormat.clock(message.createdAt))
                .font(.app(size: 10))
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
        // 和网页 .message-card 一致：气泡底色包住图片；内边距与文字气泡同步 +2。
        .padding(6)
        .background(bubbleShape.fill(bubbleFill))
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
        if isOutgoing { return Theme.bubbleOutgoingText }
        return scheme == .dark ? Theme.bubbleIncomingTextDark : Theme.bubbleIncomingText
    }

    /// 左侧圆角小的是左上角，右侧圆角小的是右上角（和网页一一对应）。
    private var bubbleShape: BubbleShape {
        isOutgoing
            ? BubbleShape(topLeading: 14, topTrailing: 3, bottomLeading: 14, bottomTrailing: 14)
            : BubbleShape(topLeading: 3, topTrailing: 14, bottomLeading: 14, bottomTrailing: 14)
    }

    private var bubbleFill: Color {
        if message.isPrivateNote { return Theme.bubblePrivate }
        if isOutgoing { return Theme.bubbleOutgoing }
        return scheme == .dark ? Theme.bubbleIncomingDark : Theme.bubbleIncoming
    }
}
