import SwiftUI
import UIKit

// MARK: - Lucide 图标（内联 SVG path，运行期解析为 SwiftUI Path）
//
// path 数据与仓库里的 web/icons.js 保持一致，保证 iOS 与网页后台的图标完全同款。
// 全部是 Lucide 官方 24×24 viewBox 的描边图标（stroke，不是填充）。

private enum SVGElement {
    case path(String)
    case circle(CGFloat, CGFloat, CGFloat)
    case line(CGFloat, CGFloat, CGFloat, CGFloat)
    case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case polyline(String)
}

/// 极简 SVG path 解析器：支持 M/L/H/V/C/S/Q/T/A/Z 及相对命令。
/// 仅用于绘制 Lucide 图标，不追求完整 SVG 规范覆盖。
private enum SVGPathParser {
    private struct Scanner {
        let characters: [Character]
        var index = 0
        init(_ text: String) { characters = Array(text) }
        var hasMore: Bool {
            var i = index
            while i < characters.count {
                let c = characters[i]
                if c == " " || c == "," || c == "\n" || c == "\r" || c == "\t" { i += 1 } else { return true }
            }
            return false
        }
        mutating func skipSeparators() {
            while index < characters.count {
                let c = characters[index]
                if c == " " || c == "," || c == "\n" || c == "\r" || c == "\t" { index += 1 } else { break }
            }
        }
        mutating func takeCommand() -> Character? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let c = characters[index]
            guard c.isLetter else { return nil }
            index += 1
            return c
        }
        mutating func number() -> CGFloat? {
            skipSeparators()
            guard index < characters.count else { return nil }
            var text = ""
            var seenDot = false
            var seenExponent = false
            // 开头允许正负号。SVG 里 "l-1.065 3.29" 这种写法非常常见，
            // 少了这一步会在第一个负号处直接解析失败，整条路径被截断，
            // 表现出来就是「所有图标都被裁掉一部分」。
            if characters[index] == "-" || characters[index] == "+" {
                text.append(characters[index])
                index += 1
            }
            while index < characters.count {
                let c = characters[index]
                if c.isNumber {
                    text.append(c)
                    index += 1
                    continue
                }
                if c == "." && !seenDot && !seenExponent {
                    seenDot = true
                    text.append(c)
                    index += 1
                    continue
                }
                if (c == "e" || c == "E") && !seenExponent && !text.isEmpty {
                    seenExponent = true
                    text.append(c)
                    index += 1
                    continue
                }
                if (c == "+" || c == "-") && !text.isEmpty && (text.last == "e" || text.last == "E") {
                    text.append(c)
                    index += 1
                    continue
                }
                break
            }
            guard let value = Double(text) else { return nil }
            return CGFloat(value)
        }
        /// SVG 弧线 flag 只占一个字符（0/1），不能按数字解析；也允许连写成 "01"。
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let c = characters[index]
            guard c == "0" || c == "1" else { return nil }
            index += 1
            return c == "1"
        }
    }

    static func path(from d: String) -> Path {
        var path = Path()
        var scanner = Scanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while scanner.hasMore {
            if let letter = scanner.takeCommand() {
                command = letter
            } else if command == nil {
                break
            }
            guard let cmd = command else { break }
            let relative = cmd.isLowercase

            switch cmd {
            case "M", "m":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let target = point(x, y, relative: relative)
                path.move(to: target)
                current = target
                subpathStart = target
                // 后续坐标按 LineTo 处理。
                command = relative ? "l" : "L"
                lastCubicControl = nil
                lastQuadControl = nil

            case "L", "l":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let target = point(x, y, relative: relative)
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "H", "h":
                guard let x = scanner.number() else { return path }
                let target = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "V", "v":
                guard let y = scanner.number() else { return path }
                let target = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "C", "c":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = point(x1, y1, relative: relative)
                let c2 = point(x2, y2, relative: relative)
                let target = point(x, y, relative: relative)
                path.addCurve(to: target, control1: c1, control2: c2)
                current = target
                lastCubicControl = c2
                lastQuadControl = nil

            case "S", "s":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let reflected = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(x2, y2, relative: relative)
                let target = point(x, y, relative: relative)
                path.addCurve(to: target, control1: reflected, control2: c2)
                current = target
                lastCubicControl = c2
                lastQuadControl = nil

            case "Q", "q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let control = point(x1, y1, relative: relative)
                let target = point(x, y, relative: relative)
                path.addQuadCurve(to: target, control: control)
                current = target
                lastQuadControl = control
                lastCubicControl = nil

            case "T", "t":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let reflected = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let target = point(x, y, relative: relative)
                path.addQuadCurve(to: target, control: reflected)
                current = target
                lastQuadControl = reflected
                lastCubicControl = nil

            case "A", "a":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let target = point(x, y, relative: relative)
                addArc(to: &path, from: current, to: target, rx: rx, ry: ry, rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = target
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                command = nil
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                // 未知命令：停止解析，保留已绘制部分。
                return path
            }
        }
        return path
    }

    private static func addArc(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        rx rawRx: CGFloat,
        ry rawRy: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        if rx == 0 || ry == 0 || (start.x == end.x && start.y == end.y) {
            if !(start.x == end.x && start.y == end.y) { path.addLine(to: end) }
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }
        let rx2 = rx * rx
        let ry2 = ry * ry
        let numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coefficient: CGFloat = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let centerX = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let centerY = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let startAngle = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segmentCount = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segmentCount)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        var angle = startAngle

        func pointOnEllipse(_ cosine: CGFloat, _ sine: CGFloat) -> CGPoint {
            CGPoint(
                x: centerX + cosPhi * rx * cosine - sinPhi * ry * sine,
                y: centerY + sinPhi * rx * cosine + cosPhi * ry * sine
            )
        }
        func derivativeOnEllipse(_ cosine: CGFloat, _ sine: CGFloat) -> CGPoint {
            CGPoint(
                x: -cosPhi * rx * sine - sinPhi * ry * cosine,
                y: -sinPhi * rx * sine + cosPhi * ry * cosine
            )
        }

        for _ in 0..<segmentCount {
            let nextAngle = angle + step
            let startPoint = pointOnEllipse(cos(angle), sin(angle))
            let endPoint = pointOnEllipse(cos(nextAngle), sin(nextAngle))
            let startDerivative = derivativeOnEllipse(cos(angle), sin(angle))
            let endDerivative = derivativeOnEllipse(cos(nextAngle), sin(nextAngle))
            let control1 = CGPoint(
                x: startPoint.x + alpha * startDerivative.x,
                y: startPoint.y + alpha * startDerivative.y
            )
            let control2 = CGPoint(
                x: endPoint.x - alpha * endDerivative.x,
                y: endPoint.y - alpha * endDerivative.y
            )
            path.addCurve(to: endPoint, control1: control1, control2: control2)
            angle = nextAngle
        }
    }
}

