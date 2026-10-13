import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Domain

/// Accessibility access, which Auto-Type needs to read window titles and post keystrokes.
@MainActor
enum AccessibilityPermission {
    static var isGranted: Bool {
        if UITesting.isActive {
            return UITesting.autoTypePermissionGranted
        }
        return AXIsProcessTrusted()
    }

    /// Adds KeeMac to the Accessibility list (switched off) so the user only has to turn it on.
    static func request() {
        guard !UITesting.isActive else {
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        guard !UITesting.isActive,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// The frontmost window of another app, read through Accessibility.
struct AutoTypeTarget: Equatable {
    let window: AutoTypeWindow
    let processIdentifier: pid_t
    let appIcon: NSImage?

    static func == (lhs: AutoTypeTarget, rhs: AutoTypeTarget) -> Bool {
        lhs.window == rhs.window && lhs.processIdentifier == rhs.processIdentifier
    }
}

@MainActor
enum AutoTypeWindowReader {
    /// Browsers whose tab address can be read: Safari through the window's document, Chromium
    /// browsers through their address field.
    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Nil when the frontmost app is KeeMac or nothing is in front.
    static func frontmostTarget() -> AutoTypeTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let window: AXUIElement? = attribute(element, kAXFocusedWindowAttribute)
        let title = window.flatMap { stringAttribute($0, kAXTitleAttribute) } ?? ""
        var url: String?
        if let window, let bundleID = app.bundleIdentifier, browserBundleIdentifiers.contains(bundleID) {
            url = browserURL(in: window)
        }
        return AutoTypeTarget(
            window: AutoTypeWindow(
                appName: app.localizedName ?? app.bundleIdentifier ?? "",
                bundleIdentifier: app.bundleIdentifier,
                title: title,
                url: url
            ),
            processIdentifier: app.processIdentifier,
            appIcon: app.icon
        )
    }

    /// Safari's window document, a web area's URL, or the address field's text.
    private static func browserURL(in window: AXUIElement) -> String? {
        if let document = stringAttribute(window, kAXDocumentAttribute), document.contains("://") {
            return document
        }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var addressField: String?
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url: CFURL = attribute(element, kAXURLAttribute) {
                    return (url as URL).absoluteString
                }
                continue
            }
            if role == kAXTextFieldRole, addressField == nil,
               let value = stringAttribute(element, kAXValueAttribute), looksLikeAddress(value) {
                addressField = value
            }
            guard depth < 12, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else {
                continue
            }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        guard let addressField else {
            return nil
        }
        return addressField.contains("://") ? addressField : "https://" + addressField
    }

    private static func looksLikeAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else {
            return false
        }
        if trimmed.contains("://") {
            return true
        }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? ""
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as String?
    }
}

/// Posts the keystrokes of a resolved sequence.
@MainActor
protocol AutoTypeTypist: AnyObject {
    func type(_ actions: [AutoTypeAction], keyDelay: Int) async throws
}

/// Types into whatever app is in front with Quartz keyboard events. Text goes as Unicode, so the
/// keyboard layout doesn't matter; named keys and shortcuts use virtual key codes.
@MainActor
final class SystemAutoTypeTypist: AutoTypeTypist {
    private let source = CGEventSource(stateID: .privateState)

    func type(_ actions: [AutoTypeAction], keyDelay: Int) async throws {
        var delay = keyDelay
        for action in actions {
            try Task.checkCancellation()
            switch action {
            case .text(let text):
                for character in text {
                    try Task.checkCancellation()
                    switch character {
                    case "\n", "\r", "\r\n":
                        press(keyCode: CGKeyCode(kVK_Return), flags: [])
                    case "\t":
                        press(keyCode: CGKeyCode(kVK_Tab), flags: [])
                    default:
                        typeUnicode(String(character))
                    }
                    try await pause(delay)
                }
            case .character(let character, let modifiers):
                pressCharacter(character, flags: Self.flags(modifiers))
                try await pause(delay)
            case .key(let key, let modifiers):
                press(keyCode: Self.keyCode(key), flags: Self.flags(modifiers))
                try await pause(delay)
            case .delay(let milliseconds):
                try await Task.sleep(for: .milliseconds(milliseconds))
            case .keyDelay(let milliseconds):
                delay = milliseconds
            case .clearField:
                press(keyCode: CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
                try await pause(max(delay, 20))
                press(keyCode: CGKeyCode(kVK_Delete), flags: [])
                try await pause(delay)
            }
        }
    }

    private func pause(_ milliseconds: Int) async throws {
        guard milliseconds > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func typeUnicode(_ text: String) {
        let units = Array(text.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
                continue
            }
            event.flags = []
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func pressCharacter(_ character: Character, flags: CGEventFlags) {
        guard let keyCode = Self.ansiKeyCodes[Character(character.lowercased())] else {
            typeUnicode(String(character))
            return
        }
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                continue
            }
            event.flags = flags
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func press(keyCode: CGKeyCode, flags: CGEventFlags) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                continue
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func flags(_ modifiers: AutoTypeModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    static func keyCode(_ key: AutoTypeKey) -> CGKeyCode {
        let code: Int
        switch key {
        case .tab: code = kVK_Tab
        case .enter: code = kVK_Return
        case .space: code = kVK_Space
        case .backspace: code = kVK_Delete
        case .delete: code = kVK_ForwardDelete
        case .escape: code = kVK_Escape
        case .up: code = kVK_UpArrow
        case .down: code = kVK_DownArrow
        case .left: code = kVK_LeftArrow
        case .right: code = kVK_RightArrow
        case .home: code = kVK_Home
        case .end: code = kVK_End
        case .pageUp: code = kVK_PageUp
        case .pageDown: code = kVK_PageDown
        case .insert: code = kVK_Help
        case .function(let number):
            let functionKeys = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16
            ]
            code = functionKeys[min(max(number, 1), functionKeys.count) - 1]
        }
        return CGKeyCode(code)
    }

    /// Keys of a U.S. keyboard, for shortcuts such as `^a`.
    private static let ansiKeyCodes: [Character: CGKeyCode] = {
        let pairs: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket),
            ("]", kVK_ANSI_RightBracket), (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma),
            (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash), ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave)
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, CGKeyCode($0.1)) })
    }()
}

/// Keeps what would have been typed, for tests and the UI testing mode.
@MainActor
final class RecordingAutoTypeTypist: AutoTypeTypist {
    private(set) var typed: [[AutoTypeAction]] = []

    func type(_ actions: [AutoTypeAction], keyDelay: Int) async throws {
        typed.append(actions)
    }
}

@MainActor
enum AutoTypeKeyboard {
    /// Another app (Terminal's Secure Keyboard Entry, a password prompt) blocks synthetic keystrokes.
    static var isSecureInputOn: Bool {
        !UITesting.isActive && IsSecureEventInputEnabled()
    }

    /// Waits until the hotkey's modifiers are up, so they don't change the typed keys. False after the timeout.
    static func waitForModifierRelease(timeout: Duration = .seconds(3)) async -> Bool {
        guard !UITesting.isActive else {
            return true
        }
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
