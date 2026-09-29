import AppKit
import Observation
import ClipivoCore

public enum PasteBehavior: String, CaseIterable, Codable, Sendable {
    case paste, copyOnly, ask
    var displayName: String {
        switch self {
        case .paste: return "Paste into the active app"
        case .copyOnly: return "Copy to clipboard only"
        case .ask: return "Ask each time"
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark
    var displayName: String { rawValue.capitalized }
}

public enum ListDensity: String, CaseIterable, Codable, Sendable {
    case compact, comfortable
    var displayName: String { rawValue.capitalized }
}

public enum PanelPosition: String, CaseIterable, Codable, Sendable {
    case center, top, bottom, cursor, remembered
    var displayName: String {
        switch self {
        case .center: return "Center"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .cursor: return "Near the pointer"
        case .remembered: return "Last position"
        }
    }
}

public enum PanelLayout: String, CaseIterable, Codable, Sendable {
    /// Full-width strip of cards docked to a screen edge.
    case shelf
    /// Compact floating window with a vertical list.
    case list
    var displayName: String { self == .shelf ? "Card shelf" : "Floating list" }
}

public enum ShelfEdge: String, CaseIterable, Codable, Sendable {
    case bottom, top
    var displayName: String { rawValue.capitalized }
}

public enum PanelScreen: String, CaseIterable, Codable, Sendable {
    case active, cursor, primary
    var displayName: String {
        switch self {
        case .active: return "Screen with the active window"
        case .cursor: return "Screen with the pointer"
        case .primary: return "Primary display"
        }
    }
}

public enum MenuBarClickAction: String, CaseIterable, Codable, Sendable {
    case showMenu, openPanel
    var displayName: String { self == .showMenu ? "Shows the menu" : "Opens the clipboard panel" }
}

/// User preferences, persisted in `UserDefaults`. Observable so SwiftUI settings update live.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()
    @ObservationIgnored private let defaults: UserDefaults

    // General
    public var showDockIcon: Bool { didSet { save("showDockIcon", showDockIcon) } }
    public var menuBarClickAction: MenuBarClickAction { didSet { save("menuBarClickAction", menuBarClickAction.rawValue) } }
    /// Full-color logo in the menu bar (default) or a monochrome template glyph.
    public var colorMenuBarIcon: Bool { didSet { save("colorMenuBarIcon", colorMenuBarIcon) } }
    public var hasCompletedOnboarding: Bool { didSet { save("hasCompletedOnboarding", hasCompletedOnboarding) } }

    // Clipboard
    public var monitoringPaused: Bool { didSet { save("monitoringPaused", monitoringPaused) } }
    public var duplicatePolicy: DuplicatePolicy { didSet { save("duplicatePolicy", duplicatePolicy.rawValue) } }
    public var pasteBehavior: PasteBehavior { didSet { save("pasteBehavior", pasteBehavior.rawValue) } }
    public var alwaysPastePlainText: Bool { didSet { save("alwaysPastePlainText", alwaysPastePlainText) } }
    public var singleClickPastes: Bool { didSet { save("singleClickPastes", singleClickPastes) } }
    public var closeAfterCopy: Bool { didSet { save("closeAfterCopy", closeAfterCopy) } }
    public var moveUsedToTop: Bool { didSet { save("moveUsedToTop", moveUsedToTop) } }
    public var pollInterval: Double { didSet { save("pollInterval", pollInterval) } }
    public var maxItemSizeMB: Int { didSet { save("maxItemSizeMB", maxItemSizeMB) } }

    // History
    public var cleanupEnabled: Bool { didSet { save("cleanupEnabled", cleanupEnabled) } }
    public var cleanupAgeDays: Int { didSet { save("cleanupAgeDays", cleanupAgeDays) } }
    public var cleanupImagesOnly: Bool { didSet { save("cleanupImagesOnly", cleanupImagesOnly) } }

    // Privacy
    public var concealedPolicy: SensitiveContentPolicy { didSet { save("concealedPolicy", concealedPolicy.rawValue) } }
    public var sensitivePolicy: SensitiveContentPolicy { didSet { save("sensitivePolicy", sensitivePolicy.rawValue) } }
    public var oneTimeCodePolicy: SensitiveContentPolicy { didSet { save("oneTimeCodePolicy", oneTimeCodePolicy.rawValue) } }
    public var honorTransientMarker: Bool { didSet { save("honorTransientMarker", honorTransientMarker) } }
    public var lockEnabled: Bool { didSet { save("lockEnabled", lockEnabled) } }
    public var lockAfterMinutes: Int { didSet { save("lockAfterMinutes", lockAfterMinutes) } }
    public var lockOnSleep: Bool { didSet { save("lockOnSleep", lockOnSleep) } }

    // Search
    public var searchTitles: Bool { didSet { save("searchTitles", searchTitles) } }
    public var searchOCR: Bool { didSet { save("searchOCR", searchOCR) } }
    public var searchFileNames: Bool { didSet { save("searchFileNames", searchFileNames) } }
    public var searchAppNames: Bool { didSet { save("searchAppNames", searchAppNames) } }
    public var ocrEnabled: Bool { didSet { save("ocrEnabled", ocrEnabled) } }
    public var fetchLinkTitles: Bool { didSet { save("fetchLinkTitles", fetchLinkTitles) } }

    // Appearance
    public var appearance: AppearanceMode { didSet { save("appearance", appearance.rawValue) } }
    public var density: ListDensity { didSet { save("density", density.rawValue) } }
    public var showSidebar: Bool { didSet { save("showSidebar", showSidebar) } }
    public var showSourceIcons: Bool { didSet { save("showSourceIcons", showSourceIcons) } }

    // Keyboard
    public var panelHotKey: KeyCombo? { didSet { saveCodable("panelHotKey", panelHotKey) } }
    public var plainTextHotKey: KeyCombo? { didSet { saveCodable("plainTextHotKey", plainTextHotKey) } }
    public var spaceOpensQuickLook: Bool { didSet { save("spaceOpensQuickLook", spaceOpensQuickLook) } }

    // Window
    public var panelLayout: PanelLayout { didSet { save("panelLayout", panelLayout.rawValue) } }
    public var shelfEdge: ShelfEdge { didSet { save("shelfEdge", shelfEdge.rawValue) } }
    public var shelfHeight: Double { didSet { save("shelfHeight", shelfHeight) } }
    public var panelPosition: PanelPosition { didSet { save("panelPosition", panelPosition.rawValue) } }
    public var panelScreen: PanelScreen { didSet { save("panelScreen", panelScreen.rawValue) } }
    public var panelFrame: String? { didSet { save("panelFrame", panelFrame) } }

    // Backups
    public var autoBackupEnabled: Bool { didSet { save("autoBackupEnabled", autoBackupEnabled) } }
    public var autoBackupIntervalDays: Int { didSet { save("autoBackupIntervalDays", autoBackupIntervalDays) } }
    public var backupsToKeep: Int { didSet { save("backupsToKeep", backupsToKeep) } }
    public var lastBackupDate: Date? { didSet { save("lastBackupDate", lastBackupDate) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        func enumValue<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func codable<T: Decodable>(_ key: String, _ fallback: T?) -> T? {
            guard let data = defaults.data(forKey: key) else { return fallback }
            if data.isEmpty { return nil } // explicitly cleared
            return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        }

        showDockIcon = bool("showDockIcon", false)
        menuBarClickAction = enumValue("menuBarClickAction", MenuBarClickAction.showMenu)
        colorMenuBarIcon = bool("colorMenuBarIcon", true)
        hasCompletedOnboarding = bool("hasCompletedOnboarding", false)

        monitoringPaused = bool("monitoringPaused", false)
        duplicatePolicy = enumValue("duplicatePolicy", DuplicatePolicy.moveToTop)
        pasteBehavior = enumValue("pasteBehavior", PasteBehavior.paste)
        alwaysPastePlainText = bool("alwaysPastePlainText", false)
        closeAfterCopy = bool("closeAfterCopy", true)
        singleClickPastes = bool("singleClickPastes", true)
        moveUsedToTop = bool("moveUsedToTop", true)
        pollInterval = defaults.object(forKey: "pollInterval") as? Double ?? 0.3
        maxItemSizeMB = int("maxItemSizeMB", 200)

        cleanupEnabled = bool("cleanupEnabled", false)
        cleanupAgeDays = int("cleanupAgeDays", 365)
        cleanupImagesOnly = bool("cleanupImagesOnly", true)

        concealedPolicy = enumValue("concealedPolicy", SensitiveContentPolicy.discard)
        sensitivePolicy = enumValue("sensitivePolicy", SensitiveContentPolicy.ask)
        oneTimeCodePolicy = enumValue("oneTimeCodePolicy", SensitiveContentPolicy.discard)
        honorTransientMarker = bool("honorTransientMarker", true)
        lockEnabled = bool("lockEnabled", false)
        lockAfterMinutes = int("lockAfterMinutes", 15)
        lockOnSleep = bool("lockOnSleep", true)

        searchTitles = bool("searchTitles", true)
        searchOCR = bool("searchOCR", true)
        searchFileNames = bool("searchFileNames", true)
        searchAppNames = bool("searchAppNames", true)
        ocrEnabled = bool("ocrEnabled", true)
        fetchLinkTitles = bool("fetchLinkTitles", false)

        appearance = enumValue("appearance", AppearanceMode.system)
        density = enumValue("density", ListDensity.comfortable)
        showSidebar = bool("showSidebar", true)
        showSourceIcons = bool("showSourceIcons", true)

        panelHotKey = codable("panelHotKey", KeyCombo.defaultPanel)
        plainTextHotKey = codable("plainTextHotKey", nil)
        spaceOpensQuickLook = bool("spaceOpensQuickLook", true)

        panelLayout = enumValue("panelLayout", PanelLayout.shelf)
        shelfEdge = enumValue("shelfEdge", ShelfEdge.bottom)
        shelfHeight = defaults.object(forKey: "shelfHeight") as? Double ?? 300
        panelPosition = enumValue("panelPosition", PanelPosition.center)
        panelScreen = enumValue("panelScreen", PanelScreen.active)
        panelFrame = defaults.string(forKey: "panelFrame")

        autoBackupEnabled = bool("autoBackupEnabled", false)
        autoBackupIntervalDays = int("autoBackupIntervalDays", 7)
        backupsToKeep = int("backupsToKeep", 3)
        lastBackupDate = defaults.object(forKey: "lastBackupDate") as? Date
    }

    private func save(_ key: String, _ value: Any?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func saveCodable<T: Encodable>(_ key: String, _ value: T?) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.set(Data(), forKey: key) }
    }

    /// Fields searched by free text, derived from the Search settings.
    public var searchFields: SearchFields {
        var fields: SearchFields = [.content, .urls, .tags]
        if searchTitles { fields.insert(.titles) }
        if searchOCR { fields.insert(.ocr) }
        if searchFileNames { fields.insert(.fileNames) }
        if searchAppNames { fields.insert(.appNames) }
        return fields
    }

    public func capturePolicy(ignored: Set<String>, privateStorageAvailable: Bool) -> CapturePolicy {
        var policy = CapturePolicy()
        policy.isPaused = monitoringPaused
        policy.ignoredBundleIDs = ignored
        policy.concealedPolicy = concealedPolicy
        policy.sensitivePolicy = sensitivePolicy
        policy.oneTimeCodePolicy = oneTimeCodePolicy
        policy.honorTransientMarker = honorTransientMarker
        policy.duplicatePolicy = duplicatePolicy
        policy.maxRepresentationBytes = maxItemSizeMB > 0 ? maxItemSizeMB * 1024 * 1024 : nil
        policy.privateStorageAvailable = privateStorageAvailable
        return policy
    }

    /// Restores every preference to its default (used by Settings ▸ Advanced).
    public func resetToDefaults() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        defaults.removePersistentDomain(forName: domain)
    }
}
