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
                LaunchView()
            case .login:
                LoginView()
            case .unreachable(let message):
                UnreachableView(
                    message: message,
                    currentServer: UserDefaults.standard.string(forKey: AppConfig.lastServerDefaultsKey)
                        ?? AppConfig.defaultServer,
                    retry: { Task { await app.restore() } },
                    changeServer: { origin in
                        Task { await app.changeServer(to: origin) }
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
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                BrandMark(size: 58)
                ProgressView()
                    .padding(.top, 6)
            }
        }
    }
}

struct UnreachableView: View {
    let message: String
    let currentServer: String
    let retry: () -> Void
    /// 换服务器地址并重新连接。传 nil 表示不提供该入口。
    var changeServer: ((String) -> Void)?

    @State private var editing = false
    @State private var serverText = ""

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    BrandMark(size: 58)
                        .padding(.top, 40)
                    Text("无法连接服务器")
                        .font(.app(size: 17, weight: .semibold))
                    Text(message)
                        .font(.app(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    if let current = ServerAddress.parse(currentServer) {
                        HStack(spacing: 5) {
                            LucideIcon(name: "globe", size: 11, color: .secondary)
                            Text(current.origin)
                                .font(.app(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if editing {
                        serverEditor
                    } else {
                        actions
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: retry) {
                HStack(spacing: 6) {
                    LucideIcon(name: "refresh-cw", size: 14, color: .white)
                    Text("重试")
                        .font(.app(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)

            if changeServer != nil {
                Button {
                    serverText = currentServer
                    withAnimation(.easeOut(duration: 0.16)) { editing = true }
                } label: {
                    HStack(spacing: 6) {
                        LucideIcon(name: "globe", size: 14, color: Theme.accent)
                        Text("更改服务器地址")
                            .font(.app(size: 15, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
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
                            .fill(Color(uiColor: .tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { editing = false }
                } label: {
                    Text("取消")
                        .font(.app(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
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
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.accent))
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
