import UIKit
import WebKit

@MainActor
final class WebDialogs: NSObject, WKUIDelegate {
    weak var session: WebSession?

    private var presenter: UIViewController? {
        var controller = session?.webView.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    func confirmNavigation(_ completion: @escaping (Bool) -> Void) {
        confirm(title: "打开通知会话", message: "当前系统需要重新加载页面才能打开会话。未发送的草稿会丢失，是否继续？", completion: completion)
    }

    private func confirm(title: String, message: String, completion: @escaping (Bool) -> Void) {
        guard let presenter, !(presenter is UIAlertController) else { completion(false); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completion(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard trusted(frame), let presenter, !(presenter is UIAlertController) else { completionHandler(); return }
        let alert = UIAlertController(title: "客服工作台", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard trusted(frame) else { completionHandler(false); return }
        confirm(title: "客服工作台", message: message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard trusted(frame), let presenter, !(presenter is UIAlertController) else { completionHandler(nil); return }
        let alert = UIAlertController(title: "客服工作台", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { session?.openNewWindow(navigationAction) }
        return nil
    }

    private func trusted(_ frame: WKFrameInfo) -> Bool {
        guard frame.isMainFrame, let url = frame.request.url, let session else { return false }
        return session.configuration.owns(url)
    }

    // iOS 自带 WKWebView 的 <input type=file> 选择器负责相册、拍照、文件。
    // 不重写仅在较新系统可用的 openPanel API，保持 iOS 16 兼容。
}
