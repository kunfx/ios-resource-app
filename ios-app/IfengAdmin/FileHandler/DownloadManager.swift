import Foundation
import WebKit

struct DownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    let configuration: AppConfiguration
    var onComplete: ((DownloadedFile) -> Void)?
    var onError: ((String) -> Void)?
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]

    init(configuration: AppConfiguration) { self.configuration = configuration }

    func accept(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 不采用服务器提供的目录，且每次使用独立目录，不覆盖同名文件。
            let last = (suggestedFilename as NSString).lastPathComponent
            let scalars = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160)
            let clean = String(String.UnicodeScalarView(scalars))
            let name = clean.isEmpty || clean == "." || clean == ".." ? "download" : clean
            let url = directory.appendingPathComponent(name)
            destinations[key] = url
            completionHandler(url)
        } catch {
            completionHandler(nil)
            downloads.removeValue(forKey: key)
            onError?("无法创建下载文件，请检查手机存储空间后重试。")
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard let url = request.url, configuration.owns(url) else {
            decisionHandler(.cancel)
            onError?("下载已取消：文件重定向到了未信任的地址。")
            let key = ObjectIdentifier(download)
            destinations.removeValue(forKey: key)
            downloads.removeValue(forKey: key)
            return
        }
        decisionHandler(.allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        let file = destinations.removeValue(forKey: key)
        downloads.removeValue(forKey: key)
        if let file { onComplete?(DownloadedFile(url: file)) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        destinations.removeValue(forKey: key)
        downloads.removeValue(forKey: key)
        onError?("文件下载失败，请检查网络后重试。")
    }
}
