import SwiftUI

@MainActor
struct AdminRootView: View {
    @StateObject private var session: WebSession
    @Environment(\.scenePhase) private var scenePhase

    init(configuration: AppConfiguration) {
        _session = StateObject(wrappedValue: WebSession(configuration: configuration))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 不忽略键盘安全区，让 WKWebView 随键盘正常缩小。
            AdminWebView(session: session)
            if session.isLoading {
                ProgressView(value: session.progress).tint(.blue).accessibilityLabel("正在加载工作台")
            }
            if let error = session.pageError {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text("无法加载工作台").font(.headline)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("重新加载") { session.reload() }.buttonStyle(.borderedProminent)
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
            }
            if let message = session.notice {
                HStack {
                    Text(message).font(.footnote)
                    Spacer()
                    Button { session.notice = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭提示")
                }.padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding().padding(.top, 5)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if session.viewingAttachment {
                HStack {
                    Button("返回工作台") { session.returnToWorkspace() }
                    Spacer()
                    Button { session.downloadCurrentPage() } label: {
                        Label("下载", systemImage: "square.and.arrow.down")
                    }
                }.padding(12).background(.regularMaterial)
            }
        }
        .sheet(item: $session.downloadedFile) { DownloadPreview(file: $0) }
        .onOpenURL { session.receive($0) }
        .onChange(of: scenePhase) { phase in
            if phase == .active { session.becomeActive() }
        }
    }
}
