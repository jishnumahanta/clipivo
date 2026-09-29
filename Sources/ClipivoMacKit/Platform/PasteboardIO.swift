import AppKit
import ImageIO
import ClipivoCore

/// Marker type Clipivo adds to everything it writes so its own writes are never re-captured.
let clipivoInternalType = NSPasteboard.PasteboardType(AppIdentity.scoped("internal"))

/// Reads the pasteboard into a platform-neutral `ClipboardSnapshot`. Safe to call off the main thread.
public enum PasteboardReader {
    /// Non-preferred types are only read up to this count per item, to bound work for apps that
    /// publish dozens of proprietary formats.
    static let maxOtherTypesPerItem = 12

    public static func snapshot(from pasteboard: NSPasteboard, source: SourceApplication?) -> ClipboardSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        // Use the types the source actually wrote. `pasteboard.types` also lists conversions the
        // system can synthesise (e.g. TIFF from PNG), which would hide what was really copied.
        let declared = Set(items.flatMap { $0.types.map(\.rawValue) })
        if declared.contains(clipivoInternalType.rawValue) { return nil }

        var result: [[ClipRepresentation]] = []
        for (index, item) in items.enumerated() {
            var reps: [ClipRepresentation] = []
            var otherCount = 0
            // Preferred types first so the stored order matches restore priority.
            let types = item.types.map(\.rawValue).sorted { lhs, rhs in
                (RepresentationType.preferred.firstIndex(of: lhs) ?? .max) < (RepresentationType.preferred.firstIndex(of: rhs) ?? .max)
            }
            for type in types where !RepresentationType.isIgnored(type) {
                let preferred = RepresentationType.preferred.contains(type)
                if !preferred {
                    otherCount += 1
                    if otherCount > maxOtherTypesPerItem { continue }
                }
                // `data(forType:)` can fail for lazily provided or malformed data; skip, never crash.
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty else { continue }
                reps.append(ClipRepresentation(itemIndex: index, type: type, data: data))
            }
            if !reps.isEmpty { result.append(reps) }
        }
        guard !result.isEmpty else { return nil }

        var sourceApp = source
        if let marker = pasteboard.string(forType: NSPasteboard.PasteboardType(RepresentationType.sourceMarker)),
           !marker.isEmpty, marker != source?.bundleID {
            // nspasteboard.org source marker is more accurate than "frontmost app" when present.
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: marker).map { FileManager.default.displayName(atPath: $0.path) } ?? marker
            sourceApp = SourceApplication(bundleID: marker, name: name.replacingOccurrences(of: ".app", with: ""))
        }

        var snapshot = ClipboardSnapshot(items: result, declaredTypes: declared, sourceApp: sourceApp)
        snapshot.hints = hints(for: snapshot, pasteboard: pasteboard)
        return snapshot
    }

    static func hints(for snapshot: ClipboardSnapshot, pasteboard: NSPasteboard) -> ClipboardSnapshot.Hints {
        var hints = ClipboardSnapshot.Hints()
        if snapshot.declaredTypes.contains(RepresentationType.color),
           let color = NSColor(from: pasteboard)?.usingColorSpace(.sRGB) {
            hints.colorHex = ParsedColor(red: Double(color.redComponent), green: Double(color.greenComponent),
                                         blue: Double(color.blueComponent), alpha: Double(color.alphaComponent)).hex
        }
        if let image = snapshot.imageData, let size = imagePixelSize(image.data) {
            hints.imagePixelSize = size
        }
        var directories = Set<String>()
        for url in snapshot.fileURLs.prefix(50) {
            var isDirectory: ObjCBool = false
            // Resolve symlinks first: e.g. /Applications/Safari.app links into the system cryptex.
            let resolved = url.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let isPackage = ((try? resolved.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false)
                || NSWorkspace.shared.isFilePackage(atPath: resolved.path) || resolved.pathExtension == "app"
            if !isPackage { directories.insert(url.path) }
        }
        hints.directoryPaths = directories
        if let pdf = snapshot.first(RepresentationType.pdf), let provider = CGDataProvider(data: pdf as CFData),
           let document = CGPDFDocument(provider) {
            hints.pdfPageCount = document.numberOfPages
        }
        return hints
    }

    /// Reads image dimensions from the header only (no full decode).
    static func imagePixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

/// Writes stored clips back to the pasteboard. Main-thread only: HTML → text conversion uses WebKit.
@MainActor
public enum PasteboardWriter {
    public enum Mode { case original, plainText }

    public struct WriteResult {
        public var wroteSomething: Bool
        public var missingFiles: [String]
    }

    @discardableResult
    public static func write(_ content: ClipContent, mode: Mode, to pasteboard: NSPasteboard = .general) -> WriteResult {
        var missing: [String] = []
        switch mode {
        case .plainText:
            guard let text = plainText(for: content), !text.isEmpty else {
                return WriteResult(wroteSomething: write(content, mode: .original, to: pasteboard).wroteSomething, missingFiles: [])
            }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: clipivoInternalType)
            return WriteResult(wroteSomething: pasteboard.writeObjects([item]), missingFiles: [])

        case .original:
            var grouped: [Int: [ClipRepresentation]] = [:]
            for rep in content.representations { grouped[rep.itemIndex, default: []].append(rep) }
            var items: [NSPasteboardItem] = []
            for index in grouped.keys.sorted() {
                let item = NSPasteboardItem()
                for rep in grouped[index] ?? [] {
                    if rep.type == RepresentationType.fileURL, let path = String(data: rep.data, encoding: .utf8).flatMap(URL.init(string:))?.path,
                       !FileManager.default.fileExists(atPath: path) {
                        missing.append(path)
                    }
                    item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
                }
                item.setData(Data(), forType: clipivoInternalType)
                items.append(item)
            }
            // Clips with only derived text (e.g. imported records) still paste as text.
            if items.isEmpty, let text = plainText(for: content) {
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setData(Data(), forType: clipivoInternalType)
                items.append(item)
            }
            guard !items.isEmpty else { return WriteResult(wroteSomething: false, missingFiles: []) }
            pasteboard.clearContents()
            return WriteResult(wroteSomething: pasteboard.writeObjects(items), missingFiles: missing)
        }
    }

    /// Best plain-text form of a clip: its text, text extracted from RTF/HTML, OCR text, or file paths.
    public static func plainText(for content: ClipContent) -> String? {
        if let text = content.plainText, !text.isEmpty { return text }
        if let rtf = content.data(for: RepresentationType.rtf),
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return attributed.string
        }
        if let html = content.data(for: RepresentationType.html),
           let attributed = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                            .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            return attributed.string
        }
        if let ocr = content.ocrText, !ocr.isEmpty { return ocr }
        if let hex = content.summary.metadata.colorHex { return hex }
        return nil
    }

    public static func writeString(_ string: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(Data(), forType: clipivoInternalType)
        pasteboard.writeObjects([item])
    }
}
