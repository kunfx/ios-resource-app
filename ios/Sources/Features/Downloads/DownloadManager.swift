import Foundation
import Combine

enum DownloadState: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed

    var text: String {
        switch self {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
}

struct DownloadItem: Identifiable, Codable, Equatable {
    let id: UUID
    var appID: Int
    var appName: String
    var iconURL: String?
    var linkTitle: String
    var fileName: String
    var remoteURL: String
    var state: DownloadState
    var progress: Double
    var receivedBytes: Int64
    var totalBytes: Int64
    var errorMessage: String?
    var createdAt: Date

    var isActive: Bool { state == .downloading || state == .queued }

    var fileURL: URL? {
        guard state == .completed else { return nil }
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName)
    }

    var sizeText: String {
        if totalBytes > 0 {
            return "\(DownloadItem.format(receivedBytes)) / \(DownloadItem.format(totalBytes))"
        }
        if receivedBytes > 0 {
            return DownloadItem.format(receivedBytes)
        }
        return ""
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// 内置下载管理：所有资源都在 App 内下载，不跳浏览器。
/// 文件保存在 Documents/Downloads，可在「文件」App 里直接取用。
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []

    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir
    }

    private var session: URLSession!
    private var taskByItem: [UUID: URLSessionDownloadTask] = [:]
    private var itemByTask: [Int: UUID] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var pausedOnPurpose: Set<UUID> = []

    private override init() {
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "AppKu-iOS/1.0"]

        // delegateQueue: .main 让进度回调直接落在主线程，UI 更新不需要再切线程
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        loadFromDisk()
    }

    // MARK: - 对外操作

    @discardableResult
    func enqueue(appID: Int, appName: String, iconURL: String?,
                 linkTitle: String, urlString: String) -> UUID? {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }

        // 同一个地址已在列表里：暂停中的直接续传，其它状态不重复添加
        if let existing = items.first(where: { $0.remoteURL == urlString && $0.state != .failed }) {
            if existing.state == .paused { resume(itemID: existing.id) }
            return existing.id
        }

        let name = uniqueFileName(makeFileName(appName: appName, linkTitle: linkTitle, url: url))

        let item = DownloadItem(
            id: UUID(),
            appID: appID,
            appName: appName,
            iconURL: iconURL,
            linkTitle: linkTitle,
            fileName: name,
            remoteURL: urlString,
            state: .queued,
            progress: 0,
            receivedBytes: 0,
            totalBytes: 0,
            errorMessage: nil,
            createdAt: Date()
        )

        items.insert(item, at: 0)
        start(itemID: item.id)
        persist()

        return item.id
    }

    func pause(itemID: UUID) {
        guard let task = taskByItem[itemID] else { return }

        pausedOnPurpose.insert(itemID)

        task.cancel { [weak self] data in
            guard let self = self, let data = data else { return }
            // cancel 的完成回调不一定在主线程，统一切回主线程再写状态
            DispatchQueue.main.async {
                self.resumeData[itemID] = data
            }
        }
    }

    func resume(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[index].state != .completed else { return }

        if let data = resumeData[itemID] {
            let task = session.downloadTask(withResumeData: data)
            items[index].state = .downloading
            items[index].errorMessage = nil
            taskByItem[itemID] = task
            itemByTask[task.taskIdentifier] = itemID
            task.resume()
        } else {
            start(itemID: itemID)
        }

        persist()
    }

    func retry(itemID: UUID) {
        resumeData[itemID] = nil
        start(itemID: itemID)
    }

    func remove(itemID: UUID) {
        taskByItem[itemID]?.cancel()
        taskByItem[itemID] = nil
        pausedOnPurpose.remove(itemID)
        resumeData[itemID] = nil

        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let file = Self.downloadsDirectory.appendingPathComponent(items[index].fileName)
            try? FileManager.default.removeItem(at: file)
            items.remove(at: index)
        }

        persist()
    }

    func clearCompleted() {
        for item in items where item.state == .completed {
            let file = Self.downloadsDirectory.appendingPathComponent(item.fileName)
            try? FileManager.default.removeItem(at: file)
        }

        items.removeAll { $0.state == .completed }
        persist()
    }

    func contains(appID: Int) -> Bool {
        items.contains { $0.appID == appID && $0.state != .failed }
    }

    // MARK: - 内部

    private func start(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard let url = URL(string: items[index].remoteURL) else {
            items[index].state = .failed
            items[index].errorMessage = "下载地址无效"
            persist()
            return
        }

        let task = session.downloadTask(with: url)

        items[index].state = .downloading
        items[index].progress = 0
        items[index].receivedBytes = 0
        items[index].errorMessage = nil

        taskByItem[itemID] = task
        itemByTask[task.taskIdentifier] = itemID
        task.resume()
    }

    private func makeFileName(appName: String, linkTitle: String, url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "ipa" : url.pathExtension.lowercased()

        var base = "\(appName)-\(linkTitle)"
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n"] {
            base = base.replacingOccurrences(of: bad, with: "_")
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)

        if base.isEmpty { base = "resource" }
        if base.count > 80 { base = String(base.prefix(80)) }

        return "\(base).\(ext)"
    }

    private func uniqueFileName(_ name: String) -> String {
        let directory = Self.downloadsDirectory
        let nsName = name as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var candidate = name
        var index = 1

        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                || items.contains(where: { $0.fileName == candidate }) {
            candidate = ext.isEmpty ? "\(base)(\(index))" : "\(base)(\(index)).\(ext)"
            index += 1
        }

        return candidate
    }

    // MARK: - 持久化

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AppKu", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.appendingPathComponent("downloads.json")
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? decoder.decode([DownloadItem].self, from: data) else {
            return
        }

        // 上次退出时还在下载的任务无法续传，统一标记为已暂停，让用户手动继续
        items = saved.map { item in
            var copy = item
            if copy.state == .downloading || copy.state == .queued {
                copy.state = .paused
            }
            return copy
        }
    }
}

// MARK: - URLSession 回调

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let itemID = itemByTask[downloadTask.taskIdentifier],
              let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].state = .downloading
        items[index].receivedBytes = totalBytesWritten

        if totalBytesExpectedToWrite > 0 {
            items[index].totalBytes = totalBytesExpectedToWrite
            items[index].progress = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let itemID = itemByTask[downloadTask.taskIdentifier],
              let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let destination = Self.downloadsDirectory.appendingPathComponent(items[index].fileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            // 临时文件在本方法返回后就会被系统删除，必须同步搬走
            try FileManager.default.moveItem(at: location, to: destination)

            items[index].state = .completed
            items[index].progress = 1
            items[index].errorMessage = nil

            if items[index].totalBytes > 0 {
                items[index].receivedBytes = items[index].totalBytes
            }
        } catch {
            items[index].state = .failed
            items[index].errorMessage = "保存文件失败：\(error.localizedDescription)"
        }

        persist()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let itemID = itemByTask[task.taskIdentifier] else { return }

        taskByItem[itemID] = nil
        itemByTask[task.taskIdentifier] = nil

        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }

        if pausedOnPurpose.contains(itemID) {
            pausedOnPurpose.remove(itemID)
            items[index].state = .paused
            persist()
            return
        }

        // 成功的情况已经在 didFinishDownloadingTo 里处理过
        guard items[index].state != .completed else { return }

        if let error = error as NSError? {
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeData[itemID] = data
            }

            items[index].state = .failed
            items[index].errorMessage = error.localizedDescription
            persist()
        }
    }
}
