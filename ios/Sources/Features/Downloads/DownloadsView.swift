import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @State private var share: SharePayload?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if manager.items.isEmpty {
                        EmptyStateView(icon: "arrow.down.circle",
                                       title: "还没有下载任务",
                                       message: "在资源详情页点「获取下载」，文件会在这里下载")
                            .padding(.top, 40)
                    } else {
                        ForEach(manager.items) { item in
                            row(item)
                        }

                        Text("文件保存在「文件」App → 我的 iPhone → AppKu → Downloads")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .padding(.top, 10)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if manager.items.contains(where: { $0.state == .completed }) {
                        Button("清空已完成") {
                            manager.clearCompleted()
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            .sheet(item: $share) { payload in
                ActivityView(url: payload.url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - 单条任务

    private func row(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIconView(urlString: item.iconURL, size: 44, cornerRadius: 11)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.appName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(item.linkTitle)
                            .lineLimit(1)

                        if !item.sizeText.isEmpty {
                            Text("·")
                            Text(item.sizeText)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                }

                Spacer(minLength: 4)

                statusLabel(item)
            }

            ProgressView(value: item.state == .completed ? 1 : item.progress)
                .progressViewStyle(.linear)
                .tint(progressColor(item))

            if let error = item.errorMessage, item.state == .failed {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(spacing: 16) {
                actionButtons(item)
                Spacer()
            }
        }
        .cardStyle(padding: 12, radius: 14)
    }

    private func progressColor(_ item: DownloadItem) -> Color {
        switch item.state {
        case .failed: return .red
        case .completed: return Theme.accent
        case .paused: return .orange
        default: return Theme.accentSoft
        }
    }

    private func statusLabel(_ item: DownloadItem) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(item.state.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(progressColor(item))

            if item.state == .downloading {
                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ item: DownloadItem) -> some View {
        switch item.state {
        case .downloading, .queued:
            smallButton(title: "暂停", icon: "pause.fill") { manager.pause(itemID: item.id) }

        case .paused:
            smallButton(title: "继续", icon: "play.fill") { manager.resume(itemID: item.id) }

        case .failed:
            smallButton(title: "重试", icon: "arrow.clockwise") { manager.retry(itemID: item.id) }

        case .completed:
            smallButton(title: "分享 / 安装", icon: "square.and.arrow.up") {
                if let url = item.fileURL {
                    share = SharePayload(url: url)
                }
            }
        }

        smallButton(title: "删除", icon: "trash", tint: .red) {
            manager.remove(itemID: item.id)
        }
    }

    private func smallButton(title: String, icon: String,
                             tint: Color = Theme.secondaryText,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
