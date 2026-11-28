import SwiftUI
import UIKit

/// 把 `MarkdownRender.parse` 的结果画成 SwiftUI 视图。
///
/// 布局上只有一个硬要求：**任何块都不能撑破气泡**。
/// 所以代码块用 `ScrollView(.horizontal)` 兜住超长行，
/// 引用和列表都靠 `fixedSize(horizontal: false, vertical: true)` 让高度自适应。
struct MarkdownTextView: View {
    let blocks: [MarkdownRender.Block]
    /// 普通文字颜色（由气泡按底色传入）。
    let textColor: Color
    /// 链接颜色（只用于自动识别出的 http(s)，不是 Markdown 语法）。
    let linkColor: Color
    /// 基础字号。行内代码、代码块都从它派生，保证和正文协调。
    var baseSize: CGFloat = 15
    /// 单击正文回调（弹「复制 / 编辑 / 撤销」）。由 `ChatMessageRow` 注入。
    var onTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 块之间用 6pt 分隔。单块时 VStack 不会引入额外间距。
        content
            // 宽度策略要分情况，否则「**你好**」这种短消息会把气泡拉成满宽：
            //
            // - 含块级元素（列表 / 代码块 / 引用）→ 必须铺满父宽，
            //   否则长行不会换行、代码块也没法横向滚动
            // - 纯段落 → 交给文字自己决定宽度，短消息就保持短气泡
            .frame(maxWidth: needsFullWidth ? .infinity : nil, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 用 `indices` 而不是 `Array(blocks.enumerated())`：
            // `enumerated()` 的元素是**元组** `(offset:element:)`，
            // 而 Swift 不支持对元组取 key path（`id: \.offset`），
            // 正常应报 `key path cannot refer to tuple elements`。
            // 在 Xcode 26.3 上这个写法直接把 swift-frontend 弄崩了，
            // 且不留任何诊断信息。改成下标访问，彻底绕开元组。
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
    }

    /// 是否必须占满可用宽度。
    ///
    /// 只有块级元素（列表 / 代码块 / 引用）才需要；纯段落让文字自适应，
    /// 这样「**你好**」仍然是一个小气泡，和改造前一致。
    private var needsFullWidth: Bool {
        blocks.contains { block in
            switch block {
            case .paragraph: return false
            case .bulletList, .codeBlock, .quote: return true
            }
        }
    }

    // MARK: 块

    @ViewBuilder
    private func blockView(_ block: MarkdownRender.Block) -> some View {
        switch block {
        case .paragraph(let inlines):
            inlineText(inlines)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    // 对齐用 `.top` 而不是 `.firstTextBaseline`：正文现在是
                    // `UITextView`（`SelectableText`），没有文字基线可对齐，
                    // 用基线对齐会让圆点掉到下面去。圆点补 1pt 上边距近似原来
                    // 的基线位置。
                    HStack(alignment: .top, spacing: 6) {
                        // 圆点用固定宽度的容器：不同字符宽度的项目符号
                        // 会让第二行文字和第一行错位。
                        Text("•")
                            .font(.app(size: baseSize, weight: .semibold))
                            .foregroundStyle(textColor.opacity(0.7))
                            .frame(width: 8, alignment: .leading)
                            .padding(.top, 1)
                        inlineText(items[index])
                    }
                }
            }

        case .codeBlock(let code):
            codeBlockView(code)

