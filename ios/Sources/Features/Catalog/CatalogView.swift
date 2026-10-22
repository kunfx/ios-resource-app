import SwiftUI
import Combine

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var roots: [CategoryNode] = []
    @Published var selectedRootID: Int?
    @Published var selectedSubID: Int?
    @Published var items: [AppItem] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isLoadingMore = false

    private var page = 1
    private var lastPage = 1

    var selectedRoot: CategoryNode? {
        roots.first(where: { $0.id == selectedRootID })
    }

    var subCategories: [CategoryNode] {
        selectedRoot?.children ?? []
    }

    func loadCategories() async {
        guard roots.isEmpty else { return }

        isLoading = true
        do {
            let list: [CategoryNode] = try await APIClient.shared.get("/api/categories")
            roots = list
            if selectedRootID == nil { selectedRootID = list.first?.id }
            await loadApps(reset: true)
        } catch {
            errorMessage = error.readableMessage
            isLoading = false
        }
    }

    func selectRoot(_ id: Int) async {
        guard selectedRootID != id else { return }
        selectedRootID = id
        selectedSubID = nil
        await loadApps(reset: true)
    }

    func selectSub(_ id: Int?) async {
        guard selectedSubID != id else { return }
        selectedSubID = id
        await loadApps(reset: true)
    }

    func loadApps(reset: Bool) async {
        if reset {
            page = 1
            isLoading = true
        } else {
            guard page < lastPage, !isLoadingMore else { return }
            isLoadingMore = true
        }

        errorMessage = nil

        var query: [String: String] = [
            "sort": "latest",
            "per_page": "\(AppConfig.pageSize)",
            "page": "\(page)"
        ]

        if let sub = selectedSubID {
            query["category_id"] = "\(sub)"
        } else if let root = selectedRoot {
            query["parent_slug"] = root.slug ?? root.name
        }

        do {
            let result: Page<AppItem> = try await APIClient.shared.get("/api/apps", query: query)
            lastPage = result.lastPage

            if reset {
                items = result.items
            } else {
                let existing = Set(items.map { $0.id })
                items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                page += 1
            }
        } catch {
            let cancelled = (error as? APIError)?.isCancelled ?? false
            if !cancelled {
                errorMessage = error.readableMessage
            }
        }

        isLoading = false
        isLoadingMore = false
    }

    func loadMoreIfNeeded(current item: AppItem) async {
        guard item.id == items.last?.id else { return }
        await loadApps(reset: false)
    }
}

struct CatalogView: View {
    @StateObject private var viewModel = CatalogViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                rootPicker

                ScrollView {
                    VStack(spacing: 14) {
                        subPicker

                        if viewModel.isLoading {
                            LoadingView()
                        } else if let message = viewModel.errorMessage, viewModel.items.isEmpty {
                            ErrorStateView(message: message) {
                                Task { await viewModel.loadApps(reset: true) }
                            }
                        } else if viewModel.items.isEmpty {
                            EmptyStateView(title: "这个分类下还没有资源")
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
                                ProgressView().padding(.vertical, 12)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .background(Theme.background)
            }
            .background(Theme.background)
            .navigationTitle("分类")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppItem.self) { item in
                AppDetailView(appID: item.id)
            }
            .task {
                await viewModel.loadCategories()
            }
        }
    }

    private var rootPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.roots) { root in
                    let active = root.id == viewModel.selectedRootID

                    Button {
                        Task { await viewModel.selectRoot(root.id) }
                    } label: {
                        Text(root.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(active ? Color.white : Theme.secondaryText)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().fill(active ? AnyShapeStyle(Theme.brandGradient)
                                                      : AnyShapeStyle(Theme.card))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.background)
    }

    private var subPicker: some View {
        Group {
            if !viewModel.subCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        subChip(title: "全部", id: nil)

                        ForEach(viewModel.subCategories) { sub in
                            subChip(title: sub.name, id: sub.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func subChip(title: String, id: Int?) -> some View {
        let active = viewModel.selectedSubID == id

        return Button {
            Task { await viewModel.selectSub(id) }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? Theme.accent.opacity(0.12) : Theme.card)
                )
        }
        .buttonStyle(.plain)
    }
}
