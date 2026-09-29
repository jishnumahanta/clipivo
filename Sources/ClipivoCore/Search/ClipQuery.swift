import Foundation

/// Which indexed fields free-text search looks at. Maps to FTS5 columns.
public struct SearchFields: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let titles = SearchFields(rawValue: 1 << 0)
    public static let content = SearchFields(rawValue: 1 << 1)
    public static let ocr = SearchFields(rawValue: 1 << 2)
    public static let fileNames = SearchFields(rawValue: 1 << 3)
    public static let urls = SearchFields(rawValue: 1 << 4)
    public static let appNames = SearchFields(rawValue: 1 << 5)
    public static let tags = SearchFields(rawValue: 1 << 6)

    public static let all: SearchFields = [.titles, .content, .ocr, .fileNames, .urls, .appNames, .tags]

    var ftsColumns: [String] {
        var columns: [String] = []
        if contains(.titles) { columns.append("title") }
        if contains(.content) { columns.append("body") }
        if contains(.ocr) { columns.append("ocr") }
        if contains(.fileNames) { columns.append("files") }
        if contains(.urls) { columns.append("url") }
        if contains(.appNames) { columns.append("app") }
        if contains(.tags) { columns.append("tags") }
        return columns
    }
}

public enum DateFilter: Sendable, Hashable {
    case today, yesterday, last7Days, last30Days, thisYear
    case range(from: Date?, to: Date?)

    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .thisYear: return "This Year"
        case .range: return "Custom Range"
        }
    }

    public static let presets: [DateFilter] = [.today, .yesterday, .last7Days, .last30Days, .thisYear]

    public func interval(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today: return (startOfToday, nil)
        case .yesterday: return (calendar.date(byAdding: .day, value: -1, to: startOfToday), startOfToday)
        case .last7Days: return (calendar.date(byAdding: .day, value: -7, to: now), nil)
        case .last30Days: return (calendar.date(byAdding: .day, value: -30, to: now), nil)
        case .thisYear: return (calendar.date(from: calendar.dateComponents([.year], from: now)), nil)
        case .range(let from, let to): return (from, to)
        }
    }
}

public enum ClipSortOrder: String, Sendable, Codable, CaseIterable {
    /// Most recently copied or used first (default).
    case recent
    /// Relevance first when searching, falling back to recency.
    case relevance
    /// First-captured date, newest first.
    case created
}

/// A fully-specified history query. Every filter is optional and they combine with AND.
public struct ClipQuery: Sendable, Hashable {
    public var text: String = ""
    public var kinds: Set<ClipKind>?
    public var sourceBundleIDs: Set<String> = []
    /// Free-form app filter from the `app:` search token (matches name or bundle id).
    public var appNameContains: String?
    public var spaceID: Int64?
    public var spaceNameContains: String?
    public var pinnedOnly = false
    public var tag: String?
    public var dateFilter: DateFilter?
    public var fields: SearchFields = .all
    public var sort: ClipSortOrder = .relevance
    public var limit = 100
    public var offset = 0

    public init(text: String = "", kinds: Set<ClipKind>? = nil, sourceBundleIDs: Set<String> = [], spaceID: Int64? = nil,
                pinnedOnly: Bool = false, dateFilter: DateFilter? = nil, limit: Int = 100, offset: Int = 0) {
        self.text = text
        self.kinds = kinds
        self.sourceBundleIDs = sourceBundleIDs
        self.spaceID = spaceID
        self.pinnedOnly = pinnedOnly
        self.dateFilter = dateFilter
        self.limit = limit
        self.offset = offset
    }

    /// Applies inline filter tokens (`app:`, `type:`, `in:`, `is:pinned`, `tag:`, `date:`) typed into the
    /// search field. Explicit UI filters win over inline tokens.
    public func applyingInlineFilters() -> ClipQuery {
        let parsed = SearchSyntax.parse(text)
        var q = self
        q.text = parsed.freeText
        if q.kinds == nil, let category = parsed.category { q.kinds = category.kinds }
        if q.appNameContains == nil { q.appNameContains = parsed.app }
        if q.spaceID == nil, q.spaceNameContains == nil { q.spaceNameContains = parsed.space }
        if parsed.pinned { q.pinnedOnly = true }
        if q.tag == nil { q.tag = parsed.tag }
        if q.dateFilter == nil { q.dateFilter = parsed.date }
        return q
    }
}

/// Parser for the search-field mini language.
public enum SearchSyntax {
    public struct Parsed: Sendable, Hashable {
        public var freeText = ""
        public var app: String?
        public var category: ClipCategory?
        public var space: String?
        public var pinned = false
        public var tag: String?
        public var date: DateFilter?
    }

    public static func parse(_ input: String) -> Parsed {
        var parsed = Parsed()
        var free: [String] = []
        for token in tokenize(input) {
            guard !token.quoted, let colon = token.text.firstIndex(of: ":") else {
                free.append(token.quoted ? "\"\(token.text)\"" : token.text)
                continue
            }
            let key = token.text[..<colon].lowercased()
            let value = String(token.text[token.text.index(after: colon)...])
            guard !value.isEmpty else { free.append(token.text); continue }
            switch key {
            case "app", "from": parsed.app = value
            case "type", "kind":
                if let category = ClipCategory.parse(value) { parsed.category = category } else { free.append(token.text) }
            case "in", "space": parsed.space = value
            case "is" where value.lowercased() == "pinned": parsed.pinned = true
            case "tag": parsed.tag = value
            case "date", "when":
                if let date = parseDate(value) { parsed.date = date } else { free.append(token.text) }
            default:
                // Not a filter (e.g. "https://…" or "key:value" text) — search it literally.
                free.append(token.text)
            }
        }
        parsed.freeText = free.joined(separator: " ")
        return parsed
    }

    static func parseDate(_ value: String) -> DateFilter? {
        switch value.lowercased() {
        case "today": return .today
        case "yesterday": return .yesterday
        case "week", "7d", "thisweek": return .last7Days
        case "month", "30d", "thismonth": return .last30Days
        case "year", "thisyear": return .thisYear
        default: return nil
        }
    }

    struct Token: Hashable { var text: String; var quoted: Bool }

    /// Splits on whitespace, keeping "quoted phrases" together.
    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        func flush(quoted: Bool) {
            if !current.isEmpty { tokens.append(Token(text: current, quoted: quoted)) }
            current = ""
        }
        for ch in input {
            if ch == "\"" {
                flush(quoted: inQuotes)
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush(quoted: false)
            } else {
                current.append(ch)
            }
        }
        flush(quoted: inQuotes)
        return tokens
    }

    /// Free-text search terms. Quoted phrases are kept as single terms.
    public static func terms(_ freeText: String) -> [String] {
        tokenize(freeText).map(\.text).filter { !$0.isEmpty }
    }
}
