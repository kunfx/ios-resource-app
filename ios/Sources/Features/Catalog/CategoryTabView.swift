import SwiftUI
import Combine

@MainActor
final class CategoryTabViewModel: ObservableObject {
    @Published var root: CategoryNode?
    @Published var items: [AppItem] = []
    @Published var selectedSubID: Int?
    @Published var keyword: String = ""
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?

    private var slug = ""
    private var page = 1
    private var lastPage = 1

    var subCategories: [CategoryNode] { root?.children ?? [] }
    var isSearching: Bool { !keyword.isEmpty }

    func start(slug: String) async {
        guard self.slug != slug else { return }

        self.slug = slug
        await loadCategories()
        await reload()
    }

    private func loadCategories() async {
        do {
            let tree: [CategoryNode] = try await APIClient.shared.get("/api/categories")

            root = tree.first {
                ($0.slug ?? "").lowercased() == slug.lowercased() || $0.name == slug
            }
        } catch {
            // 分类拉不到不影响资源列表，列表会用 parent_slug 兜底
        }
    }

    func selectSub(_ id: Int?) async {
        guard selectedSubID != id else { return }
        selectedSubID = id
        await reload()
    }

    func apply(keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != self.keyword else { return }

        self.keyword = trimmed
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        await fetch(reset: true)
    }

    func loadMoreIfNeeded(current item: AppItem) async {
        guard item.id == items.last?.id, page < lastPage, !isLoadingMore, !isLoading else { return }

        isLoadingMore = true
        await fetch(reset: false)
        isLoadingMore = false
    }

    private func fetch(reset: Bool) async {
        let targetPage = reset ? 1 : page + 1

        var query: [String: String] = [
            "sort": "latest",
            "per_page": "\(AppConfig.pageSize)",
            "page": "\(targetPage)"
        ]

        if !keyword.isEmpty {
            query["q"] = keyword
        }

        if let sub = selectedSubID {
            query["category_id"] = "\(sub)"
        } else if !slug.isEmpty {
            query["parent_slug"] = slug
        }

        do {
            let result: Page<AppItem> = try await APIClient.shared.get("/api/apps", query: query)

            lastPage = result.lastPage

            if reset {
                items = result.items
                page = 1
            } else {
                let existing = Set(items.map { $0.id })
                items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                page = targetPage
            }

            errorMessage = nil
        } catch {
            if !((error as? APIError)?.isCancelled ?? false), reset {
                errorMessage = error.readableMessage
            }
        }

        isLoading = false
    }
}

/// 三个资源分类页共用：应用 / 游戏 / 巨魔
struct CategoryTabView: View {
    let slug: String
    let title: String

    @StateObject private var viewModel = CategoryTabViewModel()
    @State private var query = ""

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                ScrollView {
                    VStack(spacing: 12) {
                        if !viewModel.isSearching {
                            subChips
                        }

                        content
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
                .background(Theme.background)
                .refreshable { await viewModel.reload() }
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppItem.self) { item in
                AppDetailView(appID: item.id)
            }
            .task { await viewModel.start(slug: slug) }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                await viewModel.apply(keyword: query)
            }
        }
    }

    // MARK: - 搜索框（放大镜在最左）

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)

            TextField("搜索\(title)", text: $query)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var subChips: some View {
        Group {
            if !viewModel.subCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(title: "全部", id: nil)

                        ForEach(viewModel.subCategories) { sub in
                            chip(title: sub.name, id: sub.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func chip(title: String, id: Int?) -> some View {
        let active = viewModel.selectedSubID == id

        return Button {
            Task { await viewModel.selectSub(id) }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(active ? Theme.accent.opacity(0.12) : Theme.card))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            LoadingView()
        } else if let message = viewModel.errorMessage, viewModel.items.isEmpty {
            ErrorStateView(message: message) {
                Task { await viewModel.reload() }
            }
        } else if viewModel.items.isEmpty {
            EmptyStateView(icon: viewModel.isSearching ? "magnifyingglass" : "tray",
                           title: viewModel.isSearching ? "没有找到「\(viewModel.keyword)」" : "这个分类下还没有资源",
                           message: viewModel.isSearching ? "换个关键词试试" : nil)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.items) { item in
                    NavigationLink(value: item) {
                        AppGridCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .task {
                        await viewModel.loadMoreIfNeeded(current: item)
                    }
                }
            }
            .padding(.horizontal, 16)

            if viewModel.isLoadingMore {
                ProgressView().padding(.vertical, 10)
            }
        }
    }
}
