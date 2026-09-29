import AppKit
import ClipivoCore

/// Watches the general pasteboard for changes.
///
/// macOS has no pasteboard-change notification, so every clipboard manager polls `changeCount`.
/// That read is a cheap integer IPC; contents are only read when the count changes. Polling and
/// reading happen on a utility queue, never on the main thread, and the timer uses leeway so the
/// system can coalesce wake-ups for energy efficiency.
public final class ClipboardMonitor: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let queue = DispatchQueue(label: AppIdentity.scoped("clipboard-monitor"), qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    // Guarded by `lock`.
    private var lastChangeCount: Int
    private var frontmostApp: SourceApplication?
    private var policy = CapturePolicy()
    private var interval: Double = 0.3

    /// Called on the monitor queue with each new snapshot that passed the cheap pre-checks.
    public var onSnapshot: (@Sendable (ClipboardSnapshot, CapturePolicy) -> Void)?
    /// Called when a change was skipped before reading (paused / ignored app).
    public var onSkip: (@Sendable (SkipReason) -> Void)?

    private var activationObserver: NSObjectProtocol?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    @MainActor
    public func start(interval: Double) {
        lock.withLock {
            self.interval = max(0.1, min(interval, 2.0))
            lastChangeCount = pasteboard.changeCount
            frontmostApp = Self.sourceApplication(NSWorkspace.shared.frontmostApplication)
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let source = Self.sourceApplication(app)
                self?.lock.withLock { self?.frontmostApp = source }
            }
        }
        scheduleTimer()
    }

    @MainActor
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func update(policy: CapturePolicy) {
        lock.withLock { self.policy = policy }
    }

    @MainActor
    public func update(interval: Double) {
        lock.withLock { self.interval = max(0.1, min(interval, 2.0)) }
        if timer != nil { scheduleTimer() }
    }

    /// Call after Clipivo writes to the pasteboard so that write is not captured as a new clip.
    public func acknowledgeOwnWrite() {
        let count = pasteboard.changeCount
        lock.withLock { lastChangeCount = count }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let interval = lock.withLock { self.interval }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        let count = pasteboard.changeCount
        let (changed, policy, source) = lock.withLock { () -> (Bool, CapturePolicy, SourceApplication?) in
            guard count != lastChangeCount else { return (false, self.policy, nil) }
            lastChangeCount = count
            return (true, self.policy, frontmostApp)
        }
        guard changed else { return }

        // Privacy: decide whether to read *before* touching the contents.
        if let reason = CaptureProcessor.shouldRead(sourceBundleID: source?.bundleID, policy: policy) {
            onSkip?(reason)
            return
        }
        guard let snapshot = PasteboardReader.snapshot(from: pasteboard, source: source) else { return }
        // If the pasteboard changed while we were reading, drop this read; the next poll gets the new state.
        guard pasteboard.changeCount == count else { return }
        onSnapshot?(snapshot, policy)
    }

    static func sourceApplication(_ app: NSRunningApplication?) -> SourceApplication? {
        guard let app, let bundleID = app.bundleIdentifier else { return nil }
        return SourceApplication(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
}