// MARK: - 图标注册表

private enum LucideRegistry {
    static let icons: [String: [SVGElement]] = [
        // ── 底部导航 ──────────────────────────────────────────────
        "message-circle-more": [
            .path("M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"),
            .path("M8 12h.01"),
            .path("M12 12h.01"),
            .path("M16 12h.01")
        ],
        "message-circle": [
            .path("M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719")
        ],
        "messages-square": [
            .path("M16 10a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 14.286V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"),
            .path("M20 9a2 2 0 0 1 2 2v10.286a.71.71 0 0 1-1.212.502l-2.202-2.202A2 2 0 0 0 17.172 19H10a2 2 0 0 1-2-2v-1")
        ],
        "inbox": [
            .polyline("22 12 16 12 14 15 10 15 8 12 2 12"),
            .path("M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z")
        ],
        "settings": [
            .path("M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915"),
            .circle(12, 12, 3)
        ],

        // ── 通用操作 ──────────────────────────────────────────────
        "info": [
            .circle(12, 12, 10),
            .path("M12 16v-4"),
            .path("M12 8h.01")
        ],
        "circle-help": [
            .circle(12, 12, 10),
            .path("M9 9.5a3 2.5 0 016 0c0 2-2 2-3 3.5"),
            .path("M12 17h.01")
        ],
        "x": [
            .path("M18 6 6 18"),
            .path("m6 6 12 12")
        ],
        "chevron-left": [.path("m15 18-6-6 6-6")],
        "chevron-right": [.path("m9 18 6-6-6-6")],
        "check": [.path("M20 6 9 17l-5-5")],
        "check-check": [
            .path("M18 6 7 17l-5-5"),
            .path("m22 10-7.5 7.5L13 16")
        ],
        "clock": [
            .circle(12, 12, 10),
            .path("M12 6v6l4 2")
        ],
        "circle-alert": [
            .circle(12, 12, 10),
            .line(12, 8, 12, 12),
            .line(12, 16, 12.01, 16)
        ],
        "refresh-cw": [
            .path("M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"),
            .path("M21 3v5h-5"),
            .path("M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"),
            .path("M8 16H3v5")
        ],
        "copy": [
            .rect(8, 8, 14, 14, 2),
            .path("M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2")
        ],
        "wifi-off": [
            .path("M12 20h.01"),
            .path("M8.5 16.429a5 5 0 0 1 7 0"),
            .path("M5 12.859a10 10 0 0 1 5.17-2.69"),
            .path("M19 12.859a10 10 0 0 0-2.007-1.523"),
            .path("M2 8.82a15 15 0 0 1 4.177-2.643"),
            .path("M22 8.82a15 15 0 0 0-11.288-3.764"),
            .path("m2 2 20 20")
        ],
        "external-link": [
            .path("M15 3h6v6"),
            .path("M10 14 21 3"),
            .path("M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6")
        ],
        "list-filter": [
            .path("M3 6h18"),
            .path("M7 12h10"),
            .path("M10 18h4")
        ],
        "loader-circle": [.path("M21 12a9 9 0 1 1-6.219-8.56")],

        // ── 输入区 ────────────────────────────────────────────────
        "image": [
            .rect(3, 3, 18, 18, 2),
            .circle(9, 9, 2),
            .path("m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21")
        ],
        "smile": [
            .circle(12, 12, 10),
            .path("M15 10V9"),
            .path("M9 10V9"),
            .path("M16.472 15a6 6 0 01-8.943 0")
        ],
        "send": [
            .path("M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"),
            .path("m21.854 2.147-10.94 10.939")
        ],

        // ── 访客信息 ──────────────────────────────────────────────
        "globe": [
            .circle(12, 12, 10),
            .path("M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"),
            .path("M2 12h20")
        ],
        "map-pin": [
            .path("M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"),
            .circle(12, 10, 3)
        ],
        "monitor": [
            .rect(2, 3, 20, 14, 2),
            .line(8, 21, 16, 21),
            .line(12, 17, 12, 21)
        ],
        "compass": [
            .path("m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z"),
            .circle(12, 12, 10)
        ],
        "languages": [
            .path("m5 8 6 6"),
            .path("m4 14 6-6 2-3"),
            .path("M2 5h12"),
            .path("M7 2h1"),
            .path("m22 22-5-10-5 10"),
            .path("M14 18h6")
        ],
        "calendar": [
            .path("M8 2v4"),
            .path("M16 2v4"),
            .rect(3, 4, 18, 18, 2),
            .path("M3 10h18")
        ],
        "envelope": [
            .rect(2, 4, 20, 16, 2),
            .path("m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7")
        ],
        "network": [
            .rect(16, 16, 6, 6, 1),
            .rect(2, 16, 6, 6, 1),
            .rect(9, 2, 6, 6, 1),
            .path("M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"),
            .path("M12 12V8")
        ],
        "lock": [
            .rect(3, 11, 18, 11, 2),
            .path("M7 11V7a5 5 0 0 1 10 0v4")
        ],

        // ── 设置 ──────────────────────────────────────────────────
        "user-round": [
            .circle(12, 8, 5),
            .path("M20 21a8 8 0 0 0-16 0")
        ],
        "bell": [
            .path("M10.268 21a2 2 0 0 0 3.464 0"),
            .path("M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326")
        ],
        "log-out": [
            .path("m16 17 5-5-5-5"),
            .path("M21 12H9"),
            .path("M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4")
        ],

        // ── 状态 ──────────────────────────────────────────────────
        "ban": [
            .circle(12, 12, 10),
            .path("M4.929 4.929 19.07 19.071")
        ],
        "shield-off": [
            .path("m2 2 20 20"),
            .path("M5 5a1 1 0 0 0-1 1v7c0 5 3.5 7.5 7.67 8.94a1 1 0 0 0 .67.01c2.35-.82 4.48-1.97 5.9-3.71"),
            .path("M9.309 3.652A12.252 12.252 0 0 0 11.24 2.28a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1v7a9.784 9.784 0 0 1-.08 1.264")
        ],
        "search": [
            .circle(11, 11, 8),
            .path("m21 21-4.34-4.34")
        ],
        "eye": [
            .path("M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"),
            .circle(12, 12, 3)
        ],
        "eye-off": [
            .path("M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"),
            .path("M14.084 14.158a3 3 0 0 1-4.242-4.242"),
            .path("M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"),
            .path("m2 2 20 20")
        ]
    ]

