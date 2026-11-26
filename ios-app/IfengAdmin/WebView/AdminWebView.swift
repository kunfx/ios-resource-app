import SwiftUI
import WebKit

struct AdminWebView: UIViewRepresentable {
    @ObservedObject var session: WebSession

    func makeUIView(context: Context) -> WKWebView {
        session.start()
        return session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
