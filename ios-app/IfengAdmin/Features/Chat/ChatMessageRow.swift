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
                contentColumn
            } else {
                contentColumn
                Spacer(minLength: 44)
            }
        }
        .padding(.vertical, 3)
    }

    /// 气泡列：正文 / 图片 + 时间行。
    ///
    /// 时序行（`metaLine`）**不在**菜单范围内，见 `menuablePayload`。
    ///
    /// 这里刻意**不写** `.frame(maxWidth: 282)`：一旦写死，整列在布局上恒为 282pt
    /// （哪怕只有「你好」两个字），`contextMenu` 会把这一列当作预览底板，
    /// 长按时就出现一条远超气泡的矩形阴影。宽度交给内容自己决定，
    /// 上限由 `bubble` / `imageGrid` 各自负责。
    private var contentColumn: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
            menuablePayload
            metaLine
        }
    }

    /// 真正接收长按的那一块：只有气泡本体（或图片网格），不含时间行。
    ///
    /// 这样菜单底板 = 气泡，长按高亮不会向上/向下扩到时间行，
    /// 也不会因为时间行比气泡宽而把整块拉宽。
    ///
    /// 用 `preview:` 显式指定预览：默认的系统预览会额外铺一层圆角白底，
    /// 在气泡周围留出一圈「白框」，看起来就像那个多余的矩形阴影。
    /// 这里直接把气泡本身当预览，视觉上就是它被轻轻抬起。
    @ViewBuilder
    private var menuablePayload: some View {
        if let menu, !message.isRecalled {
            payload.contextMenu {
                menu()
            } preview: {
                payload
            }
        } else {
            payload
        }
    }

    /// 气泡本体（图片 + 正文）。
    @ViewBuilder
    private var payload: some View {
        if message.isRecalled {
            recalledPlaceholder
        } else {
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.images.isEmpty {
                    imageGrid
                }
                if !trimmedText.isEmpty {
                    bubble
                }
            }
        }
    }

    /// 正文气泡。
    ///
    /// 尺寸与配色照抄网页，**四周各比网页多 2pt**（用户实测网页间距偏挤）：
    /// 左侧 `border-radius: 3px 14px 14px 14px; padding: 8px 15px 8px 14px;` → 10/17/10/16
    /// 右侧 `border-radius: 14px 3px 14px 14px; padding: 8px 14px 8px 15px;` → 10/16/10/17
    ///
    /// 这里刻意不使用 `.textSelection(.enabled)`：iOS 上长按选中文字的手势会抢走
    /// 长按手势，导致「复制 / 编辑 / 撤销」悬浮菜单弹不出来。复制统一走菜单里的「复制」。
    ///
    /// 宽度上限写在这里（而不是外层 VStack），因为外层用了 `fixedSize`
    /// 让短消息收缩——真正约束换行的应该是文字本身。
    /// 282 是「气泡内容」的上限，减去左右内边距 33 得到文字可用宽度。
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
            // 气泡外轮廓的宽度上限。放在 background 之后，限制的是「整个气泡」
            // 而不是里面的 Text，短消息不会被撑开。
            .frame(maxWidth: Self.maxBubbleWidth, alignment: isOutgoing ? .trailing : .leading)
    }

    /// 气泡外轮廓最大宽度（含内边距）。
    static let maxBubbleWidth: CGFloat = 282

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
