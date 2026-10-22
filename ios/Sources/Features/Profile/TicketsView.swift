import SwiftUI

struct TicketsView: View {
    @State private var items: [Ticket] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var lastPage = 1
    @State private var showNew = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if isLoading {
                    LoadingView(text: "加载反馈记录")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load(reset: true) }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "bubble.left.and.bubble.right",
                                   title: "还没有提交过问题",
                                   message: "遇到资源失效、账号或充值问题，可以在这里反馈")
                } else {
                    ForEach(items) { ticket in
                        NavigationLink {
                            TicketDetailView(ticketID: ticket.id, title: ticket.title)
                        } label: {
                            card(ticket)
                        }
                        .buttonStyle(.plain)
                        .task {
                            if ticket.id == items.last?.id {
                                await load(reset: false)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("问题反馈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showNew) {
            NewTicketView { await load(reset: true) }
        }
        .refreshable { await load(reset: true) }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
    }

    private func card(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(ticket.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)

                Spacer(minLength: 6)

                Text(ticket.statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor(ticket.status))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(statusColor(ticket.status).opacity(0.12)))
            }

            if let preview = ticket.preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(ticket.ticketNo)
                Spacer()
                Text(DateText.relative(ticket.lastReplyAt ?? ticket.createdAt))
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 1: return Theme.accent
        case 2: return Theme.secondaryText
        default: return .orange
        }
    }

    private func load(reset: Bool) async {
        if reset {
            page = 1
            isLoading = items.isEmpty
        } else {
            guard page < lastPage else { return }
        }

        let target = reset ? 1 : page + 1

        do {
            let result: Page<Ticket> = try await APIClient.shared.get("/api/tickets", query: [
                "page": "\(target)",
                "per_page": "20"
            ])

            lastPage = result.lastPage

            if reset {
                items = result.items
                page = 1
            } else {
                items.append(contentsOf: result.items)
                page = target
            }

            errorMessage = nil
        } catch {
            if reset { errorMessage = error.readableMessage }
        }

        isLoading = false
    }
}

// MARK: - 新建反馈

private struct TicketCategoryOption: Identifiable {
    let id: String
    let title: String
}

struct NewTicketView: View {
    var onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category = "resource"
    @State private var message = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let categories = [
        TicketCategoryOption(id: "resource", title: "资源失效"),
        TicketCategoryOption(id: "account", title: "账号问题"),
        TicketCategoryOption(id: "payment", title: "充值 / 订单"),
        TicketCategoryOption(id: "other", title: "其他")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标题")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)

                        TextField("一句话描述问题", text: $title)
                            .font(.system(size: 15))
                    }
                    .padding(12)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("类型")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)

                        Picker("类型", selection: $category) {
                            ForEach(categories) { item in
                                Text(item.title).tag(item.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(12)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("问题描述")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)

                        TextField("尽量写清楚资源名称、报错信息和操作步骤", text: $message, axis: .vertical)
                            .font(.system(size: 15))
                            .lineLimit(5...10)
                    }
                    .padding(12)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 6) {
                            if isSubmitting { ProgressView().tint(.white) }
                            Text(isSubmitting ? "提交中…" : "提交反馈")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: canSubmit && !isSubmitting))
                    .disabled(!canSubmit || isSubmitting)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("新建反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var canSubmit: Bool {
        title.trimmingCharacters(in: .whitespaces).count >= 2 &&
        message.trimmingCharacters(in: .whitespaces).count >= 4
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil

        do {
            let _: CreatedTicket = try await APIClient.shared.post("/api/tickets", body: [
                "title": title.trimmingCharacters(in: .whitespaces),
                "category": category,
                "message": message.trimmingCharacters(in: .whitespaces)
            ])

            await onCreated()
            dismiss()
        } catch {
            errorMessage = error.readableMessage
        }

        isSubmitting = false
    }
}

// MARK: - 反馈详情

struct TicketDetailView: View {
    let ticketID: Int
    let title: String

    @State private var ticket: Ticket?
    @State private var messages: [TicketMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if isLoading {
                    LoadingView()
                } else if let message = errorMessage {
                    ErrorStateView(message: message) {
                        Task { await load() }
                    }
                } else {
                    ForEach(messages) { item in
                        bubble(item)
                    }

                    if let ticket = ticket, ticket.status == 2 {
                        Text("该反馈已关闭")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("反馈详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func bubble(_ item: TicketMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !item.isAdmin { Spacer(minLength: 40) }

            VStack(alignment: item.isAdmin ? .leading : .trailing, spacing: 4) {
                Text(item.isAdmin ? "客服" : "我")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)

                Text(item.message)
                    .font(.system(size: 13))
                    .foregroundStyle(item.isAdmin ? Color.primary : Color.white)
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(item.isAdmin ? Theme.card : Theme.accent)
                    )
                    .fixedSize(horizontal: false, vertical: true)

                Text(DateText.relative(item.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }

            if item.isAdmin { Spacer(minLength: 40) }
        }
    }

    private func load() async {
        isLoading = messages.isEmpty

        do {
            let payload: TicketDetailPayload = try await APIClient.shared.get("/api/tickets/\(ticketID)")
            ticket = payload.ticket
            messages = payload.messages
            errorMessage = nil
        } catch {
            errorMessage = error.readableMessage
        }

        isLoading = false
    }
}
