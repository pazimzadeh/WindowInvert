import AppKit
import Carbon

/// A key plus Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        modifiers = mods
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Function keys may be used without modifiers; anything else needs ⌘, ⌥ or ⌃.
    var isValidGlobalShortcut: Bool {
        if Self.functionKeys.contains(Int(keyCode)) { return true }
        return modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// The key's character on the current layout (ignoring modifiers), e.g. "8".
    var keyName: String {
        if let special = Self.specialKeyNames[Int(keyCode)] { return special }
        return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// For NSMenuItem.keyEquivalent; nil if the key can't be shown as a menu key equivalent.
    var menuKeyEquivalent: String? {
        guard Self.specialKeyNames[Int(keyCode)] == nil, let c = Self.character(for: keyCode), c.count == 1 else {
            return nil
        }
        return c.lowercased()
    }

    var storageString: String { "\(keyCode):\(modifiers)" }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

enum ShortcutAction: String, CaseIterable {
    case invertWindow
    case invertContent
    case switchStyle

    var hotKeyID: UInt32 {
        switch self {
        case .invertWindow: return 1
        case .invertContent: return 2
        case .switchStyle: return 3
        }
    }

    var title: String {
        switch self {
        case .invertWindow: return "Invert whole window"
        case .invertContent: return "Invert content only"
        case .switchStyle: return "Switch invert style"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .invertWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(optionKey))
        case .invertContent: return KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(optionKey))
        case .switchStyle: return KeyCombo(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(optionKey))
        }
    }

    private var defaultsKey: String { "shortcut.\(rawValue)" }

    /// nil means the shortcut was cleared by the user.
    var combo: KeyCombo? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: defaultsKey) else { return defaultCombo }
            return KeyCombo(storageString: stored)
        }
        nonmutating set {
            UserDefaults.standard.set(newValue?.storageString ?? "", forKey: defaultsKey)
        }
    }
}
