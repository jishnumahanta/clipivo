import Foundation

/// A dotted version like `0.9.1`, optionally with a pre-release suffix (`0.9.1-beta`, `v1.0`).
/// Only the numeric part is compared, so `0.9.1-beta` and `0.9.1` are the same release.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let label: String

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let numeric = text.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        var values = parts.compactMap { $0 }
        while values.count > 1, values.last == 0 { values.removeLast() }
        components = values
        label = text
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public var description: String { label }
}

/// A newer release found on GitHub.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let title: String
    /// Always a page under the official releases URL (see `UpdateCheck.isTrustedReleasePage`).
    public let pageURL: URL
}

/// Decides whether GitHub's release list contains a newer Clipivo. Pure logic, no networking, so
/// it's fully testable; the macOS app does the request and calls `evaluate`.
public enum UpdateCheck {
    public static let owner = "jishnumahanta"
    public static let repository = "clipivo"

    /// The one request the checker makes: public release metadata, no authentication.
    public static var releasesAPI: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=10")!
    }

    public static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let html_url: String
        let draft: Bool
    }

    /// Returns the newest published release if it's newer than `current`. Anything malformed, or a
    /// link outside the official releases page, is ignored rather than trusted.
    public static func evaluate(releasesJSON data: Data, current: String) -> AvailableUpdate? {
        guard let currentVersion = AppVersion(current),
              let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        let candidates = releases.compactMap { release -> (AppVersion, Release)? in
            guard !release.draft, let version = AppVersion(release.tag_name) else { return nil }
            return (version, release)
        }
        guard let (version, release) = candidates.max(by: { $0.0 < $1.0 }), currentVersion < version,
              let url = URL(string: release.html_url), isTrustedReleasePage(url) else { return nil }
        let title = (release.name?.isEmpty == false ? release.name! : "\(version)")
        return AvailableUpdate(version: version.label, title: String(title.prefix(80)), pageURL: url)
    }

    /// Only `https://github.com/<owner>/<repository>/releases…` may ever be opened.
    public static func isTrustedReleasePage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.port == nil else { return false }
        let path = url.path.lowercased()
        let base = "/\(owner)/\(repository)/releases".lowercased()
        return path == base || path.hasPrefix(base + "/")
    }

    /// Whether an automatic check is due (at most once a day).
    public static func isDue(lastCheck: Date?, now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }
}
