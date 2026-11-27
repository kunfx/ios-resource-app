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
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
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
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // 圆点用固定宽度的容器：不同字符宽度的项目符号
                        // 会让第二行文字和第一行错位。
                        Text("•")
                            .font(.app(size: baseSize, weight: .semibold))
                            .foregroundStyle(textColor.opacity(0.7))
                            .frame(width: 8, alignment: .leading)
                        inlineText(item)
                            .fixedSize(horizontal: false, vertical: true)
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
    private func inlineText(_ inlines: [MarkdownRender.Inline]) -> Text {
        var output = AttributedString()

        for part in inlines {
            switch part {
            case .text(let value):
                // 普通文本里也要识别 http(s)：用户要求「所有 https 开头都变超链接」，
                // 这条规则和 Markdown 语法是两套，要同时生效。
                if let linked = LinkDetector.attributed(
                    value,
                    textColor: textColor,
                    linkColor: linkColor
                ) {
                    output.append(linked)
                } else {
                    var piece = AttributedString(value)
                    piece.foregroundColor = textColor
                    output.append(piece)
                }

            case .bold(let value):
                var piece = AttributedString(value)
                piece.foregroundColor = textColor
                piece.inlinePresentationIntent = .stronglyEmphasized
                output.append(piece)

            case .code(let value):
                var piece = AttributedString(value)
                // 行内代码用等宽字体 + 底色。`backgroundColor` 在
                // AttributedString 里由 SwiftUI 支持，能画出字符底纹。
                piece.foregroundColor = textColor
                piece.font = .system(size: baseSize, design: .monospaced)
                piece.backgroundColor = codeBackground
                output.append(piece)
            }
        }

        return Text(output)
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
    private func quoteView(_ inner: [MarkdownRender.Block]) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // 竖线。用固定宽度矩形而不是 `Divider`，这样才能控制粗细和圆角。
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(textColor.opacity(0.28))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 竖线要跟着内容高度走，所以水平方向不能固定尺寸。
        .fixedSize(horizontal: false, vertical: true)
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
