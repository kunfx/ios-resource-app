import SwiftUI
import UIKit

// MARK: - 主题

enum Theme {
    /// 主色（与网页后台默认蓝色接近，但不照搬网页布局）。
    static let accent = Color(red: 0.16, green: 0.45, blue: 0.94)
    static let bubbleIncoming = Color(uiColor: .secondarySystemBackground)
    static let bubbleOutgoing = Color(red: 0.16, green: 0.45, blue: 0.94)
    static let bubblePrivate = Color(red: 0.99, green: 0.93, blue: 0.72)
    static let danger = Color(uiColor: .systemRed)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    static let avatarColors: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 0.90),
        Color(red: 0.42, green: 0.70, blue: 0.55),
        Color(red: 0.86, green: 0.55, blue: 0.35),
        Color(red: 0.62, green: 0.48, blue: 0.82),
        Color(red: 0.30, green: 0.66, blue: 0.72),
        Color(red: 0.80, green: 0.45, blue: 0.55)
    ]
}

// MARK: - 玻璃质感

/// Liquid Glass 风格的兼容实现：半透明材质 + 柔和高光 + 描边 + 阴影。
/// iOS 16 起可用；不依赖 iOS 26 才有的系统玻璃 API，避免旧系统无法编译/运行。
struct GlassBackground<S: InsettableShape>: View {
    let shape: S
    var strong: Bool = false

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(strong ? 0.42 : 0.28),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.65), Color.white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 6)
    }
}

// MARK: - 圆形图标按钮

struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 34
    var iconSize: CGFloat = 15
    var foreground: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

// MARK: - 头像

struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 44

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        // 邮箱/订单号这类长字符串取前两个字符，保持与截图一致。
        let characters = Array(trimmed)
        if characters.count >= 2 {
            return String(characters.prefix(2)).uppercased()
        }
        return String(characters[0]).uppercased()
    }

    private var color: Color {
        // 用稳定的字符权重，避免 hashValue 每次启动变化导致颜色跳动。
        var seed = 0
        for scalar in name.unicodeScalars {
            seed = (seed &* 31 &+ Int(scalar.value)) & 0x7FFF_FFFF
        }
        return Theme.avatarColors[seed % Theme.avatarColors.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            Text(initials)
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(size * 0.12)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8))
    }
}

/// 管理员头像：服务端当前不提供头像地址，按交接说明使用占位图标。
struct AdminAvatar: View {
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(Color.secondary)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8))
    }
}

// MARK: - 未读角标

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 5 : 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Theme.danger))
    }
}

// MARK: - 时间格式（沿用网页的北京时间习惯）

enum TimeFormat {
    private static let zone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    private static let clockFormatter = formatter("HH:mm")
    private static let monthDayFormatter = formatter("M/d")
    private static let fullDayFormatter = formatter("yyyy/M/d")
    private static let dayLabelFormatter = formatter("yyyy年M月d日")

    static func date(_ seconds: Int?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// 会话列表右侧时间：今天显示 HH:mm，今年显示 M/d，更早显示 yyyy/M/d。
    static func listLabel(_ seconds: Int?) -> String {
        guard let date = date(seconds) else { return "" }
        let calendar = Calendar(identifier: .gregorian)
        var local = calendar
        local.timeZone = zone
        if local.isDateInToday(date) {
            return clockFormatter.string(from: date)
        }
        if local.component(.year, from: date) == local.component(.year, from: Date()) {
            return monthDayFormatter.string(from: date)
        }
        return fullDayFormatter.string(from: date)
    }

    static func clock(_ seconds: Int?) -> String {
        guard let date = date(seconds) else { return "" }
        return clockFormatter.string(from: date)
    }

    static func full(_ seconds: Int?) -> String {
        guard let date = date(seconds) else { return "未知" }
        return dayLabelFormatter.string(from: date) + " " + clockFormatter.string(from: date)
    }

    /// 聊天记录中的日期分隔：今天 / 昨天 / 具体日期。
    static func daySeparator(_ seconds: Int?) -> String {
        guard let date = date(seconds) else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return dayLabelFormatter.string(from: date)
    }

    static func isSameDay(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let left = date(lhs), let right = date(rhs) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(left, inSameDayAs: right)
    }
}
