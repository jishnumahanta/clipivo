import Foundation
import Testing
@testable import ClipivoCore

@Suite("Library persistence")
struct LibraryPersistenceTests {
    @Test func storesAndReloadsAcrossInstances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoReopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let library = try ClipLibrary(layout: StorageLayout(root: root))
            let processor = CaptureProcessor(library: library)
            _ = try await processor.process(.text("persist me"), policy: .testDefault)
        }
        let reopened = try ClipLibrary(layout: StorageLayout(root: root))
        let clips = try await reopened.fetch(ClipQuery())
        #expect(clips.count == 1)
        #expect(clips.first?.previewText == "persist me")
        #expect(reopened.recoveredFromCorruption == false)
    }

    @Test func secureFilePermissions() async throws {
        let t = try TemporaryLibrary()
        let attrs = try FileManager.default.attributesOfItem(atPath: t.library.layout.root.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        try await t.capture("forces the WAL file to exist")
        for suffix in ["", "-wal", "-shm"] {
            let path = t.library.layout.databaseFile.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attrs[.posixPermissions] as? Int) == 0o600, "\(suffix.isEmpty ? "database" : suffix) is not owner-only")
        }
        _ = try await t.processor.process(.single([RepresentationType.png: largePayload(100_000)]), policy: .testDefault)
        let blob = try #require(t.library.blobs.allKeys().first)
        let blobAttrs = try FileManager.default.attributesOfItem(atPath: t.library.blobs.url(for: blob).path)
        #expect((blobAttrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func duplicatesMoveToTopInsteadOfInserting() async throws {
        let t = try TemporaryLibrary()
        let first = try await t.capture("alpha", at: Date(timeIntervalSince1970: 1_000))
        try await t.capture("beta", at: Date(timeIntervalSince1970: 2_000))
        let again = try await t.capture("alpha", at: Date(timeIntervalSince1970: 3_000))
        guard case .stored(.inserted(let id), _) = first, case .stored(.duplicate(let dupID), _) = again else {
            Issue.record("unexpected outcomes \(first) \(again)"); return
        }
        #expect(id == dupID)
        let clips = try await t.library.fetch(ClipQuery())
        #expect(clips.map(\.previewText) == ["alpha", "beta"])
        #expect(clips[0].createdAt == Date(timeIntervalSince1970: 1_000)) // original capture time preserved
        #expect(clips[0].useCount == 1)
    }

    @Test func keepAllPolicyInsertsDuplicates() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy.testDefault
        policy.duplicatePolicy = .keepAll
        try await t.capture("same", policy: policy)
        try await t.capture("same", policy: policy)
        #expect(try await t.library.totalCount() == 2)
    }

    @Test func richTextPreservesAllRepresentations() async throws {
        let t = try TemporaryLibrary()
        let rtf = Data("{\\rtf1\\ansi {\\b Bold} text}".utf8)
        let html = Data("<b>Bold</b> text".utf8)
        let snapshot = ClipboardSnapshot.single([
            RepresentationType.plainText: Data("Bold text".utf8), RepresentationType.rtf: rtf, RepresentationType.html: html,
        ])
        let outcome = try await t.processor.process(snapshot, policy: .testDefault)
        let id = try #require(t.storedID(outcome))
        let content = try await t.library.content(id: id)
        #expect(content.summary.kind == .richText)
        #expect(content.data(for: RepresentationType.rtf) == rtf)
        #expect(content.data(for: RepresentationType.html) == html)
        #expect(content.plainText == "Bold text")
    }

    @Test func largePayloadsGoToDeduplicatedBlobStore() async throws {
        let t = try TemporaryLibrary()
        let image = largePayload(500_000)
        let snapshot = ClipboardSnapshot.single([RepresentationType.png: image])
        var policy = CapturePolicy.testDefault
        policy.duplicatePolicy = .keepAll
        let a = try #require(t.storedID(try await t.processor.process(snapshot, policy: policy)))
        let b = try #require(t.storedID(try await t.processor.process(snapshot, policy: policy)))
        #expect(a != b)
        #expect(t.library.blobs.allKeys().count == 1) // one file for two clips
        let content = try await t.library.content(id: a)
        #expect(content.data(for: RepresentationType.png) == image)

        try await t.library.delete([a])
        #expect(t.library.blobs.allKeys().count == 1) // still referenced by b
        try await t.library.delete([b])
        #expect(t.library.blobs.allKeys().isEmpty)     // garbage collected
    }

    @Test func dropsRedundantTIFFWhenPNGPresent() async throws {
        let t = try TemporaryLibrary()
        let snapshot = ClipboardSnapshot.single([RepresentationType.png: tinyPNG, RepresentationType.tiff: largePayload(100_000)])
        let id = try #require(t.storedID(try await t.processor.process(snapshot, policy: .testDefault)))
        let content = try await t.library.content(id: id)
        #expect(content.data(for: RepresentationType.tiff) == nil)
        #expect(content.data(for: RepresentationType.png) == tinyPNG)
    }

    @Test func multipleFileItemsRoundTrip() async throws {
        let t = try TemporaryLibrary()
        let snapshot = ClipboardSnapshot(items: [
            [ClipRepresentation(itemIndex: 0, type: RepresentationType.fileURL, data: Data("file:///tmp/a.txt".utf8))],
            [ClipRepresentation(itemIndex: 1, type: RepresentationType.fileURL, data: Data("file:///tmp/b.txt".utf8))],
        ], sourceApp: SourceApplication(bundleID: "com.apple.finder", name: "Finder"))
        let id = try #require(t.storedID(try await t.processor.process(snapshot, policy: .testDefault)))
        let content = try await t.library.content(id: id)
        #expect(content.itemCount == 2)
        #expect(content.plainText == "/tmp/a.txt\n/tmp/b.txt")
        let found = try await t.library.fetch(ClipQuery(text: "b.txt"))
        #expect(found.map(\.id) == [id])
    }

    @Test func corruptDatabaseIsMovedAsideNotDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = StorageLayout(root: root)
        try layout.prepare()
        try Data(repeating: 0x42, count: 8192).write(to: layout.databaseFile)
        let library = try ClipLibrary(layout: layout)
        #expect(library.recoveredFromCorruption)
        let files = try FileManager.default.contentsOfDirectory(atPath: layout.databaseDirectory.path)
        #expect(files.contains { $0.hasPrefix("damaged-") })
    }
}

