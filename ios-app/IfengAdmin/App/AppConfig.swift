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
