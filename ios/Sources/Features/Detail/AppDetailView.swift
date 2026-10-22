import SwiftUI
import UIKit

struct AppDetailView: View {
    let appID: Int

    @EnvironmentObject private var session: SessionStore

    @State private var detail: AppDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var isDownloading = false
    @State private var confirmPoints: Int?
    @State private var unlockedLinks: [DownloadLink] = []
    @State private var toast: String?
    @State private var showLogin = false

    @State private var commentText = ""
    @State private var isPostingComment = false
    @State private var localComments: [AppComment] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    LoadingView(text: "加载详情")
                } else if let message = errorMessage {
                    ErrorStateView(message: message) {
                        Task { await load() }
                    }
                } else if let detail = detail {
                    header(detail)
                    actionCard(detail)

                    if !detail.screenshots.isEmpty {
                        screenshots(detail)
                    }

                    if let modInfo = detail.modInfo, !modInfo.isEmpty {
                        textSection(title: "功能特点", icon: "sparkles", content: modInfo)
                    }

                    if let description = detail.description, !description.isEmpty {
                        textSection(title: "详细介绍", icon: "text.alignleft", content: description)
                    }

                    downloadSection

                    commentsSection(detail)

                    if !detail.related.isEmpty {
                        relatedSection(detail.related)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle(detail?.name ?? "资源详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $showLogin) {
            LoginView()
                .environmentObject(session)
        }
        .alert("确认下载", isPresented: Binding(
            get: { confirmPoints != nil },
            set: { if !$0 { confirmPoints = nil } }
        )) {
            Button("取消", role: .cancel) { confirmPoints = nil }
            Button("确认扣除") {
                Task { await confirmDownload() }
            }
        } message: {
            Text("本资源需要消耗 \(confirmPoints ?? 0) 积分，当前余额 \(session.points) 积分。\n积分扣除由服务器校验，扣除后不可退回。")
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 30)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 头部

    private func header(_ detail: AppDetail) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                AppIconView(urlString: detail.icon, size: 84, cornerRadius: 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let short = detail.shortDescription, !short.isEmpty {
                        Text(short)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        PillTag(text: "v\(detail.version ?? "1.0")", color: Theme.accentSoft)

                        if let size = detail.size, !size.isEmpty {
                            PillTag(text: size, color: Theme.secondaryText)
                        }

                        if let category = detail.category {
                            PillTag(text: category.parent?.name ?? category.name, color: Theme.accent)
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                statItem(title: "浏览", value: NumberText.compact(detail.views))
                divider
                statItem(title: "评论", value: "\(detail.commentCount)")
                divider
                statItem(title: "价格", value: detail.isFree ? "免费" : "\(detail.pointsRequired) 积分")
                divider
                statItem(title: "更新", value: DateText.day(detail.updatedAt))
            }
            .padding(.top, 2)
        }
        .cardStyle()
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.separator.opacity(0.5))
            .frame(width: 1, height: 22)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 下载区

    private func actionCard(_ detail: AppDetail) -> some View {
        VStack(spacing: 10) {
            if detail.isUnlocked || !unlockedLinks.isEmpty {
                unlockedList
            } else {
                Button {
                    startDownload()
                } label: {
                    HStack(spacing: 6) {
                        if isDownloading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: detail.isFree ? "arrow.down.circle.fill" : "lock.open.fill")
                        }
                        Text(buttonTitle(detail))
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !isDownloading))
                .disabled(isDownloading)

                Text(hintText(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
    }

    private func buttonTitle(_ detail: AppDetail) -> String {
        if isDownloading { return "正在校验权限…" }
        if detail.isFree { return "获取下载地址" }
        if detail.isVipFree { return "会员免费下载" }
        return "使用 \(detail.pointsRequired) 积分下载"
    }

    private func hintText(_ detail: AppDetail) -> String {
        if !session.isLoggedIn { return "下载需要先登录，链接由服务端校验后下发" }
        if detail.isFree { return "免费资源每日有下载次数限制，具体以服务端校验为准" }
        if detail.isVipFree { return "当前账号为会员，付费资源免费下载" }
        return "点击后需要二次确认才会扣除积分"
    }

    private var unlockedList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.accent)
                Text("已解锁，下载链接 2 小时内有效")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }

            ForEach(unlockedLinks) { link in
                Button {
                    enqueue(link)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let type = link.type {
                                Text(type)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }

                        Spacer()

                        Text("下载")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .padding(12)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 截图

    private func screenshots(_ detail: AppDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "应用截图", subtitle: "SCREENSHOTS")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(detail.screenshots, id: \.self) { url in
                        RemoteImage(urlString: url, placeholderIcon: "photo")
                            .frame(width: 190, height: 330)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 文本区块

    private func textSection(title: String, icon: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
            }

            Text(content)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
        .padding(.horizontal, 16)
    }

    // MARK: - 下载列表（详情接口已返回但未解锁时展示标题）

    @ViewBuilder
    private var downloadSection: some View {
        if let detail = detail, !detail.downloadLinks.isEmpty, unlockedLinks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accentSoft)
                    Text("可用下载")
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                }

                ForEach(detail.downloadLinks) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)

                        Text(link.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)

                        if let type = link.type {
                            Text(type)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                        }

                        Spacer()
                    }
                }
            }
            .cardStyle()
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 评论

    private func commentsSection(_ detail: AppDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("用户评论")
                    .font(.system(size: 15, weight: .bold))
                Text("\(detail.commentCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }

            if session.isLoggedIn {
                HStack(spacing: 8) {
                    TextField("说点什么…", text: $commentText, axis: .vertical)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.field)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        Task { await postComment() }
                    } label: {
                        if isPostingComment {
                            ProgressView().frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Theme.accent))
                        }
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty || isPostingComment)
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Text("登录后可以发表评论")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }
            }

            let list = localComments.isEmpty ? detail.comments : localComments

            if list.isEmpty {
                Text("还没有评论，来做第一个吧")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(list) { comment in
                        commentRow(comment)
                    }
                }
            }
        }
        .cardStyle()
        .padding(.horizontal, 16)
    }

    private func commentRow(_ comment: AppComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(urlString: comment.user?.avatar, placeholderIcon: "person.fill")
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.user?.name ?? "匿名用户")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(DateText.relative(comment.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)

                    Spacer()
                }

                Text(comment.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 相关推荐

    private func relatedSection(_ items: [AppItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "相关推荐", subtitle: "MORE LIKE THIS")

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

    // MARK: - 数据

    private func load() async {
        isLoading = detail == nil
        errorMessage = nil

        do {
            let result: AppDetail = try await APIClient.shared.get("/api/apps/\(appID)")
            detail = result
            unlockedLinks = result.isUnlocked ? result.downloadLinks.filter { $0.url != nil } : []
        } catch {
            if !((error as? APIError)?.isCancelled ?? false) {
                errorMessage = error.readableMessage
            }
        }

        isLoading = false
    }

    private func startDownload() {
        guard session.isLoggedIn else {
            showLogin = true
            return
        }
        Task { await requestDownload() }
    }

    private func requestDownload() async {
        isDownloading = true
        defer { isDownloading = false }

        do {
            let result: DownloadResult = try await APIClient.shared.post("/api/apps/\(appID)/download/request")

            if result.needsConfirm {
                confirmPoints = result.pointsRequired ?? 0
            } else if result.isReady {
                unlockedLinks = (result.downloadLinks ?? []).filter { $0.url != nil }
                showToast(result.message ?? "已获取下载地址")
            } else {
                showToast(result.message ?? "暂时无法下载")
            }

            await session.refreshProfile(silent: true)
        } catch {
            showToast(error.readableMessage)
        }
    }

    private func confirmDownload() async {
        confirmPoints = nil
        isDownloading = true
        defer { isDownloading = false }

        do {
            let result: DownloadResult = try await APIClient.shared.post("/api/apps/\(appID)/download/confirm")
            unlockedLinks = (result.downloadLinks ?? []).filter { $0.url != nil }
            showToast(result.message ?? "已解锁下载")
            await session.refreshProfile(silent: true)
        } catch {
            showToast(error.readableMessage)
        }
    }

    private func postComment() async {
        let content = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 2 else { return }

        isPostingComment = true
        defer { isPostingComment = false }

        do {
            let comment: AppComment = try await APIClient.shared.post(
                "/api/apps/\(appID)/comments",
                body: ["content": content]
            )
            var list = localComments.isEmpty ? (detail?.comments ?? []) : localComments
            list.insert(comment, at: 0)
            localComments = list
            commentText = ""
        } catch {
            showToast(error.readableMessage)
        }
    }

    /// 所有下载都走内置下载管理，不跳浏览器
    private func enqueue(_ link: DownloadLink) {
        guard let urlString = link.url, !urlString.isEmpty else {
            showToast("下载地址无效，请重新获取")
            return
        }

        guard let detail = detail else { return }

        let id = DownloadManager.shared.enqueue(
            appID: detail.id,
            appName: detail.name,
            iconURL: detail.icon,
            linkTitle: link.title,
            urlString: urlString
        )

        showToast(id == nil ? "下载地址无效" : "已加入下载，切到「下载」标签查看进度")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { toast = nil }
        }
    }
}
