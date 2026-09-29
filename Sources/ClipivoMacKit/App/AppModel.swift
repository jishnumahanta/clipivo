import AppKit
import Observation
import ClipivoCore

/// A transient message shown in the panel footer (or as a HUD when the panel is closed).
public struct Notice: Identifiable, Equatable {
    public enum Style { case info, success, warning, error }
    public let id = UUID()
    public var message: String
    public var style: Style
}

/// Composition root and coordinator for the macOS app. Owns the core services and exposes
/// user-level operations (paste, copy, pin, …) with consistent error handling.
@MainActor
@Observable
public final class AppModel {
    public let preferences: Preferences
    public let library: ClipLibrary
    public let lock: LockService
    public let updates: UpdateService
    @ObservationIgnored let processor: CaptureProcessor
    @ObservationIgnored let background: BackgroundProcessor
    @ObservationIgnored let monitor: ClipboardMonitor
    @ObservationIgnored private let linkFetcher = LinkTitleFetcher()
    @ObservationIgnored let privateStorageAvailable: Bool

    /// Bumped (debounced) whenever the library changes; views observe it to refresh.
    public private(set) var libraryVersion = 0
    public private(set) var spaces: [Space] = []
    public private(set) var ignoredApps: [IgnoredApplication] = []
    public private(set) var pendingCaptures: [PendingCapture] = []
    public private(set) var notice: Notice?
    public private(set) var hotKeyError: String?
    public private(set) var totalClipCount = 0
    public private(set) var pinnedCount = 0

    /// The app that was frontmost when the panel opened; paste goes back to it.
    @ObservationIgnored public var pasteTarget: NSRunningApplication?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored var onPanelRequest: ((PanelRequest) -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?

    public enum PanelRequest { case toggle, show, hide, showSpace(Int64?), showPinned }

    public init(preferences: Preferences? = nil, layout: StorageLayout = .standard()) throws {
        let preferences = preferences ?? Preferences.shared
        self.preferences = preferences
        // The Keychain is only touched when a private clip is first created or opened.
        privateStorageAvailable = true
        library = try ClipLibrary(layout: layout, cipher: KeychainBackedCipher())
        processor = CaptureProcessor(library: library)
        background = BackgroundProcessor(library: library, recognizer: VisionTextRecognizer(), renderer: ImageIOThumbnailRenderer())
        monitor = ClipboardMonitor()
        lock = LockService(preferences: preferences)
        updates = UpdateService(preferences: preferences)
    }

    // MARK: - Lifecycle

    public func start() {
        changeObserver = NotificationCenter.default.addObserver(forName: .clipLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        monitor.onSnapshot = { [weak self] snapshot, policy in
            Task { @MainActor in await self?.handle(snapshot, policy: policy) }
        }
        Task {
            try? await library.seedDefaultSpacesIfNeeded()
            _ = try? await library.reclassifyIfNeeded()
            await refreshCaches()
            applyCapturePolicy()
            monitor.start(interval: preferences.pollInterval)
            await background.setOCREnabled(preferences.ocrEnabled)
            await background.refreshThumbnailsIfSizeChanged()
            background.schedule()
            runMaintenance()
        }
        registerHotKeys()
        applyAppearance()
        if library.recoveredFromCorruption {
            show("The clipboard database was damaged and has been set aside. A new history was started.", style: .warning)
        }
        updates.onChange = { [weak self] in self?.onStateChange?() }
        // First update check shortly after launch (so it never delays startup), then at most daily.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.updates.checkIfDue()
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runMaintenance()
                self?.updates.checkIfDue()
            }
        }
    }

