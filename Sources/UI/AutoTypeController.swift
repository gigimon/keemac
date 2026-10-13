import AppKit
import Data
import Domain

/// Auto-Type: a global shortcut types the entry for the frontmost window of another app.
/// One match types right away; otherwise Quick Access opens in Auto-Type mode to pick one.
@MainActor
public final class AutoTypeController {
    public static let shared = AutoTypeController()

    /// Set when the shortcut can't be registered, usually because another app holds it.
    public private(set) var shortcutConflict = false

    private weak var viewModel: AppViewModel?
    private let settings = AppSettingsStore.shared
    private var hotKey: GlobalHotKey?
    private var typingTask: Task<Void, Never>?
    /// Escape pressed in any app while KeeMac types.
    private var escapeMonitor: Any?
    let typist: any AutoTypeTypist = UITesting.isActive ? RecordingAutoTypeTypist() : SystemAutoTypeTypist()

    private init() {}

    public func configure(viewModel: AppViewModel) {
        attach(viewModel)
        hotKey = GlobalHotKey { [weak self] in
            self?.perform()
        }
        updateHotKey()
    }

    /// The database Auto-Type reads, without the global shortcut (tests use this alone).
    func attach(_ viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    /// Registers the shortcut from settings again (after it changed or was turned off).
    public func updateHotKey() {
        guard let hotKey, !UITesting.isActive else {
            return
        }
        guard settings.autoTypeEnabled else {
            hotKey.unregister()
            shortcutConflict = false
            return
        }
        shortcutConflict = !hotKey.register(settings.autoTypeShortcut)
    }

    /// Lets the shortcut recorder see the current shortcut instead of typing.
    public func suspendHotKey() {
        hotKey?.unregister()
    }

    /// "Edit Entry" in a failure notice: the entry's editor with the Auto-Type section open.
    func revealForEditing(_ entryID: UUID) {
        viewModel?.requestReveal([entryID], editingAutoType: true)
    }

    /// Stops typing right away (Escape, or the database locked).
    public func cancelTyping() {
        typingTask?.cancel()
    }

    /// The shortcut was pressed.
    public func perform() {
        guard settings.autoTypeEnabled, typingTask == nil else {
            return
        }
        // An open Quick Access panel holds the keyboard although another app is in front.
        QuickAccessController.shared.close()
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.request()
            AutoTypeNoticeController.shared.show(.permission)
            return
        }
        guard let target = AutoTypeWindowReader.frontmostTarget() else {
            NSSound.beep()
            return
        }
        start(target)
    }

    /// The UI tests' stand-in for the shortcut: a made-up browser window, keystrokes recorded.
    public func performForUITesting() {
        guard UITesting.isActive, typingTask == nil else {
            return
        }
        guard AccessibilityPermission.isGranted else {
            AutoTypeNoticeController.shared.show(.permission)
            return
        }
        start(AutoTypeTarget(window: UITesting.autoTypeWindow, processIdentifier: 0, appIcon: nil))
    }

    private func start(_ target: AutoTypeTarget) {
        if let entries = mainEntries {
            let matches = AutoTypeMatcher.matches(in: entries, window: target.window)
            if matches.count == 1, let match = matches.first {
                type(match.entry, sequence: match.sequence, into: target)
                return
            }
        }
        QuickAccessController.shared.showAutoType(target: target)
    }

    /// Main database entries, nil while it is locked.
    var mainEntries: [VaultEntry]? {
        guard let viewModel, case .loaded(let vault) = viewModel.loadState else {
            return nil
        }
        return vault.entries
    }

    /// Called by the picker; uses the entry's association for the window if it has one.
    /// False when another sequence is still being typed.
    @discardableResult
    func type(_ entry: VaultEntry, into target: AutoTypeTarget) -> Bool {
        type(entry, sequence: AutoTypeMatcher.sequence(for: entry, window: target.window), into: target)
    }

    @discardableResult
    private func type(_ entry: VaultEntry, sequence: String, into target: AutoTypeTarget) -> Bool {
        guard typingTask == nil else {
            return false
        }
        typingTask = Task { [weak self] in
            await self?.run(entry, sequence: sequence, target: target)
            self?.typingTask = nil
            QuickAccessController.shared.autoTypeDidFinish()
        }
        return true
    }

