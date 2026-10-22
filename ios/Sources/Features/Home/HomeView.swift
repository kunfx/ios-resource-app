import SwiftUI
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var latestApps: [AppItem] = []
    @Published var latestGames: [AppItem] = []
    @Published var trolls: [AppItem] = []
    @Published var articles: [Article] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var isEmpty: Bool { latestApps.isEmpty && latestGames.isEmpty && trolls.isEmpty }

    func load() async {
        if isEmpty { isLoading = true }
        errorMessage = nil

        do {
            async let apps: Page<AppItem> = APIClient.shared.get("/api/apps", query: [
                "parent_slug": "Apps", "sort": "latest", "per_page": "9"
            ])
            async let games: Page<AppItem> = APIClient.shared.get("/api/apps", query: [
                "parent_slug": "Games", "sort": "latest", "per_page": "9"
            ])
            async let trollsPage: Page<AppItem> = APIClient.shared.get("/api/apps", query: [
                "parent_slug": "Trolls", "sort": "latest", "per_page": "9"
            ])
            async let posts: Page<Article> = APIClient.shared.get("/api/articles", query: [
                "per_page": "6"
            ])

            let (appsPage, gamesPage, trollsResult, articlesPage) = try await (apps, games, trollsPage, posts)

            latestApps = appsPage.items
            latestGames = gamesPage.items
            trolls = trollsResult.items
            articles = articlesPage.items
        } catch {
            if (error as? APIError)?.isCancelled != true {
                errorMessage = error.readableMessage
            }
        }

        isLoading = false
    }
}

struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    searchEntry

                    if viewModel.isLoading {
                        LoadingView(text: "正在获取资源")
                    } else if let message = viewModel.errorMessage, viewModel.isEmpty {
                        ErrorStateView(message: message) {
                            Task { await viewModel.load() }
                        }
                    } else if viewModel.isEmpty {
                        EmptyStateView(title: "还没有上架的资源",
                                       message: "去后台添加一些应用或游戏吧")
                    } else {
                        sections
                    }

                    footer
                }
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await viewModel.load()
                await session.refreshProfile(silent: true)
            }
            .task {
                if viewModel.isEmpty {
                    await viewModel.load()
                }
            }
            .navigationDestination(for: AppItem.self) { item in
                AppDetailView(appID: item.id)
            }
            .navigationDestination(for: Article.self) { article in
                ArticleDetailView(articleID: article.id)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(AppConfig.appName)
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.brandGradient)

                    Text("PRO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }

                Text("精选 iOS 应用 · 游戏 · 巨魔资源")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            if session.isLoggedIn, let user = session.user {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(user.points)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                        Text("积分")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.tertiaryText)
                    }

                    RemoteImage(urlString: user.avatar, placeholderIcon: "person.fill")
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var searchEntry: some View {
        NavigationLink {
            SearchView(isPushed: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)

                Text("搜索应用、游戏、教程")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.tertiaryText)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - 内容区块

    private var sections: some View {
        VStack(spacing: 24) {
            section(title: "最新应用", subtitle: "APP", items: viewModel.latestApps)
            section(title: "最新游戏", subtitle: "GAME", items: viewModel.latestGames)
            section(title: "巨魔专用", subtitle: "TROLLSTORE", items: viewModel.trolls)

            if !viewModel.articles.isEmpty {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("教程文章")
                            .font(.system(size: 19, weight: .bold))
                        Text("GUIDE")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)

                        Spacer()

                        NavigationLink {
                            ArticlesView()
                        } label: {
                            HStack(spacing: 2) {
                                Text("全部")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 14) {
                        ForEach(viewModel.articles) { article in
                            NavigationLink(value: article) {
                                ArticleCard(article: article)
                            }
                            .buttonStyle(.plain)

                            if article.id != viewModel.articles.last?.id {
                                Divider().padding(.leading, 104)
                            }
                        }
                    }
                    .cardStyle(padding: 14)
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func section(title: String, subtitle: String, items: [AppItem]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(spacing: 12) {
                    SectionHeader(title: title, subtitle: subtitle)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(items) { item in
                                NavigationLink(value: item) {
                                    AppTile(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("数据由 \(AppConfig.normalizedBaseURLString) 提供")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            Text("所有资源信息以服务端返回为准")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.top, 8)
    }
}