        case .quote(let inner):
            quoteView(inner)
        }
    }

    /// 行内组合：`**粗体**` + `` `代码` `` + 自动识别的 http(s) 链接。
    ///
    /// 返回 `SelectableText`（`UITextView`）而不是 `Text`：只有真正的文本视图
    /// 才有系统原生选字（长按选词 + 拖动把手 + 完整编辑菜单），
    /// SwiftUI 的 `Text` 一旦被外层手势覆盖，长按就只剩链接预览菜单。
    private func inlineText(_ inlines: [MarkdownRender.Inline]) -> SelectableText {
        SelectableText(
            attributed: MessageAttributed.inlines(
                inlines,
                textColor: UIColor(textColor),
                linkColor: UIColor(linkColor),
                size: baseSize,
                codeBackground: UIColor(codeBackground)
            ),
            onTap: onTap
        )
    }

    /// 围栏代码块。
    ///
    /// 关键点：
    /// - `.scrollView` 横向滚动，超长行不会把气泡撑宽
    /// - 纵向不滚动（消息里滚两层很难用），高度随内容
    /// - 保留原始空格：`Text` 对 `AttributedString` 里的空格会折叠吗？
    ///   不会——`Text` 不做 HTML 式空白折叠，但连续空格在系统字体下
    ///   视觉上会被压缩，所以这里显式换成不换行空格更稳。
    private func codeBlockView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(preservingSpaces(code))
                .font(.system(size: baseSize - 1, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                // 让短代码块不铺满整行，长代码块自然超出后横向滚动。
                .fixedSize(horizontal: true, vertical: false)
        }
        // `frame(maxWidth: .infinity)` 把滚动容器的可用宽度钉死在父级给的宽度上。
        // 这一步不能省：不加的话 ScrollView 会按**内容**宽度申请空间，
        // 长代码行会把整个气泡撑出屏幕。
        .frame(maxWidth: .infinity, alignment: .leading)
        // 双保险：即使上面某处算错，也绝不让内容画出气泡之外。
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(codeBackground)
        )
        // 代码块外层再套一层细描边：浅色底在浅色气泡上不够明显。
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(textColor.opacity(0.10), lineWidth: 1)
        )
    }

    /// 块引用：左侧竖向细线 + 稍暗的文字。
    ///
    /// ## 为什么返回 `AnyView` 而不是 `some View`（别改回去！）
    ///
    /// `Block` 是**递归枚举**（`case quote([Block])`），而这里和 `blockView`
    /// 互相调用：
    ///
    ///     blockView(.quote) → quoteView → blockView ...
    ///
    /// 如果两个函数都返回 `some View`，编译器推断 `blockView` 的返回类型时
    /// 必须先知道 `quoteView` 的类型，反之亦然 —— **不透明类型推断死循环**，
    /// 类型检查器一路递归到**栈溢出**。
    ///
    /// 栈溢出时信号处理器自己都跑不起来，所以编译器**不会打印任何诊断**，
    /// 表现就是 `Failed frontend command:` 后面空无一物、几毫秒内直接死掉，
    /// 极难排查（我们在 GitHub Actions 上踩过这个坑）。
    ///
    /// 把这一端擦除成具体的 `AnyView` 就切断了环：`quoteView` 的类型不再依赖
    /// `blockView`，`blockView` 也就能算出来了。`AnyView` 只在引用块上用，
    /// 聊天消息里引用很少，性能影响可以忽略。
    private func quoteView(_ inner: [MarkdownRender.Block]) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 9) {
                // 竖线。用固定宽度矩形而不是 `Divider`，这样才能控制粗细和圆角。
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(textColor.opacity(0.28))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(inner.indices, id: \.self) { index in
                        blockView(inner[index])
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 竖线要跟着内容高度走，所以水平方向不能固定尺寸。
            .fixedSize(horizontal: false, vertical: true)
        )
    }

    // MARK: 配色

    /// 代码底色。深色模式用更亮一点的黑，浅色模式用极浅的灰。
    private var codeBackground: Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.055)
    }

    /// 保留代码块里的连续空格。
    ///
    /// 只用不换行空格会破坏自动换行，所以只处理**行首缩进**和
    /// **连续 2 个以上空格**里的第二个及之后——把每行的前导空格换成
    /// 不换行空格（缩进必须保留），行内连续空格同理。
    private func preservingSpaces(_ code: String) -> String {
        code
            .components(separatedBy: "\n")
            .map { line -> String in
                var result = ""
                var pendingSpaces = 0
                for ch in line {
                    if ch == " " {
                        pendingSpaces += 1
                        continue
                    }
                    if pendingSpaces > 0 {
                        // 缩进用不换行空格，视觉宽度一致且不会被折叠。
                        result += String(repeating: "\u{00A0}", count: pendingSpaces)
                        pendingSpaces = 0
                    }
                    result.append(ch)
                }
                // 行尾空格通常无意义，直接丢掉（否则横向滚动会莫名变长）。
                return result
            }
            .joined(separator: "\n")
    }
}

