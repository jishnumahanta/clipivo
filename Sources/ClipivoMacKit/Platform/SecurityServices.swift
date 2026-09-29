import AppKit
import LocalAuthentication
import Observation
import Security
import ClipivoCore

/// Stores the private-clip encryption key in the login Keychain (this device only).
public enum KeychainKeyStore {
    static let service = AppIdentity.scoped("private-clips")
    static let legacyService = "\(AppIdentity.legacyNamespace).private-clips"
    static let account = "content-key-v1"

    /// Returns the existing key or creates one. `nil` if the Keychain is unavailable.
    public static func loadOrCreateKey() -> Data? {
        if let existing = read() { return existing }
        // A key from a pre-release build is copied (not moved) so its private clips stay readable.
        let key = read(service: legacyService) ?? AESGCMCipher.generateKeyData()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "\(Branding.productName) private clip key",
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return key }
        if status == errSecDuplicateItem { return read() }
        return nil
    }

    private static func read(service: String = service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
}

/// Cipher whose Keychain key is fetched on first use, not at launch. Reading the Keychain can
/// show a system permission prompt (for example after an update changes the code signature);
/// doing that lazily means launch never blocks, and users who never create private clips are
/// never asked. A failed lookup is not cached, so allowing access later works without a relaunch.
final class KeychainBackedCipher: ContentCipher, @unchecked Sendable {
    private let lock = NSLock()
    private var cipher: AESGCMCipher?

    struct KeychainUnavailable: LocalizedError {
        var errorDescription: String? { "The Keychain key for private clips isn't available. Allow \(Branding.productName) to access it when macOS asks." }
    }

    private func resolve() throws -> AESGCMCipher {
        try lock.withLock {
            if let cipher { return cipher }
            guard let key = KeychainKeyStore.loadOrCreateKey() else { throw KeychainUnavailable() }
            let resolved = AESGCMCipher(keyData: key)
            cipher = resolved
            return resolved
        }
    }

    func seal(_ plaintext: Data) throws -> Data { try resolve().seal(plaintext) }
    func open(_ ciphertext: Data) throws -> Data { try resolve().open(ciphertext) }
}

/// App lock with Touch ID / Apple Watch / login password (LocalAuthentication).
///
/// When locked, history and search results are hidden. Capture keeps running unless the user
/// pauses it separately — locking protects viewing, not recording.
@MainActor
@Observable
public final class LockService {
    public private(set) var isLocked: Bool
    /// Private clips need a recent authentication even when the app lock is off.
    public private(set) var privateUnlockedUntil: Date?
    public private(set) var lastError: String?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let preferences: Preferences

    public init(preferences: Preferences) {
        self.preferences = preferences
        self.isLocked = preferences.lockEnabled
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockForSleepIfNeeded() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockForSleepIfNeeded() }
        })
    }

    public var biometryDescription: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your password"
        }
    }

    public var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public var isPrivateUnlocked: Bool {
        guard let until = privateUnlockedUntil else { return false }
        return until > Date()
    }

    public func lock() {
        guard preferences.lockEnabled else { return }
        isLocked = true
        privateUnlockedUntil = nil
    }

    public func lockPrivateClips() { privateUnlockedUntil = nil }

    /// Records user activity; locks if the idle timeout has passed since the last activity.
    public func noteActivity() {
        if preferences.lockEnabled, preferences.lockAfterMinutes > 0,
           Date().timeIntervalSince(lastActivity) > Double(preferences.lockAfterMinutes) * 60 {
            lock()
        }
        lastActivity = Date()
    }

    public func preferencesChanged() {
        if !preferences.lockEnabled { isLocked = false }
    }

    private func lockForSleepIfNeeded() {
        if preferences.lockOnSleep { lock(); privateUnlockedUntil = nil }
    }

    /// Prompts for Touch ID or the account password. Returns true on success.
    @discardableResult
    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription ?? "Authentication is not available on this Mac."
            // Without any authentication method the lock cannot be enforced meaningfully.
            isLocked = false
            return true
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok {
                isLocked = false
                privateUnlockedUntil = Date().addingTimeInterval(Double(max(preferences.lockAfterMinutes, 5)) * 60)
                lastActivity = Date()
                lastError = nil
            }
            return ok
        } catch {
            let laError = error as? LAError
            if laError?.code != .userCancel && laError?.code != .appCancel && laError?.code != .systemCancel {
                lastError = error.localizedDescription
            }
            return false
        }
    }
}
