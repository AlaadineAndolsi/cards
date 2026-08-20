import SwiftUI

/// Minimal SVG path-data parser covering the commands used by the reference
/// deck art (M/m, L/l, H/h, V/v, C/c, S/s, Q/q, A/a, Z/z).
enum SVGPath {

    static func path(_ d: String) -> Path {
        var path = Path()
        var scanner = Tokenizer(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "

        while let command = scanner.nextCommand() {
            let relative = command.isLowercase
            switch Character(command.lowercased()) {
            case "m":
                var first = true
                while let x = scanner.nextNumber() {
                    let y = scanner.nextNumber() ?? 0
                    var point = CGPoint(x: x, y: y)
                    if relative { point = current + point }
                    if first {
                        path.move(to: point)
                        subpathStart = point
                        first = false
                    } else {
                        path.addLine(to: point)
                    }
                    current = point
                }
                lastControl = nil
            case "l":
                while let x = scanner.nextNumber() {
                    let y = scanner.nextNumber() ?? 0
                    var point = CGPoint(x: x, y: y)
                    if relative { point = current + point }
                    path.addLine(to: point)
                    current = point
                }
                lastControl = nil
            case "h":
                while let x = scanner.nextNumber() {
                    let point = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: point)
                    current = point
                }
                lastControl = nil
            case "v":
                while let y = scanner.nextNumber() {
                    let point = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: point)
                    current = point
                }
                lastControl = nil
            case "c":
                while let x1 = scanner.nextNumber() {
                    let y1 = scanner.nextNumber() ?? 0
                    let x2 = scanner.nextNumber() ?? 0
                    let y2 = scanner.nextNumber() ?? 0
                    let x = scanner.nextNumber() ?? 0
                    let y = scanner.nextNumber() ?? 0
                    var c1 = CGPoint(x: x1, y: y1)
                    var c2 = CGPoint(x: x2, y: y2)
                    var end = CGPoint(x: x, y: y)
                    if relative { c1 = current + c1; c2 = current + c2; end = current + end }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                }
            case "s":
                while let x2n = scanner.nextNumber() {
                    let y2 = scanner.nextNumber() ?? 0
                    let x = scanner.nextNumber() ?? 0
                    let y = scanner.nextNumber() ?? 0
                    var c2 = CGPoint(x: x2n, y: y2)
                    var end = CGPoint(x: x, y: y)
                    if relative { c2 = current + c2; end = current + end }
                    let reflectable = "cs".contains(Character(lastCommand.lowercased()))
                    let c1 = (reflectable && lastControl != nil)
                        ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y)
                        : current
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                    lastCommand = command
                }
            case "q":
                while let x1 = scanner.nextNumber() {
                    let y1 = scanner.nextNumber() ?? 0
                    let x = scanner.nextNumber() ?? 0
                    let y = scanner.nextNumber() ?? 0
                    var control = CGPoint(x: x1, y: y1)
                    var end = CGPoint(x: x, y: y)
                    if relative { control = current + control; end = current + end }
                    path.addQuadCurve(to: end, control: control)
                    lastControl = control
                    current = end
                }
            case "a":
                while let rx = scanner.nextNumber() {
                    let ry = scanner.nextNumber() ?? 0
                    let rotation = scanner.nextNumber() ?? 0
                    let largeArc = (scanner.nextNumber() ?? 0) != 0
                    let sweep = (scanner.nextNumber() ?? 0) != 0
                    let x = scanner.nextNumber() ?? 0
                    let y = scanner.nextNumber() ?? 0
                    var end = CGPoint(x: x, y: y)
                    if relative { end = current + end }
                    addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                           rotation: rotation, largeArc: largeArc, sweep: sweep)
                    current = end
                    lastControl = nil
                }
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
            default:
                break
            }
            lastCommand = command
        }
        return path
    }

    /// SVG elliptical arc → cubic segments (endpoint parameterization, W3C F.6.5).
    private static func addArc(
        to path: inout Path, from start: CGPoint, to end: CGPoint,
        rx rxIn: Double, ry ryIn: Double, rotation: Double, largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || start == end {
            path.addLine(to: end)
            return
        }
        let phi = rotation * .pi / 180
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cos(phi) * dx + sin(phi) * dy
        let y1p = -sin(phi) * dx + cos(phi) * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }
        let sign: Double = largeArc != sweep ? 1 : -1
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = sign * sqrt(max(0, numerator / denominator))
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cos(phi) * cxp - sin(phi) * cyp + (start.x + end.x) / 2
        let cy = sin(phi) * cxp + cos(phi) * cyp + (start.y + end.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        var t = theta1
        for _ in 0..<segments {
            let t2 = t + step
            let alpha = 4.0 / 3.0 * tan(step / 4)
            func point(_ theta: Double) -> CGPoint {
                CGPoint(
                    x: cx + rx * cos(theta) * cos(phi) - ry * sin(theta) * sin(phi),
                    y: cy + rx * cos(theta) * sin(phi) + ry * sin(theta) * cos(phi))
            }
            func derivative(_ theta: Double) -> CGPoint {
                CGPoint(
                    x: -rx * sin(theta) * cos(phi) - ry * cos(theta) * sin(phi),
                    y: -rx * sin(theta) * sin(phi) + ry * cos(theta) * cos(phi))
            }
            let p1 = point(t), p2 = point(t2)
            let d1 = derivative(t), d2 = derivative(t2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + alpha * d1.x, y: p1.y + alpha * d1.y),
                control2: CGPoint(x: p2.x - alpha * d2.x, y: p2.y - alpha * d2.y))
            t = t2
        }
    }

    private struct Tokenizer {
        private let characters: [Character]
        private var index = 0

        init(_ string: String) { characters = Array(string) }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < characters.count, characters[index].isLetter else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        mutating func nextNumber() -> Double? {
            skipSeparators()
            guard index < characters.count else { return nil }
            var text = ""
            var seenDot = false
            var char = characters[index]
            if char == "-" || char == "+" {
                text.append(char)
                index += 1
            }
            while index < characters.count {
                char = characters[index]
                if char.isNumber || (char == "." && !seenDot) {
                    if char == "." { seenDot = true }
                    text.append(char)
                    index += 1
                } else if char == "e" || char == "E" {
                    text.append(char)
                    index += 1
                    if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                        text.append(characters[index])
                        index += 1
                    }
                } else {
                    break
                }
            }
            return Double(text)
        }

        private mutating func skipSeparators() {
            while index < characters.count,
                  characters[index] == "," || characters[index].isWhitespace {
                index += 1
            }
        }
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
