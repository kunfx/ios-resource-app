import SwiftUI

@main
struct AppKuApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .task {
                    await session.bootstrap()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        Group {
            if session.isRestoring {
                SplashView()
            } else {
                MainTabView()
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var downloads = DownloadManager.shared

    private var activeDownloads: Int {
        downloads.items.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    var body: some View {
        TabView {
            CategoryTabView(slug: "Apps", title: "应用")
                .tabItem { Label("应用", systemImage: "square.grid.2x2.fill") }

            CategoryTabView(slug: "Games", title: "游戏")
                .tabItem { Label("游戏", systemImage: "gamecontroller.fill") }

            CategoryTabView(slug: "Trolls", title: "巨魔")
                .tabItem { Label("巨魔", systemImage: "wand.and.stars") }

            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
                .badge(activeDownloads)

            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .badge(session.stats?.unreadMessages ?? 0)
        }
        .tint(Theme.accent)
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Theme.brandGradient)
                        .frame(width: 88, height: 88)

                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(AppConfig.appName)
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.brandGradient)

                ProgressView()
                    .tint(Theme.accent)
            }
        }
    }
}
