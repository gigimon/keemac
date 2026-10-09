import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcut that opens Quick Access, stored as a virtual key code plus modifiers.
public struct QuickAccessShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, device-independent bits only.
    public var modifiers: UInt
    /// What the key prints on its own ("K", "Space", "F5").
    public var keyName: String

    public static let `default` = QuickAccessShortcut(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
        keyName: "K"
    )

    public init(keyCode: UInt32, modifiers: UInt, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Reads a shortcut from a key press; nil when the press can't be a global shortcut
    /// (no ⌘, ⌥ or ⌃, except for function keys).
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        let name = Self.specialKeyNames[keyCode]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
            ?? ""
        let isFunctionKey = Self.functionKeyCodes.contains(keyCode)
        guard !name.isEmpty, isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }
        self.init(keyCode: UInt32(keyCode), modifiers: flags.rawValue, keyName: name)
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// "⌥⌘K", modifiers in the order macOS menus use.
    public var displayString: String {
        let flags = modifierFlags
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyName
    }

    /// The same shortcut for a menu item, when SwiftUI can express its key.
    public var keyboardShortcut: KeyboardShortcut? {
        let key: KeyEquivalent
        if keyName == "Space" {
            key = .space
        } else if keyName.count == 1, let character = keyName.lowercased().first {
            key = KeyEquivalent(character)
        } else {
            return nil
        }
        let flags = modifierFlags
        var modifiers: SwiftUI.EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    private static let specialKeyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "↩",
            kVK_Tab: "⇥",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟"
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()
}

/// How long a database unlocked from Quick Access stays unlocked after the panel closes.
/// Doesn't apply when the database was already unlocked.
public enum QuickAccessUnlockDuration: Int, CaseIterable, Codable, Sendable {
    case singleUse = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case untilAutoLock = -1

    /// Seconds before locking again; nil keeps the database unlocked until the usual auto-lock.
    public var relockDelay: TimeInterval? {
        self == .untilAutoLock ? nil : TimeInterval(rawValue)
    }

    public var title: String {
        switch self {
        case .singleUse:
            return L("Lock after closing")
        case .oneMinute, .fiveMinutes, .fifteenMinutes:
            return L("\(rawValue / 60) minutes")
        case .untilAutoLock:
            return L("Until auto-lock")
        }
    }
}

/// One system-wide hotkey through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    private static var handler: (() -> Void)?
    private static var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(onPress: @escaping () -> Void) {
        Self.handler = onPress
        Self.installEventHandlerIfNeeded()
    }

    /// Returns false when macOS refuses the shortcut (another app already holds it).
    @discardableResult
    func register(_ shortcut: QuickAccessShortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4B4D_5141), id: 1) // "KMQA"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in
                GlobalHotKey.handler?()
            }
            return noErr
        }, 1, &spec, nil, &eventHandlerRef)
    }
}
