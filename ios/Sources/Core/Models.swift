import Foundation

// MARK: - 统一返回信封

struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let message: String?
    let data: T?
}

struct ServerErrorBody: Decodable {
    let success: Bool?
    let message: String?
}

struct EmptyPayload: Decodable {
    let ok: Bool?
}

// MARK: - 分页

struct Page<T: Decodable>: Decodable {
    let items: [T]
    let page: Int
    let perPage: Int
    let total: Int
    let lastPage: Int

    enum CodingKeys: String, CodingKey {
        case items, page, total
        case perPage = "per_page"
        case lastPage = "last_page"
    }

    var hasMore: Bool { page < lastPage }
}

// MARK: - 用户

struct User: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let email: String
    let avatar: String?
    let points: Int
    let vipLevel: Int
    let vipLabel: String
    let isVip: Bool
    let vipExpiredText: String?
    let isAdmin: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, email, avatar, points
        case vipLevel = "vip_level"
        case vipLabel = "vip_label"
        case isVip = "is_vip"
        case vipExpiredText = "vip_expired_text"
        case isAdmin = "is_admin"
    }
}

struct ProfileStats: Codable, Hashable {
    let freeLimit: Int
    let freeUsed: Int
    let freeLeft: Int
    let isUnlimited: Bool
    let unreadMessages: Int
    let downloadsTotal: Int

    enum CodingKeys: String, CodingKey {
        case freeLimit = "free_limit"
        case freeUsed = "free_used"
        case freeLeft = "free_left"
        case isUnlimited = "is_unlimited"
        case unreadMessages = "unread_messages"
        case downloadsTotal = "downloads_total"
    }
}

struct ProfilePayload: Codable {
    let user: User
    let stats: ProfileStats
}

struct LoginPayload: Codable {
    let token: String
    let tokenType: String
    let expiresAt: String?
    let user: User

    enum CodingKeys: String, CodingKey {
        case token, user
        case tokenType = "token_type"
        case expiresAt = "expires_at"
    }
}

// MARK: - 分类

struct CategoryBrief: Codable, Hashable {
    let id: Int
    let name: String
    let slug: String?
}

struct CategoryRef: Codable, Hashable {
    let id: Int
    let name: String
    let slug: String?
    let parent: CategoryBrief?
}

struct CategoryNode: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let slug: String?
    let children: [CategoryNode]

    enum CodingKeys: String, CodingKey {
        case id, name, slug, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        children = try container.decodeIfPresent([CategoryNode].self, forKey: .children) ?? []
    }
}

// MARK: - 资源

struct AppItem: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let version: String?
    let size: String?
    let shortDescription: String?
    let pointsRequired: Int
    let views: Int
    let category: CategoryRef?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, version, size, views, category
        case shortDescription = "short_description"
        case pointsRequired = "points_required"
        case updatedAt = "updated_at"
    }

    var isFree: Bool { pointsRequired <= 0 }
}

struct DownloadLink: Codable, Hashable, Identifiable {
    let title: String
    let type: String?
    let url: String?
    let locked: Bool

    var id: String { "\(title)#\(type ?? "")#\(url ?? "locked")" }
}

struct CommentAuthor: Codable, Hashable {
    let id: Int
    let name: String
    let avatar: String?
}

struct AppComment: Codable, Identifiable, Hashable {
    let id: Int
    let content: String
    let createdAt: String?
    let user: CommentAuthor?

    enum CodingKeys: String, CodingKey {
        case id, content, user
        case createdAt = "created_at"
    }
}

struct AppDetail: Codable, Identifiable {
    let id: Int
    let name: String
    let icon: String?
    let version: String?
    let size: String?
    let shortDescription: String?
    let pointsRequired: Int
    let views: Int
    let category: CategoryRef?
    let updatedAt: String?
    let modInfo: String?
    let description: String?
    let screenshots: [String]
    let downloadLinks: [DownloadLink]
    let isUnlocked: Bool
    let isVipFree: Bool
    let comments: [AppComment]
    let commentCount: Int
    let related: [AppItem]

    enum CodingKeys: String, CodingKey {
        case id, name, icon, version, size, views, category, description, screenshots, comments, related
        case shortDescription = "short_description"
        case pointsRequired = "points_required"
        case updatedAt = "updated_at"
        case modInfo = "mod_info"
        case downloadLinks = "download_links"
        case isUnlocked = "is_unlocked"
        case isVipFree = "is_vip_free"
        case commentCount = "comment_count"
    }

    var isFree: Bool { pointsRequired <= 0 }
}

// MARK: - 下载结果

struct DownloadResult: Codable {
    let status: String
    let message: String?
    let costType: String?
    let pointsRequired: Int?
    let pointsSpent: Int?
    let userPoints: Int?
    let freeLeft: Int?
    let downloadLinks: [DownloadLink]?

    enum CodingKeys: String, CodingKey {
        case status, message
        case costType = "cost_type"
        case pointsRequired = "points_required"
        case pointsSpent = "points_spent"
        case userPoints = "user_points"
        case freeLeft = "free_left"
        case downloadLinks = "download_links"
    }

    var isReady: Bool { status == "DOWNLOAD_READY" || status == "REPEAT_DOWNLOAD" }
    var needsConfirm: Bool { status == "REQUIRE_CONFIRM" }
}

// MARK: - 文章

struct Article: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let summary: String?
    let cover: String?
    let views: Int
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, cover, views
        case publishedAt = "published_at"
    }
}

struct ArticleDetail: Codable, Identifiable {
    let id: Int
    let title: String
    let summary: String?
    let cover: String?
    let content: String?
    let views: Int
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, cover, content, views
        case publishedAt = "published_at"
    }
}

// MARK: - 消息 / 积分

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let body: String?
    let url: String?
    let isRead: Bool
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body, url
        case isRead = "is_read"
        case createdAt = "created_at"
    }
}

struct PointLog: Codable, Identifiable, Hashable {
    let id: Int
    let type: String
    let action: Int
    let points: Int
    let beforePoints: Int
    let afterPoints: Int
    let description: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, action, points, description
        case beforePoints = "before_points"
        case afterPoints = "after_points"
        case createdAt = "created_at"
    }

    var isIncome: Bool { action != 2 }
}