@Suite("Capture policy")
struct CapturePolicyTests {
    @Test func pausedCapturesNothing() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy.testDefault
        policy.isPaused = true
        let outcome = try await t.capture("secret plans", policy: policy)
        guard case .skipped(.paused) = outcome else { Issue.record("expected paused, got \(outcome)"); return }
        #expect(try await t.library.totalCount() == 0)
    }

    @Test func ignoredApplicationsAreNeverStored() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy.testDefault
        policy.ignoredBundleIDs = ["com.bank.app"]
        let outcome = try await t.capture("account 12345", app: "com.bank.app", policy: policy)
        guard case .skipped(.ignoredApplication) = outcome else { Issue.record("got \(outcome)"); return }
        let image = ClipboardSnapshot.single([RepresentationType.png: largePayload(100_000)], source: SourceApplication(bundleID: "com.bank.app", name: "Bank"))
        _ = try await t.processor.process(image, policy: policy)
        #expect(try await t.library.totalCount() == 0)
        #expect(t.library.blobs.allKeys().isEmpty) // nothing written to disk
        #expect(CaptureProcessor.shouldRead(sourceBundleID: "com.bank.app", policy: policy) == .ignoredApplication)
    }

    @Test func transientMarkerIsHonored() async throws {
        let t = try TemporaryLibrary()
        let snapshot = ClipboardSnapshot(items: [[ClipRepresentation(type: RepresentationType.plainText, data: Data("x".utf8))]],
                                         declaredTypes: [RepresentationType.plainText, RepresentationType.transient], sourceApp: nil)
        guard case .skipped(.transient) = try await t.processor.process(snapshot, policy: .testDefault) else { Issue.record("expected transient skip"); return }
    }

    @Test func concealedDiscardedByDefault() async throws {
        let t = try TemporaryLibrary()
        let snapshot = ClipboardSnapshot(items: [[ClipRepresentation(type: RepresentationType.plainText, data: Data("hunter2".utf8))]],
                                         declaredTypes: [RepresentationType.plainText, RepresentationType.concealed], sourceApp: nil)
        let outcome = try await t.processor.process(snapshot, policy: CapturePolicy())
        guard case .skipped(.concealed) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(try await t.library.totalCount() == 0)
    }

    @Test func sensitiveAskReturnsPendingWithoutStoring() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy()
        policy.sensitivePolicy = .ask
        let outcome = try await t.capture(FakeSecrets.githubToken, policy: policy)
        guard case .needsConfirmation(let pending) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(pending.findings.contains(.apiKey))
        #expect(try await t.library.totalCount() == 0)
        // User chooses "Save".
        try await t.library.store(pending.prepared)
        #expect(try await t.library.totalCount() == 1)
    }

    @Test func sensitiveNeverSave() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy()
        policy.sensitivePolicy = .discard
        guard case .skipped(.sensitive) = try await t.capture(FakeSecrets.awsKeyID, policy: policy) else { Issue.record("expected skip"); return }
    }

    @Test func oneTimeCodesDiscardedByDefault() async throws {
        let t = try TemporaryLibrary()
        guard case .skipped(.oneTimeCode) = try await t.capture("739201", policy: CapturePolicy()) else { Issue.record("expected skip"); return }
    }

    @Test func sensitiveSaveAsPrivateEncryptsAtRest() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy()
        policy.sensitivePolicy = .saveAsPrivate
        let secret = FakeSecrets.stripeLiveLong
        let id = try #require(t.storedID(try await t.capture(secret, policy: policy)))
        let summary = try #require(try await t.library.summary(id: id))
        #expect(summary.isPrivate)
        #expect(summary.previewText.isEmpty)
        // Not searchable by content, not readable without unlocking.
        #expect(try await t.library.fetch(ClipQuery(text: "51H8abc")).isEmpty)
        await #expect(throws: LibraryError.self) { try await t.library.content(id: id) }
        let unlocked = try await t.library.content(id: id, allowPrivate: true)
        #expect(unlocked.plainText == secret)
        // Raw database bytes never contain the secret.
        let dbBytes = try Data(contentsOf: t.library.layout.databaseFile)
        let wal = (try? Data(contentsOf: URL(fileURLWithPath: t.library.layout.databaseFile.path + "-wal"))) ?? Data()
        #expect(dbBytes.range(of: Data(secret.utf8)) == nil)
        #expect(wal.range(of: Data(secret.utf8)) == nil)
    }

    @Test func togglePrivateRoundTrip() async throws {
        let t = try TemporaryLibrary()
        let id = try #require(t.storedID(try await t.capture("confidential roadmap draft")))
        try await t.library.setPrivate(id, isPrivate: true)
        #expect(try await t.library.fetch(ClipQuery(text: "roadmap")).isEmpty)
        try await t.library.setPrivate(id, isPrivate: false)
        #expect(try await t.library.fetch(ClipQuery(text: "roadmap")).map(\.id) == [id])
        #expect(try await t.library.content(id: id).plainText == "confidential roadmap draft")
    }

    @Test func oversizedRepresentationsAreDropped() async throws {
        let t = try TemporaryLibrary()
        var policy = CapturePolicy.testDefault
        policy.maxRepresentationBytes = 1_000
        let outcome = try await t.processor.process(.single([RepresentationType.png: largePayload(5_000)]), policy: policy)
        guard case .skipped(.tooLarge) = outcome else { Issue.record("got \(outcome)"); return }
    }
}

