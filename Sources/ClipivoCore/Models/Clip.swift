import Foundation

/// Identifies the application a clip was copied from.
public struct SourceApplication: Codable, Sendable, Hashable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Lightweight, list-friendly view of a clip. Never contains full payloads so that
/// pages of thousands of rows stay cheap to load and render.
public struct ClipSummary: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var uuid: UUID
    public var kind: ClipKind
    public var title: String?
    public var autoTitle: String?
    public var previewText: String
    public var textLength: Int
    public var sourceApp: SourceApplication?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    public var isPinned: Bool
    public var isPrivate: Bool
    public var sensitivity: SensitivityLevel
    public var byteSize: Int64
    public var thumbnailKey: String?
    public var ocrState: OCRState
    public var hasOCRText: Bool
    public var metadata: ClipMetadata
    public var spaceIDs: [Int64]
    public var tags: [String]

    public init(id: Int64, uuid: UUID, kind: ClipKind, title: String?, autoTitle: String?, previewText: String,
                textLength: Int, sourceApp: SourceApplication?, createdAt: Date, lastUsedAt: Date, useCount: Int,
                isPinned: Bool, isPrivate: Bool, sensitivity: SensitivityLevel, byteSize: Int64,
                thumbnailKey: String?, ocrState: OCRState, hasOCRText: Bool, metadata: ClipMetadata,
                spaceIDs: [Int64] = [], tags: [String] = []) {
        self.id = id
        self.uuid = uuid
        self.kind = kind
        self.title = title
        self.autoTitle = autoTitle
        self.previewText = previewText
        self.textLength = textLength
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.sensitivity = sensitivity
        self.byteSize = byteSize
        self.thumbnailKey = thumbnailKey
        self.ocrState = ocrState
        self.hasOCRText = hasOCRText
        self.metadata = metadata
        self.spaceIDs = spaceIDs
        self.tags = tags
    }

    /// The best single-line label for the clip: user title, then automatic title, then text.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if isPrivate { return "Private clip" }
        if let autoTitle, !autoTitle.isEmpty, !kind.isTextLike || kind == .url { return autoTitle }
        let line = previewText.firstNonEmptyLine
        if !line.isEmpty { return line }
        if let autoTitle, !autoTitle.isEmpty { return autoTitle }
        return kind.displayName
    }
}

public enum OCRState: Int, Codable, Sendable {
    case notApplicable = 0
    case pending = 1
    case done = 2
    case failed = 3
}

public enum SensitivityLevel: Int, Codable, Sendable, Comparable {
    case none = 0
    case possible = 1
    case likely = 2

    public static func < (lhs: SensitivityLevel, rhs: SensitivityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Kind-specific metadata stored as JSON on the clip row.
public struct ClipMetadata: Codable, Sendable, Hashable {
    public var colorHex: String?
    public var codeLanguage: String?
    public var urlHost: String?
    public var urlTitle: String?
    public var fileNames: [String]?
    public var fileCount: Int?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var pageCount: Int?
    public var sensitiveKinds: [String]?
    public var representationTypes: [String]?

    public init(colorHex: String? = nil, codeLanguage: String? = nil, urlHost: String? = nil, urlTitle: String? = nil,
                fileNames: [String]? = nil, fileCount: Int? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
                pageCount: Int? = nil, sensitiveKinds: [String]? = nil, representationTypes: [String]? = nil) {
        self.colorHex = colorHex
        self.codeLanguage = codeLanguage
        self.urlHost = urlHost
        self.urlTitle = urlTitle
        self.fileNames = fileNames
        self.fileCount = fileCount
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.pageCount = pageCount
        self.sensitiveKinds = sensitiveKinds
        self.representationTypes = representationTypes
    }

    public static let empty = ClipMetadata()

    func encoded() -> String? {
        guard self != .empty, let data = try? JSONEncoder.sorted.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> ClipMetadata {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(ClipMetadata.self, from: data) else { return .empty }
        return value
    }
}

/// One pasteboard representation of a clip (for example `public.rtf`), fully loaded.
public struct ClipRepresentation: Sendable, Hashable {
    /// Index of the pasteboard item this representation belongs to (multi-file copies have several).
    public var itemIndex: Int
    /// Uniform type identifier / pasteboard type string.
    public var type: String
    public var data: Data

    public init(itemIndex: Int = 0, type: String, data: Data) {
        self.itemIndex = itemIndex
        self.type = type
        self.data = data
    }
}

/// Full clip content, loaded on demand for paste/copy/preview.
public struct ClipContent: Sendable {
    public var summary: ClipSummary
    public var representations: [ClipRepresentation]
    public var plainText: String?
    public var ocrText: String?

    public init(summary: ClipSummary, representations: [ClipRepresentation], plainText: String?, ocrText: String?) {
        self.summary = summary
        self.representations = representations
        self.plainText = plainText
        self.ocrText = ocrText
    }

    public func data(for type: String) -> Data? {
        representations.first { $0.type == type }?.data
    }

    public var itemCount: Int { (representations.map(\.itemIndex).max() ?? -1) + 1 }
}

public struct Space: Identifiable, Sendable, Hashable, Codable {
    public var id: Int64
    public var uuid: UUID
    public var name: String
    public var icon: String
    public var sortOrder: Int
    public var isPinned: Bool
    public var createdAt: Date
    public var clipCount: Int

    public init(id: Int64, uuid: UUID, name: String, icon: String, sortOrder: Int, isPinned: Bool, createdAt: Date, clipCount: Int = 0) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.clipCount = clipCount
    }
}

public struct IgnoredApplication: Sendable, Hashable, Codable, Identifiable {
    public var bundleID: String
    public var name: String
    public var addedAt: Date
    public var id: String { bundleID }

    public init(bundleID: String, name: String, addedAt: Date = Date()) {
        self.bundleID = bundleID
        self.name = name
        self.addedAt = addedAt
    }
}

public struct SourceAppUsage: Sendable, Hashable, Identifiable {
    public var app: SourceApplication
    public var clipCount: Int
    public var id: String { app.bundleID }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension String {
    var firstNonEmptyLine: String {
        for line in split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
        }
        return ""
    }
}
