import Foundation

/// Result of classifying a clipboard snapshot. Pure data; deterministic for a given input.
public struct Classification: Sendable {
    public var kind: ClipKind
    public var autoTitle: String?
    public var metadata: ClipMetadata
    /// Canonical searchable/plain text for the clip (may be derived, e.g. file paths).
    public var searchableText: String
    /// Text that "Paste as Plain Text" should produce, when available.
    public var plainText: String?
    public var sensitivity: SensitiveContentDetector.Report
    public var urlString: String?
}

public enum ContentClassifier {
    /// Bundle identifiers of screenshot tools. Images copied while these are frontmost are screenshots.
    public static let screenshotBundles: Set<String> = [
        "com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.Screenshot",
        "cc.ffitch.shottr", "pl.maketheweb.cleanshotx", "com.techsmith.snagit.capturehelper2020",
        "com.monosnap.monosnap", "com.xnapper.app", "com.augiefra.PastScreen", "com.skitch.skitch",
    ]

    public static func classify(_ snapshot: ClipboardSnapshot) -> Classification {
        let types = snapshot.declaredTypes
        let text = snapshot.plainText
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceBundle = snapshot.sourceApp?.bundleID
        let sensitivity = SensitiveContentDetector.analyze(text: text, declaredTypes: types, sourceBundleID: sourceBundle)
        var metadata = ClipMetadata()
        metadata.representationTypes = Array(Set(snapshot.allRepresentations.map(\.type))).sorted()
        if !sensitivity.findings.isEmpty { metadata.sensitiveKinds = sensitivity.findings.map(\.rawValue) }

        func result(_ kind: ClipKind, title: String?, searchable: String? = nil, plain: String? = text, url: String? = nil) -> Classification {
            Classification(kind: kind, autoTitle: title, metadata: metadata, searchableText: searchable ?? (text ?? ""),
                           plainText: plain, sensitivity: sensitivity, urlString: url)
        }

        // 1. Files and folders.
        let fileURLs = snapshot.fileURLs
        if !fileURLs.isEmpty {
            let names = fileURLs.map { $0.lastPathComponent }
            metadata.fileNames = Array(names.prefix(50))
            metadata.fileCount = fileURLs.count
            let paths = fileURLs.map(\.path)
            let isFolder = fileURLs.count == 1 && snapshot.hints.directoryPaths.contains(paths[0])
            let title = fileURLs.count == 1 ? names[0] : "\(names[0]) and \(fileURLs.count - 1) more"
            return result(isFolder ? .folder : .file, title: title, searchable: paths.joined(separator: "\n"),
                          plain: paths.joined(separator: "\n"))
        }

        // 2. Bitmap images and screenshots (take priority over any accompanying text such as a file name).
        if let image = snapshot.imageData {
            if let size = snapshot.hints.imagePixelSize {
                metadata.imageWidth = size.width
                metadata.imageHeight = size.height
            }
            let isScreenshot = isLikelyScreenshot(snapshot, imageType: image.type)
            var title = isScreenshot ? "Screenshot" : "Image"
            if let w = metadata.imageWidth, let h = metadata.imageHeight { title += " \(w)×\(h)" }
            let hasMeaningfulText = !trimmed.isEmpty && types.contains(RepresentationType.html) == false
            return result(isScreenshot ? .screenshot : .image, title: title,
                          searchable: hasMeaningfulText ? trimmed : "", plain: hasMeaningfulText ? text : nil)
        }

        // 3. PDF data.
        if snapshot.first(RepresentationType.pdf) != nil && trimmed.isEmpty {
            metadata.pageCount = snapshot.hints.pdfPageCount
            let title = metadata.pageCount.map { "PDF, \($0) page\($0 == 1 ? "" : "s")" } ?? "PDF"
            return result(.pdf, title: title, searchable: "", plain: nil)
        }

        // 4. Native color objects.
        if let hex = snapshot.hints.colorHex, types.contains(RepresentationType.color) {
            metadata.colorHex = hex
            return result(.color, title: hex, searchable: [hex, trimmed].filter { !$0.isEmpty }.joined(separator: " "),
                          plain: trimmed.isEmpty ? hex : text)
        }

        // 5. Explicit URL representations without other text.
        if trimmed.isEmpty, let urlData = snapshot.first(RepresentationType.url),
           let urlString = String(data: urlData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: urlString), url.scheme != nil {
            metadata.urlHost = url.host
            return result(.url, title: autoTitle(for: url), searchable: urlString, plain: urlString, url: urlString)
        }

        guard !trimmed.isEmpty else {
            return result(.unknown, title: nil, searchable: "", plain: nil)
        }

        let isRich = types.contains(RepresentationType.rtf) || types.contains(RepresentationType.html) || types.contains(RepresentationType.rtfd)
        let singleToken = !trimmed.contains(where: \.isWhitespace)

        // 6. Text-shaped kinds, most specific first.
        if singleToken, let url = webURL(trimmed) {
            metadata.urlHost = url.host
            return result(.url, title: autoTitle(for: url), url: trimmed)
        }
        if let color = ColorParser.parse(trimmed) {
            metadata.colorHex = color.hex
            let searchable = trimmed.caseInsensitiveCompare(color.hex) == .orderedSame ? trimmed : "\(trimmed)\n\(color.hex)"
            return result(.color, title: color.hex, searchable: searchable)
        }
        if isEmail(trimmed) {
            return result(.email, title: trimmed.replacingOccurrences(of: "mailto:", with: ""))
        }
        if sensitivity.findings.contains(.oneTimeCode) {
            return result(.otp, title: "Code \(trimmed)")
        }
        if isPhoneNumber(trimmed) {
            return result(.phone, title: trimmed)
        }
        if sensitivity.level == .likely && !sensitivity.findings.contains(.creditCard) || sensitivity.findings == [.password] {
            let title = sensitivity.findings.first?.displayName ?? "Credential"
            // A private key or env file can also be code; the credential classification wins for safety.
            return result(.credential, title: title)
        }
        if let code = CodeDetector.detect(trimmed) {
            metadata.codeLanguage = code.language
            return result(.code, title: "\(CodeDetector.displayName(code.language)) snippet")
        }
        if isPostalAddress(trimmed) {
            return result(.address, title: trimmed.firstNonEmptyLine)
        }
        return result(isRich ? .richText : .text, title: nil)
    }

