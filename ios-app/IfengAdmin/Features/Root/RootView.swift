import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Identifiable {
    case conversations
    case inbox
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversations: return "会话"
        case .inbox: return "收件箱"
        case .settings: return "设置"
        }
    }

    /// 只允许这三个 Lucide 图标。
    var iconName: String {
        switch self {
        case .conversations: return "message-circle-more"
        case .inbox: return "inbox"
        case .settings: return "settings"
        }
    }
}

struct ChatRoute: Hashable {
    let id: Int
}

struct InboxRoute: Hashable {
    let id: Int
    let name: String
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .conversations
    @State private var conversationPath = NavigationPath()
    @State private var inboxPath = NavigationPath()

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                // 显示正在连接的地址：探测最长 5 秒（见 AppConfig.probeTimeout），
                // 有这行字用户就知道它在干什么，不像卡死。
                LaunchView(
                    serverText: ServerAddress.parse(
                        UserDefaults.standard.string(forKey: AppConfig.lastServerDefaultsKey)
                            ?? AppConfig.defaultServer
                    )?.displayHost
                )
            case .login:
                LoginView()
            case .unreachable(let message):
                UnreachableView(
                    message: message,
                    currentServer: UserDefaults.standard.string(forKey: AppConfig.lastServerDefaultsKey)
                        ?? AppConfig.defaultServer,
                    // 重试不切回启动页：这一页自己会显示「连接中…」，
                    // 再切一次会闪屏，像是重新进了 App。
                    retry: { await app.restore(showLaunching: false) },
                    changeServer: { origin in
                        Task { await app.changeServer(to: origin) }
                    },
                    changeAccount: {
                        Task { await app.forceLogout() }
                    }
                )
            case .ready:
                if let session = app.session {
                    main(session: session)
                } else {
                    LoginView()
                }
            }
        }
        .overlay(alignment: .top) {
            if let banner = app.banner {
                BannerView(text: banner) { app.banner = nil }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.banner)
        .onChange(of: app.pendingConversationId) { value in
            guard let value else { return }
            openConversation(value)
        }
        .onChange(of: scenePhase) { newPhase in
            app.handleScenePhase(newPhase)
        }
    }

    @ViewBuilder
    private func main(session: AppSession) -> some View {
        let dockVisible = isDockVisible
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .conversations:
                    NavigationStack(path: $conversationPath) {
                        ConversationListScreen(session: session, title: "会话", showsBackButton: false)
                            .navigationDestination(for: ChatRoute.self) { route in
                                ChatView(session: session, conversationId: route.id) {
                                    if !conversationPath.isEmpty { conversationPath.removeLast() }
                                }
                            }
                    }
                case .inbox:
                    NavigationStack(path: $inboxPath) {
                        InboxScreen(session: session)
                            .navigationDestination(for: InboxRoute.self) { route in
                                ConversationListScreen(
                                    session: session,
                                    title: route.name,
                                    inboxId: route.id,
                                    showsBackButton: true
                                )
                            }
                            .navigationDestination(for: ChatRoute.self) { route in
                                ChatView(session: session, conversationId: route.id) {
                                    if !inboxPath.isEmpty { inboxPath.removeLast() }
                                }
                            }
                    }
                case .settings:
                    NavigationStack {
                        SettingsScreen(session: session)
                    }
                }
            }

            if dockVisible {
                DockBar(selection: $tab)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }

    private var isDockVisible: Bool {
        switch tab {
        case .conversations: return conversationPath.isEmpty
        case .inbox: return inboxPath.isEmpty
        case .settings: return true
        }
    }

    private func openConversation(_ id: Int) {
        app.pendingConversationId = nil
        tab = .conversations
        conversationPath = NavigationPath()
        conversationPath.append(ChatRoute(id: id))
    }
}

// MARK: - 底部 Dock（Liquid Glass）

/// 底部三个大图标。
///
/// - 整条 Dock 是一层玻璃；**选中的那一个按钮自己也是一层玻璃**，
///   并用 `matchedGeometryEffect` 在三个位置之间滑动，得到系统 TabBar 那种
///   「玻璃胶囊跟着选中项滚动」的动画。
/// - iOS 26 及以上走官方 `glassEffect`，更早系统自动回退到材质实现。
struct DockBar: View {
    @Binding var selection: AppTab

    @Namespace private var glassNamespace

    private let cellWidth: CGFloat = 62
    private let cellHeight: CGFloat = 46
    private let iconSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { item in
                button(for: item)
            }
        }
        .padding(6)
        .background(GlassSurface(shape: Capsule(), strong: true))
    }

    private func button(for item: AppTab) -> some View {
        let selected = selection == item
        return Button {
            guard selection != item else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                selection = item
            }
        } label: {
            ZStack {
                if selected {
                    // 选中态的玻璃胶囊；同一个 id 让它在切换时从旧位置滑到新位置。
                    GlassSurface(shape: Capsule(), strong: true)
                        .matchedGeometryEffect(id: "dock.selection", in: glassNamespace)
                        .frame(width: cellWidth, height: cellHeight)
                }
                LucideIcon(
                    name: item.iconName,
                    size: iconSize,
                    color: selected ? Color.primary : Color.secondary
                )
            }
            .frame(width: cellWidth, height: cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 启动与网络异常

struct LaunchView: View {
    /// 正在连接的目标地址。有值时在转圈下面显示出来，
    /// 用户能立刻看出「它在连哪个域名」，而不是对着一个空白转圈猜。
    var serverText: String?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                BrandMark(size: 58)
                ProgressView()
                    .padding(.top, 6)
                if let serverText, !serverText.isEmpty {
                    Text("正在连接 \(serverText)…")
                        .font(.app(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 40)
                        .padding(.top, 2)
                }
            }
        }
    }
}

