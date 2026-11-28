import SwiftUI
import UIKit

/// 带 Markdown 编辑菜单的聊天输入框。
///
/// ## 为什么必须用 `UITextView`
///
/// SwiftUI 的 `TextField` / `TextEditor` 在 iOS 16 上**没有**开放「向系统原生
/// 编辑菜单追加自定义项」的能力。`UIEditMenuInteraction` 只在 `UITextView`、
/// `UITextField` 这类 UIKit 文本控件上才可定制（重写
/// `editMenu(for:suggestedActions:)`）。
///
/// 所以这里用 `UIViewRepresentable` 把 `UITextView` 包进来，
/// 但**只替换输入控件这一小块**——发送按钮、图片按钮、表情面板、
/// 正在输入上报、焦点管理全部保持原样。
///
/// ## 如何保证不破坏原生能力
///
/// 关键点是：**不重写 `editMenu` 之外的任何东西**。
///
/// - `editMenu(for:suggestedActions:)` 里只往系统给的建议菜单**追加**三项，
///   系统自带的复制 / 剪切 / 粘贴 / 全选 / 翻译 / 查询全部原样保留。
/// - 不实现 `canPerformAction` 的拦截（只对三个自定义 selector 返回 true，
///   其它一律交还 super），所以粘贴、全选等不会被屏蔽。
/// - 让它继续用系统输入法：不碰 `inputDelegate`、不设置 `textContentType`、
///   不改 `keyboardType`，中文拼音候选词行为与原生一致。
/// - 撤销重做交给 `UITextView.undoManager`，编辑时用
///   `replace(_:withText:)` 而不是直接改 `text`，这样能进撤销栈。
struct MarkdownInputField: UIViewRepresentable {
    @Binding var text: String
    /// 是否可编辑（对应 `model.canReply`）。
    var isEditable: Bool = true
    /// 聚焦状态绑定，和原来的 `@FocusState` 对接。
    var isFocused: Binding<Bool>
    /// 内容变化回调（用来上报「正在输入」）。
    var onTextChange: ((String) -> Void)? = nil

    /// 行数上限对应的近似高度。超过后内部滚动。
    var minLines: Int = 1
    var maxLines: Int = 5

    func makeUIView(context: Context) -> UITextView {
        let view = MarkdownInputTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.font = UIFont.systemFont(ofSize: 16)   // 对应 Theme.app(size: 15) 的 +1
        view.textColor = .label
        // 关闭「智能」改写：聊天输入里不需要自动把引号变弯、把 -- 变破折号，
        // 那会破坏用户手写的 Markdown 标记。
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        // 不要自动大写（服务器地址、代码片段都可能被改写）。
        view.autocapitalizationType = .none
        view.autocorrectionType = .default
        view.keyboardDismissMode = .interactive
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self

        // 只在外部值和内部不一致时才写回。直接无条件赋值会把
        // 用户正在输入的拼音候选状态清掉（输入法的 markedText 被覆盖）。
        if view.text != text {
            let previous = view.text ?? ""

            // 判断这次变化是不是「外部在末尾追加」（点击表情面板就是这个场景）。
            // 是的话光标要跟到新内容末尾，否则用户点完表情光光标还停在中间，
            // 接着打的字会插到表情前面，体验很怪。
            let isAppendOnly = text.count > previous.count && text.hasPrefix(previous)

            if isAppendOnly {
                view.text = text
                let end = (text as NSString).length
                view.selectedRange = NSRange(location: end, length: 0)
            } else {
                // 其它情况（发送后清空、外部整体替换）保留原光标，
                // 并夹到合法范围内，避免越界崩溃。
                let selected = view.selectedRange
                view.text = text
                let limit = (text as NSString).length
                let location = min(selected.location, limit)
                view.selectedRange = NSRange(
                    location: location,
                    length: min(selected.length, limit - location)
                )
            }
        }

        view.isEditable = isEditable

        // 聚焦同步。`becomeFirstResponder` 必须在主线程且避免重复调用，
        // 否则会打断输入法的候选词窗口。
        if isFocused.wrappedValue, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused.wrappedValue, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// 高度自适应。
    ///
    /// 逻辑：
    /// 1. 先按当前宽度算「内容真正需要多高」
    /// 2. 夹在 `minLines`~`maxLines` 之间
    /// 3. 超过 `maxLines` 时打开内部滚动，否则多余内容会被裁掉却滚不到
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        // 上下各留一点呼吸空间，否则光标会贴边。
        let minHeight = lineHeight * CGFloat(minLines) + 2
        let maxHeight = lineHeight * CGFloat(maxLines) + 2
        let height = min(max(fitting.height, minHeight), maxHeight)

        // 内容超过上限 → 允许内部滚动（这才是原生输入框该有的行为）。
        // 注意这个赋值不能放在 `makeUIView`：那时还不知道实际宽度。
        let needsScroll = fitting.height > maxHeight + 0.5
        if uiView.isScrollEnabled != needsScroll {
            uiView.isScrollEnabled = needsScroll
            // 滚动开关会重置 textContainerInset，必须重新压成 0，
            // 否则文字会突然向右下偏移 8pt，看起来像抖动。
            uiView.textContainerInset = .zero
            uiView.textContainer.lineFragmentPadding = 0
        }

        return CGSize(width: width, height: height)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownInputField

        init(parent: MarkdownInputField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let value = textView.text ?? ""
            // 回写 SwiftUI 状态。注意这里不触发循环：`updateUIView` 会比对值。
            parent.text = value
            parent.onTextChange?(value)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused.wrappedValue {
                parent.isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused.wrappedValue {
                parent.isFocused.wrappedValue = false
            }
        }

        /// 控制可编辑性之外的所有原生行为都不拦。
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            true
        }
    }
}

