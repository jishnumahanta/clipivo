import Foundation

/// Clipivo's permanent reverse-DNS identity. The bundle identifier must never change: macOS keys
/// preferences, Accessibility permission, login items and Keychain access to it. Extensions use
/// sub-identifiers (`in.jishnumahanta.clipivo.share`, `in.jishnumahanta.clipivo.helper`).
public enum AppIdentity {
    public static let bundleIdentifier = "in.jishnumahanta.clipivo"

    /// Pre-release identifiers, read once so early builds keep their settings and private-clip key.
    static let legacyBundleIdentifier = "com.clipivo.macos"
    static let legacyNamespace = "app.clipivo"

    /// `in.jishnumahanta.clipivo.<suffix>`, for queue labels, pasteboard types and Keychain services.
    static func scoped(_ suffix: String) -> String { "\(bundleIdentifier).\(suffix)" }

    /// Copies preferences saved under the pre-release bundle identifier, once. The old domain is
    /// left in place so going back to an older build still works.
    static func migrateLegacyPreferences(into defaults: UserDefaults = .standard) {
        let marker = "migratedLegacyPreferences"
        guard Bundle.main.bundleIdentifier == bundleIdentifier, !defaults.bool(forKey: marker) else { return }
        if let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
