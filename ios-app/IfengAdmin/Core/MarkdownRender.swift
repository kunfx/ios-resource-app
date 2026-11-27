import Foundation
import SwiftUI

/// 聊天消息的 Markdown 轻量渲染器。
///
/// ## 为什么不是完整 Markdown 解析器
///
/// 需求只要 **4 种**语法：粗体、无序列表、代码（行内 + 围栏块）、块引用。
/// 引入完整 markdown-it 之类会顺带支持斜体、标题、表格……反而超出范围，
/// 而且第三方库更难以控制「不撑破气泡」这类布局细节。
///
/// 所以这里手写一个**只认这 4 种**的行级 + 行内两层解析：
///
/// - 行级：把原文切成段落 / 列表 / 代码块 / 引用块
/// - 行内：在段落和列表项里再识别 `**粗体**` 和 `` `行内代码` ``
///
/// 与网页端 `web/message-format.js`（markdown-it + 标签白名单）的差异：
/// 网页端把 `> 引用` 渲染成 `<blockquote>`、列表渲染成 `<ul><li>`，
/// 这里在视觉上对齐同样的观感（左侧竖线、圆点列表），但不产出 HTML。
///
/// ## 安全
///
/// 全程只做「文本 → SwiftUI 视图」，**不解释 HTML、不执行任何脚本**，
/// 也不改写服务端的原始消息内容——解析只发生在渲染时。
enum MarkdownRender {

    // MARK: 块模型

    /// 一个块级元素。
    enum Block: Equatable {
        /// 普通段落（可能多行，行内已解析）。
        case paragraph([Inline])
        /// 无序列表。`items` 每个元素是一行的行内内容。
        case bulletList([[Inline]])
        /// 围栏代码块。`code` 保留原始换行与空格。
        case codeBlock(String)
        /// 块引用。内部可以再嵌套段落 / 列表 / 代码。
        case quote([Block])
    }

    /// 行内片段。
    enum Inline: Equatable {
        case text(String)
        case bold(String)
        case code(String)
    }

    // MARK: 入口

