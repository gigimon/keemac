import AppKit
import Domain
import SwiftUI

// MARK: - Suggestions

/// Values already used in the database, offered while typing in unprotected fields.
/// Protected fields (passwords, protected custom fields) are never collected.
struct FieldCompletions: Equatable {
    var titles: [String] = []
    var usernames: [String] = []
    var urls: [String] = []
    var tags: [String] = []
    /// Hosts of `ssh://` servers.
    var hosts: [String] = []
    /// Unprotected custom field values by field name.
    var customValues: [String: [String]] = [:]

    static let empty = FieldCompletions()

    init() {}

    init(entries: [VaultEntry]) {
        let live = entries.filter { !$0.isTrashed }
        titles = Self.ranked(live.map(\.title))
        usernames = Self.ranked(live.compactMap(\.username))
        urls = Self.ranked(live.compactMap { $0.url?.absoluteString })
        tags = Self.ranked(live.flatMap(\.tags))
        hosts = Self.ranked(live.compactMap { $0.url?.scheme == "ssh" ? $0.url?.host() : nil })
        var values: [String: [String]] = [:]
        for entry in live {
            for field in entry.customFields where !field.isProtected {
                values[field.key, default: []].append(field.value)
            }
        }
        customValues = values.mapValues(Self.ranked)
    }

    /// Most used first, so the first prefix match is the likeliest one.
    private static func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unresolved references and placeholders are not useful suggestions.
            guard !trimmed.isEmpty, !trimmed.contains("{") else {
                continue
            }
            if counts[trimmed] == nil {
                order.append(trimmed)
            }
            counts[trimmed, default: 0] += 1
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let left = counts[lhs.element] ?? 0
                let right = counts[rhs.element] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The first suggestion that starts with `typed` (any case) and is longer.
    static func complete(_ typed: String, from suggestions: [String]) -> String? {
        guard !typed.isEmpty else {
            return nil
        }
        let lowered = typed.lowercased()
        guard let match = suggestions.first(where: { $0.count > typed.count && $0.lowercased().hasPrefix(lowered) }) else {
            return nil
        }
        // Keep what the user typed as typed; only the rest comes from the suggestion.
        return typed + match.dropFirst(typed.count)
    }

    /// Completes the last tag in a comma-separated list.
    static func completeTag(_ typed: String, from tags: [String]) -> String? {
        let separator = typed.lastIndex(of: ",").map { typed.index(after: $0) } ?? typed.startIndex
        let head = typed[..<separator]
        let token = typed[separator...]
        let leading = token.prefix { $0 == " " }
        let word = String(token.dropFirst(leading.count))
        let used = Set(head.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        guard let completed = complete(word, from: tags.filter { !used.contains($0.lowercased()) }) else {
            return nil
        }
        return String(head) + leading + completed
    }
}

private struct FieldCompletionsKey: EnvironmentKey {
    static let defaultValue = FieldCompletions.empty
}

extension EnvironmentValues {
    var fieldCompletions: FieldCompletions {
        get { self[FieldCompletionsKey.self] }
        set { self[FieldCompletionsKey.self] = newValue }
    }
}

// MARK: - Field

/// A plain text field that completes the value inline, like KeePassXC: the rest of a matching
/// value appears selected; Tab, → or Return accept it, typing on replaces it, Esc removes it.
struct CompletingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 13)
    /// Returns the completed full text for what was typed, or nil.
    let completer: (String) -> String?
    var isFocused: Binding<Bool>?
    var onSubmit: () -> Void = {}
    /// Set on the text field itself, where UI tests look for it.
    var identifier: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.setFocused(true)
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: field)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        apply(to: field)
        if !context.coordinator.isEditing, field.stringValue != text {
            field.stringValue = text
        }
        if isFocused?.wrappedValue == true, !context.coordinator.isEditing, let window = field.window {
            DispatchQueue.main.async {
                if window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                }
            }
        }
    }

    private func apply(to field: NSTextField) {
        field.font = font
        field.setAccessibilityIdentifier(identifier)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: font]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingTextField
        private(set) var isEditing = false
        /// Length of the user's own text while a completion is shown after it.
        private var typedLength: Int?
        private var suppressNextCompletion = false

        init(parent: CompletingTextField) {
            self.parent = parent
        }

        func setFocused(_ focused: Bool) {
            if parent.isFocused?.wrappedValue != focused {
                parent.isFocused?.wrappedValue = focused
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
            setFocused(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                dropCompletion(in: editor)
            }
            typedLength = nil
            isEditing = false
            setFocused(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else {
                return
            }
            let typed = editor.string
            typedLength = nil
            defer {
                parent.text = typedLength.map { String(editor.string.prefix($0)) } ?? editor.string
            }
            if suppressNextCompletion {
                suppressNextCompletion = false
                return
            }
            // Only complete when typing at the end.
            guard editor.selectedRange().location == (typed as NSString).length,
                  let completed = parent.completer(typed),
                  completed.count > typed.count else {
                return
            }
            let typedUTF16 = (typed as NSString).length
            editor.string = completed
            editor.setSelectedRange(NSRange(location: typedUTF16, length: (completed as NSString).length - typedUTF16))
            typedLength = typed.count
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
                // Deleting shouldn't bring the completion straight back.
                suppressNextCompletion = true
                return false
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveToEndOfLine(_:)),
                 #selector(NSResponder.moveToEndOfDocument(_:)):
                return acceptCompletion(in: textView)
            case #selector(NSResponder.insertNewline(_:)):
                if acceptCompletion(in: textView) {
                    return true
                }
                parent.onSubmit()
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                if typedLength != nil {
                    dropCompletion(in: textView)
                    return true
                }
                return false
            default:
                return false
            }
        }

        private func acceptCompletion(in textView: NSTextView) -> Bool {
            guard typedLength != nil else {
                return false
            }
            typedLength = nil
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            parent.text = textView.string
            return true
        }

        private func dropCompletion(in textView: NSTextView) {
            guard let typedLength else {
                return
            }
            self.typedLength = nil
            let typed = String(textView.string.prefix(typedLength))
            textView.string = typed
            parent.text = typed
        }
    }
}

/// Reports becoming first responder so SwiftUI focus rings follow clicks into the field.
private final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }
}

// MARK: - Convenience

extension CompletingTextField {
    func fieldIdentifier(_ identifier: String) -> CompletingTextField {
        var field = self
        field.identifier = identifier
        return field
    }

    /// Completes from a list of earlier values.
    init(
        _ placeholder: String,
        text: Binding<String>,
        suggestions: [String],
        font: NSFont = .systemFont(ofSize: 13),
        isFocused: Binding<Bool>? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.init(
            text: text,
            placeholder: placeholder,
            font: font,
            completer: { FieldCompletions.complete($0, from: suggestions) },
            isFocused: isFocused,
            onSubmit: onSubmit
        )
    }
}