    static func isLikelyScreenshot(_ snapshot: ClipboardSnapshot, imageType: String) -> Bool {
        if let bundle = snapshot.sourceApp?.bundleID, screenshotBundles.contains(bundle) { return true }
        // The system screenshot shortcut (⌃⇧⌘4) writes a PNG and nothing else.
        let meaningful = snapshot.declaredTypes.filter { !RepresentationType.isIgnored($0) }
        return imageType == RepresentationType.png && meaningful == [RepresentationType.png]
    }

    static func webURL(_ s: String) -> URL? {
        guard s.count <= 8_192, let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "ftp", "sftp", "ssh", "file", "ws", "wss":
            return url.host != nil || scheme == "file" ? url : nil
        default:
            // App deep links (e.g. `slack://`, `vscode://`) are still URLs worth treating as links.
            return s.contains("://") && url.host != nil ? url : nil
        }
    }

    static func autoTitle(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path == "/" ? "" : url.path
        return String((trimmedHost + path).prefix(120))
    }

    private static let emailRegex = try! NSRegularExpression(pattern: #"^(mailto:)?[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.caseInsensitive])
    private static let phoneRegex = try! NSRegularExpression(pattern: #"^\+?[0-9(][0-9 ().-]{6,18}[0-9]$"#)
    private static let streetRegex = try! NSRegularExpression(
        pattern: #"\b\d{1,5}\s+([A-Za-z0-9.'-]+\s){0,4}(street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|court|ct|way|parkway|pkwy|place|pl|terrace|highway|hwy|nagar|marg)\b\.?"#,
        options: [.caseInsensitive])
    private static let postalRegex = try! NSRegularExpression(
        pattern: #"(\b[A-Z]{2}\s+\d{5}(-\d{4})?\b)|(\b\d{6}\b)|(\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b)"#, options: [])

    static func isEmail(_ s: String) -> Bool {
        s.count <= 320 && emailRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func isPhoneNumber(_ s: String) -> Bool {
        guard s.count <= 22, phoneRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { return false }
        let digits = s.filter(\.isASCIIDigitCharacter)
        // Plain digit runs without separators or a leading + are more likely IDs than phone numbers.
        let hasPhoneShape = s.hasPrefix("+") || s.contains(" ") || s.contains("-") || s.contains("(")
        return (7...15).contains(digits.count) && hasPhoneShape
    }

    static func isPostalAddress(_ s: String) -> Bool {
        let lines = s.split(whereSeparator: \.isNewline)
        guard s.count <= 300, (1...6).contains(lines.count) else { return false }
        let range = NSRange(s.startIndex..., in: s)
        let hasStreet = streetRegex.firstMatch(in: s, range: range) != nil
        let hasPostal = postalRegex.firstMatch(in: s, range: range) != nil
        return hasStreet && (hasPostal || lines.count >= 2)
    }
}
