import SwiftUI

/// 横向滑动区块用的小卡片
struct AppTile: View {
    let item: AppItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AppIconView(urlString: item.icon, size: 64, cornerRadius: 16)

            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(item.shortDescription ?? "v\(item.version ?? "1.0")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(width: 76, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 列表用的横排卡片
struct AppRow: View {
    let item: AppItem
    var showCategory: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(urlString: item.icon, size: 58, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if item.pointsRequired > 0 {
                        PillTag(text: "\(item.pointsRequired) 积分", color: .orange)
                    } else {
                        PillTag(text: "免费", color: Theme.accent)
                    }
                }

                Text(item.shortDescription ?? "暂无简介")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("v\(item.version ?? "1.0")")
                    if let size = item.size, !size.isEmpty {
                        Text(size)
                    }
                    if showCategory, let category = item.category {
                        Text(category.parent?.name ?? category.name)
                    }
                    Text(DateText.relative(item.updatedAt))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .contentShape(Rectangle())
    }
}

/// 两列网格卡片
struct AppGridCard: View {
    let item: AppItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                AppIconView(urlString: item.icon, size: 54, cornerRadius: 13)
                Spacer()
                if item.pointsRequired > 0 {
                    Text("\(item.pointsRequired)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
            }

            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(item.shortDescription ?? "v\(item.version ?? "1.0")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(item.size ?? "")
                Text("·")
                Text("\(NumberText.compact(item.views)) 浏览")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiaryText)
            .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 文章卡片
struct ArticleCard: View {
    let article: Article

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: article.cover, placeholderIcon: "doc.text")
                .frame(width: 92, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let summary = article.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(DateText.day(article.publishedAt))
                    Text("\(NumberText.compact(article.views)) 阅读")
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