    static func path(named name: String) -> Path {
        var path = Path()
        guard let elements = icons[name] else { return path }
        for element in elements {
            switch element {
            case .path(let d):
                path.addPath(SVGPathParser.path(from: d))
            case .circle(let cx, let cy, let r):
                path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            case .line(let x1, let y1, let x2, let y2):
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
            case .rect(let x, let y, let width, let height, let radius):
                path.addRoundedRect(
                    in: CGRect(x: x, y: y, width: width, height: height),
                    cornerSize: CGSize(width: radius, height: radius)
                )
            case .polyline(let points):
                let numbers = points
                    .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
                    .compactMap { Double($0) }
                    .map { CGFloat($0) }
                guard numbers.count >= 4 else { break }
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
                var index = 2
                while index + 1 < numbers.count {
                    path.addLine(to: CGPoint(x: numbers[index], y: numbers[index + 1]))
                    index += 2
                }
            }
        }
        return path
    }

    static func exists(_ name: String) -> Bool {
        icons[name] != nil
    }
}

// MARK: - 渲染

struct LucideShape: Shape {
    let name: String
    /// 描边宽度，用于在 24 viewBox 外预留空间。
    var lineWidth: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }

        // 关键：把 24×24 的图形内缩半个线宽（再多留 0.5pt 余量），
        // 保证描边不会贴到 frame 边缘，也就不会被父容器的圆角/裁切吃掉一截。
        let inset = min(lineWidth / 2 + 0.5, side / 4)
        let available = max(1, side - inset * 2)
        let scale = available / 24
        let offsetX = (rect.width - available) / 2
        let offsetY = (rect.height - available) / 2
        // 直接给出矩阵，避免 translatedBy/scaledBy 的乘法顺序歧义：
        // 先按 available/24 缩放，再平移到居中位置。
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
        return LucideRegistry.path(named: name).applying(transform)
    }
}

