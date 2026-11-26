import Foundation

/// 基于 `URLSessionDataDelegate` 的 SSE 传输层。
///
/// **为什么不能用 `URLSession.bytes(for:)`**：
/// `AsyncBytes` 看起来很适合 SSE，但 iOS 的 CFNetwork 对流式响应会做输出缓冲。
/// 服务端明明已经 `Flush()`，客户端却要等到攒够一定字节（或下一次心跳 15 秒）
/// 才拿到数据。表现就是「心跳能收到、状态看起来正常，但业务事件总是迟到甚至过期」：
/// 访客打字只有 3 秒租约，等 15 秒后送达时气泡早已该消失；
/// 新消息也一样被压住，只有下一次心跳才一起冲出。
///
/// `urlSession(_:dataTask:didReceive:)` 是**收到即回调**，没有这层缓冲，
/// 是 SSE / 长轮询的标准做法（网页端 `EventSource` 也是逐块解析）。
///
/// 这个类只负责「把字节流按 SSE 帧切开」，业务分发仍交给 `RealtimeClient`。
final class SSETransport: NSObject {
    /// 收到一个完整事件。
    var onEvent: (@Sendable (String, String, String?) -> Void)?
    /// 连接建立（HTTP 200，且响应头已到）。
    var onOpen: (@Sendable () -> Void)?
    /// 连接结束。`clean` 表示服务端正常收尾（例如 20 分钟续连）。
    var onClose: (@Sendable (_ clean: Bool) -> Void)?
    /// 收到任意字节，用于心跳看门狗。
    var onActivity: (@Sendable () -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var opened = false
    private let lock = NSLock()

    func start(_ request: URLRequest) {
        stop()
        let configuration = URLSessionConfiguration.default
        // 流式响应：不设整体超时，连接空闲由服务端心跳 + 看门狗负责。
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // 关键：不要让系统为了省电把请求合并/延后。
        configuration.httpShouldUsePipelining = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.lock()
        opened = false
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        task.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        lock.lock()
        opened = false
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

extension SSETransport: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        // 200 才继续；204（ticket 已消费）、401 等交给上层处理，立刻结束。
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            return
        }
        lock.lock()
        opened = true
        lock.unlock()
        onActivity?()
        onOpen?()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        onActivity?()
        lock.lock()
        buffer.append(data)
        let frames = Self.drain(&buffer)
        lock.unlock()
        for frame in frames {
            onEvent?(frame.event, frame.data, frame.id)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasOpen = opened
        opened = false
        lock.unlock()
        _ = wasOpen
        onClose?(error == nil)
    }

    // MARK: SSE 帧解析

    struct Frame {
        let event: String
        let data: String
        let id: String?
    }

    /// 从缓冲区里取出所有已完整的帧（以空行分隔）。
    ///
    /// 必须按字节扫描 `\n\n`（并兼容 `\r\n\r\n`），不能按 `String` 行解析：
    /// 一次回调可能只到半个帧，留下的残片要等下次拼接，否则会丢事件。
    private static func drain(_ buffer: inout Data) -> [Frame] {
        var frames: [Frame] = []
        while true {
            guard let range = nextSeparator(in: buffer) else { break }
            let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let frame = parse(chunk) {
                frames.append(frame)
            }
        }
        return frames
    }

    /// 找到帧结束位置：`\n\n` 或 `\r\n\r\n`。返回要删除的区间。
    private static func nextSeparator(in buffer: Data) -> Range<Data.Index>? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {
                let start = buffer.startIndex + index
                return start..<(start + 2)
            }
            if index + 3 < bytes.count,
               bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                let start = buffer.startIndex + index
                return start..<(start + 4)
            }
            index += 1
        }
        return nil
    }

    private static func parse(_ chunk: Data) -> Frame? {
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        var event = ""
        var dataLines: [String] = []
        var id: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue }   // 注释 / 心跳占位
            guard let separator = line.firstIndex(of: ":") else { continue }
            let field = String(line[line.startIndex..<separator])
            var value = String(line[line.index(after: separator)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            case "id": id = value
            default: break
            }
        }
        guard !event.isEmpty || !dataLines.isEmpty else { return nil }
        return Frame(
            event: event.isEmpty ? "message" : event,
            data: dataLines.joined(separator: "\n"),
            id: id
        )
    }
}
