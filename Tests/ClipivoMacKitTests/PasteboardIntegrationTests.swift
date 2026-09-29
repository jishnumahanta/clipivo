import AppKit
import Testing
import Carbon.HIToolbox
@testable import ClipivoMacKit
@testable import ClipivoCore

/// Integration tests against real `NSPasteboard` instances. Each test uses a uniquely named
/// pasteboard, so the user's general clipboard is never read or modified.
@Suite("Pasteboard integration", .serialized)
@MainActor
struct PasteboardIntegrationTests {
    func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("in.jishnumahanta.clipivo.tests.\(UUID().uuidString)"))
    }

    func tempLibrary() throws -> (ClipLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoMacTests-\(UUID().uuidString)")
        return (try ClipLibrary(layout: StorageLayout(root: root), cipher: AESGCMCipher(keyData: AESGCMCipher.generateKeyData())), root)
    }

    @Test func readsRichTextWithAllRepresentations() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("Hello bold world", forType: .string)
        item.setData(Data("{\\rtf1\\ansi Hello {\\b bold} world}".utf8), forType: .rtf)
        item.setString("<p>Hello <b>bold</b> world</p>", forType: .html)
        pb.writeObjects([item])

        let snapshot = try #require(PasteboardReader.snapshot(from: pb, source: SourceApplication(bundleID: "com.apple.TextEdit", name: "TextEdit")))
        let types = Set(snapshot.allRepresentations.map(\.type))
        #expect(types.isSuperset(of: [RepresentationType.plainText, RepresentationType.rtf, RepresentationType.html]))
        #expect(ContentClassifier.classify(snapshot).kind == .richText)
    }

    @Test func ownWritesAreNotReCaptured() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        PasteboardWriter.writeString("from clipivo", to: pb)
        #expect(PasteboardReader.snapshot(from: pb, source: nil) == nil)
    }

    @Test func imageHintsAndMultipleFiles() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let png = rep.representation(using: .png, properties: [:])!
        pb.clearContents()
        pb.setData(png, forType: .png)
        let snapshot = try #require(PasteboardReader.snapshot(from: pb, source: nil))
        #expect(snapshot.hints.imagePixelSize?.width == rep.pixelsWide)
        #expect(ContentClassifier.classify(snapshot).kind == .screenshot) // PNG-only, like ⌃⇧⌘4

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])
        let files = try #require(PasteboardReader.snapshot(from: pb, source: nil))
        #expect(files.fileURLs.count == 2)
        #expect(ContentClassifier.classify(files).kind == .file)

        pb.clearContents()
        pb.writeObjects([dir as NSURL])
        let folder = try #require(PasteboardReader.snapshot(from: pb, source: nil))
        #expect(ContentClassifier.classify(folder).kind == .folder)
    }

    @Test func nativeColorIsDecoded() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)])
        let snapshot = try #require(PasteboardReader.snapshot(from: pb, source: nil))
        #expect(snapshot.hints.colorHex == "#FF0000")
        #expect(ContentClassifier.classify(snapshot).kind == .color)
    }

    /// Full round trip: capture → store → restore → the pasteboard holds the original formats.
    @Test func captureStoreRestoreRoundTrip() async throws {
        let (library, root) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = makePasteboard(), target = makePasteboard()
        defer { source.releaseGlobally(); target.releaseGlobally() }
        let rtf = Data("{\\rtf1\\ansi Styled {\\i text}}".utf8)
        source.clearContents()
        let item = NSPasteboardItem()
        item.setString("Styled text", forType: .string)
        item.setData(rtf, forType: .rtf)
        source.writeObjects([item])

        let snapshot = try #require(PasteboardReader.snapshot(from: source, source: nil))
        var policy = CapturePolicy()
        policy.sensitivePolicy = .save
        guard case .stored(let result, _) = try await CaptureProcessor(library: library).process(snapshot, policy: policy) else {
            Issue.record("not stored"); return
        }
        let content = try await library.content(id: result.clipID)

        PasteboardWriter.write(content, mode: .original, to: target)
        #expect(target.data(forType: .rtf) == rtf)
        #expect(target.string(forType: .string) == "Styled text")

        PasteboardWriter.write(content, mode: .plainText, to: target)
        #expect(target.string(forType: .string) == "Styled text")
        #expect(target.data(forType: .rtf) == nil) // formatting stripped
    }

    @Test func plainTextDerivedFromRTFOnlyAndOCR() throws {
        let summary = ClipSummary(id: 1, uuid: UUID(), kind: .richText, title: nil, autoTitle: nil, previewText: "", textLength: 0,
                                  sourceApp: nil, createdAt: Date(), lastUsedAt: Date(), useCount: 0, isPinned: false, isPrivate: false,
                                  sensitivity: .none, byteSize: 0, thumbnailKey: nil, ocrState: .notApplicable, hasOCRText: false, metadata: .empty)
        let rtfOnly = ClipContent(summary: summary, representations: [ClipRepresentation(type: RepresentationType.rtf, data: Data("{\\rtf1\\ansi Only rich}".utf8))],
                                  plainText: nil, ocrText: nil)
        #expect(PasteboardWriter.plainText(for: rtfOnly) == "Only rich")
        let image = ClipContent(summary: summary, representations: [ClipRepresentation(type: RepresentationType.png, data: Data([0]))],
                                plainText: nil, ocrText: "Words in picture")
        #expect(PasteboardWriter.plainText(for: image) == "Words in picture")
    }

    @Test func missingFilesAreReported() throws {
        let target = makePasteboard()
        defer { target.releaseGlobally() }
        let summary = ClipSummary(id: 1, uuid: UUID(), kind: .file, title: nil, autoTitle: nil, previewText: "", textLength: 0,
                                  sourceApp: nil, createdAt: Date(), lastUsedAt: Date(), useCount: 0, isPinned: false, isPrivate: false,
                                  sensitivity: .none, byteSize: 0, thumbnailKey: nil, ocrState: .notApplicable, hasOCRText: false, metadata: .empty)
        let content = ClipContent(summary: summary, representations: [
            ClipRepresentation(type: RepresentationType.fileURL, data: Data("file:///nonexistent/\(UUID().uuidString).txt".utf8)),
        ], plainText: nil, ocrText: nil)
        let result = PasteboardWriter.write(content, mode: .original, to: target)
        #expect(result.wroteSomething)
        #expect(result.missingFiles.count == 1)
    }

    /// The monitor polls a pasteboard, applies the ignore list before reading, and delivers snapshots.
    @Test func monitorDeliversChangesAndHonorsPause() async throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pb)
        let received = LockedBox<[String]>([])
        let skipped = LockedBox<[SkipReason]>([])
        monitor.onSnapshot = { snapshot, _ in received.mutate { $0.append(snapshot.plainText ?? "") } }
        monitor.onSkip = { reason in skipped.mutate { $0.append(reason) } }
        monitor.start(interval: 0.1)
        defer { monitor.stop() }

        pb.clearContents(); pb.setString("first", forType: .string)
        try await waitUntil { received.value.contains("first") }

        var paused = CapturePolicy(); paused.isPaused = true
        monitor.update(policy: paused)
        pb.clearContents(); pb.setString("while paused", forType: .string)
        try await waitUntil { skipped.value.contains(.paused) }
        #expect(!received.value.contains("while paused"))

        monitor.update(policy: CapturePolicy())
        pb.clearContents(); pb.setString("resumed", forType: .string)
        try await waitUntil { received.value.contains("resumed") }

        // Clipivo's own writes are acknowledged and not delivered.
        PasteboardWriter.writeString("own write", to: pb)
        monitor.acknowledgeOwnWrite()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!received.value.contains("own write"))
    }

    @Test func keyComboDisplayAndValidation() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .shift])
        #expect(combo.displayString.hasPrefix("⇧⌘"))
        #expect(combo.isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: [.shift]).isValidGlobalShortcut)
        let data = try! JSONEncoder().encode(combo)
        #expect(try! JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }

    @Test func preferencesPersistAndDeriveSearchFields() {
        let suite = "in.jishnumahanta.clipivo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.panelHotKey == KeyCombo.defaultPanel)
        #expect(prefs.sensitivePolicy == .ask)
        #expect(prefs.cleanupEnabled == false) // history is kept forever by default
        prefs.searchOCR = false
        prefs.panelHotKey = nil
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.searchOCR == false)
        #expect(reloaded.panelHotKey == nil)
        #expect(!reloaded.searchFields.contains(.ocr))
    }

    @Test func linkTitleExtraction() {
        #expect(LinkTitleFetcher.extractTitle("<html><head><title> Supabase &amp; Auth\n Docs </title></head>") == "Supabase & Auth Docs")
        #expect(LinkTitleFetcher.extractTitle("<html>no title</html>") == nil)
    }

    func waitUntil(timeout: Double = 3, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}
