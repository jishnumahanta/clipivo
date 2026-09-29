import SwiftUI
import AppKit
import ClipivoCore

/// Visual constants. Clipivo leans on system colors and materials so it matches the user's
/// appearance, accent color and accessibility settings (increased contrast, reduced transparency).
enum Theme {
    static let panelCornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 7
    static let tileCornerRadius: CGFloat = 6
    static let sidebarWidth: CGFloat = 176
    static let hairline = Color.primary.opacity(0.08)

    static func rowHeight(_ density: ListDensity) -> CGFloat { density == .compact ? 30 : 54 }
    static func tileSize(_ density: ListDensity) -> CGFloat { density == .compact ? 20 : 38 }

    /// Per-kind tint for the leading glyph tile. Muted so the list stays calm.
    /// Per-kind tint, shared with the website's palette (website/app/globals.css `--color-kind-*`).
    static func tint(for kind: ClipKind) -> Color {
        switch kind {
        case .url: return Color(hex: 0x2E7BF6)
        case .code: return Color(hex: 0x7C3AED)
        case .image: return Color(hex: 0x0EA5E9)
        case .screenshot: return Color(hex: 0x0891B2)
        case .file, .folder: return Color(hex: 0xD97706)
        case .pdf: return Color(hex: 0xE5484D)
        case .color: return Color(hex: 0xDB2777)
        case .richText: return Color(hex: 0x5B5BF0)
        case .email, .phone, .address: return Color(hex: 0x0E9F9A)
        case .credential, .otp: return Color(hex: 0xCA8A04)
        default: return Color(hex: 0x64748B)
        }
    }

    static func symbol(for kind: ClipKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .url: return "link"
        case .image: return "photo"
        case .screenshot: return "camera.viewfinder"
        case .file: return "doc"
        case .folder: return "folder"
        case .pdf: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .color: return "paintpalette"
        case .email: return "envelope"
        case .phone: return "phone"
        case .address: return "mappin.and.ellipse"
        case .credential: return "key"
        case .otp: return "number"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    static func symbol(for category: ClipCategory) -> String {
        switch category {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .screenshots: return "camera.viewfinder"
        case .links: return "link"
        case .files: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .colors: return "paintpalette"
        case .pdfs: return "doc.richtext"
        }
    }

    static let spaceIcons = ["folder", "briefcase", "person", "house", "star", "heart", "bolt", "flag", "bookmark", "tag",
                             "chevron.left.forwardslash.chevron.right", "terminal", "sparkles", "brain", "paintbrush",
                             "photo", "doc.text", "cart", "graduationcap", "globe", "lightbulb", "hammer", "leaf", "music.note"]
}

/// Native vibrancy background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

enum RelativeTime {
    /// Compact timestamps: "now", "4m", "2h", "Yesterday", "Tue", "12 Mar", "12 Mar 2023".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return weekday.string(from: date) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return dayMonth.string(from: date) }
        return dayMonthYear.string(from: date)
    }

    static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f }()
    static let dayMonth: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f }()
    static let dayMonthYear: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM yyyy"); return f }()
    static let full: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
}

extension ByteCountFormatter {
    static func file(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

extension ClipSummary {
    /// Secondary line shown under the title.
    var subtitle: String {
        if isPrivate { return metadata.sensitiveKinds.flatMap { $0.first }.flatMap { SensitiveContentDetector.Finding(rawValue: $0)?.displayName } ?? "Hidden until unlocked" }
        switch kind {
        case .image, .screenshot:
            // Dimensions are already in the title; show what the image says instead.
            let ocrLine = previewText.firstNonEmptyLineValue
            if !ocrLine.isEmpty { return "Text in image: “\(ocrLine)”" }
            return ByteCountFormatter.file(byteSize)
        case .file, .folder:
            return previewText.split(separator: "\n").first.map { ($0 as NSString).deletingLastPathComponent }.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        case .url:
            if let title = metadata.urlTitle, title != displayTitle { return title }
            return previewText.firstNonEmptyLineValue
        case .color:
            return ColorParser.parse(metadata.colorHex ?? "")?.rgbString ?? ""
        case .pdf:
            return ByteCountFormatter.file(byteSize)
        case .code:
            let lines = previewText.split(separator: "\n", omittingEmptySubsequences: false)
            let language = metadata.codeLanguage.map(CodeDetector.displayName) ?? "Code"
            return "\(language) · \(lines.count) line\(lines.count == 1 ? "" : "s")"
        default:
            // Continue the text after the title line.
            if title != nil { return previewText.firstNonEmptyLineValue }
            let lines = previewText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.dropFirst().first ?? (textLength > 120 ? "\(textLength.formatted()) characters" : "")
        }
    }

    var accessibilityDescription: String {
        var parts = [kind.displayName, displayTitle]
        if isPinned { parts.append("pinned") }
        if let app = sourceApp?.name { parts.append("from \(app)") }
        parts.append(RelativeTime.full.string(from: lastUsedAt))
        return parts.joined(separator: ", ")
    }
}

extension String {
    var firstNonEmptyLineValue: String {
        for line in split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
        }
        return ""
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// A small keyboard key, used for shortcut hints (⌘1, ↩, ⇧⌘V …).
struct KeyCap: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
            .accessibilityHidden(true)
    }
}
