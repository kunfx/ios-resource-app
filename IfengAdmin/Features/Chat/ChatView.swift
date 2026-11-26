import SwiftUI
import UIKit
import PhotosUI
import Photos
import Combine

struct ChatView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ChatModel

    @State private var draft = ""
    @State private var showInfo = false
    @State private var showEmojiPanel = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isPreparingImage = false
    @State private var previewImage: ImagePreviewItem?
    @State private var atBottom = true
    @FocusState private var inputFocused: Bool

    private let emojis = [
        "😀", "😄", "😊", "🙂", "😉", "😍", "🤔", "😅",
        "😂", "🥲", "😭", "😴", "😎", "🙏", "👍", "👌",
        "👏", "🤝", "💪", "🎉", "❤️", "🔥", "✅", "❗",
        "📦", "💰", "🕐", "📷", "📎", "🚚", "⭐", "🌹"
    ]

    init(session: AppSession, conversationId: Int, seed: Conversation? = nil) {
        _model = StateObject(wrappedValue: ChatModel(session: session, conversationId: conversationId, seed: seed))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            messagesArea
            composer
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await model.start()
        }
        .onReceive(app.events) { event in
            Task { await model.handle(event: event) }
        }
        .onChange(of: model.isLoading) { loading in
            if !loading { atBottom = true }
        }
        .onChange(of: photoItem) { value in
            guard value != nil else { return }
            Task { await handleSelectedPhoto() }
        }
        .onChange(of: model.actionError) { value in
            if value != nil { inputFocused = false }
        }
        .sheet(isPresented: $showInfo) {
            VisitorInfoView(model: model)
        }
        .sheet(item: $previewImage) { item in
            ImagePreviewSheet(item: item)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.actionError != nil && !showInfo },
            set: { newValue in if !newValue { model.clearActionMessage() } }
        )) {
            Button("知道了", role: .cancel) { model.clearActionMessage() }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    // MARK: 顶部导航

    private var header: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "chevron.left", size: 34, iconSize: 15) {
                dismiss()
            }

            InitialsAvatar(name: model.conversation.visitorName, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.conversation.visitorName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let source = sourceText {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                            .font(.system(size: 9, weight: .medium))
                        Text(source)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            CircleIconButton(systemName: "info", size: 34, iconSize: 16) {
                showInfo = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var sourceText: String? {
        if let url = model.conversation.visitorDetails?.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            return "来自 \(url)"
        }
        return nil
    }

    // MARK: 消息区

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.hasMoreOlder {
                        Button {
                            loadOlder(proxy: proxy)
                        } label: {
                            HStack(spacing: 5) {
                                if model.isLoadingOlder {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text(model.isLoadingOlder ? "加载中…" : "加载更早消息")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingOlder)
                    }

                    if model.isLoading && model.messages.isEmpty {
                        ProgressView()
                            .padding(.top, 40)
                    } else if let loadError = model.loadError, model.messages.isEmpty {
                        VStack(spacing: 10) {
                            Text(loadError)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("重试") {
                                Task { await model.loadAll() }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 40)
                    }

                    ForEach(chatRows) { row in
                        switch row.kind {
                        case .day(let label):
                            Text(label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                                .padding(.vertical, 8)
                        case .message(let message, let showsHeader):
                            MessageRow(
                                message: message,
                                showsHeader: showsHeader,
                                onTapImage: { attachment in
                                    previewImage = ImagePreviewItem(
                                        fullURL: URL(string: attachment.dataUrl ?? ""),
                                        thumbURL: URL(string: attachment.thumbUrl ?? "")
                                    )
                                }
                            )
                            .id("m-\(message.id)")
                        }
                    }

                    ForEach(model.pending) { item in
                        PendingMessageRow(
                            item: item,
                            onRetry: { Task { await model.retry(pendingId: item.id) } },
                            onDiscard: { model.discard(pendingId: item.id) }
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _ in
                if atBottom || model.justSent {
                    scrollToBottom(proxy)
                    model.justSent = false
                }
            }
            .onChange(of: model.pending.count) { _ in
                if model.justSent { scrollToBottom(proxy) }
            }
            .onChange(of: model.isLoading) { loading in
                if !loading && atBottom { scrollToBottom(proxy, animated: false) }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    inputFocused = false
                    showEmojiPanel = false
                }
            )
        }
    }

    private var chatRows: [ChatRow] {
        var rows: [ChatRow] = []
        var lastDay = ""
        for (index, message) in model.messages.enumerated() {
            let day = TimeFormat.daySeparator(message.createdAt)
            if day != lastDay {
                rows.append(ChatRow(id: "day-\(day)-\(message.id)", kind: .day(day)))
                lastDay = day
            }
            let previous = index > 0 ? model.messages[index - 1] : nil
            var showsHeader = true
            if let previous {
                let gap = (message.createdAt ?? 0) - (previous.createdAt ?? 0)
                showsHeader = previous.type != message.type
                    || previous.isPrivateNote != message.isPrivateNote
                    || !TimeFormat.isSameDay(previous.createdAt, message.createdAt)
                    || gap > 300
            }
            rows.append(ChatRow(id: "message-\(message.id)", kind: .message(message, showsHeader)))
        }
        return rows
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func loadOlder(proxy: ScrollViewProxy) {
        let anchor = model.messages.first?.id
        Task {
            await model.loadOlder()
            if let anchor {
                proxy.scrollTo("m-\(anchor)", anchor: .top)
            }
        }
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            if !model.canReply {
                Text("当前渠道不支持回复")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    Text("图片")
                        .font(.system(size: 13))
                        .foregroundStyle(model.canReply ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .disabled(!model.canReply || isPreparingImage)

                Button {
                    showEmojiPanel.toggle()
                    if showEmojiPanel { inputFocused = false }
                } label: {
                    Text("表情")
                        .font(.system(size: 13))
                        .foregroundStyle(model.canReply ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .disabled(!model.canReply)

                HStack(spacing: 6) {
                    TextField("输入消息", text: $draft, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(1...5)
                        .focused($inputFocused)
                        .disabled(!model.canReply)
                        .onTapGesture { showEmojiPanel = false }
                    if isPreparingImage {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))

                Button(action: sendCurrentDraft) {
                    Text("发送")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 4)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if showEmojiPanel {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button {
                                draft += emoji
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 22))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .frame(height: 132)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isSending
            && model.canReply
    }

    private func sendCurrentDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        model.send(text: text)
    }

    private func handleSelectedPhoto() async {
        guard let item = photoItem else { return }
        isPreparingImage = true
        defer {
            isPreparingImage = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.presentError("无法读取所选图片，请重新选择。")
                return
            }
            guard let jpeg = ImagePreparer.jpegData(from: data) else {
                model.presentError("无法处理这张图片，请选择 JPG / PNG 图片。")
                return
            }
            let caption = draft
            draft = ""
            model.sendImage(jpegData: jpeg, caption: caption)
        } catch {
            model.presentError("读取相册图片失败，请重试。")
        }
    }
}

// MARK: - 行模型

struct ChatRow: Identifiable {
    enum Kind {
        case day(String)
        case message(Message, Bool)
    }
    let id: String
    let kind: Kind
}

struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let fullURL: URL?
    let thumbURL: URL?
}

// MARK: - 图片预览

struct ImagePreviewSheet: View {
    let item: ImagePreviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: item.fullURL ?? item.thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                        Text("图片加载失败或链接已过期")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                default:
                    ProgressView().tint(.white)
                }
            }
            .padding(.horizontal, 8)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}