@Suite("Search")
struct SearchTests {
    func seeded() async throws -> TemporaryLibrary {
        let t = try TemporaryLibrary()
        let base = Date().addingTimeInterval(-3_600)
        try await t.capture("npx supabase db push --linked", app: "com.microsoft.VSCode", at: base)
        try await t.capture("Invoice #4411 for March", app: "com.google.Chrome", at: base.addingTimeInterval(10))
        try await t.capture("https://supabase.com/dashboard/project/abc", app: "com.apple.Safari", at: base.addingTimeInterval(20))
        try await t.capture("Grocery list: milk, eggs, bread", app: "com.apple.Notes", at: base.addingTimeInterval(30))
        try await t.capture("ÜBER façade naïve café", app: "com.apple.Notes", at: base.addingTimeInterval(40))
        return t
    }

    @Test func substringCaseInsensitive() async throws {
        let t = try await seeded()
        let results = try await t.library.fetch(ClipQuery(text: "SUPABASE"))
        #expect(results.count == 2)
        let partial = try await t.library.fetch(ClipQuery(text: "pabas"))
        #expect(partial.count == 2)
    }

    @Test func multiWordAND() async throws {
        let t = try await seeded()
        #expect(try await t.library.fetch(ClipQuery(text: "supabase push")).count == 1)
        #expect(try await t.library.fetch(ClipQuery(text: "supabase grocery")).isEmpty)
    }