// MARK: - 带 Markdown 菜单的 UITextView

/// 只在系统原生编辑菜单上**追加**三项，其余全部交还系统。
final class MarkdownInputTextView: UITextView {

    // MARK: 原生菜单扩展

    override func editMenu(
        for textRange: UITextRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let markdown = UIMenu(
            title: "Markdown",
            options: [.displayInline],
            children: [
                UIAction(title: "粗体", image: UIImage(systemName: "bold")) { [weak self] _ in
                    self?.applyBold()
                },
                UIAction(title: "代码", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { [weak self] _ in
                    self?.applyCode()
                },
                UIAction(title: "引用", image: UIImage(systemName: "text.quote")) { [weak self] _ in
                    self?.applyQuote()
                }
            ]
        )

        // 优先用系统给的菜单（复制 / 剪切 / 粘贴 / 全选 / 翻译 / 查询…），
        // 在其基础上**追加**，原生项的文案、顺序、分组全部保留。
        //
        // ⚠️ 但 `super.editMenu(for:suggestedActions:)` 在某些情况下会返回
        // **nil 或空 children**（比如刚进页面还没选中任何文字、剪贴板为空）。
        // 之前这里直接 `return markdown`，结果原生菜单整组消失，只剩 3 个
        // 自定义项 —— 用户完全没法复制粘贴了。
        //
        // 所以这里做兜底：系统没给就自己补上 4 个标准编辑项。
        // 宁可少几个系统特有的项（翻译/查询），也不能让复制粘贴消失。
        if let base = super.editMenu(for: textRange, suggestedActions: suggestedActions),
           !base.children.isEmpty {
            return base.replacingChildren(base.children + [markdown])
        }

        let fallback = standardEditActions()
        if fallback.isEmpty {
            // 连「粘贴/全选」都不可用（输入框空且剪贴板空）——只留 Markdown 项。
            return markdown
        }
        return UIMenu(title: "", options: [.displayInline], children: fallback + [markdown])
    }

    /// 自己构造标准编辑项，仅在系统没给菜单时使用。
    ///
    /// 每一项都先问 `canPerformAction`，不可用的直接不显示——
    /// 和系统原生菜单的行为保持一致（没选中文字时不显示「复制」）。
    private func standardEditActions() -> [UIMenuElement] {
        var items: [UIMenuElement] = []

        let cutSelector = #selector(UIResponderStandardEditActions.cut(_:))
        if canPerformAction(cutSelector, withSender: nil) {
            items.append(
                UIAction(title: "剪切", image: UIImage(systemName: "scissors")) { [weak self] _ in
                    self?.cut(nil)
                }
            )
        }

        let copySelector = #selector(UIResponderStandardEditActions.copy(_:))
        if canPerformAction(copySelector, withSender: nil) {
            items.append(
                UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copy(nil)
                }
            )
        }

        let pasteSelector = #selector(UIResponderStandardEditActions.paste(_:))
        if canPerformAction(pasteSelector, withSender: nil) {
            items.append(
                UIAction(title: "粘贴", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    self?.paste(nil)
                }
            )
        }

        let selectAllSelector = #selector(UIResponderStandardEditActions.selectAll(_:))
        if canPerformAction(selectAllSelector, withSender: nil) {
            // 「全选」没有合适的 SF Symbol，和系统原生菜单一样不配图标。
            items.append(
                UIAction(title: "全选") { [weak self] _ in
                    self?.selectAll(nil)
                }
            )
        }

        return items
    }

    // MARK: 三个编辑动作

    /// 粗体：选中就包起来，没选中就插入一对并把光标放中间。
    private func applyBold() {
        commitMarkedTextIfNeeded()
        wrapSelection(with: "**")
    }

