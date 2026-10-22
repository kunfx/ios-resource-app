import SwiftUI

struct ArticlesView: View {
    @State private var items: [Article] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var lastPage = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    LoadingView(text: "加载文章")
                } else if let message = errorMessage, items.isEmpty {
                    ErrorStateView(message: message) {
                        Task { await load(reset: true) }
                    }
                } else if items.isEmpty {
                    EmptyStateView(icon: "doc.text", title: "还没有发布文章")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { article in
                            NavigationLink(value: article) {
                                ArticleCard(article: article)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .task {
                                if article.id == items.last?.id {
                                    await load(reset: false)
                                }
                            }

                            Divider().padding(.leading, 120)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Theme.background)
        .navigationTitle("教程文章")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Article.self) { article in
            ArticleDetailView(articleID: article.id)
        }
        .refreshable { await load(reset: true) }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
    }

    private func load(reset: Bool) async {
        if reset {
            page = 1
            isLoading = items.isEmpty
        } else {
            guard page < lastPage else { return }
        }

        do {
            let result: Page<Article> = try await APIClient.shared.get("/api/articles", query: [
                "page": "\(page)",
                "per_page": "20"
            ])

            lastPage = result.lastPage

            if reset {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
                page += 1
            }

            errorMessage = nil
        } catch {
            if reset { errorMessage = error.readableMessage }
        }

        isLoading = false
    }
}

struct ArticleDetailView: View {
    let articleID: Int

    @State private var article: ArticleDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                LoadingView(text: "加载文章")
            } else if let message = errorMessage {
                ErrorStateView(message: message) {
                    Task { await load() }
                }
            } else if let article = article {
                VStack(spacing: 0) {
                    header(article)
                    Divider()
                    HTMLView(html: article.content ?? "<p>暂无内容</p>")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("文章")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func header(_ article: ArticleDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(article.title)
                .font(.system(size: 19, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(DateText.day(article.publishedAt))
                Text("\(NumberText.compact(article.views)) 阅读")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.background)
    }

    private func load() async {
        isLoading = article == nil

        do {
            let result: ArticleDetail = try await APIClient.shared.get("/api/articles/\(articleID)")
            article = result
            errorMessage = nil
        } catch {
            if !((error as? APIError)?.isCancelled ?? false) {
                errorMessage = error.readableMessage
            }
        }

        isLoading = false
    }
}
