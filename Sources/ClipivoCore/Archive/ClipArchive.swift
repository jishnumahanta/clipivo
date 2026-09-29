import Foundation

/// Portable Clipivo archive format (version 1).
///
///     <name>.clipivoarchive/
///       manifest.json   ArchiveManifest (format, version, spaces, counts)
///       clips.jsonl     one ArchivedClip JSON object per line (streamable)
///       blobs/<sha256>  representation payloads, deduplicated
///
/// The platform layer may zip the folder for transport; the core only reads/writes the folder.
public struct ArchiveManifest: Codable, Sendable {
    public static let formatIdentifier = "clipivo-archive"
    public static let currentVersion = 1

    public var format = ArchiveManifest.formatIdentifier
    public var version = ArchiveManifest.currentVersion
    public var exportedAt: Date
    public var generator: String
    public var clipCount: Int
    public var spaces: [ArchivedSpace]
}

public struct ArchivedSpace: Codable, Sendable {
    public var uuid: UUID
    public var name: String
    public var icon: String
    public var sortOrder: Int
    public var isPinned: Bool
}

public struct ArchivedRepresentation: Codable, Sendable {
    public var item: Int
    public var type: String
    public var blob: String
    public var size: Int
}

public struct ArchivedClip: Codable, Sendable {
    public var uuid: UUID
    public var kind: String
    public var title: String?
    public var autoTitle: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    public var isPinned: Bool
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var metadata: ClipMetadata
    public var searchableText: String
    public var plainText: String?
    public var ocrText: String?
    public var url: String?
    public var contentHash: String
    public var sensitivity: Int
    public var isPrivate: Bool?
    public var tags: [String]
    public var spaces: [UUID]
    public var representations: [ArchivedRepresentation]
}

public struct ArchiveSummary: Sendable, Equatable {
    public var clipsWritten = 0
    public var clipsImported = 0
    public var clipsMerged = 0
    public var clipsSkipped = 0
    public var spacesCreated = 0
    public var bytesWritten: Int64 = 0
}

