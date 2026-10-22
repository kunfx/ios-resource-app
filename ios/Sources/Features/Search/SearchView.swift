import SwiftUI

struct SearchView: View {
    /// true 表示从首页 push 进来，复用外层的 NavigationStack
    var isPushed: Bool = false

    @State private var query = ""
    @State private var results: [AppItem] = []
    @State private var suggestions: [AppItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    var body: some View {
        if isPushed {
            content
        } else {
            NavigationStack {
                content
                    .navigationDestination(for: AppItem.self) { item in
                        AppDetailView(appID: item.id)
                    }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isSearching {
                    LoadingView(text: "搜索中")
                } else if let message = errorMessage {
                    ErrorStateView(message: message) {
                        Task { await performSearch() }
                    }
                } else if !results.isEmpty {
                    resultList
                } else if hasSearched {
                    EmptyStateView(icon: "magnifyingglass",
                                   title: "没有找到「\(query)」",
                                   message: "换个关键词试试，或者去分类里逛逛")
                } else {
                    suggestionList
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索应用、游戏、教程")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: query) {
            await debounceSearch()
        }
        .task {
            if suggestions.isEmpty {
                await loadSuggestions()
            }
        }
    }

    private var resultList: some View {
        LazyVStack(spacing: 0) {
            HStack {
                Text("共 \(results.count) 个结果")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ForEach(results) { item in
                NavigationLink(value: item) {
                    AppRow(item: item, showCategory: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 86)
            }
        }
    }

    private var suggestionList: some View {
        VStack(spacing: 12) {
            SectionHeader(title: "热门资源", subtitle: "HOT")
                .padding(.top, 8)

            LazyVStack(spacing: 0) {
                ForEach(suggestions) { item in
                    NavigationLink(value: item) {
                        AppRow(item: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 86)
                }
            }
        }
    }

    private func debounceSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !keyword.isEmpty else {
            results = []
            hasSearched = false
            errorMessage = nil
            return
        }

        // 350ms 防抖，避免每敲一个字母就发一次请求
        try? await Task.sleep(nanoseconds: 350_000_000)

        if Task.isCancelled { return }

        await performSearch()
    }

    private func performSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        isSearching = true
        errorMessage = nil

        do {
            let page: Page<AppItem> = try await APIClient.shared.get("/api/apps", query: [
                "q": keyword,
                "per_page": "30"
            ])
            results = page.items
            hasSearched = true
        } catch {
            if !((error as? APIError)?.isCancelled ?? false) {
                errorMessage = error.readableMessage
            }
        }

        isSearching = false
    }

    private func loadSuggestions() async {
        do {
            let page: Page<AppItem> = try await APIClient.shared.get("/api/apps", query: [
                "sort": "hot",
                "per_page": "10"
            ])
            suggestions = page.items
        } catch {
            // 热门推荐失败不打扰用户
        }
    }
}
