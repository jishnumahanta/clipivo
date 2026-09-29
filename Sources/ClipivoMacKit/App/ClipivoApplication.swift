import AppKit
import SwiftUI
import ClipivoCore

/// Entry point used by the `Clipivo` executable.
public enum ClipivoApplication {
    @MainActor
    public static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppModel?
    private var panel: PanelController?
    private var statusItem: StatusItemController?
    private var settingsWindow: HostedWindowController<SettingsView>?
    private var aboutWindow: HostedWindowController<AboutView>?
    private var welcomeWindow: HostedWindowController<WelcomeView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIdentity.migrateLegacyPreferences()
        installMainMenu()
        let model: AppModel
        do {
            model = try AppModel()
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(Branding.productName) couldn't open its clipboard library"
            alert.informativeText = "\(error.localizedDescription)\n\nYour data has not been deleted. Check that there is free disk space and that ~/Library/Application Support/\(Branding.productName) is accessible, then relaunch."
            alert.alertStyle = .critical
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        app = model

        let panel = PanelController(app: model)
        self.panel = panel
        let status = StatusItemController(app: model)
        statusItem = status

        panel.openSettings = { [weak self] in self?.showSettings() }
        status.showPanel = { [weak self] sidebar in self?.panel?.show(selecting: sidebar) }
        status.openSettings = { [weak self] in self?.showSettings() }
        status.openAbout = { [weak self] in self?.showAbout(nil) }

        model.onPanelRequest = { [weak self] request in
            guard let panel = self?.panel else { return }
            switch request {
            case .toggle: panel.toggle()
            case .show: panel.show()
            case .hide: panel.hide()
            case .showSpace(let id): panel.show(selecting: id.map { .space($0) } ?? .history)
            case .showPinned: panel.show(selecting: .pinned)
            }
        }
        model.onStateChange = { [weak self] in self?.statusItem?.refresh() }
        model.start()

        if !model.preferences.hasCompletedOnboarding && !UserDefaults.standard.bool(forKey: "ClipivoSkipWelcome") {
            showWelcome()
        }
        // Development aid: `open Clipivo.app --args -ClipivoShowPanelOnLaunch YES` (used for UI checks).
        if UserDefaults.standard.bool(forKey: "ClipivoShowPanelOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.panel?.show() }
            if let path = UserDefaults.standard.string(forKey: "ClipivoSnapshotPath") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.panel?.writeSnapshot(to: URL(fileURLWithPath: path)) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon (when shown) or relaunching opens the panel.
        panel?.show()
        return false
    }

    private func showSettings() {
        guard let app else { return }
        if settingsWindow == nil {
            settingsWindow = HostedWindowController(title: "\(Branding.productName) Settings", size: NSSize(width: 760, height: 560)) {
                SettingsView(app: app)
            }
        }
        settingsWindow?.show()
    }

    @objc private func showAbout(_ sender: Any?) {
        if aboutWindow == nil {
            aboutWindow = HostedWindowController(title: "About \(Branding.productName)", size: NSSize(width: 340, height: 420), resizable: false) {
                AboutView()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.show()
    }

    private func showWelcome() {
        guard let app else { return }
        welcomeWindow = HostedWindowController(title: "Welcome", size: NSSize(width: 520, height: 520), resizable: false) { [weak self] in
            WelcomeView(app: app) {
                app.preferences.hasCompletedOnboarding = true
                self?.welcomeWindow?.close()
                self?.welcomeWindow = nil
            }
        }
        welcomeWindow?.show()
    }

    /// A minimal main menu so standard editing shortcuts (⌘C/⌘V/⌘A/⌘Z) work in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(Branding.productName)", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(Branding.productName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(Branding.productName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}
