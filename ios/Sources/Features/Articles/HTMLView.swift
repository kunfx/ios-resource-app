import SwiftUI
import UIKit
import WebKit

/// 渲染后台文章里的 HTML 正文，样式适配深浅色与窄屏。
struct HTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(wrappedDocument, baseURL: URL(string: AppConfig.normalizedBaseURLString))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // 外链交给系统浏览器，避免在文章内跳走
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private var wrappedDocument: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0;
            padding: 16px;
            font: -apple-system-body;
            font-size: 15px;
            line-height: 1.75;
            color: #1c1c1e;
            background: transparent;
            -webkit-text-size-adjust: 100%;
            word-break: break-word;
          }
          img, video, iframe { max-width: 100% !important; height: auto !important; border-radius: 10px; }
          a { color: #10B981; text-decoration: none; }
          h1, h2, h3 { line-height: 1.4; margin: 1.2em 0 0.5em; }
          p { margin: 0.7em 0; }
          pre { background: rgba(127,127,127,0.12); padding: 12px; border-radius: 10px; overflow-x: auto; }
          code { background: rgba(127,127,127,0.12); padding: 1px 4px; border-radius: 4px; font-size: 13px; }
          blockquote { margin: 0.8em 0; padding-left: 12px; border-left: 3px solid #10B981; color: #6b7280; }
          table { width: 100%; border-collapse: collapse; }
          td, th { border: 1px solid rgba(127,127,127,0.3); padding: 6px 8px; font-size: 13px; }
          @media (prefers-color-scheme: dark) {
            body { color: #e5e7eb; }
            blockquote { color: #9ca3af; }
          }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
}
