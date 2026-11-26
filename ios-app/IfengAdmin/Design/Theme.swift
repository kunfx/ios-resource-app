import SwiftUI
import UIKit

// MARK: - 全局字号

extension Font {
    /// 界面字号的统一入口：**在调用方给的尺寸上 +1**。
    ///
    /// 全部界面文字都写成 `.font(.app(size: 12))`，想整体调大/调小只改这里的
    /// `+ 1`，不用去每个 View 里找数字。语义字号（`.caption` / `.headline`）
    /// 仍然直接用系统值，它们本来就跟随动态字体。
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size + 1, weight: weight)
    }

    static func app(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design) -> Font {
        .system(size: size + 1, weight: weight, design: design)
    }
}

// MARK: - 主题

enum Theme {
    /// 主色（与网页后台默认蓝色接近，但不照搬网页布局）。
    static let accent = Color(red: 0.16, green: 0.45, blue: 0.94)

    // MARK: 消息气泡（严格对齐 web/messages.css）

    /// 对方消息：#ebebeb + #1f2937 文字（网页 .chat-bubble 默认态）。
    static let bubbleIncoming = Color(red: 0.922, green: 0.922, blue: 0.922)
    static let bubbleIncomingText = Color(red: 0.122, green: 0.161, blue: 0.216)
    /// 深色模式沿用网页后台暗色主题的 --hover / --text。
    static let bubbleIncomingDark = Color(red: 0.192, green: 0.204, blue: 0.216)
    static let bubbleIncomingTextDark = Color(red: 0.933, green: 0.945, blue: 0.965)

    /// 自己消息：#1677ff + 白色文字（网页 .chat-message.is-right .chat-bubble）。
    static let bubbleOutgoing = Color(red: 0.086, green: 0.467, blue: 1.0)
    static let bubbleOutgoingText = Color.white
    /// 内部备注保持琥珀色，一眼能和普通回复区分。
    static let bubblePrivate = Color(red: 0.99, green: 0.93, blue: 0.72)

    static let danger = Color(uiColor: .systemRed)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    /// 聊天区背景：网页的消息区是纯白，气泡 #ebebeb 才能显出层次；
    /// 用分组灰会和气泡糊在一起。
    static let chatBackground = Color(uiColor: .systemBackground)

    /// 已读回执的蓝色（与网页 .chat-delivery-state.state-read 完全一致）。
    static let receiptRead = Color(red: 0.231, green: 0.510, blue: 0.965)   // #3B82F6
    /// 已发送的灰色（与网页 .chat-delivery-state 默认色一致）。
    static let receiptSent = Color(red: 0.612, green: 0.639, blue: 0.686)   // #9CA3AF

    static let avatarColors: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 0.90),
        Color(red: 0.42, green: 0.70, blue: 0.55),
        Color(red: 0.86, green: 0.55, blue: 0.35),
        Color(red: 0.62, green: 0.48, blue: 0.82),
        Color(red: 0.30, green: 0.66, blue: 0.72),
        Color(red: 0.80, green: 0.45, blue: 0.55)
    ]
}

// MARK: - 气泡形状（四个圆角可不同）

/// 复刻网页的气泡圆角：
/// 左侧 `border-radius: 3px 14px 14px 14px`，右侧 `14px 3px 14px 14px`。
/// `UnevenRoundedRectangle` 要 iOS 17，这里自己画，保证 iOS 16 也能用。
struct BubbleShape: Shape, InsettableShape {
    var topLeading: CGFloat = 14
    var topTrailing: CGFloat = 14
    var bottomLeading: CGFloat = 14
    var bottomTrailing: CGFloat = 14
    /// `strokeBorder` 需要 InsettableShape，这里按边内缩，圆角同步收小。
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> BubbleShape {
        var copy = self
        copy.insetAmount += amount
        copy.topLeading = max(0, topLeading - amount)
        copy.topTrailing = max(0, topTrailing - amount)
        copy.bottomLeading = max(0, bottomLeading - amount)
        copy.bottomTrailing = max(0, bottomTrailing - amount)
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }
        let limit = min(box.width, box.height) / 2
        let tl = min(topLeading, limit)
        let tr = min(topTrailing, limit)
        let bl = min(bottomLeading, limit)
        let br = min(bottomTrailing, limit)

        var path = Path()
        path.move(to: CGPoint(x: box.minX + tl, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - tr, y: box.minY))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: box.maxX - tr, y: box.minY + tr),
                radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: box.maxX - br, y: box.maxY - br),
                radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: box.minX + bl, y: box.maxY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: box.minX + bl, y: box.maxY - bl),
                radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: box.minX + tl, y: box.minY + tl),
                radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 玻璃质感

/// 兼容实现：半透明材质 + 柔和高光 + 描边 + 阴影。iOS 16 起可用。
/// 不依赖 iOS 26 才有的系统玻璃 API，旧系统与旧 Xcode 都能编译运行。
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

/// 玻璃表面：iOS 26 及以上优先用苹果官方 Liquid Glass（`glassEffect`），
/// 更早的系统自动回退到材质实现。
///
/// 之所以要 `#if compiler(>=6.2)`：`glassEffect` 是 iOS 26 SDK 才有的符号，
/// 用 Xcode 16 编译时必须整段跳过，否则会直接编译失败。
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var strong: Bool = false

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), AppConfig.preferSystemLiquidGlass {
            Color.clear
                .glassEffect(.regular, in: shape)
        } else {
            GlassBackground(shape: shape, strong: strong)
        }
        #else
        GlassBackground(shape: shape, strong: strong)
        #endif
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
                .font(.app(size: size * 0.34, weight: .medium))
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
            LucideIcon(name: "user-round", size: size * 0.46, color: Color.secondary)
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
            .font(.app(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 5 : 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Theme.danger))
    }
}

// MARK: - 正在输入气泡

/// 三点跳动的「正在输入」气泡，形态与网页的 .typing-bubble 一致：
/// 浅灰气泡 + 1px 柔边 + 轻微投影，保证在分组背景上也能看出是一个气泡。
struct TypingBubble: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .modifier(TypingDot(delay: Double(index) * 0.15))
            }
        }
        // 边距与左侧消息气泡完全一致（10 / 16 / 10 / 17），
        // 视觉上三个圆点是「坐在同一个气泡里」，轮廓大小才对得上。
        .padding(.top, 10)
        .padding(.bottom, 10)
        .padding(.leading, 16)
        .padding(.trailing, 17)
        .background(
            BubbleShape(topLeading: 3, topTrailing: 14, bottomLeading: 14, bottomTrailing: 14)
                .fill(scheme == .dark ? Theme.bubbleIncomingDark : Theme.bubbleIncoming)
        )
        .overlay(
            BubbleShape(topLeading: 3, topTrailing: 14, bottomLeading: 14, bottomTrailing: 14)
                .strokeBorder(Color.black.opacity(scheme == .dark ? 0.0 : 0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 3, x: 0, y: 1)
        .accessibilityLabel("对方正在输入")
    }
}

private struct TypingDot: ViewModifier {
    let delay: Double
    @State private var lifted = false

    func body(content: Content) -> some View {
        content
            .offset(y: lifted ? -3 : 0)
            .opacity(lifted ? 1 : 0.4)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(delay),
                value: lifted
            )
            .onAppear { lifted = true }
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDateInToday(date) {
            return clockFormatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
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