    @Test func shortTermsFallBackToLike() async throws {
        let t = try await seeded()
        #expect(try await t.library.fetch(ClipQuery(text: "db")).count == 1)
        #expect(try await t.library.fetch(ClipQuery(text: "#4")).count == 1)
    }

    @Test func unicode() async throws {
        let t = try await seeded()
        #expect(try await t.library.fetch(ClipQuery(text: "façade")).count == 1)
    }

    @Test func appFilterAndInlineSyntax() async throws {
        let t = try await seeded()
        #expect(try await t.library.fetch(ClipQuery(sourceBundleIDs: ["com.apple.Notes"])).count == 2)
        #expect(try await t.library.fetch(ClipQuery(text: "app:chrome")).count == 1)
        #expect(try await t.library.fetch(ClipQuery(text: "supabase app:safari")).count == 1)
        // Searching the app name itself also matches via the index.
        #expect(try await t.library.fetch(ClipQuery(text: "VSCode")).count == 1)
    }

    @Test func typeFilter() async throws {
        let t = try await seeded()
        #expect(try await t.library.fetch(ClipQuery(kinds: ClipCategory.links.kinds)).count == 1)
        #expect(try await t.library.fetch(ClipQuery(text: "type:link")).count == 1)
        #expect(try await t.library.fetch(ClipQuery(kinds: ClipCategory.code.kinds)).count == 1)
    }

    @Test func dateFilter() async throws {
        let t = try TemporaryLibrary()
        try await t.capture("old item", at: Date().addingTimeInterval(-40 * 86_400))
        try await t.capture("new item")
        #expect(try await t.library.fetch(ClipQuery(dateFilter: .last7Days)).map(\.previewText) == ["new item"])
        #expect(try await t.library.fetch(ClipQuery(text: "item date:month")).count == 1)
    }

    @Test func titlesAreSearchableAndNotOverwritten() async throws {
        let t = try await seeded()
        let clip = try #require(try await t.library.fetch(ClipQuery(text: "Grocery")).first)
        try await t.library.setTitle(clip.id, title: "Weekly shopping")
        #expect(try await t.library.fetch(ClipQuery(text: "shopping")).map(\.id) == [clip.id])
        // Re-copying the same content must not reset the user's title.
        try await t.capture("Grocery list: milk, eggs, bread", app: "com.apple.Notes")
        #expect(try await t.library.summary(id: clip.id)?.title == "Weekly shopping")
        try await t.library.setTitle(clip.id, title: "   ")
        #expect(try await t.library.summary(id: clip.id)?.title == nil)
    }

