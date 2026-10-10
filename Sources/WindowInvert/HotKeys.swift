import Carbon
import Foundation

/// Global hotkeys via Carbon's RegisterEventHotKey (does not require Accessibility permission).
final class HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private static let signature: OSType = 0x5749_4E56 // 'WINV'

    init() {
        HotKeys.installHandlerIfNeeded()
    }

    /// Returns false if the combination is already taken by another app (or invalid).
    @discardableResult
    func register(id: UInt32, combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeys.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.write("failed to register hotkey \(id) \(combo.displayString) (status \(status))")
            return false
        }
        refs[id] = ref
        HotKeys.handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        HotKeys.handlers[id] = nil
    }

    func unregisterAll() {
        refs.keys.forEach { unregister(id: $0) }
    }

    deinit {
        unregisterAll()
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            HotKeys.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
