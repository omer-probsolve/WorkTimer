import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys via the Carbon hotkey API.
///
/// This route is deliberate: unlike a `CGEventTap`, `RegisterEventHotKey` needs
/// no Accessibility permission, so the shortcuts work the moment the app starts.
final class HotKeyManager {
    enum Action: UInt32, CaseIterable {
        case togglePanel = 1
        case toggleTimer = 2
    }

    static let shared = HotKeyManager()

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x574B544D // 'WKTM'

    private init() {}

    /// Binds `combo` to `action`, replacing any previous binding. Passing nil just
    /// clears it. Returns false if the shortcut is already taken system-wide.
    @discardableResult
    func register(_ action: Action, combo: KeyCombo?, handler: @escaping () -> Void) -> Bool {
        unregister(action)
        guard let combo else { return true }
        guard installHandlerIfNeeded() else { return false }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[action] = ref
        handlers[action] = handler
        return true
    }

    func unregister(_ action: Action) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        handlers[action] = nil
    }

    func unregisterAll() {
        Action.allCases.forEach(unregister)
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr,
                  hotKeyID.signature == HotKeyManager.signature,
                  let action = Action(rawValue: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { HotKeyManager.shared.fire(action) }
            return noErr
        }

        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handler)
        guard status == noErr else { return false }
        handlerRef = handler
        return true
    }

    private func fire(_ action: Action) {
        handlers[action]?()
    }
}