    @Test func tagsSearchAndFilter() async throws {
        let t = try await seeded()
        let clip = try #require(try await t.library.fetch(ClipQuery(text: "Invoice")).first)
        try await t.library.addTag("finance", to: [clip.id])
        #expect(try await t.library.fetch(ClipQuery(text: "tag:finance")).map(\.id) == [clip.id])
        #expect(try await t.library.fetch(ClipQuery(text: "finance")).map(\.id) == [clip.id])
        try await t.library.removeTag("finance", from: [clip.id])
        #expect(try await t.library.fetch(ClipQuery(text: "tag:finance")).isEmpty)
    }

    @Test func ocrTextIsIndexed() async throws {
        let t = try TemporaryLibrary()
        let id = try #require(t.storedID(try await t.processor.process(.single([RepresentationType.png: tinyPNG]), policy: .testDefault)))
        #expect(try await t.library.clipsPendingOCR(limit: 10) == [id])
        try await t.library.setOCRResult(id, text: "Project Phoenix launch checklist")
        #expect(try await t.library.fetch(ClipQuery(text: "phoenix")).map(\.id) == [id])
        #expect(try await t.library.clipsPendingOCR(limit: 10).isEmpty)
        // Recognised text becomes the image's preview line.
        #expect(try await t.library.summary(id: id)?.previewText == "Project Phoenix launch checklist")
        var fields = SearchFields.all
        fields.remove(.ocr)
        var query = ClipQuery(text: "phoenix")
        query.fields = fields
        #expect(try await t.library.fetch(query).isEmpty)
    }

    @Test func rankingPrefersTitleMatches() async throws {
        let t = try TemporaryLibrary()
        let a = try #require(t.storedID(try await t.capture("some text mentioning deploy once")))
        let b = try #require(t.storedID(try await t.capture("unrelated body")))
        try await t.library.setTitle(b, title: "Deploy script")
        let results = try await t.library.fetch(ClipQuery(text: "deploy"))
        #expect(results.map(\.id) == [b, a])
    }

    @Test func pagination() async throws {
        let t = try TemporaryLibrary()
        for i in 0..<250 { try await t.capture("item \(i)", at: Date(timeIntervalSince1970: TimeInterval(i))) }
        var seen: [Int64] = []
        var offset = 0
        while true {
            let page = try await t.library.fetch(ClipQuery(limit: 100, offset: offset))
            if page.isEmpty { break }
            seen += page.map(\.id)
            offset += page.count
        }
        #expect(seen.count == 250)
        #expect(Set(seen).count == 250)
        #expect(try await t.library.count(ClipQuery(text: "item")) == 250)
    }
}

@Suite("Spaces, pins and cleanup")
struct OrganizationTests {
    @Test func spacesLifecycle() async throws {
        let t = try TemporaryLibrary()
        let a = try #require(t.storedID(try await t.capture("first")))
        let b = try #require(t.storedID(try await t.capture("second")))
        let work = try await t.library.createSpace(name: "Work", icon: "briefcase")
        let prompts = try await t.library.createSpace(name: "AI Prompts")
        try await t.library.addClips([a, b], toSpace: work.id)
        try await t.library.addClips([a], toSpace: prompts.id) // a clip can live in several Spaces
        #expect(try await t.library.fetch(ClipQuery(spaceID: work.id)).count == 2)
        #expect(try await t.library.summary(id: a)?.spaceIDs.sorted() == [work.id, prompts.id].sorted())
        #expect(try await t.library.fetch(ClipQuery(text: "in:prompts")).map(\.id) == [a])

        try await t.library.renameSpace(work.id, to: "Client Work")
        try await t.library.setSpaceIcon(work.id, icon: "star")
        try await t.library.setSpacePinned(prompts.id, pinned: true)
        let spaces = try await t.library.spaces()
        #expect(spaces.first?.id == prompts.id) // pinned Spaces sort first
        #expect(spaces.first(where: { $0.id == work.id })?.name == "Client Work")
        #expect(spaces.first(where: { $0.id == work.id })?.clipCount == 2)

        try await t.library.reorderSpaces([work.id, prompts.id])
        try await t.library.removeClips([b], fromSpace: work.id)
        #expect(try await t.library.fetch(ClipQuery(spaceID: work.id)).map(\.id) == [a])

        // Deleting a Space never deletes clips.
        try await t.library.deleteSpace(work.id)
        #expect(try await t.library.totalCount() == 2)
    }

