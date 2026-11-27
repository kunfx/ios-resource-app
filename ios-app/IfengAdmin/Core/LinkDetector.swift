import Foundation
import SwiftUI

/// 把纯文本里的 http(s) 地址识别成可点击链接。
///
/// ## 为什么自己写，而不是用 `NSDataDetector`
///
/// `NSDataDetector` 会把电话、日期、地址也一起识别出来，聊天场景里经常误伤
/// （订单号被当成电话、`2026-11-27` 被当成日期）。这里只要 URL，
/// 而且规则要和网页端**完全一致**，否则同一条消息在两端看起来不一样。
///
/// 规则对齐 `web/message-format.js` 的 `plainLinks`：
///
/// 1. 只认 `http://` / `https://` 开头（大小写不敏感）
/// 2. 遇到空白、`<`、`>`、`-` 就断开
/// 3. **从尾部剥掉中文和英文标点** `.,!?;:，。！？；：、`
/// 4. 再剥掉**不成对**的右括号 `)` `]` `}`
///    （`(https://a.com)` 这种整体被括号包住的，括号不算链接的一部分）
/// 5. 最后校验：必须能解析出 hostname，且不能带用户名密码
///
/// 第 3、4 步是最容易漏的地方。聊天里「详见 https://example.com/a。」这种
/// 带中文句号的句子很常见，不剥掉句号点进去就是 404。
enum LinkDetector {
    /// 尾部要去掉的标点（中英文混排，和网页端一致）。
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,!?;:，。！？；：、")

    /// 尾部需要「配对才保留」的括号。
    private static let bracketPairs: [(open: Character, close: Character)] = [
        ("(", ")"), ("[", "]"), ("{", "}")
    ]

    /// 一条文本里切出来的片段。按原顺序拼回去就是原文。
    struct Segment: Equatable {
        /// 原始显示文本（链接显示的是**剥掉标点后的**地址本身）。
        let text: String
        /// 非 nil 表示这段是链接。
        let url: URL?
        var isLink: Bool { url != nil }
    }

    /// 把文本切成「普通文本 / 链接」片段。
    ///
    /// 没有任何链接时返回单个普通片段，调用方可以直接走原来的 `Text(text)` 快速路径。
    static func segments(in text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }

        var result: [Segment] = []
        var cursor = text.startIndex

        // 用 NSRegularExpression 而不是 NSDataDetector：只要 URL，不要电话日期。
        //
        // 这里的字符集比网页端**更严**一点：把中文标点也排除掉。
        // 网页端 `[^\s<>-]+` 会把「https://a.com，后面还有字」整串吃掉，
        // 靠最后剥尾标点来救——但中间的中文逗号剥不到，整句就变成一个假链接。
        // 聊天里中英文混排极常见，所以直接在这里断开更可靠。
        //
        // 用 `\u{...}` 转义写中文标点，不用字面量：
        // 一是避免源码里混进全角/半角长得像的字符，二是这套字符集
        // 已经在 Python 里逐条验证过边界。
        let excluded = "\\s<>-"
            + "\u{FF0C}\u{3002}\u{FF01}\u{FF1F}\u{FF1B}\u{FF1A}\u{3001}"      // ，。！？；：、
            + "\u{FF08}\u{FF09}\u{3010}\u{3011}\u{300A}\u{300B}"              // （）【】《》
            + "\u{201C}\u{201D}\u{2018}\u{2019}\u{2026}\u{2014}"              // “”‘’…—
        guard let regex = try? NSRegularExpression(
            pattern: "https?://[^\(excluded)]+",
            options: [.caseInsensitive]
        ) else {
            return [Segment(text: text, url: nil)]
        }