    /// 代码：单行用反引号，多行用围栏代码块。
    private func applyCode() {
        commitMarkedTextIfNeeded()
        guard let range = selectedTextRange, !range.isEmpty else {
            // 无选区：插入一对反引号，光标居中。
            insertToken(open: "`", close: "`", at: selectedRange)
            return
        }
        let selected = text(in: range) ?? ""
        if selected.contains("\n") {
            // 多行 → 围栏代码块。`replace(_:withText:)` 才能进撤销栈。
            let replacement = "```\n" + selected + "\n```"
            replace(range, withText: replacement)
            // 把选区落在原来的内容上，方便用户继续调整。
            let start = offset(from: beginningOfDocument, to: range.start)
            let innerStart = start + 4   // "```\n"
            selectedRange = NSRange(location: innerStart, length: (selected as NSString).length)
        } else {
            wrapSelection(with: "`")
        }
    }

    /// 引用：给选中的**每一行**前面加 `> `；无选区就给当前行加。
    private func applyQuote() {
        commitMarkedTextIfNeeded()
        guard let range = selectedTextRange else { return }

        // 无选区 → 当前行整行加前缀。
        guard !range.isEmpty else {
            insertQuoteOnCurrentLine()
            return
        }

        let selected = text(in: range) ?? ""
        guard !selected.isEmpty else {
            insertQuoteOnCurrentLine()
            return
        }

        // 每行都加 `> `，保留原有换行结构。
        let quoted = selected
            .components(separatedBy: "\n")
            .map { line -> String in
                // 已经有引用标记的行不重复加，避免「> > 内容」。
                if line.hasPrefix(">") { return line }
                return "> " + line
            }
            .joined(separator: "\n")

        replace(range, withText: quoted)
        let start = offset(from: beginningOfDocument, to: range.start)
        selectedRange = NSRange(location: start, length: (quoted as NSString).length)
    }

    // MARK: 编辑辅助

    /// 中文拼音等输入法正在拼写时，先让系统把候选词上屏，再做 Markdown 编辑。
    ///
    /// 为什么必须做：拼音输入过程中 `markedTextRange` 非空，
    /// 此时直接 `replace` 会把还没上屏的拼音连标记一起覆盖掉，
    /// 用户会看到「abc**」这种残渣。调用 `unmarkText()` 等于点了一下候选词，
    /// 是系统认可的行为，不改变输入法本身的逻辑。
    private func commitMarkedTextIfNeeded() {
        guard markedTextRange != nil else { return }
        unmarkText()
    }

    /// 用一对标记包住选区；无选区时插入一对并把光标放中间。
    private func wrapSelection(with marker: String) {
        guard let range = selectedTextRange else { return }
        if range.isEmpty {
            insertToken(open: marker, close: marker, at: selectedRange)
        } else {
            let selected = text(in: range) ?? ""
            replace(range, withText: marker + selected + marker)
            // 选区保留在原文上，用户能立刻看到加粗范围。
            let start = offset(from: beginningOfDocument, to: range.start)
            selectedRange = NSRange(
                location: start + (marker as NSString).length,
                length: (selected as NSString).length
            )
        }
    }

    /// 插入 `open` + `close`，光标落在两者中间。
    ///
    /// 走 `replace(_:withText:)` 而不是拼接 `text` 字符串，
    /// 这样操作会进 `undoManager`，用户能摇一摇撤销。
    private func insertToken(open: String, close: String, at range: NSRange) {
        guard let caret = position(from: beginningOfDocument, offset: range.location),
              let insertion = textRange(from: caret, to: caret) else { return }

        replace(insertion, withText: open + close)

        // 光标移到两个标记之间。
        let target = range.location + (open as NSString).length
        if let newCaret = position(from: beginningOfDocument, offset: target) {
            selectedTextRange = textRange(from: newCaret, to: newCaret)
        }
    }

    /// 无选区时给当前整行加 `> `。
    private func insertQuoteOnCurrentLine() {
        let ns = text as NSString
        let caret = selectedRange.location
        // `lineRange` 会连行尾换行一起包含，这里只需要它的起点。
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        let lineContent = ns.substring(with: lineRange)
        // 已经引用过就不重复加。
        guard !lineContent.hasPrefix(">") else { return }

        guard let start = position(from: beginningOfDocument, offset: lineRange.location),
              let insertion = textRange(from: start, to: start) else { return }

        replace(insertion, withText: "> ")

        // 光标跟着内容后移 2 位。
        if let newCaret = position(from: beginningOfDocument, offset: caret + 2) {
            selectedTextRange = textRange(from: newCaret, to: newCaret)
        }
    }
}
