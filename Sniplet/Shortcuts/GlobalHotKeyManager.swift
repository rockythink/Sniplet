import AppKit
import Carbon
import Observation

@MainActor @Observable final class GlobalHotKeyManager {
    private(set) var errors: [CaptureMode: String] = [:]
    private(set) var bindings: [CaptureMode: ShortcutBinding] = [:]
    private(set) var recordingMode: CaptureMode?
    @ObservationIgnored private let onTrigger: (CaptureMode) -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var registrations: [CaptureMode: EventHotKeyRef] = [:]
    @ObservationIgnored private var eventIDs: [UInt32: CaptureMode] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var nextID: UInt32 = 1
    private static let signature: OSType = 0x534E4950 // SNIP
    static let modes: [CaptureMode] = [.region, .window, .fullScreen]

    init(onTrigger: @escaping (CaptureMode) -> Void) {
        self.onTrigger = onTrigger
        defaults = .standard
        loadBindings()
    }

    func registerSavedShortcuts() {
        unregisterAll()
        loadBindings()
        installHandler()
        guard handler != nil else { return }
        for mode in Self.modes {
            guard let binding = bindings[mode] else { continue }
            do {
                try validate(binding, for: mode)
                registrations[mode] = try register(binding, mode: mode)
                errors[mode] = nil
            } catch { errors[mode] = error.localizedDescription }
        }
    }

    func unregisterAll() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        eventIDs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        recordingMode = nil
    }

    func description(for mode: CaptureMode) -> String {
        bindings[mode].map(ShortcutKeyNames.description) ?? "未设置"
    }

    /// Register first; failures leave the previous binding and its persisted value intact.
    @discardableResult func set(_ binding: ShortcutBinding, for mode: CaptureMode) -> Bool {
        if bindings[mode] == binding, registrations[mode] != nil { errors[mode] = nil; return true }
        do {
            try validate(binding, for: mode)
            installHandler()
            guard handler != nil else { throw ShortcutRegistrationError.handler }
            let data = try JSONEncoder().encode(Optional(binding))
            let reference = try register(binding, mode: mode)
            if let old = registrations[mode] { UnregisterEventHotKey(old) }
            registrations[mode] = reference
            bindings[mode] = binding
            defaults.set(data, forKey: key(for: mode))
            errors[mode] = nil
            return true
        } catch {
            errors[mode] = error.localizedDescription
            return false
        }
    }

    func clear(_ mode: CaptureMode) {
        if let reference = registrations.removeValue(forKey: mode) { UnregisterEventHotKey(reference) }
        eventIDs = eventIDs.filter { $0.value != mode }
        bindings[mode] = nil
        // JSON null distinguishes an explicitly cleared action from an absent preference/default.
        defaults.set(Data("null".utf8), forKey: key(for: mode))
        errors[mode] = nil
    }

    @discardableResult func restoreDefault(for mode: CaptureMode) -> Bool {
        set(.defaultBinding(for: mode), for: mode)
    }

    func beginRecording(_ mode: CaptureMode) {
        if recordingMode == nil {
            for reference in registrations.values { UnregisterEventHotKey(reference) }
            registrations.removeAll()
            eventIDs.removeAll()
        }
        recordingMode = mode
    }

    func endRecording() {
        guard recordingMode != nil else { return }
        registerSavedShortcuts()
    }

    private func loadBindings() {
        bindings.removeAll()
        for mode in Self.modes {
            if let data = defaults.data(forKey: key(for: mode)) {
                do { bindings[mode] = try JSONDecoder().decode(ShortcutBinding?.self, from: data) }
                catch { errors[mode] = "保存的快捷键无法读取，请重新录制或恢复默认。" }
            } else { bindings[mode] = .defaultBinding(for: mode) }
        }
    }

    private func key(for mode: CaptureMode) -> String { "shortcuts.\(mode.rawValue)" }

    private func validate(_ binding: ShortcutBinding, for mode: CaptureMode) throws {
        let others = bindings.compactMap { $0.key == mode ? nil : $0.value }
        if let error = ShortcutPolicy.validationError(binding, otherBindings: others,
                                                      systemBindings: try systemBindings(), menuBindings: menuBindings(for: binding)) {
            throw ShortcutRegistrationError.policy(error)
        }
    }

    private func systemBindings() throws -> [ShortcutBinding] {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr, let array = raw?.takeRetainedValue() as? [[String: Any]] else {
            throw ShortcutRegistrationError.policy("无法读取系统快捷键以检查冲突，原绑定保持不变；请重试。")
        }
        return array.compactMap { item in
            guard (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let key = (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let modifiers = (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            return ShortcutBinding(keyCode: key, modifiers: modifiers & ShortcutBinding.modifierMask)
        }
    }

    private func menuBindings(for binding: ShortcutBinding) -> [ShortcutBinding] {
        // Also reserve responder-chain commands even when the menu-bar-extra's menu is closed.
        var result = [ShortcutBinding(keyCode: 12, modifiers: UInt32(cmdKey)), // Quit
                      ShortcutBinding(keyCode: 8, modifiers: UInt32(cmdKey)), // Copy
                      ShortcutBinding(keyCode: 1, modifiers: UInt32(cmdKey)), // Save
                      ShortcutBinding(keyCode: 43, modifiers: UInt32(cmdKey)), // Settings
                      ShortcutBinding(keyCode: 36, modifiers: UInt32(cmdKey)), // Finish
                      ShortcutBinding(keyCode: 6, modifiers: UInt32(cmdKey)), // Undo
                      ShortcutBinding(keyCode: 6, modifiers: UInt32(cmdKey | shiftKey))]
        let keyName = ShortcutKeyNames.key(binding.keyCode).lowercased()
        func append(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { append(submenu) }
                guard !item.keyEquivalent.isEmpty,
                      ShortcutBinding.modifiers(from: item.keyEquivalentModifierMask) == binding.modifiers,
                      keyName == item.keyEquivalent.lowercased() else { continue }
                result.append(binding)
            }
        }
        if let menu = NSApp.mainMenu { append(menu) }
        return result
    }

    private func installHandler() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            return MainActor.assumeIsolated {
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(context).takeUnretainedValue()
                guard id.signature == GlobalHotKeyManager.signature,
                      let mode = manager.eventIDs[id.id], manager.recordingMode == nil else { return OSStatus(eventNotHandledErr) }
                manager.onTrigger(mode)
                return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            handler = nil
            for mode in Self.modes { errors[mode] = ShortcutRegistrationError.handler.localizedDescription }
        }
    }

    private func register(_ binding: ShortcutBinding, mode: CaptureMode) throws -> EventHotKeyRef {
        let id = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw ShortcutRegistrationError.registration(status) }
        eventIDs = eventIDs.filter { $0.value != mode }
        eventIDs[id] = mode
        return reference
    }
}

nonisolated private enum ShortcutRegistrationError: LocalizedError {
    case handler
    case policy(String)
    case registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .handler: "无法安装系统快捷键处理程序；仍可从菜单截图。"
        case .policy(let message): message
        case .registration(let status): "快捷键注册失败（\(status)），可能已被其他应用使用。原快捷键保持不变。"
        }
    }
}
