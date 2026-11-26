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
                UnreachableView(message: message) {
                    Task { await app.restore() }
                }
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
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                BrandMark(size: 58)
                Text("无法连接服务器")
                    .font(.app(size: 17, weight: .semibold))
                Text(message)
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
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
                .padding(.top, 4)
            }
        }
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
