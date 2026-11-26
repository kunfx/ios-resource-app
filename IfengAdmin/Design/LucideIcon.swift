import SwiftUI

// MARK: - Lucide 图标（内联 SVG path，运行期解析为 SwiftUI Path）

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
        /// SVG 弧线 flag 只占一个字符（0/1），不能按数字解析。
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

private enum LucideRegistry {
    static let icons: [String: [SVGElement]] = [
        "message-circle-more": [
            .path("M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"),
            .path("M8 12h.01"),
            .path("M12 12h.01"),
            .path("M16 12h.01")
        ],
        "inbox": [
            .polyline("22 12 16 12 14 15 10 15 8 12 2 12"),
            .path("M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z")
        ],
        "settings": [
            .path("M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915"),
            .circle(12, 12, 3)
        ],
        "message-circle": [
            .path("M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719")
        ],
        "check-check": [
            .path("M18 6 7 17l-5-5"),
            .path("m22 10-7.5 7.5L13 16")
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
}

struct LucideShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }
        let scale = side / 24
        let offsetX = (rect.width - side) / 2
        let offsetY = (rect.height - side) / 2
        let transform = CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
        return LucideRegistry.path(named: name).applying(transform)
    }
}

struct LucideIcon: View {
    let name: String
    var size: CGFloat = 24
    var color: Color = .primary

    var body: some View {
        LucideShape(name: name)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.4, size * 2 / 24), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
