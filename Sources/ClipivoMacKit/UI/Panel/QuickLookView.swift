import SwiftUI
import AppKit
import PDFKit
import ClipivoCore

/// Enlarged preview of the selected clip (Space / ⌘Y). Follows the selection while open.
struct QuickLookView: View {
    let clipID: Int64
    let app: AppModel
    let onClose: () -> Void
    @State private var content: ClipContent?
    @State private var error: String?
    @State private var loadedID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let content, loadedID == clipID {
                    PreviewBody(content: content, app: app)
                } else if let error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let content, loadedID == clipID {
                Divider()
                details(content.summary)
            }
        }
        .background(VisualEffectBackground(material: .popover, blending: .withinWindow))
        .task(id: clipID) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let summary = content?.summary, loadedID == clipID {
                Image(systemName: Theme.symbol(for: summary.kind)).foregroundStyle(Theme.tint(for: summary.kind))
                Text(summary.displayTitle).font(.headline).lineLimit(1)
            }
            Spacer()
            Text("Space or Esc to close").font(.caption).foregroundStyle(.tertiary)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func details(_ s: ClipSummary) -> some View {
        HStack(spacing: 14) {
            Label(s.kind.displayName, systemImage: Theme.symbol(for: s.kind))
            if let app = s.sourceApp { Label(app.name, systemImage: "app") }
            Label(RelativeTime.full.string(from: s.createdAt), systemImage: "clock")
            if s.useCount > 0 { Label("Used \(s.useCount)×", systemImage: "arrow.uturn.backward") }
            Label(ByteCountFormatter.file(s.byteSize), systemImage: "internaldrive")
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func load() async {
        error = nil
        let id = clipID
        guard let summary = try? await app.library.summary(id: id) else { error = "This clip no longer exists."; return }
        if summary.isPrivate && !app.lock.isPrivateUnlocked {
            guard await app.lock.authenticate(reason: "preview a private clip") else { error = "Private clip — unlock to preview."; return }
        }
        do {
            let loaded = try await app.library.content(id: id, allowPrivate: true)
            guard id == clipID else { return }
            content = loaded
            loadedID = id
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PreviewBody: View {
    let content: ClipContent
    let app: AppModel

    var body: some View {
        let s = content.summary
        switch s.kind {
        case .image, .screenshot:
            ImagePreview(content: content, app: app)
        case .pdf:
            if let data = content.data(for: RepresentationType.pdf) { PDFPreview(data: data) } else { TextPreview(text: content.plainText ?? "") }
        case .color:
            ColorPreview(hex: s.metadata.colorHex ?? "", app: app)
        case .file, .folder:
            FilesPreview(content: content)
        case .code:
            AttributedTextPreview(text: SyntaxHighlighter.highlight(content.plainText ?? s.previewText, language: s.metadata.codeLanguage, fontSize: 12.5))
        case .richText:
            if let attributed = richText(content) { AttributedTextPreview(text: attributed) } else { TextPreview(text: content.plainText ?? "") }
        case .url:
            VStack(alignment: .leading, spacing: 10) {
                if let title = s.metadata.urlTitle { Text(title).font(.title3.weight(.semibold)) }
                Text(content.plainText ?? s.previewText).font(.body.monospaced()).textSelection(.enabled)
                if let host = s.metadata.urlHost { Label(host, systemImage: "globe").foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            TextPreview(text: content.plainText ?? s.previewText)
        }
    }

    private func richText(_ content: ClipContent) -> NSAttributedString? {
        if let rtf = content.data(for: RepresentationType.rtf) {
            return try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        if let rtfd = content.data(for: RepresentationType.rtfd) {
            return try? NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        }
        if let html = content.data(for: RepresentationType.html), html.count < 2_000_000 {
            return try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                  .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
        return nil
    }
}

private struct TextPreview: View {
    let text: String
    var body: some View {
        AttributedTextPreview(text: NSAttributedString(string: String(text.prefix(500_000)), attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ]))
    }
}

/// Read-only, selectable NSTextView. Efficient for large text (TextKit lays out lazily).
private struct AttributedTextPreview: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 14, height: 12)
            textView.setAccessibilityLabel("Clip text")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.textStorage?.isEqual(to: text) != true {
            textView.textStorage?.setAttributedString(text)
            textView.scroll(.zero)
        }
    }
}

private struct ImagePreview: View {
    let content: ClipContent
    let app: AppModel
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        .accessibilityLabel(content.summary.displayTitle)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let text = content.ocrText, !text.isEmpty {
                Divider()
                HStack(alignment: .top) {
                    ScrollView {
                        Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    Button("Copy Text") { app.copyText(text, message: "Copied text from image") }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .task(id: content.summary.id) {
            let data = RepresentationType.imageTypes.lazy.compactMap { content.data(for: $0) }.first
            guard let data else { return }
            image = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data { view.document = PDFDocument(data: data) }
    }
}

private struct ColorPreview: View {
    let hex: String
    let app: AppModel

    var body: some View {
        if let color = ColorParser.parse(hex) {
            HStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                    .frame(width: 180, height: 180)
                    .accessibilityLabel("Color swatch \(color.hex)")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([color.hex, color.rgbString, color.hslString], id: \.self) { value in
                        HStack {
                            Text(value).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            Button { app.copyText(value) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy \(value)")
                                .accessibilityLabel("Copy \(value)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FilesPreview: View {
    let content: ClipContent

    var body: some View {
        let urls = ClipActions.fileURLs(content)
        List(urls, id: \.self) { url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.body.weight(.medium))
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if exists {
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        Text(ByteCountFormatter.file(Int64(size))).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                } else {
                    Label("Missing", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollContentBackground(.hidden)
    }
}
