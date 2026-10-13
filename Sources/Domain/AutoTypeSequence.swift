import Foundation

/// A key Auto-Type presses by name (`{TAB}`, `{F5}`), not by the character it types.
public enum AutoTypeKey: Equatable, Hashable, Sendable {
    case tab
    case enter
    case space
    case backspace
    case delete
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case insert
    /// F1…F16.
    case function(Int)
}

public struct AutoTypeModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = AutoTypeModifiers(rawValue: 1 << 0)
    public static let control = AutoTypeModifiers(rawValue: 1 << 1)
    public static let option = AutoTypeModifiers(rawValue: 1 << 2)
    public static let command = AutoTypeModifiers(rawValue: 1 << 3)
}

/// One step of a parsed sequence, before field placeholders are filled in.
public enum AutoTypeToken: Equatable, Sendable {
    /// Characters typed as they are.
    case text(String)
    /// A character pressed with modifiers, like `^a` (⌘A).
    case character(Character, AutoTypeModifiers)
    case key(AutoTypeKey, AutoTypeModifiers)
    /// A field or value to type: `USERNAME`, `PASSWORD`, `S:Email`, `REF:P@I:…`, `TOTP`.
    case placeholder(String)
    /// Pause in milliseconds (`{DELAY 500}`).
    case delay(Int)
    /// New pause between keystrokes in milliseconds (`{DELAY=50}`).
    case keyDelay(Int)
    /// Select everything in the field and delete it.
    case clearField
}

/// What the typist does, with every placeholder replaced by its value.
public enum AutoTypeAction: Equatable, Sendable {
    case text(String)
    case character(Character, AutoTypeModifiers)
    case key(AutoTypeKey, AutoTypeModifiers)
    case delay(Int)
    case keyDelay(Int)
    case clearField
}

public enum AutoTypeSequenceError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case missingClosingBrace
    case unexpectedClosingBrace
    /// The command between the braces, e.g. `{PASWORD}`.
    case unknownCommand(String)

    public var errorDescription: String? {
        message
    }

    /// The text the editor shows; `unknownCommand` ends with the command so the UI can highlight it.
    public var message: String {
        switch self {
        case .empty:
            return L("Sequence is empty")
        case .missingClosingBrace:
            return L("Missing } in sequence")
        case .unexpectedClosingBrace:
            return L("Unexpected } in sequence")
        case .unknownCommand(let command):
            return L("Unknown command \(command)")
        }
    }
}

/// KeePass Auto-Type sequences: `{USERNAME}{TAB}{PASSWORD}{ENTER}`.
///
/// Placeholders become their own tokens, so a password containing `{`, `+` or `~` is typed literally.
/// Modifiers: `+` Shift, `^` Command (KeePass's Ctrl, so `^a` selects all on a Mac), `%` Option,
/// `@` and `#` Control. They apply to the next character, `{KEY}` or `(group)`.
public enum AutoTypeSequence {
    /// Field placeholders KeeMac fills in.
    public static let placeholders: Set<String> = ["USERNAME", "PASSWORD", "TITLE", "URL", "NOTES", "UUID", "TOTP", "HMACOTP"]
    /// Prefixes of placeholders with an argument (`{S:Email}`, `{REF:P@I:…}`).
    public static let placeholderPrefixes = ["S:", "REF:"]

    private static let keyNames: [String: AutoTypeKey] = {
        var names: [String: AutoTypeKey] = [
            "TAB": .tab,
            "ENTER": .enter,
            "SPACE": .space,
            "BACKSPACE": .backspace,
            "BS": .backspace,
            "BKSP": .backspace,
            "DELETE": .delete,
            "DEL": .delete,
            "ESC": .escape,
            "UP": .up,
            "DOWN": .down,
            "LEFT": .left,
            "RIGHT": .right,
            "HOME": .home,
            "END": .end,
            "PGUP": .pageUp,
            "PGDN": .pageDown,
            "INSERT": .insert,
            "INS": .insert
        ]
        for number in 1...16 {
            names["F\(number)"] = .function(number)
        }
        return names
    }()

    private static let literalNames: [String: Character] = [
        "PLUS": "+",
        "PERCENT": "%",
        "CARET": "^",
        "TILDE": "~",
        "AT": "@",
        "LEFTPAREN": "(",
        "RIGHTPAREN": ")",
        "LEFTBRACE": "{",
        "RIGHTBRACE": "}"
    ]

    private static let escapable: Set<Character> = ["+", "^", "%", "~", "@", "#", "(", ")", "{", "}", "[", "]"]

    /// Nil when the sequence can be typed.
    public static func validate(_ sequence: String) -> AutoTypeSequenceError? {
        do {
            _ = try parse(sequence)
            return nil
        } catch let error as AutoTypeSequenceError {
            return error
        } catch {
            return .empty
        }
    }

