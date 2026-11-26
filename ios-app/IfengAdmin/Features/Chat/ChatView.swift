import SwiftUI
import UIKit
import PhotosUI
import Combine

/// 聊天页。
///
/// 两个实时状态的接入点都在这里：
/// 1. **自己正在输入** → `model.userIsTyping(hasText:)`，输入框内容变化时调用；
///    离开页面 / 发送消息时 `model.stopTyping()`，保证访客那边的气泡一定会消失。
/// 2. **对方正在输入 / 已读回执 / 未读清零** → 由 `ChatModel` 订阅 `app.events`
///    的 SSE 事件驱动；只有实时通道不可用时才走轮询兜底（见 `setRealtimeHealthy`）。
///    本页只负责渲染 `model.peerTyping` 气泡与每条消息的 `deliveryState` 勾选。
struct ChatView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let session: AppSession
    /// 返回上一页。由 RootView 传入（直接操作 NavigationPath），
    /// 比只依赖 `dismiss()` 更确定，避免自定义返回键偶发失效。
    var onBack: (() -> Void)? = nil
    @StateObject private var model: ChatModel

    @State private var draft = ""
    @State private var showInfo = false
    @State private var showsEmoji = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingJPEG: Data?
    @State private var previewImage: UIImage?
    @State private var previewCaption = ""
    @State private var isPreparingPhoto = false
    @State private var imageTarget: ImageTarget?
    @State private var noticeText: String?
    @State private var alertText: String?
    @State private var didInitialScroll = false
    @State private var editingMessage: Message?
    @State private var recallTarget: Message?
    @FocusState private var inputFocused: Bool

    private let bottomAnchor = "chat-bottom-anchor"

    init(session: AppSession, conversationId: Int, onBack: (() -> Void)? = nil) {
        self.session = session
        self.onBack = onBack
        _model = StateObject(wrappedValue: ChatModel(session: session, conversationId: conversationId))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if model.isBlocked {
                blockedBar
            }

            composer
        }
        .background(Theme.chatBackground)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // 正圆底 + 放大图标（22）；圆直径仍是 32，热区 44。
                ToolbarIconButton(name: "chevron-left", label: "返回", size: 22, diameter: 32) {
                    model.stopTyping()
                    if let onBack {
                        onBack()
                    } else {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                titleBlock
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                ToolbarIconButton(name: "info", label: "访客资料", size: 21, diameter: 32) {
                    showInfo = true
                }
            }
        }
        .task {
            await model.start()
            // 首帧就开始兜底：不依赖 SSE 状态先回传。健康时它会自动降频到 15 秒。
            model.startPolling()
        }
        .task(id: app.realtimeHealthy) {
            // 只是「调频率」，不是「开关」：健康 → 15 秒淡兜底，不健康 → 2 秒快兜底。
            // 参照 web/app.js 的 schedulePoll（30s / 5s），从不把兜底关到 0，
            // 因为 SSE 握手成功不等于事件真的送得到（代理缓冲会静默吞事件）。
            model.setRealtimeHealthy(app.realtimeHealthy)
        }
        .onReceive(app.events) { event in
            // 串行入队（不是并发 Task）：保证事件到达顺序 = 处理顺序，
            // 否则 message.created 与 message.read 会互相覆盖。
            model.enqueue(event: event)
        }
        .onDisappear {
            model.stopPolling()
            model.stopTyping()
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { await preparePhoto(item) }
        }
        .onChange(of: model.actionNotice) { value in
            guard let value else { return }
            showNotice(value)
        }
        .onChange(of: model.actionError) { value in
            guard let value else { return }
            alertText = value
        }
        .onChange(of: model.loadError) { value in
            // 只有「一条消息都没有」时把加载错误弹出来，否则会打断正常聊天。
            guard let value, model.messages.isEmpty else { return }
            alertText = value
        }
        .alert("提示", isPresented: alertBinding) {
            Button("知道了", role: .cancel) { dismissAlert() }
        } message: {
            Text(alertText ?? "")
        }
        .overlay(alignment: .top) {
            if let noticeText {
                noticeBanner(noticeText)
            }
        }
        .sheet(isPresented: $showInfo) {
            VisitorInfoView(model: model)
        }
        .sheet(isPresented: photoPreviewBinding) {
            if let image = previewImage {
                PhotoSendPreview(
                    image: image,
                    caption: $previewCaption,
                    onCancel: { closePhotoPreview() },
                    onSend: { sendPendingPhoto() }
                )
            }
        }
        .fullScreenCover(item: $imageTarget) { target in
            ImageFullScreen(url: target.url) { imageTarget = nil }
        }
        .sheet(item: $editingMessage) { message in
            MessageEditSheet(original: message.text) { newText in
                Task { _ = await model.edit(message: message, content: newText) }
            }
        }
        .confirmationDialog(
            "撤销这条消息？",
            isPresented: recallBinding,
            titleVisibility: .visible,
            presenting: recallTarget
        ) { message in
            Button("撤销消息", role: .destructive) {
                Task { _ = await model.recall(message: message) }
            }
            Button("取消", role: .cancel) { recallTarget = nil }
        } message: { _ in
            Text("撤销后双方都会看到「该消息已撤回」，原始内容与图片都会被删除，且无法恢复。")
        }
    }

    // MARK: 顶部标题

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text(model.conversation.visitorName)
                .font(.app(size: 16, weight: .semibold))
                .lineLimit(1)
            if model.peerTyping {
                Text("正在输入…")
                    .font(.app(size: 11))
                    .foregroundStyle(Theme.accent)
            } else if let source = sourceLabel {
                Text("来自 \(source)")
                    .font(.app(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 210)
    }

    private var sourceLabel: String? {
        guard let raw = model.conversation.visitorDetails?.sourceUrl,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let host = URL(string: raw)?.host, !host.isEmpty { return host }
        return raw
    }

    // MARK: 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.hasMoreOlder || model.isLoadingOlder {
                        loadOlderButton
                    }

                    if model.isLoading && model.messages.isEmpty {
                        loadingPlaceholder
                    }

                    ForEach(rows) { row in
                        switch row {
                        case .day(let label, _):
                            daySeparator(label)
                        case .message(let message):
                            messageRow(message)
                                .id(row.id)
                        case .pending(let item):
                            PendingRow(
                                item: item,
                                onRetry: { Task { await model.retry(pendingId: item.id) } },
                                onDiscard: { model.discard(pendingId: item.id) }
                            )
                            .id(row.id)
                        }
                    }

                    if model.peerTyping {
                        HStack(spacing: 8) {
                            TypingBubble()
                            Spacer(minLength: 0)
                        }
                        // 气泡下方留出间距，滚动到底时不会被输入框压住。
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                // 底部多留一点：最后一条气泡 / 正在输入气泡与输入框之间不会贴死。
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.chatBackground)
            .onChange(of: model.messages.last?.id) { _ in
                scrollToBottom(proxy, animated: didInitialScroll)
            }
            .onChange(of: model.peerTyping) { typing in
                // 气泡是刚插入的，必须等一次布局完成再滚，否则滚到的是旧高度，
                // 三个圆点就会被输入框挡住一半。
                if typing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        }
                    }
                } else {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: model.messages.count) { _ in
                guard !didInitialScroll, !model.messages.isEmpty else { return }
                didInitialScroll = true
                scrollToBottom(proxy, animated: false)
            }
            .animation(.easeOut(duration: 0.18), value: model.peerTyping)
            .refreshable {
                await model.loadAll()
            }
        }
    }

    private var loadingPlaceholder: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 30)
    }

    private var loadOlderButton: some View {
        Button {
            Task { await model.loadOlder() }
        } label: {
            HStack(spacing: 5) {
                if model.isLoadingOlder {
                    ProgressView().scaleEffect(0.65)
                } else {
                    LucideIcon(name: "chevron-right", size: 11, color: .secondary)
                        .rotationEffect(.degrees(-90))
                }
                Text(model.isLoadingOlder ? "加载中…" : "查看更早消息")
                    .font(.app(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingOlder)
        .padding(.bottom, 8)
    }

    private func daySeparator(_ label: String) -> some View {
        Text(label)
            .font(.app(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    // MARK: 行模型

    private enum ChatRow: Identifiable {
        case day(String, Int)
        case message(Message)
        case pending(ChatModel.PendingMessage)

        var id: String {
            switch self {
            case .day(let label, let anchor): return "day-\(anchor)-\(label)"
            case .message(let message): return "m-\(message.id)"
            case .pending(let item): return "p-\(item.id)"
            }
        }
    }

    private var rows: [ChatRow] {
        var output: [ChatRow] = []
        var lastStamp: Int?
        for message in model.messages {
            if !TimeFormat.isSameDay(lastStamp, message.createdAt) {
                output.append(.day(TimeFormat.daySeparator(message.createdAt), message.id))
                lastStamp = message.createdAt
            }
            output.append(.message(message))
        }
        for item in model.pending {
            output.append(.pending(item))
        }
        return output
    }

    // MARK: 长按菜单（复制 / 编辑 / 撤销）

    private var viewerId: Int { session.profile.id }

    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        // 长按菜单挂在气泡本身上（见 ChatMessageRow），所以高亮范围就等于气泡，
        // 不会再出现横贯全宽的矩形阴影。没有可执行操作时不注册菜单。
        if hasMenuActions(for: message) {
            ChatMessageRow(
                message: message,
                onImageTap: { url in imageTarget = ImageTarget(url: url) },
                menu: { AnyView(messageActions(for: message)) }
            )
        } else {
            ChatMessageRow(
                message: message,
                onImageTap: { url in imageTarget = ImageTarget(url: url) }
            )
        }
    }

    /// 只要消息有正文或图片链接，就值得给一个菜单。
    private func hasMenuActions(for message: Message) -> Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!message.images.isEmpty && !message.isRecalled)
            || message.canEdit(viewerId: viewerId)
            || message.canRecall(viewerId: viewerId)
    }

    @ViewBuilder
    private func messageActions(for message: Message) -> some View {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            Button {
                copyToPasteboard(message)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        } else if !message.images.isEmpty {
            Button {
                copyToPasteboard(message)
            } label: {
                Label("复制图片链接", systemImage: "link")
            }
        }
        if message.canEdit(viewerId: viewerId) {
            Button {
                editingMessage = message
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
        }
        if message.canRecall(viewerId: viewerId) {
            Button(role: .destructive) {
                recallTarget = message
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private func copyToPasteboard(_ message: Message) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            UIPasteboard.general.string = text
            showNotice("已复制")
            return
        }
        guard let raw = message.images.first?.dataUrl ?? message.images.first?.thumbUrl,
              let url = URL(string: raw) else { return }
        UIPasteboard.general.url = url
        showNotice("已复制图片链接")
    }

    private var recallBinding: Binding<Bool> {
        Binding(
            get: { recallTarget != nil },
            set: { presented in
                if !presented { recallTarget = nil }
            }
        )
    }

    // MARK: 屏蔽提示

    private var blockedBar: some View {
        HStack(spacing: 6) {
            LucideIcon(name: "ban", size: 13, color: Theme.danger)
            Text("该访客已被屏蔽，无法继续收发消息。")
                .font(.app(size: 12))
                .foregroundStyle(Theme.danger)
            Spacer(minLength: 0)
            Button {
                Task { await model.setBlocked(false) }
            } label: {
                Text("解除")
                    .font(.app(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.08))
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            if showsEmoji {
                EmojiPanel { emoji in
                    draft += emoji
                    model.userIsTyping(hasText: true)
                }
            }

            Divider().opacity(0.35)

            HStack(alignment: .bottom, spacing: 9) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    ZStack {
                        if isPreparingPhoto {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            LucideIcon(name: "image", size: 22, color: Theme.accent)
                        }
                    }
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
                }
                .disabled(!model.canReply || isPreparingPhoto)
                .accessibilityLabel("发送图片")

                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showsEmoji.toggle() }
                } label: {
                    LucideIcon(
                        name: "smile",
                        size: 22,
                        color: showsEmoji ? Theme.accent : Color.secondary
                    )
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canReply)
                .accessibilityLabel("表情")

                TextField("输入消息…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.app(size: 15))
                    .focused($inputFocused)
                    .disabled(!model.canReply)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .onChange(of: draft) { value in
                        // 内容变化就上报「正在输入」，2 秒无输入自动发 off。
                        model.userIsTyping(
                            hasText: !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }

                Button(action: sendText) {
                    ZStack {
                        Circle().fill(canSend ? Theme.accent : Color(uiColor: .tertiarySystemBackground))
                        LucideIcon(
                            name: "send",
                            size: 16,
                            color: canSend ? .white : Color.secondary
                        )
                        .offset(x: -0.5, y: 0.5)
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        model.canReply
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 发送

    private func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.stopTyping()
        model.send(text: text)
    }

    // MARK: 图片

    private func preparePhoto(_ item: PhotosPickerItem) async {
        isPreparingPhoto = true
        defer {
            isPreparingPhoto = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.presentError("无法读取所选图片，请换一张试试。")
                return
            }
            guard let jpeg = ImagePreparer.jpegData(from: data),
                  let image = UIImage(data: jpeg) else {
                model.presentError("图片格式不支持，请换一张 JPEG 或 PNG。")
                return
            }
            pendingJPEG = jpeg
            previewCaption = ""
            previewImage = image
        } catch {
            model.presentError("读取图片失败，请重试。")
        }
    }

    private var photoPreviewBinding: Binding<Bool> {
        Binding(
            get: { previewImage != nil },
            set: { presented in
                if !presented { closePhotoPreview() }
            }
        )
    }

    private func closePhotoPreview() {
        previewImage = nil
        pendingJPEG = nil
        previewCaption = ""
    }

    private func sendPendingPhoto() {
        guard let jpeg = pendingJPEG else {
            closePhotoPreview()
            return
        }
        let caption = previewCaption
        closePhotoPreview()
        model.sendImage(jpegData: jpeg, caption: caption)
    }

    // MARK: 提示

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertText != nil },
            set: { presented in
                if !presented { dismissAlert() }
            }
        )
    }

    private func dismissAlert() {
        alertText = nil
        model.clearActionMessage()
    }

    private func showNotice(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) { noticeText = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeOut(duration: 0.2)) { noticeText = nil }
        }
    }

    /// 顶部提示横幅。宽度跟着内容走（原来是整行，短提示会横贯全屏）。
    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 7) {
            LucideIcon(name: "circle-alert", size: 14, color: Theme.accent)
            Text(text)
                .font(.app(size: 13))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(GlassSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        // 外层只留安全边距，宽度仍然跟着内容走（不会横贯全屏）。
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }
}

// MARK: - 编辑消息

/// 编辑弹窗。保存时把裁剪后的新内容交给 ChatModel，由服务端写入 edited_at。
private struct MessageEditSheet: View {
    let original: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(original: String, onSave: @escaping (String) -> Void) {
        self.original = original
        self.onSave = onSave
        _text = State(initialValue: original)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(.app(size: 15))
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 170)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                Text("\(trimmed.utf8.count) / 16000 字节")
                    .font(.app(size: 11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.screenBackground)
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = trimmed
                        guard !value.isEmpty else { return }
                        onSave(value)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty || trimmed == original)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - 待发送消息

private struct PendingRow: View {
    let item: ChatModel.PendingMessage
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 44)

            VStack(alignment: .trailing, spacing: 3) {
                if let data = item.jpegData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 216, height: 216)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(0.75)
                }

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.app(size: 15))
                        .foregroundStyle(.white)
                        // 与正式气泡同一套内边距（10/16/10/17），发送前后不会「跳一下」。
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.bubbleOutgoing.opacity(0.75))
                        )
                }

                HStack(spacing: 4) {
                    Text(TimeFormat.clock(item.createdAt))
                        .font(.app(size: 10))
                        .foregroundStyle(.secondary)

                    switch item.state {
                    case .sending:
                        LucideIcon(name: "clock", size: 12, color: Theme.receiptSent)
                    case .failed:
                        Button(action: onRetry) {
                            HStack(spacing: 3) {
                                LucideIcon(name: "circle-alert", size: 12, color: Theme.danger)
                                Text("重发")
                                    .font(.app(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let errorText = item.errorText, item.state == .failed {
                    Text(errorText)
                        .font(.app(size: 10))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: 282, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if item.state == .failed {
                Button("重新发送", action: onRetry)
            }
            Button("删除这条未发送的消息", role: .destructive, action: onDiscard)
        }
    }
}

// MARK: - 表情面板

private struct EmojiPanel: View {
    let onPick: (String) -> Void

    private let emojis = [
        "😀", "😄", "😁", "😊", "🙂", "😉", "😍", "😘",
        "😜", "🤔", "😅", "😂", "😢", "😭", "😡", "🥺",
        "👍", "👎", "👌", "🙏", "👏", "💪", "🤝", "🫡",
        "🎉", "🔥", "❤️", "💔", "✅", "❌", "⭐", "🌹",
        "☕", "🍀", "📎", "📷", "🚀", "💡", "⏰", "📌",
        "🙈", "😴", "😷", "🤗", "😎", "🥳", "🤯", "😇"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 8)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.app(size: 23))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 172)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

// MARK: - 发送图片前的预览

private struct PhotoSendPreview: View {
    let image: UIImage
    @Binding var caption: String
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)

                TextField("给图片加一句说明（可留空）", text: $caption, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.app(size: 15))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemBackground))
                    )
                    .padding(.horizontal, 16)

                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .background(Theme.screenBackground)
            .navigationTitle("发送图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送", action: onSend)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 全屏图片

