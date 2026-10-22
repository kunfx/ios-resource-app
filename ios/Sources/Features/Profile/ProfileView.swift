import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var showLogin = false
    @State private var showServerSetting = false
    @State private var serverDraft = AppConfig.baseURLString

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if session.isLoggedIn {
                        userCard
                        statsCard
                    } else {
                        guestCard
                    }

                    menuCard
                    aboutCard
                }
                .padding(.vertical, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await session.refreshProfile(silent: true)
            }
            .task {
                await session.refreshProfile(silent: true)
            }
            .sheet(isPresented: $showLogin) {
                LoginView().environmentObject(session)
            }
            .sheet(isPresented: $showServerSetting) {
                serverSheet
            }
            .navigationDestination(for: AppItem.self) { item in
                AppDetailView(appID: item.id)
            }
        }
    }

    // MARK: - 已登录

    private var userCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                RemoteImage(urlString: session.user?.avatar, placeholderIcon: "person.fill")
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 2))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(session.user?.name ?? "用户")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let user = session.user, user.isVip {
                            VipBadge(level: user.vipLevel, label: user.vipLabel)
                        }
                    }

                    Text(session.user?.email ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)

                    if let user = session.user, user.isVip {
                        Text("有效期：\(user.vipExpiredText ?? "-")")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                headerStat(title: "积分", value: "\(session.user?.points ?? 0)")
                headerDivider
                headerStat(title: "今日免费额度",
                           value: quotaText)
                headerDivider
                headerStat(title: "累计下载", value: "\(session.stats?.downloadsTotal ?? 0)")
            }
        }
        .padding(18)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var quotaText: String {
        guard let stats = session.stats else { return "-" }
        if stats.isUnlimited { return "不限" }
        return "\(max(0, stats.freeLeft)) / \(stats.freeLimit)"
    }

    private func headerStat(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(width: 1, height: 26)
    }

    private var statsCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text("会员状态与积分均由服务器校验，App 只做展示")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
            }
        }
        .cardStyle(padding: 12)
        .padding(.horizontal, 16)
    }

    // MARK: - 未登录

    private var guestCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 70, height: 70)
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.accent)
            }

            Text("还没有登录")
                .font(.system(size: 16, weight: .semibold))

            Text("登录后可查看积分、会员状态、下载记录与站内消息")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            Button("立即登录") {
                showLogin = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
        .cardStyle(padding: 20)
        .padding(.horizontal, 16)
    }

    // MARK: - 菜单

    private var menuCard: some View {
        VStack(spacing: 0) {
            if session.isLoggedIn {
                NavigationLink {
                    MessagesView()
                } label: {
                    menuRow(icon: "bell.badge.fill", title: "站内消息",
                            value: unreadText, tint: .orange)
                }
                .buttonStyle(.plain)

                rowDivider

                NavigationLink {
                    PointsLogView()
                } label: {
                    menuRow(icon: "creditcard.fill", title: "积分明细", value: nil, tint: Theme.accentSoft)
                }
                .buttonStyle(.plain)

                rowDivider
            }

            NavigationLink {
                ArticlesView()
            } label: {
                menuRow(icon: "book.fill", title: "教程文章", value: nil, tint: .purple)
            }
            .buttonStyle(.plain)

            rowDivider

            Button {
                serverDraft = AppConfig.baseURLString
                showServerSetting = true
            } label: {
                menuRow(icon: "server.rack", title: "服务器地址",
                        value: AppConfig.normalizedBaseURLString, tint: .gray)
            }
            .buttonStyle(.plain)

            if session.isLoggedIn {
                rowDivider

                Button {
                    Task { await session.logout() }
                } label: {
                    menuRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录",
                            value: nil, tint: .red)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle(padding: 0, radius: 18)
        .padding(.horizontal, 16)
    }

    private var unreadText: String? {
        guard let count = session.stats?.unreadMessages, count > 0 else { return nil }
        return "\(count) 条未读"
    }

    private func menuRow(icon: String, title: String, value: String?, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)

            Spacer()

            if let value = value {
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 54)
    }

    private var aboutCard: some View {
        VStack(spacing: 6) {
            Text("\(AppConfig.appName) for iOS · 1.0.0")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            Text("数据来自 \(AppConfig.normalizedBaseURLString)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - 服务器设置

    private var serverSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("站点根地址")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)

                TextField("https://your-domain.com", text: $serverDraft)
                    .font(.system(size: 14))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("修改后会自动退出登录，请用同一套网站账号重新登录。接口地址形如 \(AppConfig.normalizedBaseURLString)/api/apps。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)

                Button("保存并重新登录") {
                    AppConfig.baseURLString = serverDraft
                    session.resetForNewServer()
                    showServerSetting = false
                    showLogin = true
                }
                .buttonStyle(PrimaryButtonStyle())

                Spacer()
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("服务器地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showServerSetting = false }
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}
