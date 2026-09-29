import Foundation

/// Deterministic, heuristic source-code detection. It never executes anything; it scores the
/// text against per-language signals and a generic "looks like code" score.
public enum CodeDetector {
    public struct Result: Sendable, Hashable {
        public var language: String
        public var confidence: Double
    }

    private struct Signal {
        let regex: NSRegularExpression
        let weight: Double
        init(_ pattern: String, _ weight: Double, options: NSRegularExpression.Options = [.anchorsMatchLines]) {
            // Patterns are compile-time constants; a failure here is a programming error caught by tests.
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.weight = weight
        }
    }

    private static let languages: [(String, [Signal])] = [
        ("swift", [
            Signal(#"^\s*import (SwiftUI|Foundation|UIKit|AppKit|Combine)\b"#, 4),
            Signal(#"\b(func|guard|let|var)\s+\w++[^\n]{0,200}?(->|:\s*\w|=)"#, 1.5),
            Signal(#"\bguard\s+let\b"#, 3), Signal(#"\bif\s+let\b"#, 2.5),
            Signal(#"@(State|Published|MainActor|Observable|objc)\b"#, 3),
            Signal(#"\bstruct\s+\w+\s*:\s*View\b"#, 4), Signal(#"\bfunc\s+\w+\("#, 1.5),
        ]),
        ("typescript", [
            Signal(#"\b(interface|type)\s+\w+\s*(=|\{)"#, 2.5), Signal(#":\s*(string|number|boolean|any|unknown|void)\b"#, 3),
            Signal(#"^\s*import .* from ['"]"#, 2), Signal(#"\bexport\s+(default\s+)?(function|const|class|interface|type)\b"#, 2),
            Signal(#"<\w+>\("#, 1),
        ]),
        ("javascript", [
            Signal(#"\b(const|let|var)\s+\w+\s*=\s*"#, 1.5), Signal(#"=>\s*[{(]?"#, 1.5),
            Signal(#"\bfunction\s*\w*\s*\("#, 2), Signal(#"\bconsole\.log\("#, 3),
            Signal(#"\brequire\(['"]"#, 3), Signal(#"^\s*import .* from ['"]"#, 2),
            Signal(#"\b(document|window)\.\w+"#, 2), Signal(#"\bawait\s+fetch\("#, 2),
        ]),
        ("python", [
            Signal(#"^\s*def\s+\w++\([^\n]{0,300}\)\s*+(->\s*+[\w\[\], ]++)?:\s*$"#, 4), Signal(#"^\s*class\s+\w+(\(.*\))?:\s*$"#, 3),
            Signal(#"^\s*(from\s+[\w.]+\s+)?import\s+[\w., ]+$"#, 1.5), Signal(#"\bprint\("#, 1),
            Signal(#"^\s*(if|elif|for|while|with|try|except)\b.*:\s*$"#, 1.5), Signal(#"\bself\.\w+"#, 2),
            Signal(#"__name__\s*==\s*['"]__main__['"]"#, 5),
        ]),
        ("java", [
            Signal(#"\bpublic\s+(static\s+)?(class|void|final|interface)\b"#, 3), Signal(#"\bSystem\.out\.println\("#, 5),
            Signal(#"^\s*import\s+java\."#, 5), Signal(#"^\s*package\s+[\w.]+;"#, 4), Signal(#"@Override\b"#, 3),
        ]),
        ("kotlin", [
            Signal(#"\bfun\s+\w+\("#, 3), Signal(#"\bval\s+\w+\s*[:=]"#, 2), Signal(#"^\s*import\s+(android|kotlinx?|androidx)\."#, 5),
            Signal(#"@Composable\b"#, 5),
        ]),
        ("csharp", [
            Signal(#"^\s*using\s+System(\.\w+)*;"#, 5), Signal(#"\bnamespace\s+[\w.]+"#, 2.5),
            Signal(#"\bpublic\s+(async\s+)?(Task|void|string|int)\s+\w+\("#, 2.5), Signal(#"Console\.WriteLine\("#, 5),
        ]),
        ("cpp", [
            Signal(#"^\s*#include\s*<(iostream|vector|string|memory|map)>"#, 5), Signal(#"\bstd::\w+"#, 4),
            Signal(#"\btemplate\s*<"#, 3), Signal(#"\bcout\s*<<"#, 4),
        ]),
        ("c", [
            Signal(#"^\s*#include\s*[<"][\w/.]+\.h[>"]"#, 4), Signal(#"\bint\s+main\s*\("#, 3),
            Signal(#"\bprintf\("#, 2.5), Signal(#"\bmalloc\("#, 3), Signal(#"^\s*#define\s+\w+"#, 2.5),
        ]),
        ("go", [
            Signal(#"^\s*package\s+\w+\s*$"#, 3), Signal(#"\bfunc\s+(\(\w+\s+\*?\w+\)\s*)?\w+\("#, 2.5),
            Signal(#":=\s*"#, 2), Signal(#"\bfmt\.\w+\("#, 4), Signal(#"^\s*import\s+\($"#, 3),
        ]),
        ("rust", [
            Signal(#"\bfn\s+\w+\s*(<.*>)?\("#, 3), Signal(#"\blet\s+mut\b"#, 4), Signal(#"\bimpl\b.*\{"#, 3),
            Signal(#"\bprintln!\("#, 5), Signal(#"^\s*use\s+[\w:]+(::\{.*\})?;"#, 3), Signal(#"&mut\s"#, 3),
        ]),
        ("php", [
            Signal(#"<\?php"#, 6), Signal(#"\$\w+\s*=\s*"#, 1.5), Signal(#"\bfunction\s+\w+\(\$"#, 4), Signal(#"->\w+\("#, 1),
            Signal(#"\becho\s+"#, 1),
        ]),
        ("ruby", [
            Signal(#"^\s*def\s+\w+[?!]?(\(.*\))?\s*$"#, 2.5), Signal(#"^\s*end\s*$"#, 2), Signal(#"\bputs\s+"#, 2.5),
            Signal(#"^\s*require\s+['"]"#, 2.5), Signal(#"\bdo\s*\|\w+\|"#, 4),
        ]),
        ("sql", [
            Signal(#"\bSELECT\b[\s\S]{1,2000}?\bFROM\b"#, 5, options: [.caseInsensitive]),
            Signal(#"\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|CREATE\s+(TABLE|INDEX|VIEW)|ALTER\s+TABLE|DROP\s+TABLE)\b"#, 5, options: [.caseInsensitive]),
            Signal(#"\b(WHERE|JOIN|GROUP BY|ORDER BY|LIMIT)\b"#, 1.5),
        ]),
        ("css", [
            // Possessive quantifiers keep this selector pattern linear-time (no catastrophic backtracking).
            Signal(#"^\s*+[.#]?[\w-]++(?:\s*+[,>+~]?\s*+[.#:]?[\w-]++)*+\s*+\{\s*$"#, 2),
            Signal(#"^\s*[\w-]+\s*:\s*[^;]+;\s*$"#, 1.5), Signal(#"@media\b|@keyframes\b|@import\b"#, 4),
            Signal(#"\b(color|margin|padding|display|font-size|background)\s*:"#, 2),
        ]),
        ("html", [
            Signal(#"<!DOCTYPE\s+html"#, 6, options: [.caseInsensitive]),
            Signal(#"<(html|head|body|div|span|p|a|ul|li|script|style|section|button|input)(\s[^>]*)?>"#, 2.5, options: [.caseInsensitive]),
            Signal(#"</\w+>"#, 1.5),
        ]),
        ("bash", [
            Signal(#"^#!\s*/(usr/)?bin/(env\s+)?(ba|z)?sh"#, 6),
            // Unambiguous command names.
            Signal(#"^\s*(\$\s+)?(sudo|brew|npm|npx|yarn|pnpm|pip3?|git|curl|wget|chmod|chown|docker|kubectl|ssh|scp|cargo|xcodebuild|python3|mkdir|rm|ls)\s+[\w./~@:$-]"#, 2.5),
            // Command names that are also English words ("go ahead", "make sure", "export the report")
            // only count when followed by something command-shaped: a flag, path, variable or known subcommand.
            Signal(#"^\s*(\$\s+)?(cd|cp|mv|echo|export|make|go|swift|python)\s+(-{1,2}\w|[~/.$"']|\w+=|\w*/|(run|build|test|get|mod|install|vet|fmt|package|clean|all)\b)"#, 2.5),
            Signal(#"\|\s*(grep|awk|sed|xargs|sort|head|tail|wc)\b"#, 3), Signal(#"&&\s*\w+"#, 1), Signal(#"\$\{?\w+\}?"#, 0.5),
        ]),
        ("yaml", [
            Signal(#"^\s*[\w-]+:\s*(\S.*)?$"#, 0.6), Signal(#"^\s*-\s+[\w-]+:\s"#, 1.5), Signal(#"^---\s*$"#, 2),
        ]),
    ]

    private static let genericSignals: [Signal] = [
        Signal(#"[;{}]\s*$"#, 1), Signal(#"^\s{2,}\S"#, 0.4), Signal(#"\w+\([^)]*\)"#, 0.5),
        Signal(#"(==|!=|<=|>=|&&|\|\||=>|->|::)"#, 0.6), Signal(#"^\s*(//|#|/\*|\*)"#, 0.4),
    ]

    /// Returns the most likely language, or `nil` when the text does not look like code.
    public static func detect(_ text: String) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        // Analyse at most 20 KB — detection accuracy does not improve beyond that.
        let sample = String(trimmed.prefix(20_000))

        if let json = detectJSON(sample) { return json }

        let lines = sample.split(whereSeparator: \.isNewline)
        let lineCount = max(lines.count, 1)
        let range = NSRange(sample.startIndex..., in: sample)

        func score(_ signals: [Signal]) -> Double {
            signals.reduce(0) { total, signal in
                let matches = signal.regex.numberOfMatches(in: sample, options: [], range: range)
                return total + signal.weight * Double(min(matches, 6))
            }
        }

        var best: (String, Double)?
        for (language, signals) in languages {
            let s = score(signals)
            if s > (best?.1 ?? 0) { best = (language, s) }
        }
        guard let (language, languageScore) = best else { return nil }

        let generic = score(genericSignals)
        let proseRatio = proseLikeness(sample)

        // Single-line snippets need a strong, specific signal.
        let threshold: Double = lineCount == 1 ? 2.5 : 3.5
        let combined = languageScore + generic * 0.5
        guard languageScore >= 2.5, combined >= threshold else { return nil }
        // Prose that merely mentions a keyword ("Select the file from the list") should not count.
        if proseRatio > 0.6 && languageScore < 6 { return nil }
        // Casual prose (often lowercase, so the sentence check above misses it): many everyday
        // words and almost no code punctuation.
        if languageScore < 6 && stopwordRatio(sample) >= 0.2 && symbolDensity(sample) < 0.02 { return nil }
        // Longer text must *look* like code line by line, not just contain a few code-ish lines.
        if lineCount >= 6 && codeLineRatio(lines) < 0.3 && language != "yaml" { return nil }
        if language == "yaml" && yamlLineRatio(lines) < 0.7 { return nil }

        return Result(language: language, confidence: min(1, combined / 12))
    }

    private static func detectJSON(_ s: String) -> Result? {
        guard let first = s.first, let last = s.last,
              (first == "{" && last == "}") || (first == "[" && last == "]"), s.count >= 2 else { return nil }
        guard let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let array = object as? [Any], array.isEmpty { return nil }
        return Result(language: "json", confidence: 0.95)
    }

    private static let codeLineSignal = try! NSRegularExpression(
        pattern: #"([;{}()\[\]=<>$|&]|^\s{2,}\S|^\s*(#|//|--)\s?\S|::|->|=>)"#)
    private static let yamlLine = try! NSRegularExpression(pattern: #"^\s*(-\s+)?[\w.\-\"']+:(\s|$)|^\s*-\s+\S|^\s*#|^---\s*$"#)

    /// Fraction of non-empty lines with at least one code-like token (brackets, operators, indentation…).
    private static func codeLineRatio(_ lines: [Substring]) -> Double {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        let hits = nonEmpty.filter { line in
            let s = String(line)
            return codeLineSignal.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        return Double(hits.count) / Double(nonEmpty.count)
    }

    /// Fraction of non-empty lines that are valid YAML structure (key: value, list items, comments).
    private static func yamlLineRatio(_ lines: [Substring]) -> Double {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        let hits = nonEmpty.filter { line in
            let s = String(line)
            return yamlLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        return Double(hits.count) / Double(nonEmpty.count)
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "for", "to", "of", "in", "on", "at", "by", "with", "from", "which", "that",
        "this", "it", "its", "is", "are", "was", "be", "will", "would", "can", "could", "should", "i", "you", "we", "they",
        "my", "your", "our", "also", "sure", "please", "about", "into", "what", "how", "when", "where", "there", "here",
    ]

    /// Fraction of words that are common English function words.
    private static func stopwordRatio(_ s: String) -> Double {
        let words = s.lowercased().split { !$0.isLetter }
        guard words.count >= 6 else { return 0 }
        return Double(words.filter { stopwords.contains(String($0)) }.count) / Double(words.count)
    }

    /// Code punctuation per character.
    private static func symbolDensity(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let symbols = s.filter { "{}[]();=<>$|&/\\_\"'`#*+%@".contains($0) }.count
        return Double(symbols) / Double(s.count)
    }

    /// Fraction of lines that read like sentences (start with a capital, end in punctuation, mostly words).
    private static func proseLikeness(_ s: String) -> Double {
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return 0 }
        let prose = lines.filter { line in
            let words = line.split(separator: " ")
            guard words.count >= 5 else { return false }
            let symbolCount = line.filter { "{}();=<>[]$#".contains($0) }.count
            return symbolCount <= 1 && (line.first?.isUppercase ?? false)
        }
        return Double(prose.count) / Double(lines.count)
    }

    /// Human-readable language name for UI.
    public static func displayName(_ language: String) -> String {
        switch language {
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "csharp": return "C#"
        case "cpp": return "C++"
        case "php": return "PHP"
        case "sql": return "SQL"
        case "css": return "CSS"
        case "html": return "HTML"
        case "json": return "JSON"
        case "yaml": return "YAML"
        case "bash": return "Shell"
        default: return language.prefix(1).uppercased() + language.dropFirst()
        }
    }

    /// Keywords used by the lightweight syntax highlighter in the UI layer.
    public static func keywords(for language: String) -> Set<String> {
        switch language {
        case "swift": return ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import", "for", "in", "while", "switch", "case", "default", "self", "Self", "init", "private", "public", "internal", "fileprivate", "static", "async", "await", "throws", "try", "some", "any", "nil", "true", "false", "where", "actor", "defer", "do", "catch"]
        case "javascript", "typescript": return ["function", "const", "let", "var", "if", "else", "return", "for", "while", "class", "extends", "import", "from", "export", "default", "new", "this", "async", "await", "try", "catch", "throw", "null", "undefined", "true", "false", "typeof", "instanceof", "interface", "type", "implements", "enum", "of", "in", "switch", "case", "break", "continue"]
        case "python": return ["def", "class", "import", "from", "as", "if", "elif", "else", "return", "for", "while", "in", "not", "and", "or", "is", "None", "True", "False", "with", "try", "except", "finally", "raise", "lambda", "yield", "async", "await", "pass", "self", "global", "nonlocal"]
        case "java", "kotlin", "csharp": return ["public", "private", "protected", "class", "interface", "static", "final", "void", "int", "long", "double", "boolean", "String", "new", "return", "if", "else", "for", "while", "try", "catch", "throw", "throws", "import", "package", "extends", "implements", "this", "null", "true", "false", "fun", "val", "var", "override", "using", "namespace", "async", "await", "string", "bool"]
        case "c", "cpp": return ["int", "char", "float", "double", "void", "long", "short", "unsigned", "struct", "union", "enum", "typedef", "if", "else", "for", "while", "do", "return", "switch", "case", "break", "continue", "const", "static", "sizeof", "class", "public", "private", "template", "typename", "namespace", "using", "new", "delete", "auto", "nullptr", "true", "false"]
        case "go": return ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "nil", "true", "false", "select"]
        case "rust": return ["fn", "let", "mut", "if", "else", "match", "loop", "while", "for", "in", "return", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "as", "ref", "move", "async", "await", "where", "true", "false", "const", "static", "unsafe"]
        case "php": return ["function", "echo", "return", "if", "else", "elseif", "foreach", "as", "while", "class", "public", "private", "protected", "static", "new", "null", "true", "false", "namespace", "use", "array"]
        case "ruby": return ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "do", "return", "require", "self", "nil", "true", "false", "puts", "yield", "begin", "rescue"]
        case "sql": return ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT", "NULL", "GROUP", "BY", "ORDER", "LIMIT", "AS", "DISTINCT", "HAVING", "PRIMARY", "KEY", "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "join", "on", "and", "or", "not", "null", "group", "by", "order", "limit", "as"]
        case "bash": return ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "sudo", "cd"]
        default: return []
        }
    }
}
