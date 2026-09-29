import Foundation
import CryptoKit

/// Content-addressed storage for large payloads. Each blob is stored once under the hex SHA-256
/// of its bytes, so identical images/files copied repeatedly consume disk space only once.
/// Blobs are immutable; garbage collection removes blobs no longer referenced by the database.
public struct BlobStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func key(for data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    public func url(for key: String) -> URL {
        precondition(key.count >= 4 && key.allSatisfy(\.isHexDigit), "invalid blob key")
        let a = key.prefix(2), b = key.dropFirst(2).prefix(2)
        return directory.appendingPathComponent(String(a), isDirectory: true)
            .appendingPathComponent(String(b), isDirectory: true)
            .appendingPathComponent(key)
    }

    /// Stores data and returns its key. Writing an existing blob is a no-op.
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let key = Self.key(for: data)
        let target = url(for: key)
        if FileManager.default.fileExists(atPath: target.path) { return key }
        try FileUtilities.writeSecure(data, to: target)
        return key
    }

    public func get(_ key: String) throws -> Data {
        try Data(contentsOf: url(for: key), options: [.mappedIfSafe])
    }

    public func exists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    public func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// All blob keys on disk (used by garbage collection and integrity checks).
    public func allKeys() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var keys: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.count == 64, name.allSatisfy(\.isHexDigit) { keys.append(name) }
        }
        return keys
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hexString }
    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }
}
