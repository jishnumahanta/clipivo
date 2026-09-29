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