    /// 解析成块列表。
    ///
    /// 解析失败也不会抛错：任何不认识的行都按普通文本处理，
    /// 保证「格式错误不会导致消息消失或渲染失败」。
    static func parse(_ source: String) -> [Block] {
        // 统一换行符。Windows 粘贴进来的 `\r\n` 不归一化会导致代码块判断错位。
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var bullets: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            // 段落内多行用软换行拼成一行再解析行内——
            // 网页端 markdown-it 开着 `breaks:true`，单个换行会变成 `<br>`。
            // 这里用 `\n` 保留换行，由渲染层决定怎么处理。
            let joined = paragraphLines.joined(separator: "\n")
            blocks.append(.paragraph(parseInline(joined)))
            paragraphLines.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bulletList(bullets.map { parseInline($0) }))
            bullets.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
        }

        let lines = normalized.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // ---- 围栏代码块：``` 开头，找配对的结束 ``` ----
            if let fence = fenceMarker(line) {
                flushAll()
                var code: [String] = []
                index += 1
                // 一直吃到同样长度以上的 ``` 为止。没找到就吃到文末——
                // 这让「用户只打了开头三个反引号」也能正常显示，不会吞掉消息。
                while index < lines.count {
                    if let closing = fenceMarker(lines[index]), closing.count >= fence.count {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            // ---- 块引用：`>` 开头，可以连续多行，内部还能嵌套 ----
            if isQuoteLine(line) {
                flushAll()
                var quoted: [String] = []
                while index < lines.count, isQuoteLine(lines[index]) {
                    quoted.append(stripQuoteMarker(lines[index]))
                    index += 1
                }
                // 递归解析引用内部，支持「引用里有列表 / 代码」。
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            // ---- 无序列表：`- ` / `* ` / `+ ` ----
            if let item = bulletItem(line) {
                flushParagraph()
                bullets.append(item)
                index += 1
                continue
            }

            // ---- 空行：结束当前块 ----
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushAll()
                index += 1
                continue
            }

            // ---- 其它：普通段落行 ----
            flushBullets()
            paragraphLines.append(line)
            index += 1
        }

        flushAll()
        return blocks
    }

    // MARK: 行内解析

    /// 解析 `**粗体**` 与 `` `行内代码` ``。
    ///
    /// 代码优先于粗体：`` `**a**` `` 里的星号是代码内容，不该再加粗。
    static func parseInline(_ text: String) -> [Inline] {
        var result: [Inline] = []
        var buffer = ""
        var i = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            result.append(.text(buffer))
            buffer.removeAll()
        }

        while i < text.endIndex {
            let ch = text[i]

            // 行内代码：`...`，中间不能有换行（CommonMark 的行内代码可以跨行，
            // 但聊天场景里跨行反引号几乎都是误输入，限制在单行更符合预期）。
            if ch == "`" {
                if let close = text[text.index(after: i)...].firstIndex(of: "`"),
                   !text[text.index(after: i)..<close].contains("\n") {
                    flushBuffer()
                    let inner = String(text[text.index(after: i)..<close])
                    // 空的 `` 不认，避免把「两个反引号」当代码。
                    if inner.isEmpty {
                        buffer += "``"
                    } else {
                        result.append(.code(inner))
                    }
                    i = text.index(after: close)
                    continue
                }
            }

            // 粗体：**...**，要求成对，且中间不能是空串。
            if ch == "*", text[i...].hasPrefix("**") {
                let openEnd = text.index(i, offsetBy: 2)
                // 用搜索而不是简单 `firstIndex(of:)`：要从 openEnd 之后找配对的 `**`。
                if let closeStart = findClosingBold(in: text, from: openEnd) {
                    let inner = String(text[openEnd..<closeStart])
                    if !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flushBuffer()
                        result.append(.bold(inner))
                        i = text.index(closeStart, offsetBy: 2)
                        continue
                    }
                }
            }

            buffer.append(ch)
            i = text.index(after: i)
        }

        flushBuffer()
        return result
    }

    /// 从 `from` 开始找配对的 `**` 起点。
    ///
    /// 跳过 `` ` `` 包起来的片段：`` **a** 和 `**b**` `` 里第二处星号在代码中，
    /// 不该被当作粗体的闭合。
    private static func findClosingBold(in text: String, from: String.Index) -> String.Index? {
        var i = from
        while i < text.endIndex {
            let ch = text[i]
            if ch == "`" {
                // 跳过一段行内代码。
                if let close = text[text.index(after: i)...].firstIndex(of: "`") {
                    i = text.index(after: close)
                    continue
                }
                return nil
            }
            if ch == "*", text[i...].hasPrefix("**") {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: 行识别

    /// 围栏标记：连续的 3 个以上反引号。返回反引号个数。
    private static func fenceMarker(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("`") else { return nil }
        let count = trimmed.prefix { $0 == "`" }.count
        guard count >= 3 else { return nil }
        // 围栏行只允许反引号（+ 可选的语言名，这里忽略语言名）。
        let rest = trimmed.dropFirst(count)
        // 允许 ```swift 这种写法：剩下部分不含反引号即可。
        guard !rest.contains("`") else { return nil }
        return count
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func stripQuoteMarker(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix(">") else { return line }
        s.removeFirst()
        // `> 文本` 和 `>文本` 都接受，去掉紧跟的一个空格。
        if s.hasPrefix(" ") { s.removeFirst() }
        return s
    }

    /// 无序列表项。返回去掉标记后的内容。
    ///
    /// 只认 `-` `*` `+` 后跟至少一个空格，避免把 `**粗体**` 开头的行误判成列表
    /// （`*` 后紧跟 `*` 没有空格，所以不会命中）。
    private static func bulletItem(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == "-" || first == "*" || first == "+" else {
            return nil
        }
        let after = trimmed.dropFirst()
        guard after.hasPrefix(" ") || after.hasPrefix("\t") else { return nil }
        return String(after.drop(while: { $0 == " " || $0 == "\t" }))
    }

    // MARK: 纯文本

    /// 去掉所有 Markdown 标记，还原成纯文本。
    ///
    /// 用在聊天列表的摘要、推送通知等只需要文字的地方。
    static func plainText(_ source: String) -> String {
        var out: [String] = []
        for block in parse(source) {
            switch block {
            case .paragraph(let inlines):
                out.append(inlines.plain)
            case .bulletList(let items):
                for item in items { out.append("• " + item.plain) }
            case .codeBlock(let code):
                out.append(code)
            case .quote(let inner):
                out.append(inner.map { $0.plain }.joined(separator: " "))
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 是否含 Markdown

    /// 快速判断有没有**能真正生效**的 Markdown 标记。
    ///
    /// 没有就走原来的纯 `Text` 路径：排版行为更可预测，也省掉解析开销。
    ///
    /// 注意这里不能用 `contains("**")` 这种粗糙判断：
    /// 聊天里「2 * 3 = 6」「5*5」很常见，一旦误判就会走块级渲染路径，
    /// 行高和行内间距都会和纯文本路径不一致，产生肉眼可见的抖动。
    /// 所以直接跑一遍解析，看有没有真的产出 bold / code / 列表 / 引用块。
    static func hasMarkdown(_ source: String) -> Bool {
        // 先做便宜的字符筛查，绝大多数纯文本在这里就返回了。
        guard source.contains("*") || source.contains("`") || source.contains(">")
                || source.contains("- ") || source.contains("\n")
        else {
            return false
        }

        for block in parse(source) {
            switch block {
            case .paragraph(let inlines):
                // 段落里只有含 bold / code 才算「有 Markdown」。
                let hasInlineMarkup = inlines.contains { inline in
                    switch inline {
                    case .text: return false
                    case .bold, .code: return true
                    }
                }
                if hasInlineMarkup { return true }
            case .bulletList, .codeBlock, .quote:
                return true
            }
        }
        return false
    }
}

// MARK: - 便利属性

extension Array where Element == MarkdownRender.Inline {
    /// 拼回纯文本（去掉标记）。
    var plain: String {
        map { part in
            switch part {
            case .text(let t): return t
            case .bold(let t): return t
            case .code(let t): return t
            }
        }.joined()
    }
}

extension MarkdownRender.Block {
    /// 块的纯文本形式。
    var plain: String {
        switch self {
        case .paragraph(let inlines): return inlines.plain
        case .bulletList(let items): return items.map { "• " + $0.plain }.joined(separator: " ")
        case .codeBlock(let code): return code
        case .quote(let inner): return inner.map { $0.plain }.joined(separator: " ")
        }
    }
}
