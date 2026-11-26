import UIKit

/// 服务端只接受 JPEG / PNG / WebP，且 MIME、文件头、扩展名必须一致。
/// 相册里的 HEIC 不能改后缀了事，必须真正转码为 JPEG。
enum ImagePreparer {
    /// 与网页端一致：长边缩放到 1280～1600 之间，远低于服务端 1600 万像素上限。
    static let maxEdge: CGFloat = 1600
    static let maxBytes = 10 * 1024 * 1024

    static func jpegData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegData(from: image)
    }

    static func jpegData(from image: UIImage) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let flattened = renderer.image { context in
            // 透明区域铺白底，避免转 JPEG 后出现黑块。
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        var quality: CGFloat = 0.86
        var data = flattened.jpegData(compressionQuality: quality)
        while let current = data, current.count > maxBytes, quality > 0.4 {
            quality -= 0.08
            data = flattened.jpegData(compressionQuality: quality)
        }
        return data
    }
}
