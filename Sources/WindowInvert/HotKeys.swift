import Carbon
import Foundation

/// Global hotkeys via Carbon's RegisterEventHotKey (does not require Accessibility permission).
final class HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private static let signature: OSType = 0x5749_4E56 // 'WINV'

    init() {
        HotKeys.installHandlerIfNeeded()
    }

    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeys.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("WindowInvert: failed to register hotkey \(id) (status \(status))")
            return false
        }
        refs.append(ref)
        HotKeys.handlers[id] = handler
        return true
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
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
