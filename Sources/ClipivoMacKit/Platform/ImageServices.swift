import AppKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision
import ClipivoCore

/// On-device OCR with Apple's Vision framework. Nothing leaves the Mac.
public struct VisionTextRecognizer: TextRecognizer {
    private static let queue = DispatchQueue(label: AppIdentity.scoped("ocr"), qos: .utility, attributes: .concurrent)

    public init() {}

    public func recognizeText(in imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Thumbnails via ImageIO (downsampled while decoding, so huge images are never fully decoded)
/// and CoreGraphics for the first page of PDFs.
public struct ImageIOThumbnailRenderer: ThumbnailRenderer {
    public init() {}

    public func thumbnail(for data: Data, type: String, maxPixelSize: Int) async -> (png: Data, originalSize: (Int, Int)?)? {
        if type == RepresentationType.pdf { return pdfThumbnail(data, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let size = PasteboardReader.imagePixelSize(data).map { ($0.width, $0.height) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let png = Self.pngData(thumb) else { return nil }
        return (png, size)
    }

    private func pdfThumbnail(_ data: Data, maxPixelSize: Int) -> (png: Data, originalSize: (Int, Int)?)? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(box.width, box.height)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage(), let png = Self.pngData(image) else { return nil }
        return (png, (Int(box.width), Int(box.height)))
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Small in-memory caches used by list rows so scrolling never decodes images repeatedly.
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()
    private let thumbnails = NSCache<NSString, NSImage>()
    private let appIcons = NSCache<NSString, NSImage>()

    private init() {
        thumbnails.countLimit = 400
        appIcons.countLimit = 200
    }

    public func thumbnail(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    public func cachedThumbnail(at url: URL) -> NSImage? { thumbnails.object(forKey: url.path as NSString) }

    public func store(_ image: NSImage, for url: URL) { thumbnails.setObject(image, forKey: url.path as NSString) }

    public func appIcon(bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = appIcons.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        appIcons.setObject(icon, forKey: key)
        return icon
    }

    public func removeAll() {
        thumbnails.removeAllObjects()
    }
}
