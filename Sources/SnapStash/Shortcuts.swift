import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored with Carbon key codes and modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(truncatingIfNeeded: max(keyCode, 0))
        self.modifiers = UInt32(truncatingIfNeeded: max(modifiers, 0))
    }

    /// A real key with ⌘, ⌥ or ⌃. Saved shortcuts are checked against this, so damaged settings
    /// fall back to the default instead of registering garbage.
    var isValid: Bool {
        keyCode < 128 && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// From a key event, or nil if it has no ⌘, ⌥ or ⌃ (a bare key can't be a global shortcut).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        guard carbon & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: carbon)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The character the key produces on the current keyboard layout (so it's right on AZERTY etc.).
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(truncatingIfNeeded: keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers Carbon hot keys (no Accessibility permission needed) and routes presses by ID.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private static let signature = OSType(0x534E5053) // 'SNPS'

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.actions[id.id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns false if the shortcut is already taken by another app.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("Shortcut \(shortcut.display, privacy: .public) is taken (status \(status))")
            return false
        }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }
}