private struct ImageTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// 全屏看图。
///
/// 三个必须守住的点：
/// 1. **大图不能超出屏幕**：用 `GeometryReader` 拿到真实可用尺寸，再显式
///    `.frame(width:height:)` 给图片，最后 `.clipped()`。只写 `scaledToFit()`
///    时，`AsyncImage` 拿到的建议尺寸可能是 nil，大图会按原始像素铺开、直接顶出屏幕。
/// 2. **可以缩放**：捏合 1~5 倍，双击在 1 倍 / 2.5 倍之间切换，放大后可拖动查看。
/// 3. **关闭按钮永远看得见**：作为 ZStack 最后一个兄弟节点叠在图片之上；
///    背景用「毛玻璃 + 半透明黑 + 白色描边」，压在任何图片上都清晰。
private struct ImageFullScreen: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    private let doubleTapScale: CGFloat = 2.5

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                let size = proxy.size

                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            // 关键：把图片框死在可用区域内，大图才会被缩到屏幕里。
                            .frame(width: size.width, height: size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .contentShape(Rectangle())
                            .gesture(magnification(size: size))
                            .simultaneousGesture(pan(size: size))
                            .onTapGesture(count: 2) { toggleZoom() }
                    case .failure:
                        VStack(spacing: 10) {
                            LucideIcon(name: "image", size: 34, color: .white.opacity(0.6))
                            Text("图片加载失败")
                                .font(.app(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(width: size.width, height: size.height)
                    default:
                        ProgressView()
                            .tint(.white)
                            .frame(width: size.width, height: size.height)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            // 缩放/拖动后也不会画到屏幕外。
            .clipped()

            // 关闭按钮是 ZStack 的最后一个兄弟节点：一定画在图片上面，
            // 而且和原来的位置一致（右上角，安全区内）。
            HStack {
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// 关闭按钮。
    ///
    /// 和原来相比只改视觉，位置与热区都不动：
    /// - 去掉 `strokeBorder` 白色描边（在大图上显得脏）
    /// - 去掉 `ultraThinMaterial` 毛玻璃（原本发灰、和图片混在一起）
    /// - 底色改成 **60% 透明度的纯黑**
    /// - `x` 图标放大（16 → 21），**圆底直径不变**（仍 38）
    private var closeButton: some View {
        Button(action: onClose) {
            ZStack {
                Circle().fill(Color.black.opacity(0.6))
                LucideIcon(name: "x", size: 21, color: .white)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }

    // MARK: 手势

    private func magnification(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(minScale, baseScale * value), maxScale)
            }
            .onEnded { _ in
                baseScale = scale
                // 缩回 1 倍时顺手把位移归零，避免图片停在偏心的位置。
                if scale <= minScale {
                    offset = .zero
                    baseOffset = .zero
                } else {
                    offset = clamped(offset, size: size, scale: scale)
                    baseOffset = offset
                }
            }
    }

    private func pan(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > minScale else { return }
                offset = clamped(
                    CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    ),
                    size: size,
                    scale: scale
                )
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func toggleZoom() {
        let target = scale > minScale ? minScale : doubleTapScale
        withAnimation(.easeOut(duration: 0.2)) {
            scale = target
            baseScale = target
            offset = .zero
            baseOffset = .zero
        }
    }

    /// 位移上限 = 放大后多出来的那一半，保证不会把图片拖到只剩黑边。
    private func clamped(_ value: CGSize, size: CGSize, scale: CGFloat) -> CGSize {
        let limitX = max(0, (size.width * scale - size.width) / 2)
        let limitY = max(0, (size.height * scale - size.height) / 2)
        return CGSize(
            width: min(max(value.width, -limitX), limitX),
            height: min(max(value.height, -limitY), limitY)
        )
    }
}
