import SwiftUI

enum Theme {
    static let accent = Color(red: 0.06, green: 0.72, blue: 0.51)
    static let accentSoft = Color(red: 0.02, green: 0.71, blue: 0.83)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [accent, accentSoft],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let field = Color(uiColor: .tertiarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let vipGold = Color(red: 0.85, green: 0.62, blue: 0.16)
}

extension View {
    /// 统一卡片外观：圆角 + 轻微阴影
    func cardStyle(padding: CGFloat = 16, radius: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
