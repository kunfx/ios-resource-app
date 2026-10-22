import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var showServerSetting = false
    @State private var serverDraft = AppConfig.baseURLString

    var body: some View {
        NavigationStack {
            Group {
                if session.isLoggedIn {
                    account
                } else {
                    LoginView(embedded: true)
                }
            }
            .background(Theme.background)
            .navigationTitle(session.isLoggedIn ? "我的" : "登录")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await session.refreshProfile(silent: true)
            }
            .task {
                await session.refreshProfile(silent: true)
            }
            .sheet(isPresented: $showServerSetting) {
                serverSheet
            }
        }
    }

    // MARK: - 已登录

    private var account: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                menuCard
                moreCard
                footer
            }
            .padding(.vertical, 12)
            .padding(.bottom, 20)
        }
    }

    private var headerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                RemoteImage(urlString: session.user?.avatar, placeholderIcon: "person.fill")
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 2))

                VStack(alignment: .leading, spacing: 5) {
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

                    Text(session.user?.isVip == true
                         ? "有效期至 \(session.user?.vipExpiredText ?? "-")"
                         : "普通用户")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                headerStat(title: "积分", value: "\(session.user?.points ?? 0)")
                headerDivider
                headerStat(title: "今日免费额度", value: quotaText)
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

    // MARK: - 与网站 /user 面板一致的菜单

    private var menuCard: some View {
        VStack(spacing: 0) {
            menuLink(icon: "bell.badge.fill", title: "站内消息",
                     value: unreadText, tint: .orange) {
                MessagesView()
            }

            rowDivider

            menuLink(icon: "person.text.rectangle.fill", title: "个人中心",
                     value: nil, tint: Theme.accent) {
                ProfileDetailView()
            }

            rowDivider

            menuLink(icon: "square.and.pencil", title: "修改资料",
                     value: nil, tint: .blue) {
                ProfileEditView()
            }

            rowDivider

            menuLink(icon: "arrow.down.doc.fill", title: "下载记录",
                     value: nil, tint: Theme.accentSoft) {
                DownloadHistoryView()
            }

            rowDivider

            menuLink(icon: "seal.fill", title: "签名证书",
                     value: nil, tint: .purple) {
                ShopGoodsView()
            }

            rowDivider

            menuLink(icon: "star.fill", title: "升级会员",
                     value: nil, tint: Theme.vipGold) {
                VipPackagesView()
            }

            rowDivider

            menuLink(icon: "creditcard.fill", title: "我的积分",
                     value: "\(session.user?.points ?? 0)", tint: .green) {
                PointsLogView()
            }

            rowDivider

            menuLink(icon: "gift.fill", title: "赚取积分",
                     value: nil, tint: .pink) {
                EarnPointsView()
            }

            rowDivider

            menuLink(icon: "bag.fill", title: "我的订单",
                     value: nil, tint: .indigo) {
                OrdersView()
            }

            rowDivider

            menuLink(icon: "bubble.left.and.bubble.right.fill", title: "问题反馈",
                     value: nil, tint: .teal) {
                TicketsView()
            }
        }
        .cardStyle(padding: 0, radius: 18)
        .padding(.horizontal, 16)
    }

    private var moreCard: some View {
        VStack(spacing: 0) {
            menuLink(icon: "book.fill", title: "教程文章", value: nil, tint: .brown) {
                ArticlesView()
            }

            rowDivider

            Button {
                serverDraft = AppConfig.baseURLString
                showServerSetting = true
            } label: {
                menuRow(icon: "server.rack", title: "服务器地址",
                        value: AppConfig.normalizedBaseURLString, tint: .gray)
            }
            .buttonStyle(.plain)

            rowDivider

            Button {
                Task { await session.logout() }
            } label: {
                menuRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录",
                        value: nil, tint: .red)
            }
            .buttonStyle(.plain)
        }
        .cardStyle(padding: 0, radius: 18)
        .padding(.horizontal, 16)
    }

    private var unreadText: String? {
        guard let count = session.stats?.unreadMessages, count > 0 else { return nil }
        return "\(count) 条未读"
    }

    private func menuLink<Destination: View>(icon: String, title: String, value: String?,
                                             tint: Color,
                                             @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            menuRow(icon: icon, title: title, value: value, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func menuRow(icon: String, title: String, value: String?, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
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

    private var footer: some View {
        VStack(spacing: 5) {
            Text("\(AppConfig.appName) for iOS · 1.0.0")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            Text("数据来自 \(AppConfig.normalizedBaseURLString)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
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

                Text("修改后会自动退出登录，请用同一套网站账号重新登录。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)

                Button("保存并重新登录") {
                    AppConfig.baseURLString = serverDraft
                    session.resetForNewServer()
                    showServerSetting = false
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
        .presentationDetents([.height(300)])
    }
}