    @Test func seedDefaultsOnlyOnce() async throws {
        let t = try TemporaryLibrary()
        try await t.library.seedDefaultSpacesIfNeeded()
        let first = try await t.library.spaces()
        try await t.library.deleteSpace(first[0].id)
        try await t.library.seedDefaultSpacesIfNeeded()
        #expect(try await t.library.spaces().count == first.count - 1)
    }

    @Test func pinningDoesNotDuplicate() async throws {
        let t = try TemporaryLibrary()
        let a = try #require(t.storedID(try await t.capture("pin me")))
        let b = try #require(t.storedID(try await t.capture("pin me too")))
        try await t.library.setPinned([a, b], pinned: true)
        #expect(try await t.library.totalCount() == 2)
        try await t.library.reorderPinned([a, b])
        #expect(try await t.library.fetch(ClipQuery(pinnedOnly: true)).map(\.id) == [a, b])
        try await t.library.setPinned([a], pinned: false)
        #expect(try await t.library.fetch(ClipQuery(pinnedOnly: true)).map(\.id) == [b])
    }

    @Test func clearHistoryKeepsPinnedAndSpaceMembers() async throws {
        let t = try TemporaryLibrary()
        let pinned = try #require(t.storedID(try await t.capture("pinned")))
        let inSpace = try #require(t.storedID(try await t.capture("in space")))
        try await t.capture("plain 1")
        try await t.capture("plain 2")
        try await t.library.setPinned([pinned], pinned: true)
        let space = try await t.library.createSpace(name: "Keep")
        try await t.library.addClips([inSpace], toSpace: space.id)
        let removed = try await t.library.clearHistory()
        #expect(removed == 2)
        #expect(Set(try await t.library.fetch(ClipQuery()).map(\.id)) == [pinned, inSpace])
    }

    @Test func optionalAgeCleanup() async throws {
        let t = try TemporaryLibrary()
        let old = try #require(t.storedID(try await t.capture("ancient", at: Date().addingTimeInterval(-400 * 86_400))))
        let oldPinned = try #require(t.storedID(try await t.capture("ancient pinned", at: Date().addingTimeInterval(-400 * 86_400))))
        try await t.library.setPinned([oldPinned], pinned: true)
        try await t.capture("fresh")
        let removed = try await t.library.deleteClips(olderThan: Date().addingTimeInterval(-365 * 86_400))
        #expect(removed == 1)
        #expect(try await t.library.summary(id: old) == nil)
        #expect(try await t.library.summary(id: oldPinned) != nil)
    }

    @Test func deleteFromSourceAndSimilar() async throws {
        let t = try TemporaryLibrary()
        try await t.capture("a", app: "com.spam.app")
        try await t.capture("b", app: "com.spam.app")
        try await t.capture("c", app: "com.good.app")
        #expect(try await t.library.deleteAll(fromSource: "com.spam.app") == 2)
        #expect(try await t.library.totalCount() == 1)

        var policy = CapturePolicy.testDefault
        policy.duplicatePolicy = .keepAll
        let x = try #require(t.storedID(try await t.capture("Hello   World", policy: policy)))
        try await t.capture("hello world", policy: policy)
        try await t.capture("goodbye world", policy: policy)
        #expect(try await t.library.deleteSimilar(to: x) == 2)
        #expect(try await t.library.fetch(ClipQuery(text: "goodbye")).count == 1)
    }

    @Test func markUsedMovesToTop() async throws {
        let t = try TemporaryLibrary()
        let a = try #require(t.storedID(try await t.capture("older", at: Date(timeIntervalSince1970: 100))))
        try await t.capture("newer", at: Date(timeIntervalSince1970: 200))
        try await t.library.markUsed(a)
        #expect(try await t.library.fetch(ClipQuery()).first?.id == a)
    }

