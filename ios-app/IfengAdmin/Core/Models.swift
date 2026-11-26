import Foundation

// MARK: - 宽松 JSON 值

/// 用于承载不参与业务逻辑、但可能出现在响应里的字段，避免未知结构导致整体解码失败。
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - 账户与个人资料

struct Account: Codable, Hashable, Identifiable {
    var id: Int
    var name: String?
    var role: String?
}

/// GET /api/v1/profile 直接返回该对象；登录接口包在 data 里。
struct Profile: Codable, Hashable {
    var id: Int
    var name: String?
    var displayName: String?
    var email: String?
    var accountId: Int
    var role: String?
    var avatarUrl: String?
    var accounts: [Account]?

    var bestName: String {
        let candidates = [displayName, name, email]
        for candidate in candidates {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return "管理员"
    }
}

// MARK: - 访客

struct Contact: Codable, Hashable {
    var id: Int
    var name: String?
    var identifier: String?
    var email: String?
    var phoneNumber: String?
    var thumbnail: String?
}

struct Sender: Codable, Hashable {
    var id: Int?
    var name: String?
    var email: String?
    var avatarUrl: String?
    var type: String?
    var availabilityStatus: String?
}

/// 会话级访客采集快照（不是实时 GPS，也不是身份凭据）。
struct VisitorDetails: Codable, Hashable {
    var ipAddress: String?
    var city: String?
    var region: String?
    var country: String?
    var countryCode: String?
    var sourceUrl: String?
    var operatingSystem: String?
    var browser: String?
    var language: String?
    var recordedAt: Int?