/// Lucide 描边图标。`size` 是调用方给的「设计稿尺寸」，
/// 实际绘制时会统一 +1（见 `resolvedSize`），想整体调大小只改这一处。
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 24
    var color: Color = .primary
    /// 不传时按 Lucide 规范自动换算（24pt 对应 1.7pt 线宽）。
    var lineWidth: CGFloat? = nil

    /// 全局图标 +1：和字号一起放大一号，视觉重量才跟得上。
    private var resolvedSize: CGFloat { size + 1 }

    private var strokeWidth: CGFloat {
        // 线宽系数从 2/24 降到 1.7/24，整体细一点点；下限同时从 1.5 降到 1.2，
        // 否则 12~14pt 的小图标会被下限卡住，看着比大字还粗。
        lineWidth ?? max(1.2, resolvedSize * 1.7 / 24)
    }

    var body: some View {
        LucideShape(name: name, lineWidth: strokeWidth)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            )
            .frame(width: resolvedSize, height: resolvedSize)
            .accessibilityHidden(true)
    }
}

/// 导航栏图标按钮：**正圆形**底色 + 图标，点击热区固定 44×44。
///
/// 三个尺寸是分开控制的，不要混用：
/// - `size`：图标本身的大小（只放大它）
/// - `diameter`：圆形底色的直径（**不跟着图标放大**）
/// - 热区：固定 44×44（`contentShape`），保证手指好点
///
/// 之前只有裸图标没有底圆，视觉上就是一个"椭圆"（因为图标本身不是正圆，
/// 描边留白也不均匀）。现在用 `Circle()` 做底，几何上一定是正圆。
struct ToolbarIconButton: View {
    let name: String
    let label: String
    var size: CGFloat = 20
    /// 圆形底色直径。默认 32，图标再大也保持这个尺寸。
    var diameter: CGFloat = 32
    var color: Color = Theme.accent
    /// 圆形底色。浅灰，避免和导航栏标题抢视线。
    var background: Color = Color.primary.opacity(0.055)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: diameter, height: diameter)
                LucideIcon(name: name, size: size, color: color)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 圆底 Lucide 图标按钮（替代原来的 SF Symbols 圆形按钮）。
struct LucideCircleButton: View {
    let name: String
    var size: CGFloat = 34
    var iconSize: CGFloat = 17
    var foreground: Color = .primary
    var background: Color = Color(uiColor: .secondarySystemBackground)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(background)
                Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                LucideIcon(name: name, size: iconSize, color: foreground)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}
