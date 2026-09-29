import Foundation

/// Heuristic detection of secrets and other sensitive clipboard content.
///
/// This is deliberately conservative and **not** a guarantee: it catches common, recognisable
/// formats (keys, tokens, card numbers, one-time codes) and marker types set by password
/// managers. Anything it misses is stored according to the normal policy.
public enum SensitiveContentDetector {
    public enum Finding: String, Codable, Sendable, CaseIterable {
        case passwordManager = "password_manager"
        case privateKey = "private_key"
        case jwt
        case apiKey = "api_key"
        case accessToken = "access_token"
        case envSecret = "env_secret"
        case creditCard = "credit_card"
        case oneTimeCode = "otp"
        case password
        case secretURL = "secret_url"

        public var displayName: String {
            switch self {
            case .passwordManager: return "Password manager item"
            case .privateKey: return "Private key"
            case .jwt: return "JSON Web Token"
            case .apiKey: return "API key"
            case .accessToken: return "Access token"
            case .envSecret: return "Environment secret"
            case .creditCard: return "Card number"
            case .oneTimeCode: return "One-time code"
            case .password: return "Password-like text"
            case .secretURL: return "URL with credentials"
            }
        }
    }

    public struct Report: Sendable, Hashable {
        public var findings: [Finding]
        public var level: SensitivityLevel
        public static let clean = Report(findings: [], level: .none)
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let privateKey = regex(#"-----BEGIN ((RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED) )?PRIVATE KEY( BLOCK)?-----"#)
    private static let jwt = regex(#"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#)
    private static let knownKeys: [NSRegularExpression] = [
        regex(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),                         // AWS access key id
        regex(#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),                     // GitHub tokens
        regex(#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        regex(#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#),                  // Slack
        regex(#"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}\b"#),            // Stripe
        regex(#"\bsk-(proj-|ant-)?[A-Za-z0-9_-]{20,}\b"#),            // OpenAI / Anthropic style
        regex(#"\bAIza[0-9A-Za-z_-]{35}\b"#),                          // Google API key
        regex(#"\bglpat-[A-Za-z0-9_-]{20,}\b"#),                       // GitLab
        regex(#"\bnpm_[A-Za-z0-9]{36}\b"#),                            // npm
        regex(#"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#),     // SendGrid
        regex(#"\bhf_[A-Za-z0-9]{30,}\b"#),                            // Hugging Face
    ]
    private static let bearer = regex(#"\b(Bearer|Token)\s+[A-Za-z0-9._~+/=-]{20,}"#, [.caseInsensitive])
    private static let envSecret = regex(
        #"^\s*+(export\s+)?[A-Z0-9_]{0,48}(SECRET|TOKEN|PASSWORD|PASSWD|PWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIALS?)[A-Z0-9_]{0,48}\s*[=:]\s*['"]?[^\s'"]{6,}"#,
        [.anchorsMatchLines, .caseInsensitive])
    private static let secretURL = regex(#"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@[^\s]+"#, [.caseInsensitive])
    private static let secretQuery = regex(#"[?&](access_token|token|api_key|apikey|secret|password|sig|signature|X-Amz-Signature)=[^&\s]{8,}"#, [.caseInsensitive])
    private static let cardCandidate = regex(#"\b(?:\d[ -]?){13,19}\b"#)

    /// Analyses text (and optional clipboard marker types) for sensitive content.
    public static func analyze(text: String?, declaredTypes: Set<String> = [], sourceBundleID: String? = nil) -> Report {
        var findings: [Finding] = []
        if declaredTypes.contains(RepresentationType.concealed) || passwordManagerBundles.contains(sourceBundleID ?? "") {
            findings.append(.passwordManager)
        }
        guard let text, !text.isEmpty else {
            return Report(findings: findings, level: findings.isEmpty ? .none : .likely)
        }
        // Scan a bounded prefix; secrets pasted inside enormous documents are out of scope.
        let sample = String(text.prefix(64_000))
        let range = NSRange(sample.startIndex..., in: sample)
        func matches(_ r: NSRegularExpression) -> Bool { r.firstMatch(in: sample, options: [], range: range) != nil }

        if matches(privateKey) { findings.append(.privateKey) }
        if matches(jwt) { findings.append(.jwt) }
        if knownKeys.contains(where: matches) { findings.append(.apiKey) }
        if matches(bearer) { findings.append(.accessToken) }
        if matches(envSecret) { findings.append(.envSecret) }
        if matches(secretURL) || matches(secretQuery) { findings.append(.secretURL) }
        if containsCardNumber(sample, range: range) { findings.append(.creditCard) }

        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if isOneTimeCode(trimmed) { findings.append(.oneTimeCode) }
        if findings.isEmpty, isPasswordLike(trimmed) { findings.append(.password) }

        let strong: Set<Finding> = [.passwordManager, .privateKey, .jwt, .apiKey, .accessToken, .envSecret, .creditCard, .secretURL]
        let level: SensitivityLevel
        if findings.contains(where: strong.contains) { level = .likely }
        else if findings.isEmpty { level = .none }
        else { level = .possible }
        return Report(findings: findings, level: level)
    }

    /// Bundle identifiers of common password managers; clips from them are always treated as sensitive.
    public static let passwordManagerBundles: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc", "com.enpass.Enpass-Desktop",
        "com.nordpass.macos.NordPass", "com.keepersecurity.passwordmanager", "com.proton.pass",
    ]

    static func containsCardNumber(_ s: String, range: NSRange) -> Bool {
        for match in cardCandidate.matches(in: s, options: [], range: range) {
            guard let r = Range(match.range, in: s) else { continue }
            let digits = s[r].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count), luhn(digits) else { continue }
            // Reject runs of a single repeated digit, which pass Luhn by coincidence.
            if Set(digits).count <= 1 { continue }
            // Known issuer prefixes (Visa, Mastercard, Amex, Discover, JCB, Diners, UnionPay, Maestro, RuPay).
            let prefix = digits.prefix(2).reduce(0) { $0 * 10 + $1 }
            let issuerPrefixes: Set<Int> = [34, 35, 36, 37, 38, 30, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 62, 63, 64, 65, 67, 22, 23, 24, 25, 26, 27]
            if digits.first == 4 || issuerPrefixes.contains(prefix) { return true }
        }
        return false
    }

    public static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0 && !digits.isEmpty
    }

    /// A standalone 4–8 digit code (optionally split by a space or dash), typical of 2FA messages.
    public static func isOneTimeCode(_ s: String) -> Bool {
        guard (4...9).contains(s.count) else { return false }
        let compact = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard (4...8).contains(compact.count), compact.allSatisfy(\.isASCIIDigitCharacter) else { return false }
        // Avoid flagging years such as 2024 and trivially repeated digits.
        if compact.count == 4, let value = Int(compact), (1900...2100).contains(value) { return false }
        if Set(compact).count == 1 { return false }
        return true
    }

    /// Single token, 8–64 characters, mixing at least three character classes and with no
    /// dictionary-like structure. This is a weak signal and only yields `.possible`.
    public static func isPasswordLike(_ s: String) -> Bool {
        guard (8...64).contains(s.count), !s.contains(where: \.isWhitespace) else { return false }
        if s.contains("://") || s.contains("/") || s.hasPrefix("#") || s.contains("@") && s.contains(".") { return false }
        // Separators common in identifiers, serials and SKUs (ESP-MATRIX-0010, build_2024.1) are not "symbols".
        let separators: Set<Character> = ["-", "_", ".", ":"]
        var classes = 0
        if s.contains(where: \.isLowercase) { classes += 1 }
        if s.contains(where: \.isUppercase) { classes += 1 }
        if s.contains(where: \.isASCIIDigitCharacter) { classes += 1 }
        if s.contains(where: { !$0.isLetter && !$0.isNumber && !separators.contains($0) }) { classes += 1 }
        guard classes >= 3 else { return false }
        // Separator-delimited identifiers whose parts are each single-case (build_2024.10-RC1) are versions/IDs.
        let segments = s.split(whereSeparator: { separators.contains($0) })
        if segments.count >= 2, segments.allSatisfy({ !($0.contains(where: \.isLowercase) && $0.contains(where: \.isUppercase)) }) {
            return false
        }
        // Identifiers such as `myVariableName2` or `snake_case_name` are common in code; require entropy.
        return shannonEntropy(s) >= 3.0
    }

    static func shannonEntropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let length = Double(s.count)
        return counts.values.reduce(0) { acc, count in
            let p = Double(count) / length
            return acc - p * log2(p)
        }
    }
}

extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}
