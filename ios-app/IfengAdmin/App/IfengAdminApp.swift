import SwiftUI

@main
@MainActor
struct IfengAdminApp: App {
    private let configuration = Result { try AppConfiguration.load() }

    var body: some Scene {
        WindowGroup {
            switch configuration {
            case .success(let value): AdminRootView(configuration: value)
            case .failure(let error):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("配置需要检查").font(.headline)
                    Text(error.localizedDescription).multilineTextAlignment(.center)
                }.padding()
            }
        }
    }
}
