import Foundation

/// A fully classified clip ready to be written to the library.
public struct PreparedClip: Sendable {
    public var uuid: UUID
    public var kind: ClipKind
    public var title: String?
    public var autoTitle: String?
    public var metadata: ClipMetadata
    public var searchableText: String
    public var plainText: String?
    public var representations: [ClipRepresentation]
    public var contentHash: String
    public var sourceApp: SourceApplication?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    public var isPinned: Bool
    public var isPrivate: Bool
    public var sensitivity: SensitivityLevel
    public var urlString: String?
    public var ocrText: String?
    public var tags: [String]

    public init(uuid: UUID = UUID(), kind: ClipKind, title: String? = nil, autoTitle: String?, metadata: ClipMetadata,
                searchableText: String, plainText: String?, representations: [ClipRepresentation], contentHash: String,
                sourceApp: SourceApplication?, createdAt: Date, lastUsedAt: Date? = nil, useCount: Int = 0,
                isPinned: Bool = false, isPrivate: Bool = false, sensitivity: SensitivityLevel = .none,
                urlString: String? = nil, ocrText: String? = nil, tags: [String] = []) {
        self.uuid = uuid
        self.kind = kind
        self.title = title
        self.autoTitle = autoTitle
        self.metadata = metadata
        self.searchableText = searchableText
        self.plainText = plainText
        self.representations = representations
        self.contentHash = contentHash
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.sensitivity = sensitivity
        self.urlString = urlString
        self.ocrText = ocrText
        self.tags = tags
    }

    public var byteSize: Int64 { representations.reduce(0) { $0 + Int64($1.data.count) } }

    /// Whether the clip carries a bitmap that OCR can read.
    public var hasOCRCandidate: Bool {
        kind.isImageLike && representations.contains { RepresentationType.imageTypes.contains($0.type) }
    }

    /// Computes the deduplication hash from the clip's primary payload.
    ///
    /// Formatting-only differences (the same text copied as plain vs. rich) are treated as
    /// duplicates on purpose: the user thinks of them as the same clip.
    public static func contentHash(kind: ClipKind, snapshot: ClipboardSnapshot, plainText: String?) -> String {
        if !snapshot.fileURLs.isEmpty {
            return Hashing.sha256Hex("files\u{0}" + snapshot.fileURLs.map(\.path).joined(separator: "\u{0}"))
        }
        if let image = snapshot.imageData {
            return "img-" + Hashing.sha256Hex(image.data)
        }
        if let pdf = snapshot.first(RepresentationType.pdf), (plainText ?? "").isEmpty {
            return "pdf-" + Hashing.sha256Hex(pdf)
        }
        if let text = plainText, !text.isEmpty {
            return "txt-" + Hashing.sha256Hex(text)
        }
        if let hex = snapshot.hints.colorHex {
            return "col-" + hex
        }
        var combined = Data()
        for rep in snapshot.allRepresentations.sorted(by: { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }) {
            combined.append(Data(rep.type.utf8))
            combined.append(Data(Hashing.sha256Hex(rep.data).utf8))
        }
        return "raw-" + Hashing.sha256Hex(combined)
    }
}

public enum StoreResult: Sendable, Equatable {
    case inserted(Int64)
    case duplicate(Int64)

    public var clipID: Int64 {
        switch self {
        case .inserted(let id), .duplicate(let id): return id
        }
    }
}

public enum DuplicatePolicy: String, Sendable, Codable, CaseIterable {
    /// Re-copying existing content moves the existing clip to the top (default).
    case moveToTop
    /// Every copy creates a new history entry.
    case keepAll
}

public enum LibraryError: LocalizedError, Sendable {
    case notFound
    case privateContentLocked
    case invalidArchive(String)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "The clip no longer exists."
        case .privateContentLocked: return "This clip is private. Unlock Clipivo to access it."
        case .invalidArchive(let reason): return "The archive could not be read: \(reason)"
        case .corrupted(let reason): return "The clipboard library is damaged: \(reason)"
        }
    }
}