// MARK: - 可选中正文（UITextView 承载）

/// 正文的 `NSAttributedString` 构造。
///
/// 为什么正文不再用 SwiftUI `Text`：`Text` 的 `.textSelection(.enabled)` 一旦
/// 和外层手势共存，长按会被手势抢走，只剩链接预览菜单（「拷贝 / 分享」），
/// 既选不了字也拖不动。换成一个真正的 `UITextView` 才有系统原生选字：
/// 长按选词、放大镜、选区把手、完整的「拷贝 / 查询 / 翻译 / 分享」菜单。
enum MessageAttributed {
    /// 链接用的自定义属性。
    ///
    /// 刻意**不用**系统的 `.link`：`.link` 会让 `UITextView` 自己接管点击并弹
    /// 链接预览菜单，而我们要「点链接=打开、点别处=弹自定义菜单」，所以只把
    /// URL 记在这个属性里，跳转在 `SelectableTextView.handleTap` 里自己做。
    static let linkKey = NSAttributedString.Key("ChatServerMessageLink")

    /// 正文基础字号。`.font(.app(size:))` 内部会 +1，这里保持一致。
    static func baseFont(size: CGFloat) -> UIFont {
        .systemFont(ofSize: size + 1)
    }

    /// 段落样式：行距 2，和原来 `.lineSpacing(2)` 一致。
    static func paragraphStyle(lineSpacing: CGFloat = 2) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// 纯文本（自动识别 http(s) 链接）。
    static func plain(
        _ text: String,
        textColor: UIColor,
        linkColor: UIColor,
        size: CGFloat
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let font = baseFont(size: size)
        let style = paragraphStyle()

        for part in LinkDetector.segments(in: text) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: style
            ]
            if let url = part.url {
                attrs[.foregroundColor] = linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[linkKey] = url
            }
            output.append(NSAttributedString(string: part.text, attributes: attrs))
        }
        return output
    }

    /// Markdown 行内片段（粗体 / 行内代码 / 链接）。
    static func inlines(
        _ inlines: [MarkdownRender.Inline],
        textColor: UIColor,
        linkColor: UIColor,
        size: CGFloat,
        codeBackground: UIColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let font = baseFont(size: size)
        let style = paragraphStyle()

        for part in inlines {
            switch part {
            case .text(let value):
                // 普通文本里也要识别 http(s)：用户要求「所有 https 开头都变超链接」，
                // 这条规则和 Markdown 语法是两套，要同时生效。
                for segment in LinkDetector.segments(in: value) {
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: textColor,
                        .paragraphStyle: style
                    ]
                    if let url = segment.url {
                        attrs[.foregroundColor] = linkColor
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        attrs[linkKey] = url
                    }
                    output.append(NSAttributedString(string: segment.text, attributes: attrs))
                }

            case .bold(let value):
                output.append(
                    NSAttributedString(string: value, attributes: [
                        .font: UIFont.systemFont(ofSize: size + 1, weight: .semibold),
                        .foregroundColor: textColor,
                        .paragraphStyle: style
                    ])
                )

            case .code(let value):
                output.append(
                    NSAttributedString(string: value, attributes: [
                        // 行内代码和原来一样用等宽字体（不 +1），加字符底纹。
                        .font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: codeBackground,
                        .paragraphStyle: style
                    ])
                )
            }
        }
        return output
    }
}

