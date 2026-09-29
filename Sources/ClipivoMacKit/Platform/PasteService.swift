import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility (AX) permission, required only to synthesise ⌘V into another application.
public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Clipivo to the Accessibility list.
    public static func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A single click pastes and hides the panel at once, so the second click of a double-click would land
/// in the app underneath and move its focus away from the text field before ⌘V arrives. After a
/// click-to-paste, this briefly swallows only that follow-up click (click count ≥ 2, within the
/// system double-click interval). It uses the Accessibility permission pasting already needs; without
/// it, or if the tap can't be created, it does nothing.
@MainActor
enum DoubleClickGuard {
    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private static var deadline: CFAbsoluteTime = 0

    static func swallowFollowUpClick() {
        guard AccessibilityPermission.isGranted else { return }
        let interval = NSEvent.doubleClickInterval
        deadline = CFAbsoluteTimeGetCurrent() + interval
        if tap == nil { install() }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval + 0.1) {
            if CFAbsoluteTimeGetCurrent() >= deadline { uninstall() }
        }
    }

    private static func install() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
            let isFollowUp = event.getIntegerValueField(.mouseEventClickState) >= 2
            if isFollowUp && CFAbsoluteTimeGetCurrent() < DoubleClickGuard.deadline { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
    }

    private static func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }
}

/// Sends ⌘V to the frontmost application.
@MainActor
public enum PasteService {
    public enum Result {
        case pasted
        case needsAccessibility
    }

    /// Posts ⌘V after a short delay so the target app has regained key focus.
    /// Returns `.needsAccessibility` (instead of failing silently) when permission is missing.
    public static func sendPasteKeystroke(to app: NSRunningApplication?, delay: TimeInterval = 0.06) -> Result {
        guard AccessibilityPermission.isGranted else { return .needsAccessibility }
        if let app, !app.isActive {
            app.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            // Suppress the user's physically held modifiers (e.g. ⇧ from ⇧↩) so the target sees plain ⌘V.
            source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                               state: .eventSuppressionStateSuppressionInterval)
            let vKey = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
        return .pasted
    }
}
