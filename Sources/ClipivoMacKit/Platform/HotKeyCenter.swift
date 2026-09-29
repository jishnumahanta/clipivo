import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts via the Carbon hot-key API. This API needs no Accessibility permission
/// and works for non-sandboxed and sandboxed apps alike.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    public enum Action: UInt32 {
        case togglePanel = 1
        case pastePlainText = 2
    }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x434C5056 // 'CLPV'

    public enum RegistrationError: LocalizedError {
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let combo): return "The shortcut \(combo) is already used by another app or by macOS. Choose a different one in Settings ▸ Keyboard."
            }
        }
    }

    private init() {}

    /// Registers (or clears, when `combo` is nil) the shortcut for an action.
    public func register(_ combo: KeyCombo?, for action: Action, handler: @escaping () -> Void) throws {
        installEventHandlerIfNeeded()
        unregister(action)
        guard let combo else { return }
        handlers[action] = handler
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            handlers[action] = nil
            throw RegistrationError.unavailable(combo.displayString)
        }
        refs[action] = ref
    }

    public func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        handlers[action] = nil
    }

    /// Temporarily disables all shortcuts (while recording a new one in Settings).
    public func suspend() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    fileprivate func handle(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        handlers[action]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.handle(id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
