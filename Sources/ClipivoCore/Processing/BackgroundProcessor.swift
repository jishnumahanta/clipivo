import Foundation

/// Platform text recognition (Vision on Apple platforms, Windows.Media.Ocr, ML Kit on Android…).
public protocol TextRecognizer: Sendable {
    func recognizeText(in imageData: Data) async throws -> String
}

/// Platform thumbnail rendering. Must produce PNG data no larger than `maxPixelSize` on its long edge.
public protocol ThumbnailRenderer: Sendable {
    func thumbnail(for data: Data, type: String, maxPixelSize: Int) async -> (png: Data, originalSize: (Int, Int)?)?
}

/// Runs OCR and thumbnail generation off the main thread. Work is persisted as state on each clip
/// (`ocr_state`, `thumbnail_key`), so anything interrupted by quitting resumes at next launch.
public actor BackgroundProcessor {
    private let library: ClipLibrary
    private let recognizer: TextRecognizer?
    private let renderer: ThumbnailRenderer?
    private var isRunning = false
    private var needsAnotherPass = false
    public var ocrEnabled = true

    public static let thumbnailPixelSize = 560

    public init(library: ClipLibrary, recognizer: TextRecognizer?, renderer: ThumbnailRenderer?) {
        self.library = library
        self.recognizer = recognizer
        self.renderer = renderer
    }

    public func setOCREnabled(_ enabled: Bool) {
        ocrEnabled = enabled
    }

    /// Schedules a processing pass. Coalesces bursts of calls into at most one extra pass.
    public nonisolated func schedule() {
        Task(priority: .utility) { await self.run() }
    }

    /// Regenerates thumbnails once when the target size changes between versions.
    public func refreshThumbnailsIfSizeChanged() async {
        let key = "thumbnail_pixel_size"
        guard (try? await library.metaValue(key)) != String(Self.thumbnailPixelSize) else { return }
        try? await library.removeThumbnailCache()
        try? await library.setMetaValue(key, String(Self.thumbnailPixelSize))
    }

    public func run() async {
        if isRunning { needsAnotherPass = true; return }
        isRunning = true
        defer { isRunning = false }
        repeat {
            needsAnotherPass = false
            await processThumbnails()
            await processOCR()
        } while needsAnotherPass
    }

    private func processThumbnails() async {
        guard let renderer else { return }
        while let ids = try? await library.clipsNeedingThumbnails(limit: 20), !ids.isEmpty {
            for id in ids {
                guard let payload = try? await library.imagePayload(id),
                      let result = await renderer.thumbnail(for: payload.data, type: payload.type, maxPixelSize: Self.thumbnailPixelSize) else {
                    try? await library.markThumbnailUnavailable(id)
                    continue
                }
                let key = Hashing.sha256Hex(payload.data)
                do {
                    try FileUtilities.writeSecure(result.png, to: library.thumbnailURL(for: key))
                    try await library.setThumbnail(id, key: key, imageSize: result.originalSize)
                } catch {
                    try? await library.markThumbnailUnavailable(id)
                }
            }
            await Task.yield()
        }
    }

    private func processOCR() async {
        guard let recognizer, ocrEnabled else { return }
        while let ids = try? await library.clipsPendingOCR(limit: 10), !ids.isEmpty {
            for id in ids {
                guard let payload = try? await library.imagePayload(id), RepresentationType.imageTypes.contains(payload.type) else {
                    try? await library.setOCRResult(id, text: nil, failed: true)
                    continue
                }
                do {
                    let text = try await recognizer.recognizeText(in: payload.data)
                    try await library.setOCRResult(id, text: text)
                } catch {
                    try? await library.setOCRResult(id, text: nil, failed: true)
                }
            }
            await Task.yield()
        }
    }

    /// Runs OCR immediately for one clip (used by "Copy Text from Image").
    public func recognizeNow(_ id: Int64, allowPrivate: Bool = false) async throws -> String {
        if let existing = try await library.ocrText(id), !existing.isEmpty { return existing }
        guard let recognizer else { throw OCRUnavailable() }
        guard let payload = try await library.imagePayload(id, allowPrivate: allowPrivate) else { throw LibraryError.notFound }
        let text = try await recognizer.recognizeText(in: payload.data)
        if !(try await library.summary(id: id)?.isPrivate ?? false) {
            try await library.setOCRResult(id, text: text)
        }
        return text
    }

    public struct OCRUnavailable: LocalizedError {
        public var errorDescription: String? { "Text recognition is not available on this device." }
    }
}
