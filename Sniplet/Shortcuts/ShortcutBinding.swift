import AppKit
import Carbon

nonisolated struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    static func defaultBinding(for mode: CaptureMode) -> ShortcutBinding {
        switch mode {
        case .region:
            ShortcutBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey | cmdKey))
        case .window:
            ShortcutBinding(keyCode: 23, modifiers: UInt32(controlKey | optionKey | cmdKey))
        case .fullScreen:
            ShortcutBinding(keyCode: 20, modifiers: UInt32(controlKey | optionKey | cmdKey))
        case .previousRegion:
            ShortcutBinding(keyCode: 21, modifiers: UInt32(controlKey | optionKey | cmdKey))
        }
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

nonisolated enum ShortcutPolicy {
    static func validationError(_ binding: ShortcutBinding, otherBindings: [ShortcutBinding], systemBindings: [ShortcutBinding], menuBindings: [ShortcutBinding]) -> String? {
        guard binding.keyCode <= 126, binding.keyCode != 53,
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(binding.keyCode),
              binding.modifiers & ~ShortcutBinding.modifierMask == 0,
              binding.modifiers & UInt32(cmdKey | controlKey) != 0 else {
            return "快捷键必须包含 Command 或 Control，不能只含修饰键或 Escape。"
        }
        if otherBindings.contains(binding) { return "此快捷键已用于另一个截图动作。" }
        if menuBindings.contains(binding) { return "此快捷键与 Sniplet 菜单命令冲突。" }
        if systemBindings.contains(binding) { return "此快捷键已由启用的系统快捷键使用。" }
        return nil
    }
}

@MainActor enum ShortcutKeyNames {
    private static let special: [UInt32: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]
    static func key(_ code: UInt32) -> String {
        if let value = special[code] { return value }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "键码 \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "键码 \(code)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        return withUnsafeTemporaryAllocation(of: UniChar.self, capacity: 8) { characters in
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKey, characters.count, &length, characters.baseAddress)
            guard status == noErr, length > 0 else { return "键码 \(code)" }
            return String(utf16CodeUnits: characters.baseAddress!, count: length).uppercased()
        }
    }

    static func description(_ binding: ShortcutBinding) -> String {
        var result = ""
        if binding.modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if binding.modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if binding.modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if binding.modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + key(binding.keyCode)
    }
}
