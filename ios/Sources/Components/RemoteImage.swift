import SwiftUI
import UIKit

/// 带内存缓存的网络图片，避免列表滚动时反复请求。
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    var placeholderIcon: String = "app.fill"

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    placeholder
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: urlString) {
            await load()
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accentSoft.opacity(0.16)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            Image(systemName: failed ? "photo" : placeholderIcon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.6))
        }
    }

    private func load() async {
        guard let urlString = urlString, !urlString.isEmpty else {
            failed = true
            return
        }

        if let cached = ImageCache.shared.image(for: urlString) {
            image = cached
            return
        }

        guard let url = URL(string: urlString) else {
            failed = true
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }

            ImageCache.shared.store(decoded, for: urlString)
            image = decoded
        } catch {
            failed = true
        }
    }
}

/// 应用图标专用：统一圆角
struct AppIconView: View {
    let urlString: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 14

    var body: some View {
        RemoteImage(urlString: urlString)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
