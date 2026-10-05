import Foundation

/// Splits text pasted or exported from another clipboard manager into individual entries, so its
/// history can be brought into Clipivo without reading that app's private storage or needing any
/// extra permission (no Full Disk Access). Pure, platform-neutral text handling; turning the
/// entries into clips happens in `ClipivoMacKit` (it reuses the normal capture/classification path).
public enum HistoryImport {
    public enum SplitMode: String, CaseIterable, Sendable {
        /// Every non-empty line is its own clip. Matches most "select all, copy" pastes from a
        /// history list shown one item per line.
        case line
        /// Blank lines separate clips, so a multi-line clip (an address, a short note) stays whole.
        case paragraph

        public var displayName: String {
            switch self {
            case .line: return "One clip per line"
            case .paragraph: return "One clip per blank line (keeps multi-line items together)"
            }
        }
    }

    /// Splits `text` into trimmed, non-empty entries, removing exact duplicates while keeping the
    /// first occurrence's position (so order — and "most recent first" — is preserved).
    public static func split(_ text: String, mode: SplitMode) -> [String] {
        let pieces: [String]
        switch mode {
        case .line:
            pieces = text.components(separatedBy: .newlines)
        case .paragraph:
            pieces = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }
        }
        var seen = Set<String>()
        var result: [String] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Reads entries from a file exported by another app. A JSON array of strings is read
    /// directly; anything else (plain text, CSV, one-per-line exports) falls back to `split`.
    public static func read(fileContents data: Data, fallbackMode: SplitMode) -> [String] {
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            var seen = Set<String>()
            return strings.compactMap { entry -> String? in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
                seen.insert(trimmed)
                return trimmed
            }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return split(text, mode: fallbackMode)
    }
}
