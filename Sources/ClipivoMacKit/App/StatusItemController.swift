import AppKit
import ClipivoCore

/// The menu bar item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var recentClips: [ClipSummary] = []
    var showPanel: ((SidebarSelection?) -> Void)?
    var openSettings: (() -> Void)?
    var openAbout: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(Branding.productName)
        }
        statusItem.behavior = .removalAllowed
        refresh()
    }

    /// Updates the icon (paused / pending sensitive items) and click behaviour.
    func refresh() {
        guard let button = statusItem.button else { return }
        let paused = app.preferences.monitoringPaused
        let color = app.preferences.colorMenuBarIcon
        let image = StatusIcon.image(paused ? .paused : (app.pendingCaptures.isEmpty && app.updates.available == nil ? .normal : .attention),
                                     style: color ? .color : .monochrome)
        image.accessibilityDescription = paused ? "\(Branding.productName) (paused)" : Branding.productName
        button.image = image
        // The color icon draws its own dimmed/badged states; the template relies on the system dimming.
        button.appearsDisabled = paused && !color
        button.toolTip = paused ? "\(Branding.productName) — monitoring paused" : Branding.productName
        // With "show menu", attach the menu so it opens natively; otherwise handle clicks ourselves.
        statusItem.menu = app.preferences.menuBarClickAction == .showMenu ? menu : nil
        Task { recentClips = (try? await app.library.recent(limit: 10)) ?? recentClips }
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { self.refresh() }
        } else {
            showPanel?(nil)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: Branding.productName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let search = item("Search Clipboard…", #selector(openSearch))
        if let combo = app.preferences.panelHotKey { search.title = "Search Clipboard…    \(combo.displayString)" }
        menu.addItem(search)

        let recent = NSMenuItem(title: "Recent Clips", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if recentClips.isEmpty {
            let empty = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
        for (index, clip) in recentClips.enumerated() {
            let title = String(clip.displayTitle.prefix(48)) + (clip.displayTitle.count > 48 ? "…" : "")
            let entry = item(title, #selector(copyRecent(_:)))
            entry.tag = Int(clip.id)
            entry.image = NSImage(systemSymbolName: Theme.symbol(for: clip.kind), accessibilityDescription: clip.kind.displayName)
            if index < 9 { entry.keyEquivalent = "\(index + 1)"; entry.keyEquivalentModifierMask = [] }
            entry.toolTip = "Copy to clipboard"
            recentMenu.addItem(entry)
        }
        recent.submenu = recentMenu
        menu.addItem(recent)

        let spaces = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: "")
        let spacesMenu = NSMenu()
        let history = item("History", #selector(openHistory))
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        spacesMenu.addItem(history)
        let pinned = item("Pinned", #selector(openPinned))
        pinned.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        spacesMenu.addItem(pinned)
        if !app.spaces.isEmpty { spacesMenu.addItem(.separator()) }
        for space in app.spaces {
            let entry = item(space.name, #selector(openSpace(_:)))
            entry.tag = Int(space.id)
            entry.image = NSImage(systemSymbolName: space.icon, accessibilityDescription: nil)
            spacesMenu.addItem(entry)
        }
        spaces.submenu = spacesMenu
        menu.addItem(spaces)

        menu.addItem(.separator())
        if let update = app.updates.available {
            let available = item("Update Available: \(Branding.productName) \(update.version)…", #selector(openUpdate))
            available.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(available)
        }
        if !app.pendingCaptures.isEmpty {
            let pending = item("\(app.pendingCaptures.count) sensitive item\(app.pendingCaptures.count == 1 ? "" : "s") awaiting review…", #selector(openSearch))
            pending.image = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: nil)
            menu.addItem(pending)
        }
        let paused = app.preferences.monitoringPaused
        menu.addItem(item(paused ? "Resume Monitoring" : "Pause Monitoring", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Open Clipboard", #selector(openHistory)))
        menu.addItem(item("Settings…", #selector(settings), key: ","))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(item("About \(Branding.productName)", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Branding.productName)", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSearch() { showPanel?(nil) }
    @objc private func openUpdate() { app.updates.openReleasePage() }
    @objc private func checkForUpdates() { app.updates.checkInteractively() }
    @objc private func openHistory() { showPanel?(.history) }
    @objc private func openPinned() { showPanel?(.pinned) }
    @objc private func openSpace(_ sender: NSMenuItem) { showPanel?(.space(Int64(sender.tag))) }
    @objc private func settings() { openSettings?() }
    @objc private func about() { openAbout?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func togglePause() {
        app.setPaused(!app.preferences.monitoringPaused)
        refresh()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        Task { await app.deliver(id, as: .copy, plainText: false) }
    }
}