    @Test func sourceAppsAndStatistics() async throws {
        let t = try TemporaryLibrary()
        try await t.capture("x", app: "com.a")
        try await t.capture("y", app: "com.a")
        try await t.capture("z", app: "com.b")
        _ = try await t.processor.process(.single([RepresentationType.png: largePayload(200_000)]), policy: .testDefault)
        let apps = try await t.library.sourceApps()
        #expect(apps.first?.app.bundleID == "com.a")
        #expect(apps.first?.clipCount == 2)
        let stats = try await t.library.storageStatistics()
        #expect(stats.totalClips == 4)
        #expect(stats.count([.screenshot, .image]) == 1)
        #expect(stats.payloadBytes([.screenshot, .image]) == 200_000)
        #expect(stats.blobBytes >= 200_000)
        #expect(stats.databaseBytes > 0)
    }

    @Test func ignoredAppsPersist() async throws {
        let t = try TemporaryLibrary()
        try await t.library.addIgnoredApp(IgnoredApplication(bundleID: "com.x", name: "X"))
        #expect(try await t.library.ignoredApps().map(\.bundleID) == ["com.x"])
        try await t.library.removeIgnoredApp(bundleID: "com.x")
        #expect(try await t.library.ignoredApps().isEmpty)
    }

    @Test func reclassificationUpgradesOldClipsButKeepsTitles() async throws {
        let t = try TemporaryLibrary()
        let id = try #require(t.storedID(try await t.capture("ESP-MATRIX-0010")))
        // Simulate a clip stored by an older, buggier classifier.
        try await t.library.setTitle(id, title: "Board serial")
        try await t.library.db.run("UPDATE clips SET kind = 'credential', auto_title = 'Password-like text' WHERE id = ?", [.int(id)])
        try await t.library.setMetaValue("classifier_version", "1")
        #expect(try await t.library.reclassifyIfNeeded() == 1)
        let summary = try #require(try await t.library.summary(id: id))
        #expect(summary.kind == .text)
        #expect(summary.title == "Board serial")
        #expect(try await t.library.reclassifyIfNeeded() == 0) // runs once per classifier version
    }

    @Test func vacuumAndRebuild() async throws {
        let t = try TemporaryLibrary()
        for i in 0..<50 { try await t.capture("vacuum \(i)") }
        try await t.library.vacuum()
        try await t.library.rebuildSearchIndex()
        #expect(try await t.library.count(ClipQuery(text: "vacuum")) == 50)
    }
}

@Suite("Background processing")
struct BackgroundProcessingTests {
    struct FakeRecognizer: TextRecognizer {
        func recognizeText(in imageData: Data) async throws -> String { "Recognized invoice total 42" }
    }

    struct FakeRenderer: ThumbnailRenderer {
        func thumbnail(for data: Data, type: String, maxPixelSize: Int) async -> (png: Data, originalSize: (Int, Int)?)? {
            (tinyPNG, (1920, 1080))
        }
    }

    @Test func ocrAndThumbnailsPipeline() async throws {
        let t = try TemporaryLibrary()
        let id = try #require(t.storedID(try await t.processor.process(.single([RepresentationType.png: tinyPNG]), policy: .testDefault)))
        let processor = BackgroundProcessor(library: t.library, recognizer: FakeRecognizer(), renderer: FakeRenderer())
        await processor.run()
        let summary = try #require(try await t.library.summary(id: id))
        #expect(summary.ocrState == .done)
        #expect(summary.thumbnailKey != nil)
        #expect(summary.metadata.imageWidth == 1920)
        #expect(FileManager.default.fileExists(atPath: t.library.thumbnailURL(for: summary.thumbnailKey!).path))
        #expect(try await t.library.fetch(ClipQuery(text: "invoice total")).map(\.id) == [id])
        #expect(try await processor.recognizeNow(id) == "Recognized invoice total 42")
    }
}

