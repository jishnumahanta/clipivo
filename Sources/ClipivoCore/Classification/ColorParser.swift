import Foundation

/// Parses CSS-style color strings. Returns normalized components in 0...1.
public struct ParsedColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    /// `#RRGGBB` or `#RRGGBBAA` when not fully opaque.
    public var hex: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        if alpha < 0.999 {
            return String(format: "#%02X%02X%02X%02X", r, g, b, Int((alpha * 255).rounded()))
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public var rgbString: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        if alpha < 0.999 { return "rgba(\(r), \(g), \(b), \(String(format: "%.2g", alpha)))" }
        return "rgb(\(r), \(g), \(b))"
    }

    public var hslString: String {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let l = (maxC + minC) / 2
        var h = 0.0, s = 0.0
        if maxC != minC {
            let d = maxC - minC
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case red: h = (green - blue) / d + (green < blue ? 6 : 0)
            case green: h = (blue - red) / d + 2
            default: h = (red - green) / d + 4
            }
            h /= 6
        }
        return "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

public enum ColorParser {
    public static func parse(_ input: String) -> ParsedColor? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 64 else { return nil }
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
        if s.hasPrefix("0x"), s.count == 8 { return parseHex(String(s.dropFirst(2))) }
        if s.hasPrefix("rgb") { return parseRGB(s) }
        if s.hasPrefix("hsl") { return parseHSL(s) }
        return nil
    }

    static func parseHex(_ hex: String) -> ParsedColor? {
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(hex)
        func pair(_ i: Int) -> Double? { Int(String(chars[i...i + 1]), radix: 16).map { Double($0) / 255 } }
        func single(_ i: Int) -> Double? { Int(String([chars[i], chars[i]]), radix: 16).map { Double($0) / 255 } }
        switch chars.count {
        case 3:
            guard let r = single(0), let g = single(1), let b = single(2) else { return nil }
            return ParsedColor(red: r, green: g, blue: b)
        case 4:
            guard let r = single(0), let g = single(1), let b = single(2), let a = single(3) else { return nil }
            return ParsedColor(red: r, green: g, blue: b, alpha: a)
        case 6:
            guard let r = pair(0), let g = pair(2), let b = pair(4) else { return nil }
            return ParsedColor(red: r, green: g, blue: b)
        case 8:
            guard let r = pair(0), let g = pair(2), let b = pair(4), let a = pair(6) else { return nil }
            return ParsedColor(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    private static func arguments(_ s: String, prefixes: [String]) -> [String]? {
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let name = s[..<open].trimmingCharacters(in: .whitespaces)
        guard prefixes.contains(name) else { return nil }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        // Accept both comma-separated and modern space-separated syntax (`rgb(1 2 3 / 50%)`).
        let normalized = inner.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
        let parts = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        return (parts.count == 3 || parts.count == 4) ? parts : nil
    }

    private static func number(_ token: String, percentScale: Double, plainScale: Double) -> Double? {
        if token.hasSuffix("%") {
            guard let v = Double(token.dropLast()) else { return nil }
            return v / 100 * percentScale
        }
        guard let v = Double(token) else { return nil }
        return v / plainScale
    }

    static func parseRGB(_ s: String) -> ParsedColor? {
        guard let args = arguments(s, prefixes: ["rgb", "rgba"]) else { return nil }
        guard let r = number(args[0], percentScale: 1, plainScale: 255),
              let g = number(args[1], percentScale: 1, plainScale: 255),
              let b = number(args[2], percentScale: 1, plainScale: 255) else { return nil }
        guard [r, g, b].allSatisfy({ (0...1.0001).contains($0) }) else { return nil }
        var a = 1.0
        if args.count == 4 {
            guard let parsed = number(args[3], percentScale: 1, plainScale: 1), (0...1.0001).contains(parsed) else { return nil }
            a = parsed
        }
        return ParsedColor(red: r, green: g, blue: b, alpha: a)
    }

    static func parseHSL(_ s: String) -> ParsedColor? {
        guard let args = arguments(s, prefixes: ["hsl", "hsla"]) else { return nil }
        let hueToken = args[0].replacingOccurrences(of: "deg", with: "")
        guard let hDeg = Double(hueToken),
              let sat = number(args[1], percentScale: 1, plainScale: 100),
              let light = number(args[2], percentScale: 1, plainScale: 100),
              (0...1.0001).contains(sat), (0...1.0001).contains(light) else { return nil }
        var a = 1.0
        if args.count == 4 {
            guard let parsed = number(args[3], percentScale: 1, plainScale: 1) else { return nil }
            a = parsed
        }
        let h = (hDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func hueToRGB(_ p: Double, _ q: Double, _ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if sat == 0 { return ParsedColor(red: light, green: light, blue: light, alpha: a) }
        let q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
        let p = 2 * light - q
        return ParsedColor(red: hueToRGB(p, q, h + 1.0 / 3), green: hueToRGB(p, q, h), blue: hueToRGB(p, q, h - 1.0 / 3), alpha: a)
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
