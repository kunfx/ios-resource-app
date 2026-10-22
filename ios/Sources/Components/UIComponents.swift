import SwiftUI

// MARK: - 区块标题

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.primary)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
            }

            Spacer()

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 标签

struct PillTag: View {
    let text: String
    var color: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? Color.white : color)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.12))
            )
    }
}

struct PointsTag: View {
    let points: Int

    var body: some View {
        if points > 0 {
            PillTag(text: "\(points) 积分", color: .orange, filled: true)
        } else {
            PillTag(text: "免费", color: Theme.accent, filled: true)
        }
    }
}

struct VipBadge: View {
    let level: Int
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: level >= 3 ? "crown.fill" : "star.fill")
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(
            Capsule().fill(
                LinearGradient(colors: [Theme.vipGold, Color(red: 0.95, green: 0.75, blue: 0.35)],
                               startPoint: .leading, endPoint: .trailing)
            )
        )
    }
}

// MARK: - 状态视图

struct LoadingView: View {
    var text: String = "加载中"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Theme.accent)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct EmptyStateView: View {
    var icon: String = "tray"
    var title: String = "暂无内容"
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.tertiaryText)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            if let message = message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .padding(.horizontal, 30)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.tertiaryText)

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            if let retry = retry {
                Button("重试", action: retry)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .padding(.horizontal, 30)
    }
}

// MARK: - 主按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(Theme.brandGradient)
                                  : AnyShapeStyle(Color.gray.opacity(0.35)))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

// MARK: - 悬浮小标签（信息行）

struct InfoRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var tint: Color = Theme.secondaryText

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 20)
                .foregroundStyle(tint)

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)

            Spacer()

            if let value = value {
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .contentShape(Rectangle())
    }
}