    public static func parse(_ sequence: String) throws -> [AutoTypeToken] {
        guard !sequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutoTypeSequenceError.empty
        }
        var parser = Parser(characters: Array(sequence))
        return try parser.parseAll()
    }

    /// Fills in placeholders and merges neighbouring text. `value` gets the placeholder's name as written
    /// (`USERNAME`, `S:Email`) and returns what to type.
    public static func resolve(_ tokens: [AutoTypeToken], value: (String) throws -> String) rethrows -> [AutoTypeAction] {
        var actions: [AutoTypeAction] = []
        func appendText(_ text: String) {
            guard !text.isEmpty else {
                return
            }
            if case .text(let previous) = actions.last {
                actions[actions.count - 1] = .text(previous + text)
            } else {
                actions.append(.text(text))
            }
        }
        for token in tokens {
            switch token {
            case .text(let text):
                appendText(text)
            case .placeholder(let name):
                appendText(try value(name))
            case .character(let character, let modifiers):
                actions.append(.character(character, modifiers))
            case .key(let key, let modifiers):
                actions.append(.key(key, modifiers))
            case .delay(let milliseconds):
                actions.append(.delay(milliseconds))
            case .keyDelay(let milliseconds):
                actions.append(.keyDelay(milliseconds))
            case .clearField:
                actions.append(.clearField)
            }
        }
        return actions
    }

    /// Placeholder names a sequence uses (`TOTP`, `S:Email`), upper-cased except for the argument.
    public static func placeholders(in sequence: String) -> [String] {
        ((try? parse(sequence)) ?? []).compactMap { token in
            if case .placeholder(let name) = token {
                return name
            }
            return nil
        }
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        mutating func parseAll() throws -> [AutoTypeToken] {
            var tokens: [AutoTypeToken] = []
            while index < characters.count {
                tokens.append(contentsOf: try parseItem(modifiers: [], inGroup: false))
            }
            return tokens
        }

        /// One character, command or modified group, with the modifiers in front of it.
        mutating func parseItem(modifiers: AutoTypeModifiers, inGroup: Bool) throws -> [AutoTypeToken] {
            let character = characters[index]
            index += 1
            switch character {
            case "+":
                return try parseModified(modifiers.union(.shift), inGroup: inGroup)
            case "^":
                return try parseModified(modifiers.union(.command), inGroup: inGroup)
            case "%":
                return try parseModified(modifiers.union(.option), inGroup: inGroup)
            case "@", "#":
                return try parseModified(modifiers.union(.control), inGroup: inGroup)
            case "~":
                return [.key(.enter, modifiers)]
            case "{":
                return try parseCommand(modifiers: modifiers)
            case "}":
                throw AutoTypeSequenceError.unexpectedClosingBrace
            default:
                return [modifiers.isEmpty ? .text(String(character)) : .character(character, modifiers)]
            }
        }

        /// After a modifier: the next item, or every item of a `( … )` group, gets the modifiers.
        mutating func parseModified(_ modifiers: AutoTypeModifiers, inGroup: Bool) throws -> [AutoTypeToken] {
            guard index < characters.count else {
                return []
            }
            guard characters[index] == "(" else {
                return try parseItem(modifiers: modifiers, inGroup: inGroup)
            }
            index += 1
            var tokens: [AutoTypeToken] = []
            while index < characters.count, characters[index] != ")" {
                tokens.append(contentsOf: try parseItem(modifiers: modifiers, inGroup: true))
            }
            if index < characters.count {
                index += 1
            }
            return tokens
        }

        mutating func parseCommand(modifiers: AutoTypeModifiers) throws -> [AutoTypeToken] {
            // `{}}` and `{{}` are a literal brace.
            if index + 1 < characters.count, characters[index] == "}" || characters[index] == "{", characters[index + 1] == "}" {
                let brace = characters[index]
                index += 2
                return [literal(brace, modifiers: modifiers)]
            }
            guard let close = characters[index...].firstIndex(of: "}") else {
                throw AutoTypeSequenceError.missingClosingBrace
            }
            let content = String(characters[index..<close])
            guard !content.contains("{") else {
                throw AutoTypeSequenceError.missingClosingBrace
            }
            index = close + 1
            return try command(content, modifiers: modifiers)
        }

        func command(_ content: String, modifiers: AutoTypeModifiers) throws -> [AutoTypeToken] {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            let unknown = AutoTypeSequenceError.unknownCommand("{\(content)}")

            if let character = trimmed.first, trimmed.count == 1, AutoTypeSequence.escapable.contains(character) {
                return [literal(character, modifiers: modifiers)]
            }
            if let character = AutoTypeSequence.literalNames[upper] {
                return [literal(character, modifiers: modifiers)]
            }
            if upper == "CLEARFIELD" {
                return [.clearField]
            }
            if upper.hasPrefix("DELAY") {
                let rest = upper.dropFirst(5)
                if rest.first == "=", let value = Int(rest.dropFirst().trimmingCharacters(in: .whitespaces)), value >= 0 {
                    return [.keyDelay(min(value, 10_000))]
                }
                if rest.first == " ", let value = Int(rest.trimmingCharacters(in: .whitespaces)), value >= 0 {
                    return [.delay(min(value, 60_000))]
                }
                throw unknown
            }
            if AutoTypeSequence.placeholders.contains(upper) {
                return [.placeholder(upper)]
            }
            for prefix in AutoTypeSequence.placeholderPrefixes where upper.hasPrefix(prefix) && trimmed.count > prefix.count {
                return [.placeholder(prefix + trimmed.dropFirst(prefix.count))]
            }

            // `{TAB}` or `{TAB 3}`.
            let parts = upper.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = parts.first, let key = AutoTypeSequence.keyNames[String(name)] else {
                throw unknown
            }
            if parts.count == 1 {
                return [.key(key, modifiers)]
            }
            guard parts.count == 2, let count = Int(parts[1]), count >= 0 else {
                throw unknown
            }
            return Array(repeating: .key(key, modifiers), count: min(count, 100))
        }

        func literal(_ character: Character, modifiers: AutoTypeModifiers) -> AutoTypeToken {
            modifiers.isEmpty ? .text(String(character)) : .character(character, modifiers)
        }
    }
}