struct UnreachableView: View {
    let message: String
    let currentServer: String
    /// 重新探测服务器。**异步**，这样按钮的转圈能精确跟随真实结果
    /// （探测最长 5 秒，成功/失败都会在此刻返回）。
    let retry: () async -> Void
    /// 换服务器地址并重新连接。传 nil 表示不提供该入口。
    var changeServer: ((String) -> Void)?
    /// 换账号登录：清掉本机凭据并回到登录页。
    var changeAccount: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    @State private var editing = false
    @State private var serverText = ""
    /// 正在重试中：按钮换成转圈，避免用户连点导致多次并发探测。
    @State private var retrying = false

    private func startRetry() {
        guard !retrying else { return }
        retrying = true
        // 转圈精确跟随真实探测：5 秒超时或连接成功，都会在这一刻复位。
        // 用固定 sleep 会出现「已经失败了按钮还在转」的错位。
        // `Task { @MainActor in ... }` 显式绑定主 actor，`retrying` 的读写才安全
        // （View 的方法本身在主 actor 上，但闭包里要跨 await，需要显式标注）。
        Task { @MainActor in
            await retry()
            retrying = false
        }
    }

    /// 页面底色：浅灰（暗色模式用一档更深的灰），不再是纯白。
    private var screenFill: Color {
        scheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.949, green: 0.953, blue: 0.965)
    }

    private var cardFill: Color {
        scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.18) : .white
    }

    var body: some View {
        ZStack {
            screenFill.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                card
                Spacer(minLength: 20)
                if changeAccount != nil {
                    changeAccountButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 主卡片

    private var card: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.danger.opacity(scheme == .dark ? 0.22 : 0.12))
                    .frame(width: 74, height: 74)
                LucideIcon(
                    name: "wifi-off",
                    size: 30,
                    color: Theme.danger
                )
            }

            VStack(spacing: 8) {
                Text("无法连接服务器")
                    .font(.app(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !editing, let current = ServerAddress.parse(currentServer) {
                HStack(spacing: 6) {
                    LucideIcon(name: "globe", size: 12, color: .secondary)
                    Text(current.origin)
                        .font(.app(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(Color.primary.opacity(0.05))
                )
            }

            if editing {
                serverEditor
            } else {
                actionRow
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(scheme == .dark ? 0 : 0.05), radius: 14, x: 0, y: 6)
    }

    /// 两个按钮**排成一行**：重试（实心）+ 更改服务器（描边）。
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: startRetry) {
                HStack(spacing: 6) {
                    if retrying {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        LucideIcon(name: "refresh-cw", size: 15, color: .white)
                    }
                    Text(retrying ? "连接中…" : "重试")
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.accent)
                )
                .opacity(retrying ? 0.75 : 1)
            }
            .buttonStyle(.plain)
            .disabled(retrying)

            if changeServer != nil {
                Button {
                    serverText = currentServer
                    withAnimation(.easeOut(duration: 0.16)) { editing = true }
                } label: {
                    HStack(spacing: 6) {
                        LucideIcon(name: "globe", size: 15, color: Theme.accent)
                        Text("更改服务器")
                            .font(.app(size: 15, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 底部「更换账号登录」。
    private var changeAccountButton: some View {
        Button {
            changeAccount?()
        } label: {
            HStack(spacing: 6) {
                LucideIcon(name: "log-out", size: 15, color: .secondary)
                Text("更换账号登录")
                    .font(.app(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var parsedServerText: ServerAddress? {
        ServerAddress.parse(serverText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var serverEditor: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("服务器地址")
                    .font(.app(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("https://example.com", text: $serverText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.URL)
                    .font(.app(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { editing = false }
                } label: {
                    Text("取消")
                        .font(.app(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    guard let server = parsedServerText else { return }
                    withAnimation(.easeOut(duration: 0.16)) { editing = false }
                    // 先用归一化后的 origin 写回输入框，再交给上层重连。
                    serverText = server.origin
                    changeServer?(server.origin)
                } label: {
                    Text("连接")
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(parsedServerText == nil)
                .opacity(parsedServerText == nil ? 0.5 : 1)
            }
        }
        .transition(.opacity)
    }
}

struct BrandMark: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.accent)
            LucideIcon(name: "message-circle-more", size: size * 0.5, color: .white)
        }
        .frame(width: size, height: size)
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(name: "circle-alert", size: 15, color: Theme.danger)
            Text(text)
                .font(.app(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                LucideIcon(name: "x", size: 12, color: .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GlassSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
    }
}
