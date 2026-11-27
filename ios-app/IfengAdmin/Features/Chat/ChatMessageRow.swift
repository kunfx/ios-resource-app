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
    /// 首条自动回复（欢迎语）走**右侧气泡**，不是居中的系统提示。
    ///
    /// 网页 `messages.js` 里这种消息的 `right` 为真（`source_id==='website-template:greeting'`），
    /// 所以它和客服自己发的消息在同一侧。APP 之前把它归进 `isSystem` 居中显示，
    /// 和网页不一致。
    private var isWelcome: Bool {
        message.type == .template && message.sourceId == Message.welcomeSourceId
    }
    /// 模板消息里只有**欢迎语**算正常气泡；其他模板（比如后来新增的自动话术）
    /// 仍然按系统提示居中显示，避免它们突然全部跑到右侧。
    private var isSystem: Bool {
        if message.type == .template { return !isWelcome }
        return message.type == .activity
    }
    /// 靠右显示。欢迎语虽然 message_type=3，视觉上跟客服消息同侧。
    private var alignsRight: Bool { isOutgoing || isWelcome }

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
            if alignsRight {
                Spacer(minLength: 44)
                contentColumn
            } else {
                contentColumn
                Spacer(minLength: 44)
            }
        }
        .padding(.vertical, 3)
    }

    /// 气泡列：时间行 + 正文 / 图片。
    ///
    /// 时序行（时间 / 已编辑 / 投递对勾）**在气泡上方**，和网页一致。
    ///
    /// 网页 `messages.js` 的 `createRow` 是把 `chat-message-meta` 先 append 到
    /// `body`、再把气泡 append 进去，所以时间和对勾显示在消息上面。
    /// 之前这里放在下面，属于和网页不一致。
    ///
    /// 注意 `metaLine` 仍然**不在** `contextMenu` 范围内（见 `menuablePayload`），
    /// 否则长按预览底板会把这一行一起框进去，又变成宽条。
    private var contentColumn: some View {
        // 用 `alignsRight` 而不是 `isOutgoing`：欢迎语靠右，时间行也要跟着右对齐。
        VStack(alignment: alignsRight ? .trailing : .leading, spacing: 3) {
            metaLine
            menuablePayload
            // 欢迎语的快捷链接挂在气泡**下方**（和网页 `greeting-links` 一致）。
            // 放在 `menuablePayload` 外面：长按菜单的预览底板只框气泡，
            // 不该把按钮一起框进去。
            if isWelcome, !message.greetingButtons.isEmpty {
                greetingLinks
                    // 网页是 `margin-top:10px`；外层 VStack 已有 3pt 间距，
                    // 这里补 7 正好凑够 10。
                    .padding(.top, 7)
            }
        }
    }

    /// 欢迎语下方的快捷链接按钮组。
    ///
    /// 外观照搬网页 `.greeting-link`：
    /// `padding: 7px 12px` / `border: 1px solid #5d96ec` / `border-radius: 10px`
    /// / `color: #1763cf` / `font-size: 14px` / `min-height: 32px`，
    /// 按钮之间 10pt，一行放不下自动换行（网页是 `inline-block` 流式排列）。
    private var greetingLinks: some View {
        FlowLayout(spacing: 10) {
            ForEach(message.greetingButtons) { button in
                Link(destination: button.url) {
                    Text(button.title)
                        .font(.system(size: 14))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        // 标题过长时在 240pt 处换行，加上左右各 12 的内边距
                        // 正好不超过气泡上限 282。短标题不会被撑宽。
                        .frame(maxWidth: 240)
                        .foregroundStyle(greetingLinkTint)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(greetingLinkBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: Self.maxBubbleWidth, alignment: alignsRight ? .trailing : .leading)
    }

    /// 按钮文字色。浅色模式用网页的 `#1763cf`；深色模式下这个蓝太暗，提亮。
    private var greetingLinkTint: Color {
        scheme == .dark
            ? Color(red: 0.55, green: 0.75, blue: 1.0)
            : Color(red: 0.090, green: 0.388, blue: 0.812)   // #1763cf
    }

    /// 按钮描边色。浅色模式用网页的 `#5d96ec`；深色模式降低不透明度避免刺眼。
    private var greetingLinkBorder: Color {
        scheme == .dark
            ? Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.45)
            : Color(red: 0.365, green: 0.588, blue: 0.925)   // #5d96ec
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
            VStack(alignment: alignsRight ? .trailing : .leading, spacing: 4) {
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
    /// 尺寸与配色照抄网页：左侧 `padding: 8px 15px 8px 14px`、右侧 `8px 14px 8px 15px`。
    /// 上下沿用 10（网页 8 + 2），**左右在网页基础上各收 2pt**：
    /// 网页的左右留白在同字号下显得偏松，用户实测要求收紧。
    /// 即左侧 14/15、右侧 15/14（原来是 16/17 与 17/16）。
    ///
    /// 这里刻意不使用 `.textSelection(.enabled)`：iOS 上长按选中文字的手势会抢走
    /// 长按手势，导致「复制 / 编辑 / 撤销」悬浮菜单弹不出来。复制统一走菜单里的「复制」。
    ///
    /// 宽度上限写在这里（而不是外层 VStack），让短消息收缩、真正约束换行的
    /// 是文字本身。282 是「气泡外轮廓」的上限。
    private var bubble: some View {
        bubbleText
            .padding(.top, 10)
            .padding(.bottom, 10)
            // 内边距按「靠哪一侧」决定，欢迎语也在右侧，所以用和客服消息同一套值。
            // 这就是用户要求的「所有参数和管理员自己的消息保持一致」。
            .padding(.leading, alignsRight ? 15 : 14)
            .padding(.trailing, alignsRight ? 14 : 15)
            .background(bubbleShape.fill(bubbleFill))
            // 气泡外轮廓的宽度上限。放在 background 之后，限制的是「整个气泡」
            // 而不是里面的 Text，短消息不会被撑开。
            .frame(maxWidth: Self.maxBubbleWidth, alignment: alignsRight ? .trailing : .leading)
    }

    /// 正文：支持 4 种 Markdown（粗体 / 列表 / 代码 / 引用）+ 自动 http(s) 链接。
    ///
    /// 三条路径，从便宜到贵：
    /// 1. **没有 Markdown** → 纯 `Text`，排版最可预测
    /// 2. **有 Markdown** → `MarkdownTextView`（块级布局）
    ///
    /// 之所以保留纯文本快速路径：绝大多数消息是纯文字，走 `Text` 才能
    /// 保证行高、`fixedSize` 行为和改造前完全一致，不会引入回归。
    @ViewBuilder
    private var bubbleText: some View {
        if MarkdownRender.hasMarkdown(trimmedText) {
            MarkdownTextView(
                blocks: MarkdownRender.parse(trimmedText),
                textColor: textColor,
                linkColor: linkColor,
                baseSize: 15
            )
        } else if let attributed = LinkDetector.attributed(
            trimmedText,
            textColor: textColor,
            linkColor: linkColor
        ) {
            // 颜色全在 AttributedString 里，外层不再覆盖。
            Text(attributed)
                .font(.app(size: 15))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(trimmedText)
                .font(.app(size: 15))
                .lineSpacing(2)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 链接颜色。
    ///
    /// 不能一直用蓝色：自己消息是深蓝底、欢迎语是浅蓝底，
    /// 蓝色链接在它们上面都看不清。所以按气泡底色反着挑：
    /// - 深色底（自己 / 欢迎语暗色）→ 白色 + 下划线，靠下划线区分
    /// - 浅色底（对方 / 欢迎语亮色）→ 主题蓝
    private var linkColor: Color {
        if message.isPrivateNote { return Theme.accent }
        if isWelcome {
            return scheme == .dark ? Color.white : Theme.linkOnLight
        }
        if isOutgoing { return Color.white }
        return Theme.linkOnLight
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
            // 12 → 15：原来的对勾比时间字号还小，一眼看不清是单勾还是双勾；
            // 放大后单勾/双勾在 10pt 时间旁边依然平衡（时间仍小一号，主次不乱）。
            if let state = message.deliveryState {
                LucideIcon(
                    name: state.iconName,
                    size: 15,
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
        // 欢迎语是浅蓝底，字必须用深蓝，不能用白（白字在浅蓝上几乎看不见）。
        if isWelcome {
            return scheme == .dark ? Theme.bubbleWelcomeTextDark : Theme.bubbleWelcomeText
        }
        if isOutgoing { return Theme.bubbleOutgoingText }
        return scheme == .dark ? Theme.bubbleIncomingTextDark : Theme.bubbleIncomingText
    }

    /// 左侧圆角小的是左上角，右侧圆角小的是右上角（和网页一一对应）。
    ///
    /// 这里的判断用 `alignsRight` 而不是 `isOutgoing`：欢迎语也要按「右侧」的
    /// 形状画（右上角 3），否则会出现「气泡靠右、但圆角在左上」的错位。
    private var bubbleShape: BubbleShape {
        alignsRight
            ? BubbleShape(topLeading: 14, topTrailing: 3, bottomLeading: 14, bottomTrailing: 14)
            : BubbleShape(topLeading: 3, topTrailing: 14, bottomLeading: 14, bottomTrailing: 14)
    }

    private var bubbleFill: Color {
        if message.isPrivateNote { return Theme.bubblePrivate }
        if isWelcome {
            return scheme == .dark ? Theme.bubbleWelcomeDark : Theme.bubbleWelcome
        }
        if isOutgoing { return Theme.bubbleOutgoing }
        return scheme == .dark ? Theme.bubbleIncomingDark : Theme.bubbleIncoming
    }
}

// MARK: - 流式布局

/// 一行放不下就换行的布局，用来排欢迎语的快捷按钮。
///
/// 网页端 `.greeting-links` 里的 `.greeting-link` 是 `inline-block`，
/// 宽度不够会自动折行。SwiftUI 的 `HStack` 不会折行，所以这里用 `Layout`
/// 手写一个最小的流式排布：从左往右摆，超出可用宽度就另起一行。
///
/// 只在按钮组上用（最多 4 个），逻辑很轻，不会影响滚动性能。
struct FlowLayout: Layout {
    /// 同一行相邻元素之间、以及行与行之间的间距。
    var spacing: CGFloat = 10

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0          // 当前行已占用的宽度
        var y: CGFloat = 0          // 已排完的行累计高度
        var rowHeight: CGFloat = 0  // 当前行最高的元素
        var widest: CGFloat = 0     // 所有行里最宽的一行

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // 不是第一个元素、且放不下 → 换行。
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        widest = max(widest, x > 0 ? x - spacing : 0)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
