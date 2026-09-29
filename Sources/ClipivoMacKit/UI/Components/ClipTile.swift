import SwiftUI
import AppKit
import ClipivoCore

/// The leading square of a row: thumbnail for images/PDFs, swatch for colors, icon otherwise.
struct ClipTile: View {
    let clip: ClipSummary
    let size: CGFloat
    let thumbnailURL: URL?

    var body: some View {
        ZStack {
            if clip.isPrivate {
                glyph("lock.fill", tint: .secondary)
            } else if clip.kind == .color, let hex = clip.metadata.colorHex, let color = ColorParser.parse(hex) {
                RoundedRectangle(cornerRadius: Theme.tileCornerRadius, style: .continuous)
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                    .overlay(RoundedRectangle(cornerRadius: Theme.tileCornerRadius, style: .continuous).strokeBorder(Theme.hairline))
            } else if let thumbnailURL {
                ThumbnailImage(url: thumbnailURL, size: size, fallbackSymbol: Theme.symbol(for: clip.kind))
            } else if (clip.kind == .file || clip.kind == .folder), size > 24, let path = clip.previewText.split(separator: "\n").first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: String(path)))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.9, height: size * 0.9)
            } else {
                glyph(Theme.symbol(for: clip.kind), tint: Theme.tint(for: clip.kind))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func glyph(_ name: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: Theme.tileCornerRadius, style: .continuous)
            .fill(tint.opacity(0.12))
            .overlay(
                Image(systemName: name)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(tint)
            )
    }
}

/// Loads a cached thumbnail file off the main thread, then keeps it in `ImageCache`.
struct ThumbnailImage: View {
    let url: URL
    let size: CGFloat
    let fallbackSymbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? ImageCache.shared.cachedThumbnail(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.tileCornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.tileCornerRadius, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                RoundedRectangle(cornerRadius: Theme.tileCornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(Image(systemName: fallbackSymbol).foregroundStyle(.secondary))
            }
        }
        .task(id: url) {
            guard ImageCache.shared.cachedThumbnail(at: url) == nil else { return }
            let path = url
            let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: path) }.value
            if let loaded {
                ImageCache.shared.store(loaded, for: url)
                image = loaded
            }
        }
    }
}
