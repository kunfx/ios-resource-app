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
/// 交互分工（和网页 `web/message-menu.js` 完全一致）：
/// - **单击气泡** → 回调 `onMenu`，由 `ChatView` 贴着气泡弹出「复制 / 编辑 / 撤销」；
/// - **长按 / 拖动** → 完全交给系统原生选字（`.textSelection(.enabled)`），
///   系统的「复制 / 查询 / 翻译 / 分享」菜单照常出现，不再叠加自定义菜单；
/// - **图片** → 单击是「查看原图」，所以图片的菜单留在长按（`contextMenu`）上。
///
/// 为什么不再用 `contextMenu` 做文字菜单：iOS 上长按气泡必然先触发系统选字，
/// 自定义菜单和系统菜单会同时出现两个弹窗。改由单击触发就彻底错开了。
struct ChatMessageRow: View {
    let message: Message
    /// 点击图片时回调（用于全屏预览）。
    var onImageTap: ((URL) -> Void)? = nil
    /// 单击气泡时回调：弹「复制 / 编辑 / 撤销」。nil 表示这条消息没有可执行操作。
    var onMenu: (() -> Void)? = nil
    /// 图片长按菜单内容（图片的单击被「查看原图」占用）。
    var imageMenu: (() -> AnyView)? = nil

    @Environment(\.colorScheme) private var scheme
    /// 按压状态。引用类型：手势回调每帧都要写，走 `@State` 会让整行反复重绘。
    @State private var press = PressTracker()