/// 可选中正文。`UITextView` 的 SwiftUI 包装，尺寸由文字自己算。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    /// 单击（无选区、非链接）回调。
    var onTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView(frame: .zero, textContainer: nil)
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        view.onTap = onTap
        view.apply(attributed)
    }

    /// 让 SwiftUI 用文字的实际尺寸排版。
    ///
    /// 不自己算就会退化成「占满可用宽度」，短消息会变成通栏气泡。
    /// 先按「不换行」算理想宽度并夹到可用宽度，再按这个宽度算高度，
    /// 和 `Text` 的换行行为一致。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: SelectableTextView,
        context: Context
    ) -> CGSize? {
        SelectableText.measure(attributed, maxWidth: proposal.width)
    }

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat?) -> CGSize {
        guard text.length > 0 else { return .zero }

        let unbounded = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let ideal = text.boundingRect(
            with: unbounded,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width

        // 可用宽度：气泡上限 282 减掉左右内边距（14+15）≈ 253。
        // 提议宽度可能是 `nil` 或无穷大（外层没给约束），一律退回 253，
        // 否则文字会撑破气泡。
        var limit: CGFloat = 253
        if let maxWidth, maxWidth.isFinite, maxWidth > 1 {
            limit = maxWidth
        }
        let width = min(ceil(ideal) + 1, limit)

        let wrapped = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        // 多留 2pt：文本视图是硬边界（不可滚动），高度差一点点就会裁掉最后一行。
        return CGSize(width: width, height: ceil(wrapped.height) + 2)
    }
}

/// 承载正文的文本视图。
///
/// 三件事必须同时成立，缺一个就会退回到「长按只弹链接菜单」：
/// 1. `isSelectable = true` + `isEditable = false` → 系统原生选字；
/// 2. 不加任何 SwiftUI 手势到正文上（手势会抢走长按）；
/// 3. 单击用 `UITapGestureRecognizer` 自己判：有选区不弹（那一下是在收选区），
///    点在链接上则打开链接，其余才弹「复制 / 编辑 / 撤销」。
final class SelectableTextView: UITextView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    private let tapRecognizer = UITapGestureRecognizer()
    /// 上一次真正应用过的内容。和它比而不是和 `attributedText` 比：
    /// 文本视图可能对传入的属性串做规范化，直接比会永远不相等，
    /// 导致每次 SwiftUI 刷新都重置一次文本、把选区清掉。
    private var applied: NSAttributedString?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        contentInset = .zero
        // 内边距全部交给外层 SwiftUI 的 `.padding`，这里清零，
        // 否则气泡会多出 8pt 上边距、选区位置也会偏。
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        // 链接由属性串自己标（见 `MessageAttributed.linkKey`），
        // 不让系统再自动识别一遍电话/日期。
        dataDetectorTypes = []

        // `cancelsTouchesInView = false`：识别出单击后仍把触摸交给文本视图，
        // 否则系统收选区、定位插入点这些行为会失效。
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delaysTouchesBegan = false
        tapRecognizer.delegate = self
        tapRecognizer.addTarget(self, action: #selector(handleTap))
        addGestureRecognizer(tapRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ text: NSAttributedString) {
        if let applied, applied.isEqual(to: text) { return }
        applied = text
        attributedText = text
    }

    /// 允许多个手势同时识别：系统的选字手势必须能和我们这个单击手势共存。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleTap() {
        // 有选区：这一下是系统在收选区 / 拖选，不弹菜单。
        // 长按选字后抬手也会走到这里，靠这个判断挡住，不需要额外的长按手势
        // （额外加长按手势反而会抢掉系统的选字手势）。
        guard selectedRange.length == 0 else { return }

        if let url = linkURL(at: tapRecognizer.location(in: self)) {
            UIApplication.shared.open(url)
            return
        }
        onTap?()
    }

    /// 点中的字符是否带链接属性。
    private func linkURL(at point: CGPoint) -> URL? {
        guard attributedText.length > 0,
              let position = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard offset >= 0, offset < attributedText.length else { return nil }
        return attributedText.attribute(MessageAttributed.linkKey, at: offset, effectiveRange: nil) as? URL
    }
}
