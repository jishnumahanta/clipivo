import Foundation

extension Notification.Name {
    /// Posted (on an arbitrary thread) whenever the library content changes.
    public static let clipLibraryDidChange = Notification.Name("ClipLibraryDidChange")
}

/// The clipboard history. Owns the SQLite database and the blob store and serialises all
/// access through actor isolation. Never loads the whole history: every read is paged.
public actor ClipLibrary {
    public nonisolated let layout: StorageLayout
    let db: SQLiteDatabase
    nonisolated let blobs: BlobStore
    private let cipher: ContentCipher?

    /// Representations up to this size are stored inline in SQLite; larger ones become blobs.
    public static let inlineThreshold = 32 * 1024
    /// Maximum text indexed per clip for full-text search.
    public static let maxIndexedTextLength = 256 * 1024
    static let previewLength = 2_000

    /// Set when the database was unreadable at launch and a fresh one was created.
    public nonisolated let recoveredFromCorruption: Bool

    public init(layout: StorageLayout, cipher: ContentCipher? = nil) throws {
        self.layout = layout
        self.cipher = cipher
        try layout.prepare()
        blobs = BlobStore(directory: layout.blobsDirectory)

        var recovered = false
        var database: SQLiteDatabase
        do {
            database = try Self.open(layout.databaseFile)
            if !database.integrityCheck() { throw SQLiteError(code: 11, message: "integrity check failed") }
        } catch {
            // Never destroy user data: move the unreadable file aside, then start fresh.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: layout.databaseFile.path + suffix)
                if fm.fileExists(atPath: source.path) {
                    try? fm.moveItem(at: source, to: layout.databaseDirectory.appendingPathComponent("damaged-\(stamp).sqlite\(suffix)"))
                }
            }
            database = try Self.open(layout.databaseFile)
            recovered = true
        }
        db = database
        recoveredFromCorruption = recovered
        try Schema.migrate(db)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.databaseFile.path)
    }

    private static func open(_ url: URL) throws -> SQLiteDatabase {
        // Create the file with 0600 first: SQLite gives its -wal/-shm files the same mode.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -16000;
            PRAGMA mmap_size = 268435456;
            """)
        return database
    }

    nonisolated func notifyChange() {
        NotificationCenter.default.post(name: .clipLibraryDidChange, object: nil)
    }

    // MARK: - Writing clips

    /// Inserts a prepared clip, or refreshes an existing clip with identical content.
    @discardableResult
    public func store(_ clip: PreparedClip, duplicatePolicy: DuplicatePolicy = .moveToTop) throws -> StoreResult {
        if duplicatePolicy == .moveToTop,
           let existing = try db.query("SELECT id FROM clips WHERE content_hash = ? ORDER BY last_used_at DESC LIMIT 1",
                                       [.text(clip.contentHash)], map: { $0.int64(0) }).first {
            try db.run("UPDATE clips SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
                       [.date(clip.lastUsedAt), .int(existing)])
            notifyChange()
            return .duplicate(existing)
        }
        let id = try db.transaction { try insert(clip) }
        notifyChange()
        return .inserted(id)
    }

    /// Inserts many clips in one transaction without deduplication (bulk import, benchmarks).
    @discardableResult
    public func storeBatch(_ clips: [PreparedClip]) throws -> [Int64] {
        let ids = try db.transaction { try clips.map { try insert($0) } }
        notifyChange()
        return ids
    }

    /// Inserts without deduplication. Must be called inside a transaction.
    func insert(_ clip: PreparedClip) throws -> Int64 {
        let isPrivate = clip.isPrivate && cipher != nil
        let preview = isPrivate ? "" : String(clip.searchableText.prefix(Self.previewLength))
        let ocrPending = clip.hasOCRCandidate && clip.ocrText == nil && !isPrivate
        let ocrState: OCRState = clip.ocrText != nil ? .done : (ocrPending ? .pending : .notApplicable)
        try db.run("""
            INSERT INTO clips (uuid, kind, title, auto_title, preview_text, text_length, content_hash, source_bundle_id,
                source_app_name, created_at, last_used_at, use_count, is_pinned, pin_order, is_private, sensitivity,
                byte_size, ocr_state, ocr_length, url, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(clip.uuid.uuidString), .text(clip.kind.rawValue), .from(clip.title.nilIfBlank), .from(clip.autoTitle),
                .text(preview), .int(Int64(clip.searchableText.count)), .text(clip.contentHash),
                .from(clip.sourceApp?.bundleID), .from(clip.sourceApp?.name), .date(clip.createdAt), .date(clip.lastUsedAt),
                .int(Int64(clip.useCount)), .bool(clip.isPinned), clip.isPinned ? .date(clip.lastUsedAt) : .null,
                .bool(isPrivate), .int(Int64(clip.sensitivity.rawValue)), .int(clip.byteSize), .int(Int64(ocrState.rawValue)),
                .int(Int64(clip.ocrText?.count ?? 0)), .from(isPrivate ? nil : clip.urlString), .from(clip.metadata.encoded()),
            ])
        let id = db.lastInsertRowID

        // Store derived plain text only when no plain-text representation already holds it.
        let hasPlainRep = clip.representations.contains { $0.type == RepresentationType.plainText }
        let storedPlain = hasPlainRep ? nil : clip.plainText
        if storedPlain != nil || clip.ocrText != nil {
            let plain = isPrivate ? storedPlain.flatMap { try? sealString($0) } : storedPlain.map(SQLValue.text)
            try db.run("INSERT INTO clip_text (clip_id, plain_text, ocr_text) VALUES (?, ?, ?)",
                       [.int(id), plain ?? .null, .from(clip.ocrText)])
        }

        for (ordinal, rep) in clip.representations.enumerated() {
            try insertRepresentation(rep, clipID: id, ordinal: ordinal, encrypt: isPrivate)
        }
        for tag in clip.tags {
            try db.run("INSERT OR IGNORE INTO clip_tags (clip_id, tag) VALUES (?, ?)", [.int(id), .text(tag)])
        }
        try indexClip(id: id, clip: clip, isPrivate: isPrivate)
        return id
    }

    private func sealString(_ string: String) throws -> SQLValue {
        guard let cipher else { return .text(string) }
        return .blob(try cipher.seal(Data(string.utf8)))
    }

    private func insertRepresentation(_ rep: ClipRepresentation, clipID: Int64, ordinal: Int, encrypt: Bool) throws {
        var payload = rep.data
        if encrypt, let cipher { payload = try cipher.seal(payload) }
        var inline: SQLValue = .null
        var blobKey: SQLValue = .null
        if payload.count <= Self.inlineThreshold {
            inline = .blob(payload)
        } else if encrypt {
            let key = "p-" + UUID().uuidString
            try FileUtilities.writeSecure(payload, to: layout.privateDirectory.appendingPathComponent(key))
            blobKey = .text(key)
        } else {
            blobKey = .text(try blobs.put(payload))
        }
        try db.run("""
            INSERT INTO representations (clip_id, item_index, ordinal, type, byte_size, inline_data, blob_key, encrypted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(clipID), .int(Int64(rep.itemIndex)), .int(Int64(ordinal)), .text(rep.type),
                  .int(Int64(rep.data.count)), inline, blobKey, .bool(encrypt)])
    }

    private func indexClip(id: Int64, clip: PreparedClip, isPrivate: Bool) throws {
        let files = (clip.metadata.fileNames ?? []).joined(separator: " ")
            + (clip.kind == .file || clip.kind == .folder ? "\n" + clip.searchableText : "")
        let app = [clip.sourceApp?.name, clip.sourceApp?.bundleID].compactMap { $0 }.joined(separator: " ")
        let titles = [clip.title, clip.autoTitle, clip.metadata.urlTitle].compactMap { $0 }.joined(separator: " ")
        let body = isPrivate ? "" : String(clip.searchableText.prefix(Self.maxIndexedTextLength))
        try db.run("INSERT INTO clip_fts (rowid, title, body, ocr, files, url, app, tags) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
            .int(id), .text(isPrivate ? (clip.title ?? "") : titles), .text(body),
            .text(isPrivate ? "" : (clip.ocrText ?? "")), .text(isPrivate ? "" : files),
            .text(isPrivate ? "" : (clip.urlString ?? "")), .text(app), .text(clip.tags.joined(separator: " ")),
        ])
    }

    /// Rebuilds the FTS row for one clip from the database (after title/tag/OCR/privacy changes).
    func reindex(_ id: Int64) throws {
        guard let row = try db.query("""
            SELECT c.title, c.auto_title, c.preview_text, c.source_app_name, c.source_bundle_id, c.url, c.metadata,
                   c.is_private, c.kind, t.ocr_text
            FROM clips c LEFT JOIN clip_text t ON t.clip_id = c.id WHERE c.id = ?
            """, [.int(id)], map: { row in
                (title: row.string(0), auto: row.string(1), preview: row.string(2) ?? "", app: row.string(3),
                 bundle: row.string(4), url: row.string(5), metadata: ClipMetadata.decode(row.string(6)),
                 isPrivate: row.bool(7), kind: ClipKind(rawValue: row.string(8) ?? "") ?? .unknown, ocr: row.string(9))
            }).first else { return }
        let tags = try db.query("SELECT tag FROM clip_tags WHERE clip_id = ? ORDER BY tag", [.int(id)]) { $0.string(0) ?? "" }
        let isPrivate = row.isPrivate
        var body = ""
        if !isPrivate {
            if let text = try fullPlainText(id) { body = String(text.prefix(Self.maxIndexedTextLength)) }
            // An image's preview line is its OCR text, which is indexed separately in the `ocr` column
            // (so the "search text in images" setting can switch it off).
            else if !row.kind.isImageLike { body = row.preview }
        }
        let titles = isPrivate ? (row.title ?? "") : [row.title, row.auto, row.metadata.urlTitle].compactMap { $0 }.joined(separator: " ")
        let files = (row.metadata.fileNames ?? []).joined(separator: " ")
            + ((row.kind == .file || row.kind == .folder) && !isPrivate ? "\n" + row.preview : "")
        try db.run("DELETE FROM clip_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO clip_fts (rowid, title, body, ocr, files, url, app, tags) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
            .int(id), .text(titles), .text(body), .text(isPrivate ? "" : (row.ocr ?? "")), .text(isPrivate ? "" : files),
            .text(isPrivate ? "" : (row.url ?? "")),
            .text([row.app, row.bundle].compactMap { $0 }.joined(separator: " ")), .text(tags.joined(separator: " ")),
        ])
    }

    // MARK: - Reading

    static let summaryColumns = """
        c.id, c.uuid, c.kind, c.title, c.auto_title, c.preview_text, c.text_length, c.source_bundle_id, c.source_app_name,
        c.created_at, c.last_used_at, c.use_count, c.is_pinned, c.is_private, c.sensitivity, c.byte_size,
        c.thumbnail_key, c.ocr_state, c.ocr_length, c.metadata
        """

    static func summary(from row: Row) -> ClipSummary {
        let bundle = row.string(7)
        let appName = row.string(8)
        let source = bundle.map { SourceApplication(bundleID: $0, name: appName ?? $0) }
        return ClipSummary(
            id: row.int64(0), uuid: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
            kind: ClipKind(rawValue: row.string(2) ?? "") ?? .unknown, title: row.string(3), autoTitle: row.string(4),
            previewText: row.string(5) ?? "", textLength: row.int(6), sourceApp: source,
            createdAt: row.date(9), lastUsedAt: row.date(10), useCount: row.int(11), isPinned: row.bool(12),
            isPrivate: row.bool(13), sensitivity: SensitivityLevel(rawValue: row.int(14)) ?? .none, byteSize: row.int64(15),
            thumbnailKey: row.string(16).flatMap { $0.isEmpty ? nil : $0 }, ocrState: OCRState(rawValue: row.int(17)) ?? .notApplicable,
            hasOCRText: row.int(18) > 0, metadata: ClipMetadata.decode(row.string(19)))
    }

    /// Runs a query and returns one page of summaries.
    public func fetch(_ query: ClipQuery) throws -> [ClipSummary] {
        let plan = SearchPlanner.plan(query.applyingInlineFilters(), now: Date())
        var summaries = try db.query(plan.sql, plan.bindings, cache: false, map: Self.summary(from:))
        try attachRelations(&summaries)
        return summaries
    }

    public func count(_ query: ClipQuery) throws -> Int {
        let plan = SearchPlanner.plan(query.applyingInlineFilters(), now: Date(), countOnly: true)
        return Int(try db.query(plan.sql, plan.bindings, cache: false) { $0.int64(0) }.first ?? 0)
    }

    public func totalCount() throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM clips"))
    }

    public func summary(id: Int64) throws -> ClipSummary? {
        var result = try db.query("SELECT \(Self.summaryColumns) FROM clips c WHERE c.id = ?", [.int(id)], map: Self.summary(from:))
        try attachRelations(&result)
        return result.first
    }

    public func summary(uuid: UUID) throws -> ClipSummary? {
        guard let id = try db.query("SELECT id FROM clips WHERE uuid = ?", [.text(uuid.uuidString)], map: { $0.int64(0) }).first else { return nil }
        return try summary(id: id)
    }

    /// The most recent clips (for the menu-bar "Recent Clips" submenu).
    public func recent(limit: Int) throws -> [ClipSummary] {
        try fetch(ClipQuery(limit: limit))
    }

    private func attachRelations(_ summaries: inout [ClipSummary]) throws {
        guard !summaries.isEmpty else { return }
        let ids = summaries.map { String($0.id) }.joined(separator: ",")
        var spaces: [Int64: [Int64]] = [:]
        for (clip, space) in try db.query("SELECT clip_id, space_id FROM clip_spaces WHERE clip_id IN (\(ids))", cache: false, map: { ($0.int64(0), $0.int64(1)) }) {
            spaces[clip, default: []].append(space)
        }
        var tags: [Int64: [String]] = [:]
        for (clip, tag) in try db.query("SELECT clip_id, tag FROM clip_tags WHERE clip_id IN (\(ids)) ORDER BY tag", cache: false, map: { ($0.int64(0), $0.string(1) ?? "") }) {
            tags[clip, default: []].append(tag)
        }
        for index in summaries.indices {
            summaries[index].spaceIDs = spaces[summaries[index].id] ?? []
            summaries[index].tags = tags[summaries[index].id] ?? []
        }
    }

    /// Loads every representation of a clip. Private clips require `allowPrivate`.
    public func content(id: Int64, allowPrivate: Bool = false) throws -> ClipContent {
        guard let summary = try summary(id: id) else { throw LibraryError.notFound }
        if summary.isPrivate && !allowPrivate { throw LibraryError.privateContentLocked }
        let reps = try loadRepresentations(clipID: id)
        let text = try db.query("SELECT plain_text, ocr_text FROM clip_text WHERE clip_id = ?", [.int(id)]) { row -> (Data?, String?) in
            (row.data(0), row.string(1))
        }.first
        var plain: String?
        if let raw = text?.0 {
            if summary.isPrivate, let cipher, let opened = try? cipher.open(raw) { plain = String(decoding: opened, as: UTF8.self) }
            else { plain = String(data: raw, encoding: .utf8) }
        }
        if plain == nil, let data = reps.first(where: { $0.type == RepresentationType.plainText })?.data {
            plain = String(data: data, encoding: .utf8)
        }
        return ClipContent(summary: summary, representations: reps, plainText: plain, ocrText: text?.1)
    }

    func loadRepresentations(clipID: Int64) throws -> [ClipRepresentation] {
        let rows = try db.query("""
            SELECT item_index, type, inline_data, blob_key, encrypted FROM representations
            WHERE clip_id = ? ORDER BY item_index, ordinal
            """, [.int(clipID)]) { row in
            (row.int(0), row.string(1) ?? "", row.data(2), row.string(3), row.bool(4))
        }
        var reps: [ClipRepresentation] = []
        for (item, type, inline, key, encrypted) in rows {
            var data: Data
            if let inline { data = inline }
            else if let key {
                // A missing blob (deleted outside Clipivo) degrades gracefully to a missing representation.
                if key.hasPrefix("p-") {
                    guard let raw = try? Data(contentsOf: layout.privateDirectory.appendingPathComponent(key)) else { continue }
                    data = raw
                } else {
                    guard let raw = try? blobs.get(key) else { continue }
                    data = raw
                }
            } else { continue }
            if encrypted {
                guard let cipher, let opened = try? cipher.open(data) else { continue }
                data = opened
            }
            reps.append(ClipRepresentation(itemIndex: item, type: type, data: data))
        }
        return reps
    }

    /// Full plain text of a clip (unbounded, unlike `previewText`).
    public func fullPlainText(_ id: Int64) throws -> String? {
        if let stored = try db.query("SELECT plain_text, (SELECT is_private FROM clips WHERE id = ?) FROM clip_text WHERE clip_id = ?",
                                     [.int(id), .int(id)], map: { ($0.data(0), $0.bool(1)) }).first, let raw = stored.0 {
            if stored.1 { return nil }
            return String(data: raw, encoding: .utf8)
        }
        let row = try db.query("""
            SELECT r.inline_data, r.blob_key, r.encrypted FROM representations r
            WHERE r.clip_id = ? AND r.type = ? ORDER BY r.item_index
            """, [.int(id), .text(RepresentationType.plainText)]) { ($0.data(0), $0.string(1), $0.bool(2)) }
        var parts: [String] = []
        for (inline, key, encrypted) in row where !encrypted {
            if let inline, let s = String(data: inline, encoding: .utf8) { parts.append(s) }
            else if let key, !key.hasPrefix("p-"), let data = try? blobs.get(key), let s = String(data: data, encoding: .utf8) { parts.append(s) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public func ocrText(_ id: Int64) throws -> String? {
        try db.query("SELECT ocr_text FROM clip_text WHERE clip_id = ?", [.int(id)]) { $0.string(0) }.first ?? nil
    }

    /// Source applications with clip counts, most used first.
    public func sourceApps() throws -> [SourceAppUsage] {
        try db.query("""
            SELECT source_bundle_id, max(source_app_name), count(*) FROM clips
            WHERE source_bundle_id IS NOT NULL AND source_bundle_id != '' GROUP BY source_bundle_id ORDER BY count(*) DESC
            """) { row in
            SourceAppUsage(app: SourceApplication(bundleID: row.string(0) ?? "", name: row.string(1) ?? row.string(0) ?? ""),
                           clipCount: row.int(2))
        }
    }

    // MARK: - Updating clips

    /// Records that a clip was pasted/copied: moves it to the top of History.
    public func markUsed(_ id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE clips SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?", [.date(date), .int(id)])
        notifyChange()
    }

    public func setTitle(_ id: Int64, title: String?) throws {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        try db.transaction {
            try db.run("UPDATE clips SET title = ? WHERE id = ?", [.from(clean), .int(id)])
            try reindex(id)
        }
        notifyChange()
    }

    /// Sets an automatic title (e.g. a fetched page title). Never touches the user's title.
    public func setURLTitle(_ id: Int64, title: String) throws {
        guard var summary = try summary(id: id) else { return }
        summary.metadata.urlTitle = title
        try db.transaction {
            try db.run("UPDATE clips SET metadata = ? WHERE id = ?", [.from(summary.metadata.encoded()), .int(id)])
            try reindex(id)
        }
        notifyChange()
    }

    public func setPinned(_ ids: [Int64], pinned: Bool) throws {
        try db.transaction {
            for id in ids {
                try db.run("UPDATE clips SET is_pinned = ?, pin_order = ? WHERE id = ?",
                           [.bool(pinned), pinned ? .date(Date()) : .null, .int(id)])
            }
        }
        notifyChange()
    }

    /// Reorders pinned clips; `orderedIDs` lists them top to bottom.
    public func reorderPinned(_ orderedIDs: [Int64]) throws {
        try db.transaction {
            let base = Date().timeIntervalSince1970
            for (index, id) in orderedIDs.enumerated() {
                try db.run("UPDATE clips SET pin_order = ? WHERE id = ? AND is_pinned = 1", [.double(base - Double(index)), .int(id)])
            }
        }
        notifyChange()
    }

    public func addTag(_ tag: String, to ids: [Int64]) throws {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        guard !clean.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.run("INSERT OR IGNORE INTO clip_tags (clip_id, tag) VALUES (?, ?)", [.int(id), .text(clean)])
                try reindex(id)
            }
        }
        notifyChange()
    }

    public func removeTag(_ tag: String, from ids: [Int64]) throws {
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM clip_tags WHERE clip_id = ? AND tag = ?", [.int(id), .text(tag)])
                try reindex(id)
            }
        }
        notifyChange()
    }

    public func allTags() throws -> [(tag: String, count: Int)] {
        try db.query("SELECT tag, count(*) FROM clip_tags GROUP BY tag ORDER BY count(*) DESC, tag") { ($0.string(0) ?? "", $0.int(1)) }
    }

    /// Marks a clip private (encrypting its payload and removing it from the content index) or public.
    public func setPrivate(_ id: Int64, isPrivate: Bool) throws {
        guard let cipher else { throw LibraryError.privateContentLocked }
        guard let summary = try summary(id: id), summary.isPrivate != isPrivate else { return }
        let reps = try loadRepresentations(clipID: id)
        let plain = try db.query("SELECT plain_text FROM clip_text WHERE clip_id = ?", [.int(id)]) { $0.data(0) }.first ?? nil
        let oldPrivateKeys = try db.query("SELECT blob_key FROM representations WHERE clip_id = ? AND blob_key LIKE 'p-%'", [.int(id)]) { $0.string(0) ?? "" }
        try db.transaction {
            try db.run("DELETE FROM representations WHERE clip_id = ?", [.int(id)])
            for (ordinal, rep) in reps.enumerated() {
                try insertRepresentation(rep, clipID: id, ordinal: ordinal, encrypt: isPrivate)
            }
            if let plain {
                let converted: SQLValue
                if isPrivate { converted = .blob(try cipher.seal(plain)) }
                else { converted = .blob((try? cipher.open(plain)) ?? plain) }
                try db.run("UPDATE clip_text SET plain_text = ? WHERE clip_id = ?", [converted, .int(id)])
            }
            var preview = ""
            if !isPrivate {
                let text = reps.first(where: { $0.type == RepresentationType.plainText }).flatMap { String(data: $0.data, encoding: .utf8) }
                    ?? plain.flatMap { (try? cipher.open($0)).flatMap { String(data: $0, encoding: .utf8) } }
                    ?? ""
                preview = String(text.prefix(Self.previewLength))
            }
            try db.run("UPDATE clips SET is_private = ?, preview_text = ?, thumbnail_key = CASE WHEN ? THEN NULL ELSE thumbnail_key END WHERE id = ?",
                       [.bool(isPrivate), .text(preview), .bool(isPrivate), .int(id)])
            try reindex(id)
        }
        for key in oldPrivateKeys { try? FileManager.default.removeItem(at: layout.privateDirectory.appendingPathComponent(key)) }
        if !isPrivate, summary.kind.isImageLike {
            try db.run("UPDATE clips SET ocr_state = ? WHERE id = ? AND ocr_state != ?",
                       [.int(Int64(OCRState.pending.rawValue)), .int(id), .int(Int64(OCRState.done.rawValue))])
        }
        collectGarbage()
        notifyChange()
    }

    // MARK: - Deleting

    public func delete(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try deletePrivateFiles(clipID: id)
                try db.run("DELETE FROM clip_fts WHERE rowid = ?", [.int(id)])
                try db.run("DELETE FROM clips WHERE id = ?", [.int(id)])
            }
        }
        collectGarbage()
        notifyChange()
    }

    private func deletePrivateFiles(clipID: Int64) throws {
        let keys = try db.query("SELECT blob_key FROM representations WHERE clip_id = ? AND blob_key LIKE 'p-%'", [.int(clipID)]) { $0.string(0) ?? "" }
        for key in keys { try? FileManager.default.removeItem(at: layout.privateDirectory.appendingPathComponent(key)) }
    }

    /// Deletes every clip copied from the given application. Returns the number removed.
    @discardableResult
    public func deleteAll(fromSource bundleID: String, keepPinned: Bool = true) throws -> Int {
        let ids = try db.query("SELECT id FROM clips WHERE source_bundle_id = ?\(keepPinned ? " AND is_pinned = 0" : "")",
                               [.text(bundleID)]) { $0.int64(0) }
        try delete(ids)
        return ids.count
    }

    /// Deletes clips that look like the given one: same kind and same normalized text / URL host / file names.
    @discardableResult
    public func deleteSimilar(to id: Int64, keepPinned: Bool = true) throws -> Int {
        guard let target = try summary(id: id) else { return 0 }
        let ids = try similarClipIDs(to: target).filter { $0 != id || !target.isPinned || !keepPinned }
        var toDelete: [Int64] = []
        if keepPinned {
            let pinned = Set(try db.query("SELECT id FROM clips WHERE is_pinned = 1") { $0.int64(0) })
            toDelete = ids.filter { !pinned.contains($0) }
        } else {
            toDelete = ids
        }
        try delete(toDelete)
        return toDelete.count
    }

    func similarClipIDs(to target: ClipSummary) throws -> [Int64] {
        switch target.kind {
        case .url:
            guard let host = target.metadata.urlHost else { return [target.id] }
            return try db.query("SELECT id FROM clips WHERE kind = ? AND metadata LIKE ?",
                                [.text(target.kind.rawValue), .text("%\"urlHost\":\"\(host)\"%")]) { $0.int64(0) }
        case .image, .screenshot, .file, .folder, .pdf:
            let sameTitle = target.autoTitle.map { SQLValue.text($0) } ?? .null
            return try db.query("SELECT id FROM clips WHERE kind = ? AND source_bundle_id IS ? AND (auto_title IS ? OR content_hash = (SELECT content_hash FROM clips WHERE id = ?))",
                                [.text(target.kind.rawValue), .from(target.sourceApp?.bundleID), sameTitle, .int(target.id)]) { $0.int64(0) }
        default:
            let normalized = target.previewText.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let candidates = try db.query("SELECT id, preview_text FROM clips WHERE kind = ? AND text_length BETWEEN ? AND ?",
                                          [.text(target.kind.rawValue), .int(Int64(Double(target.textLength) * 0.8)), .int(Int64(Double(target.textLength) * 1.2) + 2)]) {
                ($0.int64(0), $0.string(1) ?? "")
            }
            return candidates.filter { $0.1.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") == normalized }.map(\.0)
        }
    }

    /// Clears history. Pinned clips and clips in Spaces are kept unless explicitly included.
    @discardableResult
    public func clearHistory(keepPinned: Bool = true, keepSpaceMembers: Bool = true) throws -> Int {
        var sql = "SELECT id FROM clips WHERE 1"
        if keepPinned { sql += " AND is_pinned = 0" }
        if keepSpaceMembers { sql += " AND NOT EXISTS (SELECT 1 FROM clip_spaces s WHERE s.clip_id = clips.id)" }
        let ids = try db.query(sql) { $0.int64(0) }
        try deleteInBatches(ids)
        return ids.count
    }

    /// Optional cleanup rule. Never runs unless the user configures it.
    @discardableResult
    public func deleteClips(olderThan cutoff: Date, kinds: Set<ClipKind>? = nil, keepPinned: Bool = true, keepSpaceMembers: Bool = true) throws -> Int {
        var sql = "SELECT id FROM clips WHERE last_used_at < ?"
        var bindings: [SQLValue] = [.date(cutoff)]
        if let kinds, !kinds.isEmpty {
            sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            bindings += kinds.map { .text($0.rawValue) }
        }
        if keepPinned { sql += " AND is_pinned = 0" }
        if keepSpaceMembers { sql += " AND NOT EXISTS (SELECT 1 FROM clip_spaces s WHERE s.clip_id = clips.id)" }
        let ids = try db.query(sql, bindings) { $0.int64(0) }
        try deleteInBatches(ids)
        return ids.count
    }

    private func deleteInBatches(_ ids: [Int64]) throws {
        var index = 0
        while index < ids.count {
            let batch = Array(ids[index..<min(index + 500, ids.count)])
            try delete(batch)
            index += batch.count
        }
    }

    /// Removes blob files no longer referenced by any representation. Cheap enough to run after deletes.
    public func collectGarbage() {
        guard let referenced = try? Set(db.query("SELECT DISTINCT blob_key FROM representations WHERE blob_key IS NOT NULL") { $0.string(0) ?? "" }) else { return }
        for key in blobs.allKeys() where !referenced.contains(key) { blobs.remove(key) }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: layout.privateDirectory.path) {
            for name in names where name.hasPrefix("p-") && !referenced.contains(name) {
                try? FileManager.default.removeItem(at: layout.privateDirectory.appendingPathComponent(name))
            }
        }
        if let thumbKeys = try? Set(db.query("SELECT DISTINCT thumbnail_key FROM clips WHERE thumbnail_key IS NOT NULL") { $0.string(0) ?? "" }),
           let names = try? FileManager.default.contentsOfDirectory(atPath: layout.thumbnailsDirectory.path) {
            for name in names where !thumbKeys.contains((name as NSString).deletingPathExtension) {
                try? FileManager.default.removeItem(at: layout.thumbnailsDirectory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Spaces

    public func spaces() throws -> [Space] {
        try db.query("""
            SELECT s.id, s.uuid, s.name, s.icon, s.sort_order, s.is_pinned, s.created_at,
                   (SELECT count(*) FROM clip_spaces cs WHERE cs.space_id = s.id)
            FROM spaces s ORDER BY s.is_pinned DESC, s.sort_order, s.name COLLATE NOCASE
            """) { row in
            Space(id: row.int64(0), uuid: UUID(uuidString: row.string(1) ?? "") ?? UUID(), name: row.string(2) ?? "",
                  icon: row.string(3) ?? "folder", sortOrder: row.int(4), isPinned: row.bool(5), createdAt: row.date(6),
                  clipCount: row.int(7))
        }
    }

    @discardableResult
    public func createSpace(name: String, icon: String = "folder", uuid: UUID = UUID()) throws -> Space {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = clean.isEmpty ? "Untitled Space" : clean
        let order = Int(try db.scalarInt("SELECT coalesce(max(sort_order), 0) + 1 FROM spaces"))
        try db.run("INSERT INTO spaces (uuid, name, icon, sort_order, is_pinned, created_at) VALUES (?, ?, ?, ?, 0, ?)",
                   [.text(uuid.uuidString), .text(finalName), .text(icon), .int(Int64(order)), .date(Date())])
        let id = db.lastInsertRowID
        notifyChange()
        return Space(id: id, uuid: uuid, name: finalName, icon: icon, sortOrder: order, isPinned: false, createdAt: Date())
    }

    public func renameSpace(_ id: Int64, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try db.run("UPDATE spaces SET name = ? WHERE id = ?", [.text(clean), .int(id)])
        notifyChange()
    }

    public func setSpaceIcon(_ id: Int64, icon: String) throws {
        try db.run("UPDATE spaces SET icon = ? WHERE id = ?", [.text(icon), .int(id)])
        notifyChange()
    }

    public func setSpacePinned(_ id: Int64, pinned: Bool) throws {
        try db.run("UPDATE spaces SET is_pinned = ? WHERE id = ?", [.bool(pinned), .int(id)])
        notifyChange()
    }

    /// Deletes a Space. Clips are never deleted with it — they remain in History.
    public func deleteSpace(_ id: Int64) throws {
        try db.run("DELETE FROM spaces WHERE id = ?", [.int(id)])
        notifyChange()
    }

    public func reorderSpaces(_ orderedIDs: [Int64]) throws {
        try db.transaction {
            for (index, id) in orderedIDs.enumerated() {
                try db.run("UPDATE spaces SET sort_order = ? WHERE id = ?", [.int(Int64(index)), .int(id)])
            }
        }
        notifyChange()
    }

    public func addClips(_ clipIDs: [Int64], toSpace spaceID: Int64) throws {
        try db.transaction {
            for id in clipIDs {
                try db.run("INSERT OR IGNORE INTO clip_spaces (clip_id, space_id, added_at) VALUES (?, ?, ?)",
                           [.int(id), .int(spaceID), .date(Date())])
            }
        }
        notifyChange()
    }

    public func removeClips(_ clipIDs: [Int64], fromSpace spaceID: Int64) throws {
        try db.transaction {
            for id in clipIDs {
                try db.run("DELETE FROM clip_spaces WHERE clip_id = ? AND space_id = ?", [.int(id), .int(spaceID)])
            }
        }
        notifyChange()
    }

    /// Creates the starter Spaces exactly once per library.
    public func seedDefaultSpacesIfNeeded(_ names: [(String, String)] = [("Work", "briefcase"), ("Personal", "person"), ("Development", "chevron.left.forwardslash.chevron.right")]) throws {
        guard try metaValue("seeded_spaces") == nil else { return }
        for (name, icon) in names { try createSpace(name: name, icon: icon) }
        try setMetaValue("seeded_spaces", "1")
    }

    // MARK: - Ignored applications

    public func ignoredApps() throws -> [IgnoredApplication] {
        try db.query("SELECT bundle_id, name, added_at FROM ignored_apps ORDER BY name COLLATE NOCASE") {
            IgnoredApplication(bundleID: $0.string(0) ?? "", name: $0.string(1) ?? "", addedAt: $0.date(2))
        }
    }

    public func addIgnoredApp(_ app: IgnoredApplication) throws {
        try db.run("INSERT OR REPLACE INTO ignored_apps (bundle_id, name, added_at) VALUES (?, ?, ?)",
                   [.text(app.bundleID), .text(app.name), .date(app.addedAt)])
        notifyChange()
    }

    public func removeIgnoredApp(bundleID: String) throws {
        try db.run("DELETE FROM ignored_apps WHERE bundle_id = ?", [.text(bundleID)])
        notifyChange()
    }

    // MARK: - OCR and thumbnails

    public func clipsPendingOCR(limit: Int) throws -> [Int64] {
        try db.query("SELECT id FROM clips WHERE ocr_state = 1 ORDER BY last_used_at DESC LIMIT ?", [.int(Int64(limit))]) { $0.int64(0) }
    }

    /// First bitmap representation of a clip, for OCR and thumbnails.
    public func imagePayload(_ id: Int64, allowPrivate: Bool = false) throws -> (type: String, data: Data)? {
        guard let summary = try summary(id: id) else { return nil }
        if summary.isPrivate && !allowPrivate { return nil }
        let reps = try loadRepresentations(clipID: id)
        for type in RepresentationType.imageTypes + [RepresentationType.pdf] {
            if let rep = reps.first(where: { $0.type == type }) { return (type, rep.data) }
        }
        return nil
    }

    public func setOCRResult(_ id: Int64, text: String?, failed: Bool = false) throws {
        try db.transaction {
            let state: OCRState = failed ? .failed : .done
            let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.run("UPDATE clips SET ocr_state = ?, ocr_length = ? WHERE id = ?",
                       [.int(Int64(state.rawValue)), .int(Int64(clean?.count ?? 0)), .int(id)])
            // Images have no text of their own; the recognised text becomes their preview line.
            if let clean, !clean.isEmpty {
                try db.run("UPDATE clips SET preview_text = ? WHERE id = ? AND is_private = 0 AND kind IN ('image', 'screenshot') AND preview_text = ''",
                           [.text(String(clean.prefix(Self.previewLength))), .int(id)])
            }
            try db.run("""
                INSERT INTO clip_text (clip_id, ocr_text) VALUES (?, ?)
                ON CONFLICT(clip_id) DO UPDATE SET ocr_text = excluded.ocr_text
                """, [.int(id), .from(clean)])
            try reindex(id)
        }
        notifyChange()
    }

    public func requestOCR(_ id: Int64) throws {
        try db.run("UPDATE clips SET ocr_state = 1 WHERE id = ? AND is_private = 0", [.int(id)])
    }

    public func clipsNeedingThumbnails(limit: Int) throws -> [Int64] {
        try db.query("""
            SELECT id FROM clips WHERE thumbnail_key IS NULL AND is_private = 0 AND kind IN ('image', 'screenshot', 'pdf')
            ORDER BY last_used_at DESC LIMIT ?
            """, [.int(Int64(limit))]) { $0.int64(0) }
    }

    public func setThumbnail(_ id: Int64, key: String, imageSize: (Int, Int)?) throws {
        guard var summary = try summary(id: id) else { return }
        if let imageSize, summary.metadata.imageWidth == nil {
            summary.metadata.imageWidth = imageSize.0
            summary.metadata.imageHeight = imageSize.1
        }
        try db.run("UPDATE clips SET thumbnail_key = ?, metadata = ? WHERE id = ?",
                   [.text(key), .from(summary.metadata.encoded()), .int(id)])
        notifyChange()
    }

    /// Marks a clip as having no possible thumbnail so it is not retried forever.
    public func markThumbnailUnavailable(_ id: Int64) throws {
        try db.run("UPDATE clips SET thumbnail_key = '' WHERE id = ?", [.int(id)])
    }

    public nonisolated func thumbnailURL(for key: String) -> URL {
        layout.thumbnailsDirectory.appendingPathComponent(key + ".png")
    }

    // MARK: - Reclassification

    /// Bump when classification rules change so existing history benefits from the improvement.
    public static let classifierVersion = 3

    /// Re-runs classification for text-based clips captured by an older classifier. User titles,
    /// pins, Spaces, tags and private clips are never touched. Returns the number of clips updated.
    @discardableResult
    public func reclassifyIfNeeded() async throws -> Int {
        let stored = Int(try metaValue("classifier_version") ?? "0") ?? 0
        guard stored < Self.classifierVersion else { return 0 }
        let textKinds = ClipKind.allCases.filter(\.isTextLike).map { "'\($0.rawValue)'" }.joined(separator: ",")
        var updated = 0
        var lastID: Int64 = 0
        while true {
            let ids = try db.query("SELECT id FROM clips WHERE id > ? AND is_private = 0 AND kind IN (\(textKinds)) ORDER BY id LIMIT 200",
                                   [.int(lastID)]) { $0.int64(0) }
            guard let maxID = ids.last else { break }
            lastID = maxID
            try db.transaction {
                for id in ids {
                    guard let summary = try summary(id: id) else { continue }
                    let reps = try loadRepresentations(clipID: id)
                    guard !reps.isEmpty else { continue }
                    var grouped: [Int: [ClipRepresentation]] = [:]
                    for rep in reps { grouped[rep.itemIndex, default: []].append(rep) }
                    let snapshot = ClipboardSnapshot(items: grouped.keys.sorted().map { grouped[$0]! }, sourceApp: summary.sourceApp)
                    let result = ContentClassifier.classify(snapshot)
                    guard result.kind != summary.kind || result.autoTitle != summary.autoTitle || result.sensitivity.level != summary.sensitivity else { continue }
                    var metadata = result.metadata
                    metadata.urlTitle = summary.metadata.urlTitle
                    try db.run("UPDATE clips SET kind = ?, auto_title = ?, metadata = ?, sensitivity = ?, preview_text = ? WHERE id = ?", [
                        .text(result.kind.rawValue), .from(result.autoTitle), .from(metadata.encoded()),
                        .int(Int64(result.sensitivity.level.rawValue)), .text(String(result.searchableText.prefix(Self.previewLength))), .int(id),
                    ])
                    try reindex(id)
                    updated += 1
                }
            }
            await Task.yield()
        }
        try setMetaValue("classifier_version", String(Self.classifierVersion))
        if updated > 0 { notifyChange() }
        return updated
    }

    // MARK: - Meta

    public func metaValue(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.string(0) }.first ?? nil
    }

    public func setMetaValue(_ key: String, _ value: String?) throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .from(value)])
    }

    // MARK: - Maintenance

    /// Compacts the database file and optimises the search index.
    public func vacuum() throws {
        try db.execute("INSERT INTO clip_fts(clip_fts) VALUES('optimize')")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("VACUUM")
        try db.execute("PRAGMA optimize")
        collectGarbage()
    }

    /// Rebuilds the full-text index from scratch (recovery tool).
    public func rebuildSearchIndex() throws {
        let ids = try db.query("SELECT id FROM clips") { $0.int64(0) }
        try db.transaction {
            try db.execute("DELETE FROM clip_fts")
            for id in ids { try reindex(id) }
        }
    }

    /// Writes a consistent copy of the database to `url` (used for backups).
    public func snapshotDatabase(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try db.run("VACUUM INTO ?", [.text(url.path)])
    }

    public func removeThumbnailCache() throws {
        try db.run("UPDATE clips SET thumbnail_key = NULL")
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: layout.thumbnailsDirectory.path) {
            for name in names { try? fm.removeItem(at: layout.thumbnailsDirectory.appendingPathComponent(name)) }
        }
        notifyChange()
    }

    public func storageStatistics() throws -> StorageStatistics {
        var stats = StorageStatistics()
        for (kind, count, bytes) in try db.query("SELECT kind, count(*), sum(byte_size) FROM clips GROUP BY kind", map: {
            (ClipKind(rawValue: $0.string(0) ?? "") ?? .unknown, $0.int(1), $0.int64(2))
        }) {
            stats.clipCountByKind[kind] = count
            stats.payloadBytesByKind[kind] = bytes
        }
        stats.totalClips = stats.clipCountByKind.values.reduce(0, +)
        stats.pinnedClips = Int(try db.scalarInt("SELECT count(*) FROM clips WHERE is_pinned = 1"))
        stats.privateClips = Int(try db.scalarInt("SELECT count(*) FROM clips WHERE is_private = 1"))
        stats.ocrTextBytes = try db.scalarInt("SELECT coalesce(sum(length(ocr_text)), 0) FROM clip_text")
        let dbPath = layout.databaseFile.path
        stats.databaseBytes = [dbPath, dbPath + "-wal", dbPath + "-shm"].reduce(0) { $0 + FileUtilities.fileSize(URL(fileURLWithPath: $1)) }
        stats.blobBytes = FileUtilities.directorySize(layout.blobsDirectory) + FileUtilities.directorySize(layout.privateDirectory)
        stats.thumbnailBytes = FileUtilities.directorySize(layout.thumbnailsDirectory)
        stats.backupBytes = FileUtilities.directorySize(layout.backupsDirectory)
        if let oldest = try db.query("SELECT min(created_at) FROM clips", map: { $0.isNull(0) ? nil : $0.date(0) }).first { stats.oldestClip = oldest }
        return stats
    }
}

public struct StorageStatistics: Sendable {
    public var totalClips = 0
    public var pinnedClips = 0
    public var privateClips = 0
    public var clipCountByKind: [ClipKind: Int] = [:]
    public var payloadBytesByKind: [ClipKind: Int64] = [:]
    public var databaseBytes: Int64 = 0
    public var blobBytes: Int64 = 0
    public var thumbnailBytes: Int64 = 0
    public var ocrTextBytes: Int64 = 0
    public var backupBytes: Int64 = 0
    public var oldestClip: Date?

    public init() {}

    public var totalBytes: Int64 { databaseBytes + blobBytes + thumbnailBytes }

    public func count(_ kinds: Set<ClipKind>) -> Int { kinds.reduce(0) { $0 + (clipCountByKind[$1] ?? 0) } }
    public func payloadBytes(_ kinds: Set<ClipKind>) -> Int64 { kinds.reduce(0) { $0 + (payloadBytesByKind[$1] ?? 0) } }
}

extension Optional where Wrapped == String {
    var nilIfBlank: String? { self?.nilIfBlank }
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