    /// 长按判定阈值。超过它就认为用户在选字，不弹菜单。
    private static let holdDuration: TimeInterval = 0.35

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
    /// 注意 `metaLine` 仍然**不在** `payload` 范围内：菜单要贴着气泡显示，
    /// 把时间行也算进去会跑到气泡上方一截，看起来像「菜单飘在别处」。
    private var contentColumn: some View {
        // 用 `alignsRight` 而不是 `isOutgoing`：欢迎语靠右，时间行也要跟着右对齐。
        VStack(alignment: alignsRight ? .trailing : .leading, spacing: 3) {
            metaLine
            payload
            // 欢迎语的快捷链接挂在气泡**下方**（和网页 `greeting-links` 一致）。
            // 放在 `payload` 外面：单击菜单和图片长按菜单都只针对气泡，
            // 不该把按钮一起算进命中区域。
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

    /// 气泡本体（图片 + 正文），同时把位置报给 `ChatView`。
    ///
    /// `anchorPreference` 报的是这块内容在全局坐标系里的位置，`ChatView` 拿它
    /// 把浮动菜单贴在气泡旁边；滚动时 anchor 会跟着重新解析，菜单自动跟随。
    @ViewBuilder
    private var payload: some View {
        Group {
            if message.isRecalled {
                recalledPlaceholder
            } else {
                VStack(alignment: alignsRight ? .trailing : .leading, spacing: 4) {
                    if !message.images.isEmpty {
                        imagePayload
                    }
                    if !trimmedText.isEmpty {
                        tappableBubble
                    }
                }
            }
        }
        .anchorPreference(key: MessageBubbleAnchorKey.self, value: .bounds) { [message.id: $0] }
    }

    /// 图片块：单击看原图，长按弹菜单（和网页一致）。
    ///
    /// `preview:` 显式指定预览：默认的系统预览会额外铺一层圆角白底，
    /// 在气泡周围留出一圈「白框」，看起来就像那个多余的矩形阴影。
    @ViewBuilder
    private var imagePayload: some View {
        if let imageMenu {
            imageGrid.contextMenu { imageMenu() } preview: { imageGrid }
        } else {
            imageGrid
        }
    }

    /// 可单击弹菜单的气泡。
    private var tappableBubble: some View {
        bubble
            // 允许系统原生选字：长按选字、拖动选中、系统「复制 / 查询 / 分享」都走系统。
            .textSelection(.enabled)
            // 链接照常跳转，只顺手记下时间，避免同一次点击又弹菜单。
            //
            // 这里必须返回 `.systemAction` 而不是「再调一次 openURL」：
            // `OpenURLAction.callAsFunction(_:)` 的返回类型是 `Void`（返回 `Result`
            // 的是 `handler`），所以 `return openURL(url)` 编译不过；
            // 而且 `.systemAction` 就是「按系统默认方式打开」，行为与改造前完全一致。
            .environment(\.openURL, OpenURLAction { _ in
                press.lastLinkTap = Date()
                return .systemAction
            })
            // 气泡有底色，内边距里的空白本来就在命中区域内，
            // 所以这里不再加 `contentShape`——少一层改写，避免影响系统选字的命中判断。
            .simultaneousGesture(tapOrHold)
    }

    /// 一个手势同时区分「单击」和「长按 / 拖动」。
    ///
    /// 为什么不用 `.onTapGesture`：SwiftUI 的 TapGesture 在长按后抬手也会触发，
    /// 而长按在 iOS 上是系统选字的起手式，两者叠加就会出现「系统选区 + 自定义菜单」
    /// 两个弹窗——这正是本次要消灭的问题。这里用 `DragGesture(minimumDistance: 0)`
    /// 自己算按压时长：短按且没位移才算单击，长按 / 拖动一律放行给系统。
    private var tapOrHold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let now = Date()
                // 手势被系统接管（比如开始滚动列表）时不会回调 `onEnded`，
                // 这里用「距上次更新超过 0.25s」判定这是一次全新的按压，
                // 否则残留的旧开始时间会让后面所有点击都被算成「长按」。
                if press.startedAt == nil || now.timeIntervalSince(press.lastUpdate) > 0.25 {
                    // 上一轮手势没走 `onEnded` 就被系统接管了：按持续时间补记一次长按，
                    // 这样「长按选字 → 点一下收选区」那一下仍然不会弹菜单。
                    //
                    // 必须排除「手指移动过」的情况：那是滚动列表，不是长按。
                    // 否则滚完立刻点消息会被当成「刚长按过」而吞掉这一次点击。
                    if let started = press.startedAt,
                       !press.moved,
                       now.timeIntervalSince(started) >= Self.holdDuration {
                        press.lastHoldEnd = now
                    }
                    press.startedAt = now
                    press.moved = false
                }
                press.lastUpdate = now
                if abs(value.translation.width) > 8 || abs(value.translation.height) > 8 {
                    press.moved = true
                }
            }
            .onEnded { _ in
                let duration = Date().timeIntervalSince(press.startedAt ?? Date())
                let moved = press.moved
                press.startedAt = nil
                press.moved = false

                // 长按：系统正在选字，这里什么都不做。
                if duration >= Self.holdDuration {
                    press.lastHoldEnd = Date()
                    return
                }
                guard !moved else { return }
                // 刚长按过（多半是在收系统选区）、或刚点的是链接：不弹菜单。
                guard Date().timeIntervalSince(press.lastHoldEnd) > 1.2,
                      Date().timeIntervalSince(press.lastLinkTap) > 0.4 else { return }

                // 延后一拍：链接的 openURL 和这次抬手在同一轮事件里，
                // 先让它把时间戳写完，再决定要不要弹菜单。
                let tracker = press
                let handler = onMenu
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    guard Date().timeIntervalSince(tracker.lastLinkTap) > 0.4 else { return }
                    handler?()
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
    /// 这里**不再**用 `.contextMenu` 挂文字菜单：长按在 iOS 上必然先触发系统选字，
    /// 自定义菜单会和系统菜单同时弹出两个弹窗。改成单击弹菜单（见 `tappableBubble`），
    /// 长按整段让给系统选字。
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

// MARK: - 按压状态

/// 一次按压的时间信息。
///
/// 用引用类型而不是 `@State` 值类型：手势回调里每帧都要写这些字段，
/// 走 `@State` 会让整条消息行反复重绘，滚动时明显掉帧。
private final class PressTracker {
    /// 本次按压的开始时间；nil 表示当前没有正在进行的按压。
    var startedAt: Date?
    /// 最近一次手势回调的时刻，用来识别「上一次手势被系统取消」。
    var lastUpdate = Date.distantPast
    /// 手指是否移动过（超过 8pt 就认为用户在滚动或拖选文字）。
    var moved = false
    /// 上一次长按结束的时刻。紧随其后的点击多半是在收系统选区，不弹菜单。
    var lastHoldEnd = Date.distantPast
    /// 最近一次点中气泡内链接的时刻。
    var lastLinkTap = Date.distantPast
}

// MARK: - 菜单定位

/// 每条消息气泡的位置，用来把浮动菜单贴在对应消息旁边。
///
/// 用 `Anchor<CGRect>` 而不是直接记 `CGRect`：anchor 在布局变化（滚动、
/// 键盘弹起、插入新消息）后会由 SwiftUI 重新解析，菜单自动跟着气泡走，
/// 不需要自己在滚动回调里算偏移。
struct MessageBubbleAnchorKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Int: Anchor<CGRect>],
        nextValue: () -> [Int: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 消息操作菜单

/// 菜单里的一项（复制 / 编辑 / 撤销）。
///
/// 单击菜单（SwiftUI 浮动卡片）和图片长按菜单（系统 `contextMenu`）
/// 共用同一份定义，避免两边条件判断写歪。
struct MessageMenuAction: Identifiable {
    let id: String
    let title: String
    /// SF Symbol 名称。这里不用 Lucide：菜单是系统风格的浮层，
    /// 系统符号的字重和菜单文字更搭。
    let icon: String
    let isDanger: Bool
    let run: () -> Void
}

/// 单击消息后贴着气泡弹出的操作菜单。
///
/// 外观对齐网页 `.message-menu`：圆角卡片 + 图标 + 文案，撤销用红色。
/// 尺寸固定（宽 152、每项 40），这样 `ChatView` 不用测量就能算出该摆在哪儿，
/// 也不会出现「先在错误位置显示一帧、再跳一下」的闪动。
struct MessageActionMenu: View {
    let actions: [MessageMenuAction]
    var onDismiss: () -> Void = {}

    static let width: CGFloat = 152
    private static let itemHeight: CGFloat = 40
    private static let padding: CGFloat = 6

    /// 给定项数时的整体高度（`ChatView` 定位用）。
    static func height(count: Int) -> CGFloat {
        padding * 2 + itemHeight * CGFloat(max(count, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    // 先收起菜单再执行：编辑 / 撤销会立刻弹 sheet 或确认框，
                    // 两层浮层叠在一起很乱。
                    onDismiss()
                    DispatchQueue.main.async { action.run() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: action.icon)
                            .font(.system(size: 14))
                            .frame(width: 18)
                            .foregroundStyle(action.isDanger ? Theme.danger : Color.secondary)
                        Text(action.title)
                            .font(.app(size: 14))
                            .foregroundStyle(action.isDanger ? Theme.danger : Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Self.itemHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background(
            // 用不透明卡片而不是毛玻璃：网页 `.message-menu` 就是「白卡 + 阴影」，
            // 而且实色在浅色聊天背景上边界更清楚，不会糊成一片。
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    }
}
