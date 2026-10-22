import Foundation
import Combine

/// 登录态、用户资料、额度统计的唯一来源。
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var stats: ProfileStats?
    @Published private(set) var isRestoring = true

    private let tokenKey = "appku.access_token"

    var isLoggedIn: Bool { user != nil }
    var points: Int { user?.points ?? 0 }

    init() {
        APIClient.shared.onUnauthorized = { [weak self] in
            Task { @MainActor in
                self?.clearLocalSession()
            }
        }
    }

    /// 启动时恢复 Keychain 里的 token，并静默刷新一次资料
    func bootstrap() async {
        defer { isRestoring = false }

        guard let saved = KeychainStore.read(tokenKey), !saved.isEmpty else {
            return
        }

        APIClient.shared.token = saved
        await refreshProfile(silent: true)
    }

    func login(email: String, password: String) async throws {
        let payload: LoginPayload = try await APIClient.shared.post("/api/login", body: [
            "email": email,
            "password": password,
            "device_name": "iPhone"
        ])

        KeychainStore.save(payload.token, for: tokenKey)
        APIClient.shared.token = payload.token
        user = payload.user

        await refreshProfile(silent: true)
    }

    func refreshProfile(silent: Bool = false) async {
        guard APIClient.shared.token != nil else { return }

        do {
            let payload: ProfilePayload = try await APIClient.shared.get("/api/user/profile")
            user = payload.user
            stats = payload.stats
        } catch {
            if !silent {
                // 401 由 onUnauthorized 统一处理，这里只忽略其它错误，避免打断浏览
                return
            }
        }
    }

    func logout() async {
        try? await APIClient.shared.postIgnoringData("/api/logout")
        clearLocalSession()
    }

    func clearLocalSession() {
        KeychainStore.delete(tokenKey)
        APIClient.shared.token = nil
        user = nil
        stats = nil
    }

    /// 切换服务器地址后需要重置一切本地状态
    func resetForNewServer() {
        clearLocalSession()
    }
}
