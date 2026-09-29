import AppKit
import ServiceManagement
import ClipivoCore

public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers/unregisters the login item. Throws a user-presentable error on failure.
    public static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    public static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}

/// Chooses which display the panel appears on.
@MainActor
public enum ScreenLocator {
    public static func screen(for preference: PanelScreen) -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens.first!
        switch preference {
        case .primary:
            return NSScreen.screens.first ?? fallback
        case .cursor:
            return screenContaining(NSEvent.mouseLocation) ?? fallback
        case .active:
            return frontmostWindowScreen() ?? screenContaining(NSEvent.mouseLocation) ?? fallback
        }
    }

    static func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Finds the screen holding the frontmost app's topmost window. Window bounds are readable
    /// without Screen Recording permission (titles are not, and are not used).
    static func frontmostWindowScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 50, bounds.height > 50 else { continue }
            // CG window coordinates are top-left based on the primary display; convert to Cocoa.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            return screenContaining(center)
        }
        return nil
    }
}

public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var url: URL
    public var id: String { bundleID }
}

public enum InstalledApplications {
    /// Scans the standard application folders (one level deep plus Utilities).
    public static func scan() -> [InstalledApplication] {
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                     URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Applications/Utilities")]
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var seen = Set<String>()
        var apps: [InstalledApplication] = []
        for root in roots {
            guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApplication(bundleID: id, name: name, url: url))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func application(at url: URL) -> InstalledApplication? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(bundleID: id, name: name, url: url)
    }
}

/// Optional, off by default: fetches `<title>` for copied links. Never blocks capture, never
/// sends clipboard content anywhere except the request to the copied URL itself.
public actor LinkTitleFetcher {
    private var inFlight = Set<Int64>()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func fetchTitle(for clipID: Int64, urlString: String, library: ClipLibrary) async {
        guard !inFlight.contains(clipID), let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        inFlight.insert(clipID)
        defer { inFlight.remove(clipID) }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html") else { return }
        let html = String(decoding: data.prefix(65_536), as: UTF8.self)
        guard let title = Self.extractTitle(html) else { return }
        try? await library.setURLTitle(clipID, title: title)
    }

    static func extractTitle(_ html: String) -> String? {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) else { return nil }
        let raw = html[open.upperBound..<close.lowerBound]
        let decoded = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return decoded.isEmpty ? nil : String(decoded.prefix(200))
    }
}

/// Zip-based export/import and scheduled local backups on top of the core archive format.
public enum ArchiveService {
    public static let fileExtension = "clipivo"

    /// Exports to a single `.clipivo` file (a zip of the archive folder).
    public static func export(library: ClipLibrary, to destination: URL, includePrivate: Bool,
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveSummary {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoExport-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent("Clipivo.clipivoarchive", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let summary = try await library.exportArchive(to: folder, includePrivate: includePrivate, generator: generatorString, progress: progress)
        try? FileManager.default.removeItem(at: destination)
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return summary
    }

    /// Imports a `.clipivo` zip or an unzipped `.clipivoarchive` folder.
    public static func importArchive(library: ClipLibrary, from source: URL,
                                     progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ArchiveSummary {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return try await library.importArchive(from: source, progress: progress) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try runDitto(["-x", "-k", source.path, work.path])
        let contents = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        let folder = contents.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) } ?? work
        return try await library.importArchive(from: folder, progress: progress)
    }

    /// Creates a dated backup in the library's Backups folder and prunes old ones.
    public static func backup(library: ClipLibrary, keep: Int) async throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let dir = library.layout.backupsDirectory
        let url = dir.appendingPathComponent("\(Branding.productName) Backup \(formatter.string(from: Date())).\(fileExtension)")
        _ = try await export(library: library, to: url, includePrivate: false)
        let backups = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == fileExtension }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) } ?? []
        for old in backups.dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: old) }
        return url
    }

    static var generatorString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "\(Branding.productName) \(version) (macOS)"
    }

    static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LibraryError.invalidArchive(message.isEmpty ? "the archive could not be written" : message)
        }
    }
}

extension URL {
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }
}