extension ClipLibrary {
    /// Writes the whole library (optionally including private clips, decrypted) to `folder`.
    /// `progress` receives (done, total).
    public func exportArchive(to folder: URL, includePrivate: Bool, generator: String = "\(Branding.productName)",
                              progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ArchiveSummary {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let blobDir = folder.appendingPathComponent("blobs", isDirectory: true)
        try fm.createDirectory(at: blobDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let linesURL = folder.appendingPathComponent("clips.jsonl")
        fm.createFile(atPath: linesURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: linesURL)
        defer { try? handle.close() }

        let spaceList = try spaces()
        let spaceUUIDs = Dictionary(uniqueKeysWithValues: spaceList.map { ($0.id, $0.uuid) })
        let total = Int(try db.scalarInt("SELECT count(*) FROM clips\(includePrivate ? "" : " WHERE is_private = 0")"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var summary = ArchiveSummary()
        var lastID: Int64 = 0
        while true {
            let ids = try db.query("SELECT id FROM clips WHERE id > ?\(includePrivate ? "" : " AND is_private = 0") ORDER BY id LIMIT 200",
                                   [.int(lastID)]) { $0.int64(0) }
            guard let maxID = ids.last else { break }
            lastID = maxID
            for id in ids {
                guard let content = try? content(id: id, allowPrivate: includePrivate) else { continue }
                let s = content.summary
                var reps: [ArchivedRepresentation] = []
                for rep in content.representations {
                    let key = BlobStore.key(for: rep.data)
                    let target = blobDir.appendingPathComponent(key)
                    if !fm.fileExists(atPath: target.path) {
                        try FileUtilities.writeSecure(rep.data, to: target)
                        summary.bytesWritten += Int64(rep.data.count)
                    }
                    reps.append(ArchivedRepresentation(item: rep.itemIndex, type: rep.type, blob: key, size: rep.data.count))
                }
                let row = try db.query("SELECT content_hash, url FROM clips WHERE id = ?", [.int(id)]) { ($0.string(0) ?? "", $0.string(1)) }.first
                let fullText = s.isPrivate ? content.plainText : (try fullPlainText(id))
                let record = ArchivedClip(
                    uuid: s.uuid, kind: s.kind.rawValue, title: s.title, autoTitle: s.autoTitle, createdAt: s.createdAt,
                    lastUsedAt: s.lastUsedAt, useCount: s.useCount, isPinned: s.isPinned, sourceBundleID: s.sourceApp?.bundleID,
                    sourceAppName: s.sourceApp?.name, metadata: s.metadata,
                    searchableText: s.isPrivate ? (fullText ?? "") : (fullText ?? s.previewText),
                    plainText: content.plainText, ocrText: content.ocrText, url: row?.1, contentHash: row?.0 ?? "",
                    sensitivity: s.sensitivity.rawValue, isPrivate: s.isPrivate, tags: s.tags, spaces: s.spaceIDs.compactMap { spaceUUIDs[$0] },
                    representations: reps)
                var line = try encoder.encode(record)
                line.append(0x0A)
                try handle.write(contentsOf: line)
                summary.clipsWritten += 1
            }
            progress?(summary.clipsWritten, total)
        }

        let manifest = ArchiveManifest(
            exportedAt: Date(), generator: generator, clipCount: summary.clipsWritten,
            spaces: spaceList.map { ArchivedSpace(uuid: $0.uuid, name: $0.name, icon: $0.icon, sortOrder: $0.sortOrder, isPinned: $0.isPinned) })
        try FileUtilities.writeSecure(try encoder.encode(manifest), to: folder.appendingPathComponent("manifest.json"))
        return summary
    }

    /// Imports an archive folder. Clips already present (same UUID) are skipped; clips with identical
    /// content are merged (pins, tags and Space memberships are added to the existing clip).
    public func importArchive(from folder: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ArchiveSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw LibraryError.invalidArchive("manifest.json is missing") }
        let manifest: ArchiveManifest
        do { manifest = try decoder.decode(ArchiveManifest.self, from: manifestData) }
        catch { throw LibraryError.invalidArchive("manifest.json is not valid") }
        guard manifest.format == ArchiveManifest.formatIdentifier else { throw LibraryError.invalidArchive("not a Clipivo archive") }
        guard manifest.version <= ArchiveManifest.currentVersion else {
            throw LibraryError.invalidArchive("created by a newer version of \(Branding.productName)")
        }

        var summary = ArchiveSummary()

        // Map archive Spaces onto existing ones (by UUID, then by name) or create them.
        var existing = try spaces()
        var spaceMap: [UUID: Int64] = [:]
        for space in manifest.spaces {
            if let match = existing.first(where: { $0.uuid == space.uuid }) ?? existing.first(where: { $0.name.caseInsensitiveCompare(space.name) == .orderedSame }) {
                spaceMap[space.uuid] = match.id
            } else {
                let created = try createSpace(name: space.name, icon: space.icon, uuid: space.uuid)
                if space.isPinned { try setSpacePinned(created.id, pinned: true) }
                existing.append(created)
                spaceMap[space.uuid] = created.id
                summary.spacesCreated += 1
            }
        }

        let linesURL = folder.appendingPathComponent("clips.jsonl")
        guard let reader = LineReader(url: linesURL) else { throw LibraryError.invalidArchive("clips.jsonl is missing") }
        let blobDir = folder.appendingPathComponent("blobs", isDirectory: true)
        var batch: [ArchivedClip] = []
        var processed = 0

        func flush() throws {
            guard !batch.isEmpty else { return }
            try db.transaction {
                for record in batch {
                    try importRecord(record, blobDir: blobDir, spaceMap: spaceMap, summary: &summary)
                }
            }
            processed += batch.count
            batch.removeAll(keepingCapacity: true)
            progress?(processed, manifest.clipCount)
        }

        while let line = reader.nextLine() {
            guard !line.isEmpty else { continue }
            guard let record = try? decoder.decode(ArchivedClip.self, from: line) else {
                summary.clipsSkipped += 1
                continue
            }
            batch.append(record)
            if batch.count >= 200 { try flush() }
        }
        try flush()
        notifyChange()
        return summary
    }

    private func importRecord(_ record: ArchivedClip, blobDir: URL, spaceMap: [UUID: Int64], summary: inout ArchiveSummary) throws {
        if try db.scalarInt("SELECT count(*) FROM clips WHERE uuid = ?", [.text(record.uuid.uuidString)]) > 0 {
            summary.clipsSkipped += 1
            return
        }
        let targetSpaces = record.spaces.compactMap { spaceMap[$0] }
        if !record.contentHash.isEmpty,
           let existingID = try db.query("SELECT id FROM clips WHERE content_hash = ? LIMIT 1", [.text(record.contentHash)], map: { $0.int64(0) }).first {
            // Same content already present: merge organisation data instead of duplicating.
            if record.isPinned { try db.run("UPDATE clips SET is_pinned = 1, pin_order = coalesce(pin_order, ?) WHERE id = ?", [.date(record.lastUsedAt), .int(existingID)]) }
            if let title = record.title {
                try db.run("UPDATE clips SET title = coalesce(title, ?) WHERE id = ?", [.text(title), .int(existingID)])
            }
            for tag in record.tags { try db.run("INSERT OR IGNORE INTO clip_tags (clip_id, tag) VALUES (?, ?)", [.int(existingID), .text(tag)]) }
            for space in targetSpaces {
                try db.run("INSERT OR IGNORE INTO clip_spaces (clip_id, space_id, added_at) VALUES (?, ?, ?)", [.int(existingID), .int(space), .date(Date())])
            }
            try reindex(existingID)
            summary.clipsMerged += 1
            return
        }

        var reps: [ClipRepresentation] = []
        for rep in record.representations {
            guard rep.blob.count == 64, rep.blob.allSatisfy(\.isHexDigit),
                  let data = try? Data(contentsOf: blobDir.appendingPathComponent(rep.blob), options: [.mappedIfSafe]),
                  BlobStore.key(for: data) == rep.blob else { continue } // Skip missing or tampered payloads.
            reps.append(ClipRepresentation(itemIndex: rep.item, type: rep.type, data: data))
        }
        let source = record.sourceBundleID.map { SourceApplication(bundleID: $0, name: record.sourceAppName ?? $0) }
        let prepared = PreparedClip(
            uuid: record.uuid, kind: ClipKind(rawValue: record.kind) ?? .unknown, title: record.title, autoTitle: record.autoTitle,
            metadata: record.metadata, searchableText: record.searchableText, plainText: record.plainText, representations: reps,
            contentHash: record.contentHash.isEmpty ? "import-" + record.uuid.uuidString : record.contentHash,
            sourceApp: source, createdAt: record.createdAt, lastUsedAt: record.lastUsedAt, useCount: record.useCount,
            isPinned: record.isPinned, isPrivate: record.isPrivate ?? false, sensitivity: SensitivityLevel(rawValue: record.sensitivity) ?? .none,
            urlString: record.url, ocrText: record.ocrText, tags: record.tags)
        let id = try insert(prepared)
        for space in targetSpaces {
            try db.run("INSERT OR IGNORE INTO clip_spaces (clip_id, space_id, added_at) VALUES (?, ?, ?)", [.int(id), .int(space), .date(Date())])
        }
        summary.clipsImported += 1
    }
}

/// Reads a file line by line without loading it whole.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEnd = false

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
    }

    deinit { try? handle.close() }

    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            if reachedEnd {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? nil
            if let chunk, !chunk.isEmpty { buffer.append(chunk) } else { reachedEnd = true }
        }
    }
}
