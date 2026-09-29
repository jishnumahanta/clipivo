import AppKit
import ClipivoCore

/// A small, fast, regex-based highlighter for previews. It is intentionally approximate:
/// keywords, strings, comments and numbers — enough to make snippets readable.
enum SyntaxHighlighter {
    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`"#)
    private static let lineCommentRegex = try! NSRegularExpression(pattern: #"(//|#(?!include|define|!)|--)[^\n]*"#)
    private static let blockCommentRegex = try! NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    static func highlight(_ code: String, language: String?, fontSize: CGFloat = 12) -> NSAttributedString {
        let text = String(code.prefix(30_000))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let range = NSRange(location: 0, length: (text as NSString).length)

        let keywords = CodeDetector.keywords(for: language ?? "")
        if !keywords.isEmpty {
            for match in wordRegex.matches(in: text, range: range) {
                let word = (text as NSString).substring(with: match.range)
                if keywords.contains(word) {
                    result.addAttributes([.foregroundColor: NSColor.systemPink,
                                          .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)], range: match.range)
                }
            }
        }
        for match in numberRegex.matches(in: text, range: range) {
            result.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: match.range)
        }
        for match in stringRegex.matches(in: text, range: range) {
            result.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
        }
        if language != "json" {
            let commentRegexes = (language == "python" || language == "bash" || language == "ruby" || language == "yaml")
                ? [lineCommentRegex] : [lineCommentRegex, blockCommentRegex]
            for regex in commentRegexes {
                for match in regex.matches(in: text, range: range) {
                    // `//` inside URLs in strings is common; only colour comments outside strings.
                    if let color = result.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor,
                       color == NSColor.systemGreen { continue }
                    result.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                          .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)], range: match.range)
                }
            }
        }
        return result
    }
}
