import AppKit
import UniformTypeIdentifiers
import ClipivoCore

/// Content-type-specific actions that need AppKit (opening, revealing, exporting).
@MainActor
enum ClipActions {
    static func fileURLs(_ content: ClipContent) -> [URL] {
        content.representations.filter { $0.type == RepresentationType.fileURL }
            .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
    }

    static func link(_ content: ClipContent) -> URL? {
        if let data = content.data(for: RepresentationType.url), let s = String(data: data, encoding: .utf8), let url = URL(string: s) { return url }
        if let text = content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.contains(where: \.isWhitespace),
           let url = URL(string: text), url.scheme != nil { return url }
        return nil
    }

    static func open(_ content: ClipContent) {
        switch content.summary.kind {
        case .file, .folder:
            fileURLs(content).filter { FileManager.default.fileExists(atPath: $0.path) }.forEach { NSWorkspace.shared.open($0) }
        case .url, .email:
            if let url = link(content) ?? content.plainText.flatMap({ URL(string: "mailto:" + $0.replacingOccurrences(of: "mailto:", with: "")) }) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    static func revealInFinder(_ content: ClipContent) {
        let urls = fileURLs(content).filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            NSSound.beep()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Saves the clip's best representation to a user-chosen file. Keeps original bytes (no re-encoding).
    static func export(_ content: ClipContent) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let base = (content.summary.title ?? content.summary.autoTitle ?? content.summary.kind.displayName)
            .replacingOccurrences(of: "/", with: "-").prefix(60)
        var data: Data?
        var type: UTType = .plainText

        if let image = RepresentationType.imageTypes.lazy.compactMap({ t in content.data(for: t).map { (t, $0) } }).first {
            data = image.1
            type = UTType(image.0) ?? .png
        } else if let pdf = content.data(for: RepresentationType.pdf) {
            data = pdf; type = .pdf
        } else if let rtf = content.data(for: RepresentationType.rtf) {
            data = rtf; type = .rtf
        } else if let html = content.data(for: RepresentationType.html), content.plainText == nil {
            data = html; type = .html
        } else if let text = PasteboardWriter.plainText(for: content) {
            data = Data(text.utf8)
            if content.summary.kind == .code, let ext = codeExtension(content.summary.metadata.codeLanguage), let t = UTType(filenameExtension: ext) {
                type = t
            } else {
                type = .plainText
            }
        }
        guard let data else { NSSound.beep(); return }
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = String(base) + "." + (type.preferredFilenameExtension ?? "txt")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func codeExtension(_ language: String?) -> String? {
        switch language {
        case "swift": return "swift"
        case "python": return "py"
        case "javascript": return "js"
        case "typescript": return "ts"
        case "json": return "json"
        case "html": return "html"
        case "css": return "css"
        case "sql": return "sql"
        case "bash": return "sh"
        case "go": return "go"
        case "rust": return "rs"
        case "java": return "java"
        case "kotlin": return "kt"
        case "c": return "c"
        case "cpp": return "cpp"
        case "csharp": return "cs"
        case "php": return "php"
        case "ruby": return "rb"
        case "yaml": return "yaml"
        default: return nil
        }
    }
}
