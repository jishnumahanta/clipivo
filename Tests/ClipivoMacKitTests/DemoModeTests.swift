import Foundation
import Testing
import ClipivoCore
@testable import ClipivoMacKit

@Suite struct DemoModeTests {
    @Test func normalLaunchIsNeverDemo() {
        #expect(DemoMode.parse(["/Applications/Clipivo.app/Contents/MacOS/Clipivo"]) == nil)
        #expect(DemoMode.parse(["Clipivo", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(DemoMode.parse(["Clipivo", "-ClipivoSnapshotPath", "/tmp/x.png"]) == nil, "Other flags alone never enable demo mode")
        #expect(DemoMode.parse(["Clipivo", "-ClipivoDemoLibrary", ""]) == nil)
    }

    @Test func demoModeRequiresAnExplicitLibrary() throws {
        let demo = try #require(DemoMode.parse(["Clipivo", "-ClipivoDemoLibrary", "/tmp/clipivo-demo", "-ClipivoQuickLook", "2",
                                                "-ClipivoSettings", "Privacy", "-appearance", "dark", "-unrelated", "x"]))
        #expect(demo.library.lastPathComponent == "clipivo-demo")
        #expect(demo.quickLookIndex == 2)
        #expect(demo.settingsSection == .privacy)
        #expect(demo.overrides == ["appearance": "dark"])
    }

    @Test func demoModeRefusesTheRealLibrary() {
        let real = StorageLayout.standard().root
        #expect(DemoMode.parse(["Clipivo", "-ClipivoDemoLibrary", real.path]) == nil)
        #expect(DemoMode.parse(["Clipivo", "-ClipivoDemoLibrary", real.appendingPathComponent("Database").path]) == nil)
        #expect(DemoMode.parse(["Clipivo", "-ClipivoDemoLibrary", real.deletingLastPathComponent().path]) == nil)
    }

    @MainActor @Test func demoPreferencesAreIsolated() {
        let demo = DemoMode(library: URL(fileURLWithPath: "/tmp/clipivo-demo"), snapshotPath: nil, search: nil,
                            quickLookIndex: nil, settingsSection: nil, overrides: ["appearance": "dark"])
        let prefs = demo.makePreferences()
        #expect(prefs.appearance.rawValue == "dark")
        #expect(prefs.hasCompletedOnboarding)
        // The demo writes only to its own domain, never the app's.
        #expect(UserDefaults(suiteName: DemoMode.preferencesSuite)?.bool(forKey: "hasCompletedOnboarding") == true)
        DemoMode.cleanUp()
        #expect(UserDefaults.standard.persistentDomain(forName: DemoMode.preferencesSuite) == nil)
    }
}
