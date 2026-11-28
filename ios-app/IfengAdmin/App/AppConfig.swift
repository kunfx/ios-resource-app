import Foundation

/// 全局集中配置。修改服务器默认地址、URL Scheme 时只需改这里与 Info.plist。
enum AppConfig {
    /// 自定义 URL Scheme，需与 Info.plist 的 CFBundleURLSchemes 一致。
    static let urlScheme = "ifengadmin"

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ifeng.admin"

    /// Keychain service 前缀。凭据按服务器 host 分账号保存，避免换服务器串号。
    static let keychainService = "com.ifeng.admin.session"

    /// 最近一次成功登录的服务器地址（UserDefaults）。
    static let lastServerDefaultsKey = "ifengadmin.lastServer"

    /// 默认后台地址：来自 Info.plist 的 DefaultServerURL（由工程配置提供），
    /// 不在多个源码文件里重复硬编码。
    static let defaultServer: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "DefaultServerURL") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "https://pgid.dpdns.org"
    }()

    /// 已退役的服务器地址。启动时如果发现本地还存着这些，就换回 `defaultServer`。
    ///
    /// 为什么需要这个：登录页的地址初值是
    /// `UserDefaults["ifengadmin.lastServer"] ?? defaultServer`，
    /// 只要用户曾经登录成功过一次，UserDefaults 里就有值，改 `defaultServer`
    /// 对老用户完全无效 —— 他们升级后登录页仍然显示旧域名。
    ///
    /// 这里只迁移**整个域名都退役**的情况。以后换域名往这个数组里加一项即可。
    static let retiredServers: [String] = [
        "https://p12.cc.cd"
    ]

    /// 若本地保存的地址已退役，就地改写成本次默认地址。
    /// 返回 true 表示发生了迁移（调用方可以在需要时记日志）。
    @discardableResult
    static func migrateRetiredServerIfNeeded() -> Bool {
        let key = lastServerDefaultsKey
        guard let saved = UserDefaults.standard.string(forKey: key),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = saved.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard retiredServers.contains(where: { $0.lowercased() == normalized }) else {
            return false
        }
        UserDefaults.standard.set(defaultServer, forKey: key)
        return true
    }

    /// 普通 JSON 请求超时（服务端预算约 10 秒）。
    static let requestTimeout: TimeInterval = 20
    /// 图片 multipart 上传超时（服务端预算约 45 秒）。
    static let uploadTimeout: TimeInterval = 70

    /// 「服务器是否活着」这类探测的硬上限。
    ///
    /// 启动恢复和登录都先打一次 `/api/v1/profile` 当探针。服务器关掉或域名失效时，
    /// 单纯等 `URLSession` 超时要走完 DNS + TCP 重试，实测可能二三十秒，
    /// 用户就干瞪着启动页。这里把探针压到 5 秒：连不上就立刻让用户看到
    /// 「无法连接服务器」和「更改服务器地址」，而不是继续干等。
    ///
    /// 注意只约束**探针**，不影响正常接口（拉消息、发图还是用 requestTimeout /
    /// uploadTimeout，免得慢网下正常请求被误杀）。
    static let probeTimeout: TimeInterval = 5

    /// SSE 流空闲超时；服务端每 15 秒心跳一次。
    static let streamIdleTimeout: TimeInterval = 60

    /// 消息接口每页条数。
    ///
    /// **这个值必须和服务端的 `store.MessagePageSize` 保持一致**
    /// （Go 常量是 35，客户端无法直接引用，只能人工同步）。
    /// 客户端用 `count >= pageSize` 推断「还有没有下一页」，
    /// 一旦两端不一致，翻页按钮要么永不消失、要么提前消失。
    static let pageSize = 35

    /// **会话列表**（左栏侧边栏）每页条数。
    ///
    /// 必须和服务端 `store.ConversationPageSize` 保持一致（当前 20）。
    ///
    /// 为什么单独设一个：它和 `pageSize`（会话内的消息条数）是两个
    /// 完全不同的维度。之前两者都是 20，所以代码里混用了同一个常量、
    /// 看不出问题；一旦把消息改成 35，会话列表用 `count >= 35` 判断
    /// 就会**永远为 false**，侧栏翻页会直接失效。
    static let conversationPageSize = 20

    // 注意：这里**没有**「首屏自动补几页 / 点一次拉几页」的配置。
    // 历史消息严格一页一页来：打开显示 `pageSize`（35）条，
    // 点一次「加载更早消息」再加 35 条。曾经的 `initialHistoryPages`
    // 会让首屏在后台静默补到 70 条，用户以为「分页没生效」，已经删掉。

    static let appDisplayName = "在线客服"

    // MARK: - 编译开关

    /// 是否优先使用 iOS 26 的官方 Liquid Glass。
    /// 万一某个 Xcode 版本的 SDK 签名有出入，把它改成 false 即可回退到材质实现，
    /// 不需要改其它任何代码。
    static let preferSystemLiquidGlass = true
}