    private func run(_ entry: VaultEntry, sequence: String, target: AutoTypeTarget) async {
        let notices = AutoTypeNoticeController.shared
        let tokens: [AutoTypeToken]
        do {
            tokens = try AutoTypeSequence.parse(sequence)
        } catch {
            notices.show(.failed(error as? AutoTypeSequenceError ?? .empty, entryTitle: entry.title, entryID: entry.id))
            return
        }

        // Everything that can stop typing comes before the values: an HOTP code is used up when it is resolved.
        guard await bringToFront(target), await AutoTypeKeyboard.waitForModifierRelease() else {
            NSSound.beep()
            return
        }
        guard !AutoTypeKeyboard.isSecureInputOn else {
            notices.show(.secureInput(appName: target.window.appName))
            return
        }

        let actions: [AutoTypeAction]
        do {
            actions = try await resolve(tokens, for: entry)
        } catch let error as AutoTypeSequenceError {
            notices.show(.failed(error, entryTitle: entry.title, entryID: entry.id))
            return
        } catch {
            notices.show(.message(title: L("Auto-Type failed"), body: error.localizedDescription))
            return
        }
        // Saving an HOTP counter takes a moment; focus may have moved meanwhile.
        guard !Task.isCancelled, isFront(target) else {
            notices.show(.interrupted(appName: target.window.appName))
            return
        }

        notices.show(.typing(entry: entry, appName: target.window.appName))
        startWatchingEscape()
        defer { stopWatchingEscape() }
        do {
            try await typist.type(actions, keyDelay: settings.autoTypeKeyDelay) { [weak self] in
                self?.isFront(target) ?? false
            }
        } catch is AutoTypeInterrupted {
            notices.show(.interrupted(appName: target.window.appName))
            return
        } catch {
            // Cancelled with Escape or because the database locked.
            notices.hideTyping()
            return
        }
        notices.hideTyping()
        viewModel?.recordEntryUsage(id: entry.id)
        viewModel?.registerUserActivity()
        if UITesting.isActive {
            recordForUITesting(actions)
        }
    }

    private func isFront(_ target: AutoTypeTarget) -> Bool {
        UITesting.isActive || AutoTypeWindowReader.isFront(target)
    }

    /// Escape in any app stops typing; KeeMac's own `{ESC}` keystrokes carry a marker and don't count.
    private func startWatchingEscape() {
        guard escapeMonitor == nil, !UITesting.isActive else {
            return
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) != autoTypeEventMarker else {
                return
            }
            Task { @MainActor in
                AutoTypeController.shared.cancelTyping()
            }
        }
    }

    private func stopWatchingEscape() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }

    /// The picker never activated KeeMac, but Touch ID or a click elsewhere may have moved focus.
    private func bringToFront(_ target: AutoTypeTarget) async -> Bool {
        guard !UITesting.isActive else {
            return true
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            return true
        }
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }
        app.activate()
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                // Give the window a moment to take the keyboard focus back.
                try? await Task.sleep(for: .milliseconds(80))
                return true
            }
        }
        return false
    }

    /// Fills in every placeholder; an HOTP code is used up once per sequence, however often it appears.
    func resolve(_ tokens: [AutoTypeToken], for entry: VaultEntry) async throws -> [AutoTypeAction] {
        usedHOTPCode = nil
        defer { usedHOTPCode = nil }
        var values: [String: String] = [:]
        for case .placeholder(let name) in tokens where values[name] == nil {
            values[name] = try await value(of: name, for: entry)
        }
        return AutoTypeSequence.resolve(tokens) { values[$0] ?? "" }
    }

    private var usedHOTPCode: (entryID: UUID, code: String)?

    private func value(of placeholder: String, for entry: VaultEntry) async throws -> String {
        switch placeholder {
        case "TOTP", "HMACOTP":
            return try await oneTimeCode(for: entry, counterBasedOnly: placeholder == "HMACOTP")
        default:
            break
        }
        if let value = entry.autoTypeValue(of: placeholder) {
            return value
        }
        if let value = await viewModel?.resolveAutoTypePlaceholder(placeholder, entryID: entry.id) {
            return value
        }
        throw AutoTypeSequenceError.unknownCommand("{\(placeholder)}")
    }

    private func oneTimeCode(for entry: VaultEntry, counterBasedOnly: Bool) async throws -> String {
        guard let otp = entry.otp else {
            return ""
        }
        guard otp.kind == .hotp else {
            return counterBasedOnly ? "" : OTPCodeGenerator.makeCodeState(from: otp, now: Date())?.code ?? ""
        }
        // `{TOTP}` and `{HMACOTP}` in one sequence are the same code.
        if let usedHOTPCode, usedHOTPCode.entryID == entry.id {
            return usedHOTPCode.code
        }
        guard let viewModel, let used = try await viewModel.advanceHOTPCounter(entryID: entry.id),
              let code = OTPCodeGenerator.code(secret: otp.secret, counter: used, digits: otp.digits, algorithm: otp.algorithm) else {
            return ""
        }
        usedHOTPCode = (entry.id, code)
        return code
    }

    /// Writes what would have been typed to the UI test pasteboard: text as is, keys as `{TAB}`.
    private func recordForUITesting(_ actions: [AutoTypeAction]) {
        let text = actions.map { action -> String in
            switch action {
            case .text(let text):
                return text
            case .character(let character, _):
                return "{\(character)}"
            case .key(let key, _):
                return "{\(key)}".uppercased()
            case .delay(let milliseconds):
                return "{DELAY \(milliseconds)}"
            case .keyDelay(let milliseconds):
                return "{DELAY=\(milliseconds)}"
            case .clearField:
                return "{CLEARFIELD}"
            }
        }.joined()
        let pasteboard = UITesting.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
