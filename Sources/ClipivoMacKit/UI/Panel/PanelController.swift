import AppKit
import SwiftUI
import Carbon.HIToolbox
import ClipivoCore

/// Non-activating floating panel: it can take keyboard focus while the app the user was working
/// in stays active, so paste goes straight back to it.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Transient + ignoresCycle: not shown in Mission Control, Exposé or the window cycle.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        minSize = NSSize(width: 560, height: 360)
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilityLabel("\(Branding.productName) clipboard")
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let app: AppModel
    let viewModel: PanelViewModel
    private lazy var panel: ClipboardPanel = makePanel()
    private var keyMonitor: Any?
    private var isPresentingModal = false
    var openSettings: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        self.viewModel = PanelViewModel(app: app)
        super.init()
        viewModel.onQuickLookToggled = { [weak self] open in self?.quickLookToggled(open) }
    }

    private var isShelf: Bool { app.preferences.panelLayout == .shelf }

    var isVisible: Bool { panel.isVisible }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        let root = PanelRootView(model: viewModel, app: app, onClose: { [weak self] in self?.hide() },
                                 onOpenSettings: { [weak self] in self?.hide(); self?.openSettings?() })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        if let saved = app.preferences.panelFrame {
            let frame = NSRectFromString(saved)
            if frame.width >= panel.minSize.width, frame.height >= panel.minSize.height {
                panel.setContentSize(frame.size)
            }
        }
        return panel
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show(selecting sidebar: SidebarSelection? = nil) {
        // Remember where to paste before we take keyboard focus.
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.pasteTarget = front
        }
        app.lock.noteActivity()
        if let sidebar { viewModel.sidebar = sidebar }
        viewModel.prepareForShow()
        let wasVisible = panel.isVisible
        position()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = panel.frame
        if !wasVisible && !reduceMotion {
            panel.alphaValue = 0
            if isShelf {
                // Slide in from the docked edge.
                let offset: CGFloat = app.preferences.shelfEdge == .bottom ? -40 : 40
                panel.setFrame(target.offsetBy(dx: 0, dy: offset), display: false)
            }
        }
        panel.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = isShelf ? 0.18 : 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                if isShelf { panel.animator().setFrame(target, display: true) }
            }
        } else {
            panel.alphaValue = 1
        }
        installKeyMonitor()
        if app.lock.isLocked {
            Task { await app.lock.authenticate(reason: "show your clipboard history") }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        viewModel.quickLookID = nil
        panel.orderOut(nil)
    }

    private func position() {
        let prefs = app.preferences
        let screen = ScreenLocator.screen(for: prefs.panelScreen)
        let visible = screen.visibleFrame
        panel.minSize = isShelf ? NSSize(width: 480, height: 200) : NSSize(width: 560, height: 360)
        if isShelf {
            panel.setFrame(shelfFrame(on: visible, expanded: viewModel.quickLookID != nil), display: false)
            return
        }
        // The list has its own size (default or last user resize). Never inherit the current window
        // size: after the shelf layout that would be the full screen width.
        var size = NSSize(width: 780, height: 540)
        if let saved = prefs.panelFrame, case let frame = NSRectFromString(saved),
           frame.width >= 560, frame.height >= 360 {
            size = frame.size
        }
        size.width = min(size.width, visible.width - 40)
        size.height = min(size.height, visible.height - 40)
        var origin: NSPoint
        switch prefs.panelPosition {
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.08)
        case .top:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)
        case .bottom:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        case .cursor:
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        case .remembered:
            if let saved = prefs.panelFrame, case let frame = NSRectFromString(saved), frame.width > 0,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                origin = frame.origin
                size = frame.size
            } else {
                origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            }
        }
        // Keep fully on the chosen screen.
        let target = prefs.panelPosition == .remembered ? (NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: origin.x + 10, y: origin.y + 10)) }?.visibleFrame ?? visible) : visible
        origin.x = min(max(origin.x, target.minX + 8), target.maxX - size.width - 8)
        origin.y = min(max(origin.y, target.minY + 8), target.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Demo mode: renders the panel's own content to a PNG (no screen-recording permission needed).
    func writeSnapshot(to url: URL) {
        panel.contentView?.writePNGSnapshot(to: url, solidifyVibrancy: viewModel.quickLookID != nil)
    }

    private func shelfFrame(on visible: NSRect, expanded: Bool) -> NSRect {
        let margin: CGFloat = 8
        let base = min(max(CGFloat(app.preferences.shelfHeight), 220), visible.height * 0.6)
        let height = expanded ? min(max(base * 2, 520), visible.height * 0.8) : base
        let y = app.preferences.shelfEdge == .bottom ? visible.minY + margin : visible.maxY - height - margin
        return NSRect(x: visible.minX + margin, y: y, width: visible.width - margin * 2, height: height)
    }

    /// In the shelf layout Quick Look temporarily makes the panel taller so previews are readable.
    private func quickLookToggled(_ open: Bool) {
        guard isShelf, panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = shelfFrame(on: screen.visibleFrame, expanded: open)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    // MARK: - Window delegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the panel, like a menu — but not while we show an alert.
        guard !isPresentingModal, NSApp.modalWindow == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isKeyWindow, NSApp.modalWindow == nil, !self.isPresentingModal else { return }
            if NSApp.keyWindow?.sheetParent == self.panel { return }
            self.hide()
        }
    }

    func windowDidMove(_ notification: Notification) { if !isShelf { saveFrame() } }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard panel.isVisible else { return }
        if isShelf {
            // Only the height of the shelf is user-adjustable (and only when not expanded for Quick Look).
            if viewModel.quickLookID == nil { app.preferences.shelfHeight = Double(panel.frame.height) }
        } else {
            app.preferences.panelFrame = NSStringFromRect(panel.frame)
        }
    }

    func runModal<T>(_ body: () -> T) -> T {
        isPresentingModal = true
        defer { isPresentingModal = false }
        return body()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Whether the search field currently has a text selection (so ⌘C should copy that text).
    private var fieldHasSelection: Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    private var textInputFocused: Bool { panel.firstResponder is NSTextView }

    /// Returns true when the event was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let vm = viewModel
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        app.lock.noteActivity()

        // Editors (title, tags, new Space) own the keyboard; only Escape is intercepted.
        if vm.titleEditorID != nil || vm.tagEditorID != nil || vm.newSpaceForIDs != nil {
            if code == kVK_Escape {
                vm.titleEditorID = nil; vm.tagEditorID = nil; vm.newSpaceForIDs = nil
                return true
            }
            return false
        }
        if let choice = vm.deliveryChoiceID {
            switch code {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                vm.deliveryChoiceID = nil
                Task { await app.deliver(choice, as: .paste, plainText: flags.contains(.shift)) }
                return true
            case kVK_ANSI_C:
                vm.deliveryChoiceID = nil
                Task { await app.deliver(choice, as: .copy, plainText: flags.contains(.shift)) }
                return true
            case kVK_Escape:
                vm.deliveryChoiceID = nil
                return true
            default:
                return true
            }
        }
        if app.lock.isLocked {
            if code == kVK_Escape { hide(); return true }
            if code == kVK_Return { Task { await app.lock.authenticate(reason: "show your clipboard history") }; return true }
            return false
        }

        switch code {
        case kVK_Escape:
            if vm.quickLookID != nil { vm.quickLookID = nil }
            else if !vm.searchText.isEmpty { vm.searchText = "" }
            else if !vm.multiSelection.isEmpty { vm.multiSelection.removeAll() }
            else { hide() }
            return true
        case kVK_DownArrow:
            if flags.contains(.command) { vm.selectLast() } else { vm.moveSelection(by: 1, extend: flags.contains(.shift)) }
            syncQuickLook()
            return true
        case kVK_UpArrow:
            if flags.contains(.command) { vm.selectFirst() } else { vm.moveSelection(by: -1, extend: flags.contains(.shift)) }
            syncQuickLook()
            return true
        case kVK_RightArrow where isShelf && (vm.searchText.isEmpty || !textInputFocused || flags.contains(.command)):
            if flags.contains(.command) { vm.selectLast() } else { vm.moveSelection(by: 1, extend: flags.contains(.shift)) }
            syncQuickLook()
            return true
        case kVK_LeftArrow where isShelf && (vm.searchText.isEmpty || !textInputFocused || flags.contains(.command)):
            if flags.contains(.command) { vm.selectFirst() } else { vm.moveSelection(by: -1, extend: flags.contains(.shift)) }
            syncQuickLook()
            return true
        case kVK_PageDown:
            vm.moveSelection(by: 8); syncQuickLook(); return true
        case kVK_PageUp:
            vm.moveSelection(by: -8); syncQuickLook(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            vm.activate(vm.selectedID, plainText: flags.contains(.shift), forceCopy: flags.contains(.option))
            return true
        case kVK_Space where flags.isEmpty:
            let allow = vm.quickLookID != nil || (app.preferences.spaceOpensQuickLook && (vm.searchText.isEmpty || !textInputFocused))
            guard allow else { return false }
            toggleQuickLook()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            if flags.contains(.command) || vm.searchText.isEmpty || !textInputFocused {
                vm.deleteTargets()
                return true
            }
            return false
        case kVK_Tab where flags.isEmpty || flags == .shift:
            // Tab cycles the type filter, keeping the keyboard in the panel.
            let all = ClipCategory.allCases
            let index = all.firstIndex(of: vm.category) ?? 0
            vm.category = all[(index + (flags.contains(.shift) ? all.count - 1 : 1)) % all.count]
            return true
        default:
            break
        }

        guard flags.contains(.command) else { return false }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch characters {
        case "c":
            if fieldHasSelection && !flags.contains(.shift) { return false }
            vm.activate(vm.selectedID, plainText: flags.contains(.shift), forceCopy: true)
            return true
        case "f", "l":
            vm.isSearchFocused = true
            return true
        case "y":
            toggleQuickLook(); return true
        case "p":
            vm.togglePinTargets(); return true
        case "r":
            vm.titleEditorID = vm.selectedID; return true
        case "t":
            vm.tagEditorID = vm.selectedID; return true
        case "n":
            let ids = vm.targetIDs
            vm.newSpaceForIDs = ids
            return true
        case "o":
            openSelected(); return true
        case ",":
            hide(); openSettings?(); return true
        case "w":
            hide(); return true
        case "[", "]":
            cycleSidebar(forward: characters == "]"); return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(characters), let clip = vm.clip(at: n - 1) {
                vm.selectedID = clip.id
                vm.activate(clip.id, plainText: flags.contains(.shift))
            }
            return true
        default:
            return false
        }
    }

    private func toggleQuickLook() {
        viewModel.quickLookID = viewModel.quickLookID == nil ? viewModel.selectedID : nil
    }

    private func syncQuickLook() {
        if viewModel.quickLookID != nil { viewModel.quickLookID = viewModel.selectedID }
    }

    private func cycleSidebar(forward: Bool) {
        var entries: [SidebarSelection] = [.history, .pinned]
        entries += app.spaces.map { .space($0.id) }
        let index = entries.firstIndex(of: viewModel.sidebar) ?? 0
        viewModel.sidebar = entries[(index + (forward ? 1 : entries.count - 1)) % entries.count]
    }

    func openSelected() {
        guard let summary = viewModel.selectedSummary, !summary.isPrivate else { return }
        Task {
            guard let content = try? await app.library.content(id: summary.id) else { return }
            ClipActions.open(content)
        }
    }
}
