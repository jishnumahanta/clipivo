import AppKit
import ClipivoCore

/// Demo mode renders the real interface over a sample library, for README and website screenshots.
///
/// It is strictly opt-in: it's read only from the command-line arguments of this launch (never from
/// saved preferences), so a normal launch can't enter it. In demo mode Clipivo:
/// - opens the library at `-ClipivoDemoLibrary <dir>` instead of the user's history,
/// - never monitors the clipboard and never registers global shortcuts,
/// - uses a throwaway preferences domain and an in-memory encryption key (never the Keychain),
/// - quits after writing the requested snapshot.
///
/// Flags (all require `-ClipivoDemoLibrary`):
///   -ClipivoDemoLibrary <dir>          sample library created by the DemoLibrarySeeder test
///   -ClipivoSnapshotPath <file.png>    render the panel (or Settings) to a PNG, then quit
///   -ClipivoSearch <text>              type a search before the snapshot
///   -ClipivoQuickLook <index>          open Quick Look on the result at <index> (0 = newest)
///   -ClipivoSettings <section>         snapshot the Settings window at that section (e.g. privacy)
///   -appearance light|dark             theme for this launch
///   -panelLayout shelf|list            panel layout for this launch
///
/// `scripts/demo-screenshots.sh` seeds a library and captures every README screenshot.
struct DemoMode {
    let library: URL
    let snapshotPath: URL?
    let search: String?
    let quickLookIndex: Int?
    let settingsSection: SettingsSection?
    let overrides: [String: String]

    static let preferencesSuite = "\(AppIdentity.bundleIdentifier).demo"

    /// The demo configuration for this launch, or `nil` for a normal launch.
    static let current: DemoMode? = parse(ProcessInfo.processInfo.arguments)

    static func parse(_ arguments: [String]) -> DemoMode? {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument.hasPrefix("-"), arguments.index(after: index) < arguments.endIndex {
                values[String(argument.dropFirst())] = arguments[arguments.index(after: index)]
                index = arguments.index(index, offsetBy: 2)
            } else {
                index = arguments.index(after: index)
            }
        }
        guard let path = values["ClipivoDemoLibrary"], !path.isEmpty else { return nil }
        let library = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        // Never let demo mode open (or write snapshots of) the real history.
        let real = StorageLayout.standard().root.standardizedFileURL.resolvingSymlinksInPath().path
        guard library.path != real, !library.path.hasPrefix(real + "/"), !real.hasPrefix(library.path + "/") else { return nil }
        return DemoMode(
            library: library,
            snapshotPath: values["ClipivoSnapshotPath"].map { URL(fileURLWithPath: $0) },
            search: values["ClipivoSearch"],
            quickLookIndex: values["ClipivoQuickLook"].flatMap(Int.init),
            settingsSection: values["ClipivoSettings"].flatMap { SettingsSection(rawValue: $0.lowercased()) },
            overrides: values.filter { ["appearance", "panelLayout"].contains($0.key) }
        )
    }

    /// Fresh preferences that never read or write the user's own settings.
    @MainActor func makePreferences() -> Preferences {
        let defaults = UserDefaults(suiteName: Self.preferencesSuite) ?? UserDefaults()
        defaults.removePersistentDomain(forName: Self.preferencesSuite)
        defaults.set(true, forKey: "hasCompletedOnboarding")
        for (key, value) in overrides { defaults.set(value, forKey: key) }
        return Preferences(defaults: defaults)
    }

    @MainActor func makeModel() throws -> AppModel {
        try AppModel(preferences: makePreferences(), layout: StorageLayout(root: library),
                     cipher: AESGCMCipher(keyData: AESGCMCipher.generateKeyData()), demo: true)
    }

    /// Removes the throwaway preferences domain.
    static func cleanUp() {
        UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
    }
}

/// Opaque stand-in for a frosted background while a snapshot is rendered.
private final class SnapshotFill: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

extension NSView {
    /// Renders this view (and its subviews) to a PNG over an opaque background.
    func writePNGSnapshot(to url: URL) {
        let bounds = self.bounds
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        // Vibrancy (NSVisualEffectView) is composited by the window server and would come out
        // transparent, so nested frosted areas (like Quick Look) get a temporary opaque fill.
        var fills: [NSView] = []
        func addFills(_ view: NSView) {
            for subview in view.subviews {
                if let effect = subview as? NSVisualEffectView, !effect.isHidden, effect.frame.size != bounds.size {
                    let fill = SnapshotFill(frame: effect.bounds)
                    fill.autoresizingMask = [.width, .height]
                    effect.addSubview(fill, positioned: .below, relativeTo: nil)
                    fills.append(fill)
                }
                addFills(subview)
            }
        }
        addFills(self)
        cacheDisplay(in: bounds, to: rep)
        fills.forEach { $0.removeFromSuperview() }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
            rect.fill()
            rep.draw(in: rect)
            return true
        }
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
