import SwiftUI

// MARK: - 签名证书

struct ShopGoodsView: View {
    @State private var items: [ShopGood] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if isLoading {
                    LoadingView(text: "加载证书商品")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load() }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "seal", title: "暂时没有上架的证书")
                } else {
                    ForEach(items) { good in
                        card(good)
                    }

                    WebHint(path: "/certificates", text: "证书商品有实际成本，需在线支付，请在网页端完成购买")
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("签名证书")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if items.isEmpty { await load() }
        }
    }

    private func card(_ good: ShopGood) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(good.name)
                        .font(.system(size: 15, weight: .semibold))

                    if let summary = good.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("¥\(String(format: "%.2f", good.price))")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)

                    Text(good.stock > 0 ? "库存 \(good.stock)" : "暂时缺货")
                        .font(.system(size: 10))
                        .foregroundStyle(good.stock > 0 ? Theme.tertiaryText : .red)
                }
            }

            if let description = good.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(4)
            }

            if good.giftPoints > 0 {
                PillTag(text: "赠送 \(good.giftPoints) 积分", color: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func load() async {
        isLoading = items.isEmpty

        do {
            let result: [ShopGood] = try await APIClient.shared.get("/api/shop/goods")
            items = result
            errorMessage = nil
        } catch {
            errorMessage = error.readableMessage
        }

        isLoading = false
    }
}

// MARK: - 升级会员

struct VipPackagesView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var items: [VipPackage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                currentCard

                if isLoading {
                    LoadingView(text: "加载会员套餐")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load() }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "star", title: "暂时没有可购买的套餐")
                } else {
                    ForEach(items) { package in
                        card(package)
                    }

                    WebHint(path: "/user/upgrade-vip", text: "会员支持积分兑换或在线支付，请在网页端完成")
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("升级会员")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
            await session.refreshProfile(silent: true)
        }
        .task {
            if items.isEmpty { await load() }
        }
    }

    private var currentCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.vipGold)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.vipGold.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.user?.isVip == true ? (session.user?.vipLabel ?? "会员") : "当前未开通会员")
                    .font(.system(size: 14, weight: .semibold))

                Text(session.user?.isVip == true
                     ? "有效期至 \(session.user?.vipExpiredText ?? "-")"
                     : "开通后付费资源免费下载，且不受每日免费次数限制")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    private func card(_ package: VipPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(package.name)
                        .font(.system(size: 15, weight: .semibold))

                    Text(package.vipDays > 0 ? "\(package.vipDays) 天 · 等级 \(package.vipLevel)" : "永久有效 · 等级 \(package.vipLevel)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }

                Spacer(minLength: 0)

                Text("¥\(String(format: "%.2f", package.price))")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.vipGold)
            }

            if let summary = package.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            if package.pricePoints > 0 {
                PillTag(text: "或 \(package.pricePoints) 积分兑换", color: Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func load() async {
        isLoading = items.isEmpty

        do {
            let result: [VipPackage] = try await APIClient.shared.get("/api/vip/packages")
            items = result
            errorMessage = nil
        } catch {
            errorMessage = error.readableMessage
        }

        isLoading = false
    }
}

// MARK: - 我的订单

private struct OrderKindOption: Identifiable {
    let id: String
    let title: String
}

struct OrdersView: View {
    @State private var kind = "shop"
    @State private var items: [OrderItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let kinds = [
        OrderKindOption(id: "shop", title: "证书"),
        OrderKindOption(id: "vip", title: "会员"),
        OrderKindOption(id: "recharge", title: "充值")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $kind) {
                ForEach(kinds) { item in
                    Text(item.title).tag(item.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 10) {
                    if isLoading {
                        LoadingView(text: "加载订单")
                    } else if let message = errorMessage, items.isEmpty {
                        ErrorStateView(message: message) {
                            Task { await load() }
                        }
                    } else if items.isEmpty {
                        EmptyStateView(icon: "bag", title: "还没有相关订单")
                    } else {
                        ForEach(items) { order in
                            card(order)
                        }

                        WebHint(path: "/user/my-orders", text: "订单详情与售后请在网页端处理")
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
        }
        .background(Theme.background)
        .navigationTitle("我的订单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: kind) { _ in
            Task { await load() }
        }
    }

    private func card(_ order: OrderItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(order.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)

                Spacer(minLength: 6)

                Text(order.statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(order.isFinished ? Theme.accent : .orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((order.isFinished ? Theme.accent : Color.orange).opacity(0.12)))
            }

            if let subtitle = order.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if order.amount > 0 {
                    Text("¥\(String(format: "%.2f", order.amount))")
                        .foregroundStyle(Theme.accent)
                }
                if order.points > 0 {
                    Text("\(order.points) 积分")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(DateText.relative(order.createdAt))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 11))

            Text(order.orderNo)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    private func load() async {
        isLoading = items.isEmpty

        do {
            let result: OrdersPayload = try await APIClient.shared.get("/api/orders", query: ["type": kind])
            items = result.items
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.readableMessage
        }

        isLoading = false
    }
}

// MARK: - 网页端提示

struct WebHint: View {
    let path: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)

            if let url = URL(string: AppConfig.normalizedBaseURLString + path) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("前往网页端")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent.opacity(0.1)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}
