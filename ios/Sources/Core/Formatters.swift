import Foundation

enum DateText {
    private static let inputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from raw: String?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        return inputFormatter.date(from: raw)
    }

    /// 刚刚 / 3 分钟前 / 2 天前 / 2026-04-09
    static func relative(_ raw: String?) -> String {
        guard let date = date(from: raw) else { return "" }

        let interval = Date().timeIntervalSince(date)

        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 86_400 * 7 { return "\(Int(interval / 86_400)) 天前" }

        return dayFormatter.string(from: date)
    }

    static func day(_ raw: String?) -> String {
        guard let date = date(from: raw) else { return "" }
        return dayFormatter.string(from: date)
    }
}

enum NumberText {
    /// 1.2万 / 3562
    static func compact(_ value: Int) -> String {
        if value >= 10_000 {
            let formatted = Double(value) / 10_000
            return String(format: "%.1f万", formatted)
        }
        return "\(value)"
    }
}
