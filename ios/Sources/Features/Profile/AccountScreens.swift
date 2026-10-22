import SwiftUI
import UIKit

// MARK: - 个人中心

struct ProfileDetailView: View {
    @EnvironmentObject private var session: SessionStore

    private var user: User? { session.user }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                identityCard
                accountCard
                usageCard
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("个人中心")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.refreshProfile(silent: true) }
        .task { await session.refreshProfile(silent: true) }
    }

    private var identityCard: some View {
        VStack(spacing: 10) {
            RemoteImage(urlString: user?.avatar, placeholderIcon: "person.fill")
                .frame(width: 76, height: 76)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 2))

            Text(user?.name ?? "-")
                .font(.system(size: 17, weight: .bold))

            if let user = user, user.isVip {
                VipBadge(level: user.vipLevel, label: user.vipLabel)
            } else {
                PillTag(text: "免费用户", color: Theme.secondaryText)
            }

            Text(user?.email ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var accountCard: some View {
        VStack(spacing: 0) {
            infoRow("用户 ID", "\(user?.id ?? 0)")
            rowDivider
            infoRow("注册时间", DateText.day(user?.createdAt))
            rowDivider
            infoRow("会员状态", user?.isVip == true ? user?.vipLabel ?? "-" : "非会员")
            rowDivider
            infoRow("到期时间", user?.isVip == true ? (user?.vipExpiredText ?? "-") : "-")
            rowDivider
            infoRow("账号角色", user?.isAdmin == true ? "管理员" : "普通用户")
        }
        .cardStyle(padding: 0, radius: 16)
    }

    private var usageCard: some View {
        VStack(spacing: 0) {
            infoRow("当前积分", "\(user?.points ?? 0)")
            rowDivider
            infoRow("今日免费额度", quotaText)
            rowDivider
            infoRow("累计下载", "\(session.stats?.downloadsTotal ?? 0) 次")
            rowDivider
            infoRow("未读消息", "\(session.stats?.unreadMessages ?? 0) 条")
        }
        .cardStyle(padding: 0, radius: 16)
    }

    private var quotaText: String {
        guard let stats = session.stats else { return "-" }
        if stats.isUnlimited { return "不限（会员）" }
        return "\(max(0, stats.freeLeft)) / \(stats.freeLimit)"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }
}

// MARK: - 修改资料

struct ProfileEditView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var isError = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    field(title: "昵称") {
                        TextField("输入昵称", text: $name)
                    }

                    field(title: "邮箱（不可修改）") {
                        Text(session.user?.email ?? "-")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .cardStyle()

                VStack(spacing: 12) {
                    field(title: "新密码（不改留空）") {
                        SecureField("至少 6 位", text: $password)
                    }

                    field(title: "确认新密码") {
                        SecureField("再次输入", text: $confirmPassword)
                    }
                }
                .cardStyle()

                if let message = message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(isError ? .red : Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "保存中…" : "保存")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

                Text("昵称不能包含「管理员」「官方」「客服」等敏感词；密码至少 6 位。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("修改资料")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                name = session.user?.name ?? ""
                loaded = true
            }
        }
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)

            content()
                .font(.system(size: 15))
        }
        .padding(12)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        if !password.isEmpty && password != confirmPassword {
            isError = true
            message = "两次输入的密码不一致"
            return
        }

        isSaving = true
        isError = false
        message = nil

        var payload: [String: Any] = ["name": trimmed]

        if !password.isEmpty {
            payload["password"] = password
            payload["password_confirmation"] = confirmPassword
        }

        do {
            let user: User = try await APIClient.shared.post("/api/user/profile/update", body: payload)
            isError = false
            message = "已保存：\(user.name)"
            password = ""
            confirmPassword = ""
            await session.refreshProfile(silent: true)
        } catch {
            isError = true
            message = error.readableMessage
        }

        isSaving = false
    }
}

// MARK: - 下载记录

struct DownloadHistoryView: View {
    @State private var items: [DownloadRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var lastPage = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    LoadingView(text: "加载下载记录")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load(reset: true) }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "arrow.down.doc", title: "还没有下载记录")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { record in
                            NavigationLink {
                                AppDetailView(appID: record.appId)
                            } label: {
                                row(record)
                            }
                            .buttonStyle(.plain)
                            .task {
                                if record.id == items.last?.id {
                                    await load(reset: false)
                                }
                            }

                            Divider().padding(.leading, 76)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Theme.background)
        .navigationTitle("下载记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(reset: true) }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(spacing: 12) {
            AppIconView(urlString: record.appIcon, size: 48, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let version = record.appVersion { Text("v\(version)") }
                    if let size = record.appSize { Text(size) }
                    Text(record.pointsSpent > 0 ? "消耗 \(record.pointsSpent) 积分" : "免费额度")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(DateText.relative(record.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
            let result: Page<DownloadRecord> = try await APIClient.shared.get("/api/downloads", query: [
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

// MARK: - 赚取积分（签到 / 邀请）

struct EarnPointsView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var status: SignInStatus?
    @State private var isLoading = true
    @State private var isSigning = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if isLoading {
                    LoadingView(text: "加载签到信息")
                } else if let status = status {
                    signCard(status)
                    ruleCard(status)

                    if status.inviteEnabled {
                        inviteCard(status)
                    }
                } else {
                    EmptyStateView(icon: "gift", title: "签到信息加载失败")
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("赚取积分")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func signCard(_ status: SignInStatus) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                statBlock(title: "连续签到", value: "\(status.continuousDays) 天")
                statBlock(title: "累计签到", value: "\(status.totalDays) 天")
                statBlock(title: "签到总收益", value: "\(status.totalPoints)")
            }

            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 6) {
                    if isSigning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: status.signedToday ? "checkmark.circle.fill" : "calendar.badge.plus")
                    }
                    Text(status.signedToday ? "今日已签到" : "立即签到")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !status.signedToday && !isSigning))
            .disabled(status.signedToday || isSigning)

            if let message = message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(isError ? .red : Theme.accent)
            }
        }
        .cardStyle()
    }

    private func ruleCard(_ status: SignInStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("积分规则")
                .font(.system(size: 14, weight: .bold))

            ruleLine("每日签到", "+\(status.signPoints) 积分")

            if status.bonusDays > 0 && status.bonusPoints > 0 {
                ruleLine("连续签到 \(status.bonusDays) 天", "额外 +\(status.bonusPoints) 积分")
            }

            if status.inviteEnabled {
                ruleLine("邀请好友注册", "每人 +\(status.inviteRewardPoints) 积分")
            }

            Text("积分可用于下载付费资源、兑换会员套餐，具体以服务端校验为准。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func inviteCard(_ status: SignInStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("邀请好友")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text("已邀请 \(status.inviteCount) 人")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }

            Text(status.inviteLink)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                UIPasteboard.general.string = status.inviteLink
                message = "邀请链接已复制"
                isError = false
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                    Text("复制邀请链接")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private func ruleLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    private func load() async {
        isLoading = status == nil

        do {
            let result: SignInStatus = try await APIClient.shared.get("/api/sign-in/status")
            status = result
        } catch {
            // 保持已有数据，失败时页面显示空状态
        }

        isLoading = false
    }

    private func signIn() async {
        isSigning = true
        message = nil

        do {
            let result: SignInResult = try await APIClient.shared.post("/api/sign-in")
            isError = false
            message = "签到成功 +\(result.pointsGained) 积分，已连续 \(result.continuousDays) 天"
            await session.refreshProfile(silent: true)
            await load()
        } catch {
            isError = true
            message = error.readableMessage
        }

        isSigning = false
    }
}
