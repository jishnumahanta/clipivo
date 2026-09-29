import Foundation
import CryptoKit

/// Encrypts payloads of private clips. The storage layer depends only on this protocol so a
/// future encrypted-database or sync implementation can swap in its own key management.
public protocol ContentCipher: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

/// AES-256-GCM with a caller-supplied key. Output layout: nonce ‖ ciphertext ‖ tag (CryptoKit "combined").
public struct AESGCMCipher: ContentCipher {
    private let key: SymmetricKey

    public init(keyData: Data) {
        precondition(keyData.count == 32, "AES-256 requires a 32-byte key")
        self.key = SymmetricKey(data: keyData)
    }

    public static func generateKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    public func open(_ ciphertext: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }
}
