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
                                ChatView(session: session, conversationId: route.id)
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
                                ChatView(session: session, conversationId: route.id)
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

/// 底部三个大图标。iOS 26 及以上走系统官方 Liquid Glass，
/// 更早系统用材质模拟，视觉一致但不需要新 SDK。
struct DockBar: View {
    @Binding var selection: AppTab

    private let cellWidth: CGFloat = 66
    private let cellHeight: CGFloat = 48
    private let iconSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = item }
                } label: {
                    ZStack {
                        if selection == item {
                            Capsule()
                                .fill(Color(uiColor: .systemBackground).opacity(0.62))
                                .overlay(
                                    Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.7)
                                )
                                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
                                .frame(width: cellWidth, height: 44)
                        }
                        LucideIcon(
                            name: item.iconName,
                            size: iconSize,
                            color: selection == item ? Color.primary : Color.secondary
                        )
                    }
                    // 单元格比图标大一圈，给描边留出余量，避免被胶囊边缘切掉。
                    .frame(width: cellWidth, height: cellHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
            }
        }
        .padding(7)
        .background(GlassSurface(shape: Capsule(), strong: true))
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
                    .font(.system(size: 17, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button(action: retry) {
                    HStack(spacing: 6) {
                        LucideIcon(name: "refresh-cw", size: 14, color: .white)
                        Text("重试")
                            .font(.system(size: 15, weight: .medium))
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
                .font(.system(size: 13))
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
