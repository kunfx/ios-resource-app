import Foundation
import Combine
import SwiftUI

/// `ifengadmin://conversation/123?account_id=2` 解析与校验。
struct DeepLink {
    let conversationId: Int
    let accountId: Int?

    static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.scheme?.lowercased() == AppConfig.urlScheme else { return nil }
        var segments: [String] = []
        if let host = components.host?.lowercased(), !host.isEmpty {
            segments.append(host)
        }
        segments.append(contentsOf: components.path.split(separator: "/").map(String.init))
        guard segments.count == 2, segments[0].lowercased() == "conversation" else { return nil }
        guard let conversationId = Int(segments[1]), conversationId > 0 else { return nil }
        var accountId: Int?
        for item in components.queryItems ?? [] {
            // 只接受 account_id，其它参数一律视为非法链接。
            guard item.name == "account_id",
                  let raw = item.value,
                  let value = Int(raw), value > 0 else { return nil }
            accountId = value
        }
        return DeepLink(conversationId: conversationId, accountId: accountId)
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case launching
        case login
        case ready
        case unreachable(String)
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var session: AppSession?
    /// SSE 流是否已握手成功。仅用于「同步中」这类状态文案，**不要**拿它判断能否免轮询。
    @Published private(set) var realtimeConnected = false
    /// 实时通道是否真的可用（已握手 + 近期还在收字节）。
    /// 轮询兜底的开关只看这一个值，避免「连接假装活着、事件一个不来」时界面静止。
    @Published private(set) var realtimeHealthy = false
    @Published var banner: String?
    /// 深链待打开的会话；RootView 消费后置空。
    @Published var pendingConversationId: Int?

    /// 实时事件总线：会话列表与聊天页各自订阅。
    let events = PassthroughSubject<RealtimeEvent, Never>()

    private var realtime: RealtimeClient?
    private var pendingDeepLink: DeepLink?
    private var didRestore = false

    // MARK: 启动恢复

    func restoreIfNeeded() async {
        guard !didRestore else { return }
        didRestore = true
        await restore()
    }

    func restore() async {
        phase = .launching
        let raw = UserDefaults.standard.string(forKey: AppConfig.lastServerDefaultsKey) ?? AppConfig.defaultServer
        guard let server = ServerAddress.parse(raw) else {
            phase = .login
            return
        }
        guard let stored = StoredSession.load(host: server.host) else {
            phase = .login
            return
        }
        let api = APIClient(server: server, credentials: stored.credentials, accountId: stored.accountId)
        do {
            let profile = try await api.profile()
            let session = AppSession(
                server: server,
                credentials: stored.credentials,
                profile: profile,
                api: api.withAccount(profile.accountId)
            )
            StoredSession(
                credentials: stored.credentials,
                accountId: profile.accountId,
                profileName: profile.bestName,
                profileEmail: profile.email
            ).save(host: server.host)
            self.session = session
            phase = .ready
            startRealtime()
            applyPendingDeepLink()
        } catch let error as APIError {
            if error.isAuthFailure {
                // 401 才清理凭据；离线/超时不能当成密码失效。
                StoredSession.remove(host: server.host)
                phase = .login
            } else if error.isRetryable {
                phase = .unreachable(error.message)
            } else {
                phase = .login
            }
        } catch {
            phase = .unreachable("无法连接服务器，请检查网络。")
        }
    }

    // MARK: 登录 / 退出

    func login(serverText: String, email: String, password: String) async -> String? {
        guard let server = ServerAddress.parse(serverText) else {
            return "服务器地址无效。请填写 https:// 开头的根域名，不要带路径、参数或账号密码。"
        }
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { return "请输入用户名（邮箱）。" }
        guard !password.isEmpty else { return "请输入密码。" }

        do {
            let (credentials, profile) = try await APIClient.login(server: server, email: account, password: password)
            UserDefaults.standard.set(server.origin, forKey: AppConfig.lastServerDefaultsKey)
            StoredSession(
                credentials: credentials,
                accountId: profile.accountId,
                profileName: profile.bestName,
                profileEmail: profile.email
            ).save(host: server.host)
            let api = APIClient(server: server, credentials: credentials, accountId: profile.accountId)
            session = AppSession(server: server, credentials: credentials, profile: profile, api: api)
            phase = .ready
            startRealtime()
            applyPendingDeepLink()
            return nil
        } catch let error as APIError {
            return error.message
        } catch {
            return "登录失败，请稍后重试。"
        }
    }

    func logout() async {
        realtime?.reset()
        realtime = nil
        realtimeConnected = false
        realtimeHealthy = false
        if let session = self.session {
            // 服务端撤销会话失败不影响本机退出，但本机凭据必须清理。
            try? await session.api.logout()
            StoredSession.remove(host: session.server.host)
        }
        session = nil
        pendingConversationId = nil
        phase = .login
    }

    /// 会话失效（401）统一处理。
    func handleAuthFailure() {
        guard let session = self.session else {
            phase = .login
            return
        }
        realtime?.reset()
        realtime = nil
        realtimeConnected = false
        realtimeHealthy = false
        StoredSession.remove(host: session.server.host)
        self.session = nil
        banner = "登录已失效，请重新登录。"
        phase = .login
    }

    // MARK: 实时

    private func startRealtime() {
        guard let session = self.session else { return }
        if realtime == nil {
            realtime = RealtimeClient(
                onEvent: { [weak self] event in
                    self?.events.send(event)
                },
                onResync: { [weak self] in
                    self?.events.send(RealtimeEvent(kind: .resyncRequired))
                },
                onAuthFailure: { [weak self] in
                    self?.handleAuthFailure()
                },
                onConnectionChange: { [weak self] connected in
                    self?.realtimeConnected = connected
                },
                onHealthChange: { [weak self] healthy in
                    self?.realtimeHealthy = healthy
                }
            )
        }
        realtime?.start(api: session.api)
    }

    func handleScenePhase(_ newPhase: ScenePhase) {
        guard phase == .ready, session != nil else { return }
        switch newPhase {
        case .active:
            startRealtime()
            // 回前台补拉一次快照，避免后台期间漏掉事件。
            events.send(RealtimeEvent(kind: .resyncRequired))
        case .background, .inactive:
            // iOS 后台不保证 SSE 持续可用，主动断开更省电。
            realtime?.stop()
        @unknown default:
            break
        }
    }

    // MARK: 深链

    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard let target = DeepLink.parse(url) else { return false }
        guard let session = self.session else {
            pendingDeepLink = target
            return true
        }
        if let accountId = target.accountId, accountId != session.accountId {
            banner = "该会话不属于当前账户（账户 #\(accountId)），已忽略。"
            return true
        }
        pendingConversationId = target.conversationId
        return true
    }

    private func applyPendingDeepLink() {
        guard let target = pendingDeepLink else { return }
        pendingDeepLink = nil
        if let accountId = target.accountId, let session = self.session, accountId != session.accountId {
            banner = "该会话不属于当前账户（账户 #\(accountId)），已忽略。"
            return
        }
        pendingConversationId = target.conversationId
    }
}
