import SwiftUI

@MainActor
struct AdminRootView: View {
    @StateObject private var session: WebSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var serverAddress: String

    init(configuration: AppConfiguration) {
        _session = StateObject(wrappedValue: WebSession(configuration: configuration))
        _serverAddress = State(initialValue: configuration.origin.absoluteString)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !session.loggedIn && !session.viewingAttachment {
                VStack(alignment: .leading, spacing: 9) {
                    Text("服务器地址").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        TextField("https://你的客服域名", text: $serverAddress)
                            .keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().submitLabel(.go)
                            .onSubmit { session.changeServer(serverAddress) }
                            .padding(11).background(Color(uiColor: .systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("服务器 HTTPS 域名")
                        Button("连接") { session.changeServer(serverAddress) }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(.horizontal,20).padding(.vertical,12).background(Color.white)
            }
        }
        .sheet(item: $session.downloadedFile) { DownloadPreview(file: $0) }
        .preferredColorScheme(.light)
        .onOpenURL { session.receive($0) }
        .onChange(of: scenePhase) { phase in
            if phase == .active { session.becomeActive() }
        }
    }
}