    var locationText: String {
        let parts = [city, region, country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "位置未知" : unique.joined(separator: " · ")
    }

    /// 由 ISO 国家码生成旗帜 emoji，缺失时返回 nil。
    var flagEmoji: String? {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
        var scalars = String.UnicodeScalarView()
        for character in code.unicodeScalars {
            guard let scalar = UnicodeScalar(127397 + character.value) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

// MARK: - 会话

struct ConversationMeta: Codable, Hashable {
    var sender: Contact?
    var assignee: Sender?
    var assigneeType: String?
    var channel: String?
}

struct Conversation: Codable, Hashable, Identifiable {
    var id: Int
    var accountId: Int?
    var inboxId: Int?
    var status: String?
    var unreadCount: Int?
    var createdAt: Int?
    var updatedAt: Int?
    var lastActivityAt: Int?
    var visitorMessagesBlocked: Bool?
    var canReply: Bool?
    var inboxAvatarUrl: String?
    var inboxGreetingAvatarUrl: String?
    var meta: ConversationMeta?
    var visitorDetails: VisitorDetails?
    var lastNonActivityMessage: Message?
    var messages: [Message]?
    var additionalAttributes: JSONValue?

    /// 深链或列表跳转时先构造一个只有 ID 的占位对象，随后由详情接口覆盖。
    init(id: Int) {
        self.id = id
    }

    var visitorName: String {
        let raw = meta?.sender?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "访客 #\(id)" : raw
    }

    var isResolved: Bool { status == "resolved" }
    var isBlocked: Bool { visitorMessagesBlocked ?? false }

    /// 列表里展示的最后一条消息：优先 last_non_activity_message，回退到 messages 的最后一条。
    var previewMessage: Message? {
        if let message = lastNonActivityMessage { return message }
        return messages?.last
    }

    var activityTimestamp: Int {
        lastActivityAt ?? updatedAt ?? createdAt ?? 0
    }
}

struct ConversationPage: Codable {
    struct Meta: Codable, Hashable {
        var mineCount: Int?
        var unassignedCount: Int?
        var allCount: Int?
    }
    struct Body: Codable {
        var meta: Meta?
        var payload: [Conversation]
    }
    var data: Body
}

// MARK: - 消息

struct Attachment: Codable, Hashable, Identifiable {
    var id: Int
    var messageId: Int?
    var fileType: String?
    var contentType: String?
    var fileSize: Int?
    var width: Int?
    var height: Int?
    var name: String?
    /// 服务端签名的完整 URL（含 cap），约 24 小时过期，失效需重新 GET 消息。
    var dataUrl: String?
    var thumbUrl: String?

    var isImage: Bool { (fileType ?? "image") == "image" }
}

/// 消息投递状态。判定规则与网页后台 web/messages.js 的 deliveryStatus 完全一致。
enum MessageDeliveryState {
    case failed
    case sending
    case sent
    case read

    var iconName: String {
        switch self {
        case .failed: return "circle-alert"
        case .sending: return "clock"
        case .sent: return "check"
        case .read: return "check-check"
        }
    }

    var label: String {
        switch self {
        case .failed: return "发送失败"
        case .sending: return "发送中"
        case .sent: return "已发送"
        case .read: return "对方已读"
        }
    }

    /// 只有「对方明确回执」才是蓝色双勾。
    var isRead: Bool { self == .read }
}

struct Message: Codable, Hashable, Identifiable {
    var id: Int
    var accountId: Int?
    var inboxId: Int?
    var conversationId: Int?
    var content: String?
    var contentType: String?
    /// 0 访客、1 客服、2 系统活动、3 模板/自动消息。
    var messageType: Int?
    var isPrivate: Bool?
    var status: String?
    var readAt: Int?
    var createdAt: Int?
    var senderId: Int?
    var senderType: String?
    var sender: Sender?
    var echoId: String?
    var attachments: [Attachment]?
    var contentAttributes: JSONValue?
    /// 编辑时间（秒）。0 表示没有编辑过。
    var editedAt: Int?
    /// 撤回时间（秒）。大于 0 时正文与附件都不再返回。
    var recalledAt: Int?

    var type: MessageType { MessageType(rawValue: messageType ?? 1) ?? .agent }
    var isPrivateNote: Bool { isPrivate ?? false }
    var images: [Attachment] { (attachments ?? []).filter { $0.isImage } }
    var text: String { content ?? "" }
    var isRecalled: Bool { (recalledAt ?? 0) > 0 }
    var isEdited: Bool { !isRecalled && (editedAt ?? 0) > 0 }

    /// 只对自己发出的客服消息显示投递状态。
    /// 注意不能用 `readAt != nil || status == "read"` 这种宽松判断，
    /// 服务端在消息创建时就会写入 status='sent'，只有对方回执才会变成 read + read_at。
    var deliveryState: MessageDeliveryState? {
        guard type == .agent, !isRecalled else { return nil }
        if status == "failed" { return .failed }
        if status == "sending" { return .sending }
        if !isPrivateNote, status == "read", (readAt ?? 0) > 0 { return .read }
        if let status, status == "sent" || status == "delivered" || status == "read" { return .sent }
        return nil
    }

    /// 与后端 store.mutateMessage 的权限规则保持一致：只能改自己发出的、
    /// 未撤回的消息；带图片的消息不能编辑（正文与附件会对不上）。
    func canEdit(viewerId: Int?) -> Bool {
        guard type == .agent, !isRecalled else { return false }
        guard let viewerId, let senderId, viewerId == senderId else { return false }
        guard images.isEmpty else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canRecall(viewerId: Int?) -> Bool {
        guard type == .agent, !isRecalled else { return false }
        guard let viewerId, let senderId, viewerId == senderId else { return false }
        return !text.isEmpty || !images.isEmpty
    }
}

enum MessageType: Int {
    case incoming = 0
    case agent = 1
    case activity = 2
    case template = 3
}

struct MessagePage: Codable {
    struct Meta: Codable {
        var contact: Contact?
        var assignee: Sender?
        var agentLastSeenAt: Int?
    }
    var meta: Meta?
    var payload: [Message]
}

/// GET/POST .../message_receipts 的 payload 元素。
struct MessageReceipt: Codable, Hashable {
    var id: Int
    var status: String?
    var readAt: Int?
}

struct MessageReceiptPage: Codable {
    var payload: [MessageReceipt]
    var conversationId: Int?
}

/// GET .../typing_status 的响应。actors 里是正在输入的一方（管理员看访客、访客看客服）。
struct TypingActor: Codable, Hashable {
    var id: Int?
    var type: String?
    var name: String?
    var updatedAt: Int?
    var expiresAt: Int?
}

struct TypingStatus: Codable {
    var typing: Bool
    var actors: [TypingActor]?
}

// MARK: - 收件箱

struct Inbox: Codable, Hashable, Identifiable {
    var id: Int
    var name: String?
    var channelType: String?
    var websiteUrl: String?
    var avatarUrl: String?
    var greetingAvatarUrl: String?
    var businessName: String?

    var displayName: String {
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "收件箱 #\(id)" : raw
    }

    var websiteHost: String? {
        guard let raw = websiteUrl, let url = URL(string: raw), let host = url.host else { return nil }
        return host
    }
}

struct InboxListEnvelope: Codable {
    var payload: [Inbox]
}

// MARK: - Bark

struct BarkSettings: Codable, Hashable {
    var enabled: Bool
    var hasKey: Bool
}

// MARK: - 实时

struct RealtimeTicket: Codable {
    var ticket: String
    var expiresIn: Int?
    var eventsUrl: String?
}

/// 从 SSE 摘要解析出的轻量事件。
struct RealtimeEvent {
    enum Kind: String {
        case messageCreated = "message.created"
        case messageUpdated = "message.updated"
        case messageRead = "message.read"
        case conversationRead = "conversation.read"
        case conversationStatusChanged = "conversation.status_changed"
        case conversationUpdated = "conversation.updated"
        case typingOn = "typing_on"
        case typingOff = "typing_off"
        case connected = "realtime.connected"
        case resyncRequired = "realtime.resync_required"
        case error = "realtime.error"
        case unknown
    }

    let kind: Kind
    let rawKind: String
    let conversationId: Int?
    let messageId: Int?
    let messageType: Int?
    let status: String?
    let readAt: Int?
    let errorCode: String?
    /// conversation.read 专用：这个用户的最新未读数与水位时间。
    let unreadCount: Int?
    let userId: Int?
    let agentLastSeenAt: Int?
    /// message.read 专用：是谁读的（`visitor` / `agent`）。
    /// 由 007 迁移的 `realtime_message_update` 触发器写入：`message_type=1` 记 `visitor`。
    let readerType: String?
    // typing 专用
    let actorType: String?
    let actorKey: String?
    let actorName: String?
    let leaseMs: Int?
    let typingMode: String?

    init(kind: String, payload: Data) {
        self.rawKind = kind
        self.kind = Kind(rawValue: kind) ?? .unknown
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        self.conversationId = RealtimeEvent.intValue(object?["conversation_id"])
        self.messageId = RealtimeEvent.intValue(object?["message_id"])
        self.messageType = RealtimeEvent.intValue(object?["message_type"])
        self.status = object?["status"] as? String
        self.readAt = RealtimeEvent.intValue(object?["read_at"])
        self.errorCode = object?["code"] as? String
        self.unreadCount = RealtimeEvent.intValue(object?["unread_count"])
        self.userId = RealtimeEvent.intValue(object?["user_id"])
        self.agentLastSeenAt = RealtimeEvent.intValue(object?["agent_last_seen_at"])
        self.readerType = object?["reader_type"] as? String
        self.actorType = object?["actor_type"] as? String
        self.actorKey = object?["actor_key"] as? String
        self.actorName = object?["name"] as? String
        self.leaseMs = RealtimeEvent.intValue(object?["lease_ms"])
        self.typingMode = object?["typing_mode"] as? String
    }

    init(kind: Kind) {
        self.kind = kind
        self.rawKind = kind.rawValue
        self.conversationId = nil
        self.messageId = nil
        self.messageType = nil
        self.status = nil
        self.readAt = nil
        self.errorCode = nil
        self.unreadCount = nil
        self.userId = nil
        self.agentLastSeenAt = nil
        self.readerType = nil
        self.actorType = nil
        self.actorKey = nil
        self.actorName = nil
        self.leaseMs = nil
        self.typingMode = nil
    }

    /// JSONSerialization 的数字可能是 Int / Double / NSNumber，统一取整。
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