        let full = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: full.length))

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            // 前一个匹配已经把这部分吃掉了（比如链接尾部又被剥过标点），跳过。
            guard matchRange.lowerBound >= cursor else { continue }

            // 先把「链接前面剩下的普通文本」接上。
            if cursor < matchRange.lowerBound {
                result.append(Segment(text: String(text[cursor..<matchRange.lowerBound]), url: nil))
            }

            // 再处理链接本体：剥标点、剥不成对的括号、校验。
            let raw = String(text[matchRange])
            let cleaned = trimmingTrailingNoise(raw)

            if let url = makeURL(from: cleaned) {
                result.append(Segment(text: cleaned, url: url))
                // 被剥掉的那部分标点要当作普通文本继续留在原文里。
                // `cleaned` 是从 `raw` 尾部删出来的前缀，所以
                // `lowerBound + cleaned.count` 正好指向被剥标点的起点。
                // 注意这里可能**不前进**（剥掉的标点留到下一轮处理），
                // 但 `cleaned` 非空且以 https:// 开头，所以 cursor 一定往前走。
                cursor = text.index(matchRange.lowerBound, offsetBy: cleaned.count)
            } else {
                // 校验不过就整段当普通文本（比如 `https://` 后面什么都没有）。
                result.append(Segment(text: raw, url: nil))
                cursor = matchRange.upperBound
            }

            // 防越界：正则理论上不会越过 upperBound，保险起见收敛一下。
            if cursor < matchRange.lowerBound { cursor = matchRange.lowerBound }
        }

        if cursor < text.endIndex {
            result.append(Segment(text: String(text[cursor...]), url: nil))
        }

        return result.isEmpty ? [Segment(text: text, url: nil)] : result
    }

    /// 把一段文本转成 `AttributedString`，链接部分带 `.link` 属性。
    ///
    /// - Parameters:
    ///   - text: 原始正文
    ///   - textColor: 普通文字颜色。**必须在这里写进属性**，不能靠外层
    ///     `.foregroundStyle` 兜底——视图级的样式会连链接 run 一起覆盖掉。
    ///   - linkColor: 链接颜色
    ///
    /// 返回 nil 表示「文本里没有链接」，调用方可以走更省事的纯 `Text` 路径
    /// （纯文本的排版行为更可预测，也不会因为富文本改变行高）。
    static func attributed(
        _ text: String,
        textColor: Color,
        linkColor: Color
    ) -> AttributedString? {
        let parts = segments(in: text)
        guard parts.contains(where: { $0.isLink }) else { return nil }

        var output = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            // 基色先铺满，链接再覆盖。
            piece.foregroundColor = textColor
            if let url = part.url {
                piece.link = url
                // 颜色 + 下划线，和网页 `<a>` 的观感一致。
                piece.foregroundColor = linkColor
                piece.underlineStyle = .single
            }
            output.append(piece)
        }
        return output
    }

    // MARK: 私有

    /// 剥掉尾部的标点与不成对的右括号。
    ///
    /// 括号判断用的是「右括号数量 > 左括号数量就剥掉」——
    /// 和网页端 `while(value.endsWith(right) && value.split(right).length > value.split(left).length)`
    /// 完全等价：`(https://a.com)` 里右括号比左括号多 1，所以剥掉；
    /// `https://a.com/(x)` 左右相等，保留。
    private static func trimmingTrailingNoise(_ raw: String) -> String {
        var value = raw

        // 1. 剥标点。可能连续多个，比如 `https://a.com/?.`。
        while let last = value.unicodeScalars.last, trailingPunctuation.contains(last) {
            value.removeLast()
        }

        // 2. 剥不成对的右括号。
        //    从尾部反复检查：如果最后一个字符是右括号，且这段文本里
        //    右括号数量 > 左括号数量，说明它是句子的收尾括号，不属于链接。
        var changed = true
        while changed, let last = value.last {
            changed = false
            for pair in bracketPairs where last == pair.close {
                let opens = value.filter { $0 == pair.open }.count
                let closes = value.filter { $0 == pair.close }.count
                if closes > opens {
                    value.removeLast()
                    // 剥掉括号后，尾部可能又露出标点，继续剥。
                    while let scalar = value.unicodeScalars.last, trailingPunctuation.contains(scalar) {
                        value.removeLast()
                    }
                    changed = true
                }
                break
            }
        }

        return value
    }

    /// 校验并构造 URL。规则和网页端 `safeURL` 一致。
    private static func makeURL(from value: String) -> URL? {
        // 必须 http(s) 开头。
        let lower = value.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }

        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              // 带用户名密码的地址不能点（可能被用来伪装域名）。
              url.user == nil, url.password == nil
        else {
            return nil
        }
        return url
    }
}