@Suite("Archive")
struct ArchiveTests {
    @Test func exportImportRoundTripWithoutDuplication() async throws {
        let source = try TemporaryLibrary()
        let text = try #require(source.storedID(try await source.capture("export me please", app: "com.apple.Notes")))
        let image = try #require(source.storedID(try await source.processor.process(.single([RepresentationType.png: largePayload(120_000)]), policy: .testDefault)))
        try await source.library.setTitle(text, title: "Exported title")
        try await source.library.setPinned([text], pinned: true)
        try await source.library.addTag("keep", to: [text])
        let space = try await source.library.createSpace(name: "Projects", icon: "folder")
        try await source.library.addClips([text, image], toSpace: space.id)
        try await source.library.setOCRResult(image, text: "diagram labels")

        let archive = source.root.appendingPathComponent("out.clipivoarchive")
        let exported = try await source.library.exportArchive(to: archive, includePrivate: false)
        #expect(exported.clipsWritten == 2)

        let target = try TemporaryLibrary()
        let imported = try await target.library.importArchive(from: archive)
        #expect(imported.clipsImported == 2)
        #expect(imported.spacesCreated == 1)

        let clips = try await target.library.fetch(ClipQuery())
        #expect(clips.count == 2)
        let restoredText = try #require(clips.first { $0.title == "Exported title" })
        #expect(restoredText.isPinned)
        #expect(restoredText.tags == ["keep"])
        #expect(restoredText.sourceApp?.bundleID == "com.apple.Notes")
        #expect(restoredText.spaceIDs.count == 1)
        #expect(try await target.library.fetch(ClipQuery(text: "diagram")).count == 1)
        let restoredImage = try #require(clips.first { $0.kind.isImageLike })
        #expect(try await target.library.content(id: restoredImage.id).data(for: RepresentationType.png) == largePayload(120_000))

        // Importing again must not duplicate anything.
        let again = try await target.library.importArchive(from: archive)
        #expect(again.clipsImported == 0)
        #expect(again.clipsSkipped == 2)
        #expect(try await target.library.totalCount() == 2)
    }

    @Test func importMergesSameContent() async throws {
        let source = try TemporaryLibrary()
        let id = try #require(source.storedID(try await source.capture("shared content")))
        try await source.library.setPinned([id], pinned: true)
        let archive = source.root.appendingPathComponent("merge.clipivoarchive")
        _ = try await source.library.exportArchive(to: archive, includePrivate: false)

        let target = try TemporaryLibrary()
        try await target.capture("shared content")
        let result = try await target.library.importArchive(from: archive)
        #expect(result.clipsMerged == 1)
        #expect(try await target.library.totalCount() == 1)
        #expect(try await target.library.fetch(ClipQuery()).first?.isPinned == true)
    }

    @Test func privateClipsExcludedUnlessRequested() async throws {
        let source = try TemporaryLibrary()
        let id = try #require(source.storedID(try await source.capture("private thing")))
        try await source.library.setPrivate(id, isPrivate: true)
        let archive = source.root.appendingPathComponent("p.clipivoarchive")
        #expect(try await source.library.exportArchive(to: archive, includePrivate: false).clipsWritten == 0)
        let archive2 = source.root.appendingPathComponent("p2.clipivoarchive")
        #expect(try await source.library.exportArchive(to: archive2, includePrivate: true).clipsWritten == 1)
        let target = try TemporaryLibrary()
        _ = try await target.library.importArchive(from: archive2)
        let restored = try #require(try await target.library.fetch(ClipQuery()).first)
        #expect(restored.isPrivate)
        #expect(try await target.library.content(id: restored.id, allowPrivate: true).plainText == "private thing")
    }

    @Test func rejectsForeignArchives() async throws {
        let t = try TemporaryLibrary()
        let folder = t.root.appendingPathComponent("bogus")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"format\":\"other\"}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        await #expect(throws: LibraryError.self) { try await t.library.importArchive(from: folder) }
    }
}
