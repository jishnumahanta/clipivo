import Foundation

/// On-disk layout of a Clipivo library:
///
///     <root>/
///       Database/clipivo.sqlite   metadata, search index
///       Blobs/ab/cd/<sha256>      content-addressed payloads (immutable, deduplicated)
///       Private/<uuid>            encrypted payloads of private clips
///       Thumbnails/<key>.png      cached thumbnails
///       Backups/                  optional local backups
public struct StorageLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/<productName>` (or the platform equivalent).
    public static func standard(productName: String = Branding.productName) -> StorageLayout {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return StorageLayout(root: base.appendingPathComponent(productName, isDirectory: true))
    }

    public var databaseDirectory: URL { root.appendingPathComponent("Database", isDirectory: true) }
    public var databaseFile: URL { databaseDirectory.appendingPathComponent("clipivo.sqlite") }
    public var blobsDirectory: URL { root.appendingPathComponent("Blobs", isDirectory: true) }
    public var privateDirectory: URL { root.appendingPathComponent("Private", isDirectory: true) }
    public var thumbnailsDirectory: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var backupsDirectory: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    /// Creates all directories with owner-only permissions (0700).
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, databaseDirectory, blobsDirectory, privateDirectory, thumbnailsDirectory, backupsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

/// Product identity. Kept in one place so the name can change without touching the architecture.
public enum Branding {
    public static var productName = "Clipivo"
    public static var tagline = "Your clipboard remembers."
    public static let developerName = "Jishnu Mahanta"
    public static let developerWebsite = URL(string: "https://jishnumahanta.in/go/clipivo")!
    public static let supportEmail = "jishnumahanta17@gmail.com"
    public static let copyright = "© 2026 Jishnu Mahanta. All rights reserved."
}

enum FileUtilities {
    /// Writes data atomically with 0600 permissions.
    static func writeSecure(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
