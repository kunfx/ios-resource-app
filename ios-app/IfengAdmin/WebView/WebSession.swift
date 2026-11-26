import Combine
import Foundation
import Network
import UIKit
import WebKit

@MainActor
final class WebSession: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var configuration: AppConfiguration
    let webView: WKWebView
    @Published var isLoading = true
    @Published var progress = 0.0
    @Published var pageError: String?
    @Published var notice: String?
    @Published var downloadedFile: DownloadedFile?
    @Published var viewingAttachment = false

    private let dialogs = WebDialogs()
    private let downloads: DownloadManager
    private let monitor = NWPathMonitor()
    private var observations: [NSKeyValueObservation] = []
    private var started = false
    private var backgrounded = false
    @Published private(set) var loggedIn = false
    private var accountID: Int64?
    private var pendingTarget: ConversationTarget?
    private var routing = false
    private var rejectedAccount: Int64?
    private var wasOffline = false
    private let refreshControl = UIRefreshControl()

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.downloads = DownloadManager(configuration: configuration)
        let config = WKWebViewConfiguration()
        // default 数据存储保留 Cookie/LocalStorage。认证仍完全由网页处理。
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        WebSession.installScripts(configuration: configuration, controller: config.userContentController)
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.configuration.userContentController.add(WeakScriptHandler(self), name: "ifengAdmin")
        webView.navigationDelegate = self
        webView.uiDelegate = dialogs
        dialogs.session = self
        downloads.onComplete = { [weak self] in self?.downloadedFile = $0 }
        downloads.onError = { [weak self] in self?.notice = $0 }
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .white
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            }
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if online && self.wasOffline && UIApplication.shared.applicationState == .active {
                    if self.pageError != nil { self.reload() } else { self.resumePage() }
                }
                self.wasOffline = !online
            }
        }
        monitor.start(queue: DispatchQueue(label: "ifeng-admin.network"))
    }

    private static func installScripts(configuration: AppConfiguration, controller: WKUserContentController) {
        controller.removeAllUserScripts()
        if let url = Bundle.main.url(forResource: "AdminBridge", withExtension: "js"),
           let template = try? String(contentsOf: url, encoding: .utf8),
           let json = try? JSONEncoder().encode(configuration.origin.absoluteString),
           let encoded = String(data: json, encoding: .utf8) {
            controller.addUserScript(WKUserScript(
                source: template.replacingOccurrences(of: "__ADMIN_ORIGIN__", with: encoded),
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        if let scriptURL = Bundle.main.url(forResource: "MobileUI", withExtension: "js"),
           let styleURL = Bundle.main.url(forResource: "MobileUI", withExtension: "css"),
           let script = try? String(contentsOf: scriptURL, encoding: .utf8),
           let style = try? String(contentsOf: styleURL, encoding: .utf8),
           let encodedStyle = try? JSONEncoder().encode(style),
           let styleJSON = String(data: encodedStyle, encoding: .utf8) {
            // APP 专属界面资源，普通浏览器继续使用服务器原来的后台。
            controller.addUserScript(WKUserScript(
                source: script.replacingOccurrences(of: "__IFENG_CSS__", with: styleJSON),
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
    }

    func changeServer(_ input: String) {
        guard !loggedIn else { notice = "请先退出登录，再切换服务器。"; return }
        do {
            let next = try configuration.selectingServer(input)
            webView.stopLoading()
            downloads.changeServer(next)
            configuration = next
            configuration.rememberServer()
            Self.installScripts(configuration: next, controller: webView.configuration.userContentController)
            pendingTarget = nil
            accountID = nil
            rejectedAccount = nil
            routing = false
            notice = nil
            load(next.adminURL)
        } catch { notice = error.localizedDescription }
    }

    deinit {
        monitor.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !started else { return }
        started = true
        load(configuration.adminURL)
    }

    private func load(_ url: URL) {
        pageError = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        pageError = nil
        if let url = webView.url, configuration.isAdminPage(url) { webView.reload() }
        else { load(configuration.adminURL) }
    }

    @objc private func refresh() {
        // 软刷新触发现有同步流程，避免下拉操作清空未发送草稿。
        resumePage()
        refreshControl.endRefreshing()
    }

    @objc private func didEnterBackground() {
        backgrounded = true
    }

    func becomeActive() {
        guard started else { return }
        if backgrounded {
            backgrounded = false
            resumePage()
        }
        routeIfPossible()
    }

    private func resumePage() {
        guard let url = webView.url, configuration.isAdminPage(url) else { return }
        webView.evaluateJavaScript("window.IfengAdminBridge?.resume()") { _, _ in }
    }

    func receive(_ url: URL) {
        do {
            pendingTarget = try ConversationTarget.parse(url, scheme: configuration.scheme)
            rejectedAccount = nil
            notice = nil
            if let current = webView.url, !configuration.isAdminPage(current) {
                load(configuration.adminURL)
            }
            routeIfPossible()
        } catch LinkError.openHome {
            // 只唤醒：保留当前页面、连接和未发送文本。
            becomeActive()
        } catch { notice = error.localizedDescription }
    }

    private func routeIfPossible() {
        guard !routing, !isLoading, loggedIn, let current = accountID,
              let target = pendingTarget else { return }
        let account = target.accountID ?? current
        guard account == current else {
            if rejectedAccount != current {
                notice = "该通知属于其他账户。请在工作台退出，并登录对应账户后继续打开。"
                rejectedAccount = current
            }
            return
        }
        routing = true
        let script = "window.IfengAdminBridge?.openConversation({accountID:\(account),conversationID:\(target.conversationID)})"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            self.routing = false
            guard self.pendingTarget == target else { self.routeIfPossible(); return }
            guard error == nil else { self.notice = "页面暂未准备好，请稍后重新点击通知。"; return }
            switch result as? String {
            case "handled": self.pendingTarget = nil
            case "navigate": self.navigate(to: target, account: account)
            case "needs-confirmation":
                self.routing = true
                self.dialogs.confirmNavigation {
                    self.routing = false
                    guard self.pendingTarget == target else { self.routeIfPossible(); return }
                    if $0 { self.navigate(to: target, account: account) }
                    else { self.pendingTarget = nil }
                }
            default: break
            }
        }
    }

    private func navigate(to target: ConversationTarget, account: Int64) {
        pendingTarget = nil
        load(configuration.conversationURL(accountID: account, conversationID: target.conversationID))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ifengAdmin", message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, configuration.isAdminPage(url),
              let data = message.body as? [String: Any], data["type"] as? String == "state" else { return }
        loggedIn = data["loggedIn"] as? Bool == true
        accountID = (data["accountID"] as? NSNumber).flatMap { ConversationTarget.positiveID($0.stringValue) }
        if data["routeError"] as? Bool == true {
            notice = "无法打开通知会话：会话可能不存在、无访问权限，或网络暂时不可用。"
        }
        routeIfPossible()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        pageError = nil
        loggedIn = false
        accountID = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
        refreshControl.endRefreshing()
        viewingAttachment = webView.url.map { !configuration.isAdminPage($0) } ?? false
        routeIfPossible()
    }

    private func failed(_ error: Error) {
        isLoading = false
        refreshControl.endRefreshing()
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || ((error as NSError).domain == "WebKitErrorDomain" && code == 102) { return }
        pageError = "请检查网络连接、后台地址和 HTTPS 证书，然后重试。"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        pageError = "网页进程已被系统释放，请重新加载。已登录的本地存储仍会保留；未发送草稿可能已丢失。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let user = navigationAction.navigationType == .linkActivated
        switch NavigationPolicy(configuration: configuration).destination(for: url, userInitiated: user) {
        case .internalPage:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .localPreview: decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .externalBrowser, .externalApplication:
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:]) { [weak self] success in
                if !success { self?.notice = "无法打开这个外部链接。" }
            }
        case .blocked:
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false { notice = "已阻止不安全或非用户发起的外部跳转。" }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            isLoading = false
            pageError = "后台页面加载失败（HTTP \(response.statusCode)），请检查地址和服务器状态。"
            decisionHandler(.cancel)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        isLoading = false
        downloads.accept(download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        isLoading = false
        downloads.accept(download)
    }

    func returnToWorkspace() {
        if webView.canGoBack { webView.goBack() } else { load(configuration.adminURL) }
    }

    func downloadCurrentPage() {
        guard let url = webView.url, configuration.owns(url), !configuration.isAdminPage(url) else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.downloads.accept(download)
        }
    }

    func openNewWindow(_ action: WKNavigationAction) {
        // 让同源新窗口继续由原 WKWebView 的导航策略检查。
        webView.load(action.request)
    }
}