    public func stop() {
        monitor.stop()
        maintenanceTimer?.invalidate()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            refreshScheduled = false
            await refreshCaches()
            libraryVersion &+= 1
            onStateChange?()
        }
    }

    func refreshCaches() async {
        spaces = (try? await library.spaces()) ?? spaces
        let ignored = (try? await library.ignoredApps()) ?? ignoredApps
        if ignored != ignoredApps {
            ignoredApps = ignored
            applyCapturePolicy()
        }
        totalClipCount = (try? await library.totalCount()) ?? totalClipCount
        pinnedCount = (try? await library.count(ClipQuery(pinnedOnly: true))) ?? pinnedCount
    }

    /// Pushes current preferences to the monitor. Call after any capture-related setting changes.
    public func applyCapturePolicy() {
        monitor.update(policy: preferences.capturePolicy(ignored: Set(ignoredApps.map(\.bundleID)), privateStorageAvailable: privateStorageAvailable))
        onStateChange?()
    }

    public func applyAppearance() {
        switch preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.setActivationPolicy(preferences.showDockIcon ? .regular : .accessory)
    }

    public func applyPollInterval() {
        monitor.update(interval: preferences.pollInterval)
    }

    public func registerHotKeys() {
        hotKeyError = nil
        do {
            try HotKeyCenter.shared.register(preferences.panelHotKey, for: .togglePanel) { [weak self] in
                self?.onPanelRequest?(.toggle)
            }
        } catch {
            hotKeyError = error.localizedDescription
        }
        do {
            try HotKeyCenter.shared.register(preferences.plainTextHotKey, for: .pastePlainText) { [weak self] in
                self?.pasteMostRecentAsPlainText()
            }
        } catch {
            hotKeyError = error.localizedDescription
        }
    }

    // MARK: - Capture

    private func handle(_ snapshot: ClipboardSnapshot, policy: CapturePolicy) async {
        do {
            let outcome = try await processor.process(snapshot, policy: policy)
            switch outcome {
            case .stored(let result, let kind):
                if kind.isImageLike || kind == .pdf { background.schedule() }
                if kind == .url, preferences.fetchLinkTitles, case .inserted(let id) = result,
                   let text = snapshot.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    let library = library
                    Task.detached(priority: .background) { [linkFetcher] in await linkFetcher.fetchTitle(for: id, urlString: text, library: library) }
                }
            case .needsConfirmation(let pending):
                pendingCaptures.append(pending)
                if pendingCaptures.count > 20 { pendingCaptures.removeFirst(pendingCaptures.count - 20) }
                onStateChange?()
            case .skipped:
                break
            }
        } catch {
            // Never log clipboard content; the error describes storage state only.
            show("Couldn't save the last copied item: \(error.localizedDescription)", style: .error)
        }
    }

    public func resolvePending(_ pending: PendingCapture, decision: SensitiveContentPolicy) {
        pendingCaptures.removeAll { $0.id == pending.id }
        onStateChange?()
        guard decision == .save || decision == .saveAsPrivate else { return }
        var prepared = pending.prepared
        prepared.isPrivate = decision == .saveAsPrivate && privateStorageAvailable
        Task {
            do { try await library.store(prepared, duplicatePolicy: preferences.duplicatePolicy) }
            catch { show("Couldn't save the clip: \(error.localizedDescription)", style: .error) }
        }
    }

    public func setPaused(_ paused: Bool) {
        preferences.monitoringPaused = paused
        applyCapturePolicy()
    }

    // MARK: - Paste / copy

    public enum Delivery { case paste, copy }

    /// Places a clip on the pasteboard and, for `.paste`, sends ⌘V to the previously active app.
    public func deliver(_ clipID: Int64, as delivery: Delivery, plainText: Bool) async {
        let plain = plainText || (preferences.alwaysPastePlainText && delivery == .paste)
        guard let summary = try? await library.summary(id: clipID) else {
            show("That clip no longer exists.", style: .error)
            return
        }
        if summary.isPrivate && !lock.isPrivateUnlocked {
            guard await lock.authenticate(reason: "reveal a private clip") else { return }
        }
        let content: ClipContent
        do {
            content = try await library.content(id: clipID, allowPrivate: true)
        } catch {
            show(error.localizedDescription, style: .error)
            return
        }
        let result = PasteboardWriter.write(content, mode: plain ? .plainText : .original)
        monitor.acknowledgeOwnWrite()
        guard result.wroteSomething else {
            show("This clip has no content that can be placed on the clipboard.", style: .error)
            return
        }
        if preferences.moveUsedToTop { try? await library.markUsed(clipID) }
        if !result.missingFiles.isEmpty {
            show("\(result.missingFiles.count == 1 ? "The original file was" : "\(result.missingFiles.count) original files were") moved or deleted.", style: .warning)
        }

        switch delivery {
        case .copy:
            if preferences.closeAfterCopy { onPanelRequest?(.hide) }
            show(plain ? "Copied as plain text" : "Copied", style: .success)
        case .paste:
            onPanelRequest?(.hide)
            if PasteService.sendPasteKeystroke(to: pasteTarget) == .needsAccessibility {
                presentAccessibilityExplanation()
            }
        }
    }

    public func copyText(_ text: String, message: String = "Copied") {
        PasteboardWriter.writeString(text)
        monitor.acknowledgeOwnWrite()
        show(message, style: .success)
    }

    /// Global "paste latest as plain text" shortcut.
    func pasteMostRecentAsPlainText() {
        pasteTarget = NSWorkspace.shared.frontmostApplication
        Task {
            guard let latest = try? await library.recent(limit: 1).first else { return }
            await deliver(latest.id, as: .paste, plainText: true)
        }
    }

    /// Explains why automatic paste needs Accessibility and offers to open System Settings.
    /// The clip is already on the clipboard, so the user can still press ⌘V.
    public func presentAccessibilityExplanation() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow \(Branding.productName) to paste for you"
        alert.informativeText = """
            The clip is on your clipboard — press ⌘V to paste it now.

            To paste automatically, macOS requires Accessibility access so \(Branding.productName) can send ⌘V to the app you were using. \
            \(Branding.productName) uses it only for that keystroke.

            Open System Settings ▸ Privacy & Security ▸ Accessibility and turn on \(Branding.productName). \
            Or choose "Copy only" in Settings ▸ Clipboard to stop pasting automatically.

            Already switched on? After an update macOS may keep a stale entry. Select \(Branding.productName) in the list, \
            remove it with “−”, then add it again with “+”.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.requestPrompt()
            AccessibilityPermission.openSystemSettings()
        }
    }

    // MARK: - Clip operations (errors surface as notices, never silently)

    func perform(_ label: String, _ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() }
            catch { show("\(label) failed: \(error.localizedDescription)", style: .error) }
        }
    }

    public func setPinned(_ ids: [Int64], _ pinned: Bool) { perform("Pinning") { try await self.library.setPinned(ids, pinned: pinned) } }
    public func delete(_ ids: [Int64]) { perform("Deleting") { try await self.library.delete(ids) } }
    public func setTitle(_ id: Int64, _ title: String?) { perform("Renaming") { try await self.library.setTitle(id, title: title) } }
    public func addTag(_ tag: String, to ids: [Int64]) { perform("Tagging") { try await self.library.addTag(tag, to: ids) } }
    public func removeTag(_ tag: String, from ids: [Int64]) { perform("Removing tag") { try await self.library.removeTag(tag, from: ids) } }
    public func add(_ ids: [Int64], toSpace space: Int64) { perform("Adding to Space") { try await self.library.addClips(ids, toSpace: space) } }
    public func remove(_ ids: [Int64], fromSpace space: Int64) { perform("Removing from Space") { try await self.library.removeClips(ids, fromSpace: space) } }

    public func setPrivate(_ id: Int64, _ isPrivate: Bool) {
        guard privateStorageAvailable else {
            show("Private clips need the Keychain, which is unavailable.", style: .error)
            return
        }
        Task {
            if !isPrivate && !lock.isPrivateUnlocked {
                guard await lock.authenticate(reason: "make a private clip visible") else { return }
            }
            do { try await library.setPrivate(id, isPrivate: isPrivate); show(isPrivate ? "Marked as private" : "No longer private", style: .success) }
            catch { show(error.localizedDescription, style: .error) }
        }
    }

    public func deleteAll(fromSource bundleID: String, name: String) {
        guard confirm("Delete all clips copied from \(name)?", detail: "Pinned clips are kept. This can't be undone.", destructive: "Delete") else { return }
        perform("Deleting") {
            let count = try await self.library.deleteAll(fromSource: bundleID)
            self.show("Deleted \(count) clip\(count == 1 ? "" : "s") from \(name)", style: .success)
        }
    }

    public func deleteSimilar(to id: Int64) {
        perform("Deleting") {
            let count = try await self.library.deleteSimilar(to: id)
            self.show("Deleted \(count) similar clip\(count == 1 ? "" : "s")", style: .success)
        }
    }

    public func ignoreApp(bundleID: String, name: String) {
        perform("Ignoring app") {
            try await self.library.addIgnoredApp(IgnoredApplication(bundleID: bundleID, name: name))
            await self.refreshCaches()
            self.show("\(name) will be ignored from now on", style: .success)
        }
    }

    public func unignoreApp(bundleID: String) {
        perform("Updating ignored apps") {
            try await self.library.removeIgnoredApp(bundleID: bundleID)
            await self.refreshCaches()
        }
    }

    /// Runs OCR now if needed, then copies the recognised text.
    public func copyTextFromImage(_ id: Int64) {
        Task {
            do {
                let text = try await background.recognizeNow(id, allowPrivate: lock.isPrivateUnlocked)
                guard !text.isEmpty else { show("No text was found in this image.", style: .warning); return }
                copyText(text, message: "Copied text from image")
            } catch {
                show("Text recognition failed: \(error.localizedDescription)", style: .error)
            }
        }
    }

    // MARK: - Spaces

    @discardableResult
    public func createSpace(named name: String, icon: String = "folder", adding ids: [Int64] = []) async -> Space? {
        do {
            let space = try await library.createSpace(name: name, icon: icon)
            if !ids.isEmpty { try await library.addClips(ids, toSpace: space.id) }
            await refreshCaches()
            return space
        } catch {
            show("Couldn't create the Space: \(error.localizedDescription)", style: .error)
            return nil
        }
    }

    public func renameSpace(_ id: Int64, _ name: String) { perform("Renaming Space") { try await self.library.renameSpace(id, to: name) } }
    public func setSpaceIcon(_ id: Int64, _ icon: String) { perform("Changing icon") { try await self.library.setSpaceIcon(id, icon: icon) } }
    public func setSpacePinned(_ id: Int64, _ pinned: Bool) { perform("Pinning Space") { try await self.library.setSpacePinned(id, pinned: pinned) } }
    public func reorderSpaces(_ ids: [Int64]) { perform("Reordering Spaces") { try await self.library.reorderSpaces(ids) } }

    public func deleteSpace(_ space: Space) {
        guard confirm("Delete the Space “\(space.name)”?", detail: "Its clips stay in History.", destructive: "Delete Space") else { return }
        perform("Deleting Space") { try await self.library.deleteSpace(space.id) }
    }

    // MARK: - Maintenance

    func runMaintenance() {
        Task {
            if preferences.cleanupEnabled, preferences.cleanupAgeDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(preferences.cleanupAgeDays) * 86_400)
                let kinds: Set<ClipKind>? = preferences.cleanupImagesOnly ? [.image, .screenshot] : nil
                _ = try? await library.deleteClips(olderThan: cutoff, kinds: kinds)
            }
            if preferences.autoBackupEnabled {
                let due = preferences.lastBackupDate.map { Date().timeIntervalSince($0) > Double(preferences.autoBackupIntervalDays) * 86_400 } ?? true
                if due, (try? await ArchiveService.backup(library: library, keep: preferences.backupsToKeep)) != nil {
                    preferences.lastBackupDate = Date()
                }
            }
        }
    }

    // MARK: - Notices

    public func show(_ message: String, style: Notice.Style = .info) {
        let notice = Notice(message: message, style: style)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(style == .error || style == .warning ? 6 : 2.5))
            if self.notice?.id == notice.id { self.notice = nil }
        }
        onStateChange?()
    }

    public func dismissNotice() { notice = nil }

    func confirm(_ message: String, detail: String, destructive: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: destructive).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
