import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click, then press a key combination. Esc cancels; ⌫ clears.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var allowsClearing = true
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : (combo?.displayString ?? "None"))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(combo?.displayString ?? "none"). Click to change.")
            if allowsClearing && combo != nil && !recording {
                Button { combo = nil; onChange() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear shortcut")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let code = Int(event.keyCode)
            if code == kVK_Escape { stop(); return nil }
            if (code == kVK_Delete || code == kVK_ForwardDelete) && allowsClearing {
                combo = nil
                stop()
                return nil
            }
            let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
            guard candidate.isValidGlobalShortcut else {
                message = "Include ⌘, ⌥ or ⌃"
                return nil
            }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            onChange()
        }
    }
}
