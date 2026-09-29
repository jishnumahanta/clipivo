import AppKit
import Observation
import ClipivoCore

/// Checks Clipivo's GitHub releases for a newer version: automatically at most once a day (when
/// Settings ▸ General ▸ "Check for updates automatically" is on) or when the user asks.
///
/// Safety: it makes one unauthenticated HTTPS request for public release metadata (no clipboard
/// data, identifiers or cookies), never downloads or installs anything, and only ever opens a page
/// under the official releases URL (`UpdateCheck.isTrustedReleasePage`).
@MainActor
@Observable
public final class UpdateService {
    public enum Outcome: Equatable { case upToDate, available(AvailableUpdate), failed }

    public private(set) var available: AvailableUpdate?
    public private(set) var isChecking = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Automatic check: only when enabled, and at most once a day. Silent on failure.
    func checkIfDue() {
        guard preferences.checkForUpdates, !isChecking, UpdateCheck.isDue(lastCheck: preferences.lastUpdateCheck) else { return }
        Task { _ = await check() }
    }

    /// Asks GitHub for the latest releases and records whether a newer version exists.
    func check() async -> Outcome {
        guard !isChecking else { return available.map { .available($0) } ?? .upToDate }
        isChecking = true
        defer { isChecking = false }
        guard let data = await Self.fetchReleases() else { return .failed }
        preferences.lastUpdateCheck = Date()
        available = UpdateCheck.evaluate(releasesJSON: data, current: Self.currentVersion)
        onChange?()
        return available.map { .available($0) } ?? .upToDate
    }

    /// Opens the release page in the browser (only if it's the official releases page).
    func openReleasePage(for update: AvailableUpdate? = nil) {
        let url = (update ?? available)?.pageURL ?? UpdateCheck.releasesPage
        guard UpdateCheck.isTrustedReleasePage(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// "Check for Updates…": checks now and reports the result in an alert.
    func checkInteractively() {
        Task {
            let outcome = await check()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch outcome {
            case .available(let update):
                alert.messageText = "\(Branding.productName) \(update.version) is available"
                alert.informativeText = "You have version \(Self.currentVersion). Download the new version from GitHub, then replace \(Branding.productName) in your Applications folder. Your history and settings are kept."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { openReleasePage(for: update) }
            case .upToDate:
                alert.messageText = "\(Branding.productName) is up to date"
                alert.informativeText = "Version \(Self.currentVersion) is the latest release."
                alert.runModal()
            case .failed:
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub couldn't be reached. Check your internet connection and try again, or visit the releases page."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Releases Page")
                if alert.runModal() == .alertSecondButtonReturn { openReleasePage() }
            }
        }
    }

    /// One request: public release metadata over HTTPS. No cookies, cache or credentials.
    private nonisolated static func fetchReleases() async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: UpdateCheck.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clipivo", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "api.github.com", data.count < 2_000_000 else { return nil }
        return data
    }
}
