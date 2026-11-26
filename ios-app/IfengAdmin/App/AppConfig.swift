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
        return "https://p12.cc.cd"
    }()

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

    /// 会话与消息接口每页固定 20 条，服务端不支持自定义 page size。
    static let pageSize = 20

    static let appDisplayName = "在线客服"

    // MARK: - 编译开关

    /// 是否优先使用 iOS 26 的官方 Liquid Glass。
    /// 万一某个 Xcode 版本的 SDK 签名有出入，把它改成 false 即可回退到材质实现，
    /// 不需要改其它任何代码。
    static let preferSystemLiquidGlass = true
}
