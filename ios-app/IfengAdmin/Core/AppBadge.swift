import Foundation
import UIKit
import UserNotifications

/// 桌面图标角标。
///
/// 只做一件事：把「会话列表里所有未读消息的总和」写到 iPhone 主屏图标的红点上。
///
/// 两个容易踩的点：
///
/// 1. **不需要远程推送也能有角标**。`UNUserNotificationCenter.setBadgeCount(_:)`
///    （iOS 16+）是本地 API，只要有通知授权就能用，不涉及 APNs。
///    这里只申请 `.badge` 权限，不申请 `.alert` / `.sound`，
///    用户不会收到任何通知横幅，界面也不会因此弹授权以外的打扰。
///
/// 2. **必须每次数据变化都重算**。角标是「全局汇总值」，不是单个会话的数字，
///    所以只要有任一会话未读数变了就要刷一次。调用点集中在
///    `ConversationListModel` 里（列表加载、刷新、事件合并之后）。
@MainActor
enum AppBadge {
    /// 是否已经请求过授权。`.badge` 权限只会弹一次系统弹窗。
    private static var didRequest = false
    /// 上一次写入的值，避免高频重复调用系统 API。
    private static var lastValue: Int = -1

    /// 申请角标权限。幂等，可以反复调用。
    static func requestAuthorizationIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { _, _ in }
    }

    /// 写入角标数字。传 0 等同于清空。
    static func set(_ count: Int) {
        let value = max(0, count)
        guard value != lastValue else { return }
        lastValue = value
        UNUserNotificationCenter.current().setBadgeCount(value) { error in
            // 失败时允许下次重试；不要因为一次失败就把 lastValue 永久占住。
            if error != nil {
                Task { @MainActor in lastValue = -1 }
            }
        }
    }

    /// 从一批会话里汇总未读数。
    static func totalUnread(_ conversations: [Conversation]) -> Int {
        conversations.reduce(0) { partial, conversation in
            partial + max(0, conversation.unreadCount ?? 0)
        }
    }

    /// 直接按会话列表刷新角标。
    static func update(conversations: [Conversation]) {
        set(totalUnread(conversations))
    }

    /// 退出登录 / 切账号时清空。
    static func clear() {
        set(0)
    }
}
