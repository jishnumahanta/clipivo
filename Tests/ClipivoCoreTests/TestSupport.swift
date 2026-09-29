import Foundation
@testable import ClipivoCore

/// A throwaway library in a unique temporary directory.
final class TemporaryLibrary {
    let root: URL
    let library: ClipLibrary
    let processor: CaptureProcessor

    init(cipher: ContentCipher? = AESGCMCipher(keyData: AESGCMCipher.generateKeyData())) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipivoTests-\(UUID().uuidString)", isDirectory: true)
        library = try ClipLibrary(layout: StorageLayout(root: root), cipher: cipher)
        processor = CaptureProcessor(library: library)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Captures text as if it had been copied from `app`.
    @discardableResult
    func capture(_ text: String, app: String = "com.test.editor", at date: Date = Date(), policy: CapturePolicy = .testDefault) async throws -> CaptureOutcome {
        var snapshot = ClipboardSnapshot.text(text, source: SourceApplication(bundleID: app, name: app.components(separatedBy: ".").last ?? app))
        snapshot.capturedAt = date
        return try await processor.process(snapshot, policy: policy)
    }

    func storedID(_ outcome: CaptureOutcome) -> Int64? {
        if case .stored(let result, _) = outcome { return result.clipID }
        return nil
    }
}

extension CapturePolicy {
    static var testDefault: CapturePolicy {
        var policy = CapturePolicy()
        policy.sensitivePolicy = .save
        policy.oneTimeCodePolicy = .save
        return policy
    }
}

/// Minimal valid 1×1 PNG.
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

func largePayload(_ size: Int, seed: UInt8 = 7) -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    var value = seed
    for i in 0..<size {
        value = value &* 31 &+ 17
        bytes[i] = value
    }
    return Data(bytes)
}

/// Fake credentials for detector tests. They are assembled at runtime so the source never contains
/// a literal that looks like a real secret (which would trip secret scanners such as GitHub push protection).
enum FakeSecrets {
    static let awsKeyID = "AK" + "IA" + "IOSFODNN7EXAMPLE"
    static let githubToken = "gh" + "p_" + "1234567890abcdefghijklmnopqrstuvwxyzAB"
    static let stripeLive = "sk" + "_live_" + "51H8abcdefghijklmnopqrstu"
    static let stripeLiveLong = stripeLive + "VWXYZ"
    static let openAIProject = "sk" + "-proj-" + "abcdefghijklmnopqrstuvwxyz123456"
    static let slackBot = "xo" + "xb-" + "1234567890-abcdefghijkl"
    static let googleAPI = "AI" + "za" + "SyA-1234567890abcdefghijklmnopqrstu"
}
