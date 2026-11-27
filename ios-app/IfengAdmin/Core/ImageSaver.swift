import Foundation
import Photos
import UIKit

/// 把会话里的图片存进系统相册。
///
/// ## 为什么单独抽出来
///
/// 存图涉及三件容易出错的事，散在视图里会越写越乱：
/// 1. **权限**分「仅添加」和「完全访问」两种，`NSPhotoLibraryAddUsageDescription`
///    只够前者；用户可能拒绝过，要能引导去设置。
/// 2. **下载**必须用 `URLSession` 拿原始字节，不能用 `AsyncImage` 的缓存图
///    ——那是降采样过的缩略图，存下来会比原图糊。
/// 3. **保存**用 `PHAssetCreationRequest.addResource(with:data:)`，
///    直接写原始数据，避免 `UIImage` 重新编码导致体积变大、EXIF 丢失。
///
/// 图片 URL 自带 HMAC 签名（`/media/{id}/{variant}?cap=...`），
/// 所以下载不需要带任何鉴权头。
enum ImageSaver {
    /// 保存结果。调用方据此决定提示文案。
    ///
    /// 名字故意不叫 `Result`：那会和标准库的 `Result<T, E>` 在阅读时混淆。
    enum SaveOutcome {
        case saved
        case denied
        case failed(String)

        /// 失败类结果需要让提示多停留一会儿，否则用户看不清原因。
        var isFailure: Bool {
            switch self {
            case .saved: return false
            case .denied, .failed: return true
            }
        }
    }

    /// 下载并保存到相册。整个过程在主线程回调 UI 相关的提示。
    ///
    /// - Parameter url: 带 `cap` 签名的图片地址
    /// - Returns: 保存结果
    @discardableResult
    static func saveToAlbum(from url: URL) async -> SaveOutcome {
        // 1. 先要权限。`.addOnly` 对「只存图」这个场景是最小的授权范围，
        //    比申请完全访问更容易被用户接受，也符合 App Store 的审核要求。
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            return .denied
        }

        // 2. 下载原始数据。
        let data: Data
        do {
            var request = URLRequest(url: url)
            // 相册保存不需要浏览器的「缓存再来一次」，直接要最新的字节。
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = AppConfig.uploadTimeout
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("服务器返回异常")
            }
            guard !payload.isEmpty else {
                return .failed("图片内容为空")
            }
            guard UIImage(data: payload) != nil else {
                return .failed("图片格式无法识别")
            }
            data = payload
        } catch {
            return .failed("下载失败，请检查网络")
        }

        // 3. 写入相册。用原始字节，不重新编码。
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // `PHAssetCreationRequest` 的资源接口签名是
                // `addResource(with:data:options:)`，参数名就是 `data:`。
                // 没有 `fileData:` 这个标签（那是 `PHAssetResourceCreationOptions`
                // 的字段名，容易记混）。
                request.addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed("保存失败，请重试")
        }
    }

    /// 申请「仅添加」权限。
    ///
    /// 注意 `PHPhotoLibrary.requestAuthorization(for:)` 要 iOS 14+，
    /// 工程最低支持 iOS 16，所以可以直接用。
    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        // 已经决定过就别再弹窗（系统也不会再弹，只会立刻回调旧结果）。
        if current != .notDetermined {
            return current
        }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
