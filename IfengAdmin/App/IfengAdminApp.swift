import SwiftUI

@main
struct IfengAdminApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .tint(Theme.accent)
                .task {
                    await appState.restoreIfNeeded()
                }
                .onOpenURL { url in
                    _ = appState.handleDeepLink(url)
                }
        }
    }
}
