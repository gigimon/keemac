import Foundation
import Observation

/// Everything the password generator can be set to; remembered between uses.
struct PasswordGeneratorOptions: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case password
        case passphrase

        var title: String {
            switch self {
            case .password: return L("Password")
            case .passphrase: return L("Passphrase")
            }
        }
    }

    enum Separator: String, Codable, CaseIterable, Sendable {
        case hyphen
        case space
        case dot
        case underscore
        case none
        case custom

        var title: String {
            switch self {
            case .hyphen: return L("Hyphen")
            case .space: return L("Space")
            case .dot: return L("Dot")
            case .underscore: return L("Underscore")
            case .none: return L("None")
            case .custom: return L("Custom")
            }
        }
    }

    static let defaultSymbols = "!@#$%^&*()-_=+[]{};:,.?/"
    static let lengthRange = 8...64
    static let wordsRange = 3...10

    var mode: Mode = .password
    var length = 20
    var lowercase = true
    var uppercase = true
    var digits = true
    var symbols = true
    var avoidLookAlikes = false
    var symbolSet = Self.defaultSymbols
    var words = 5
    var separator: Separator = .hyphen
    var customSeparator = ""
    var capitalize = false
    var addNumber = false

    init() {}

    init(from decoder: Decoder) throws {
        // Missing keys keep their defaults so older saved options still load.
        let defaults = PasswordGeneratorOptions()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(Mode.self, forKey: .mode)) ?? defaults.mode
        length = (try? container.decode(Int.self, forKey: .length)) ?? defaults.length
        lowercase = (try? container.decode(Bool.self, forKey: .lowercase)) ?? defaults.lowercase
        uppercase = (try? container.decode(Bool.self, forKey: .uppercase)) ?? defaults.uppercase
        digits = (try? container.decode(Bool.self, forKey: .digits)) ?? defaults.digits
        symbols = (try? container.decode(Bool.self, forKey: .symbols)) ?? defaults.symbols
        avoidLookAlikes = (try? container.decode(Bool.self, forKey: .avoidLookAlikes)) ?? defaults.avoidLookAlikes
        symbolSet = (try? container.decode(String.self, forKey: .symbolSet)) ?? defaults.symbolSet
        words = (try? container.decode(Int.self, forKey: .words)) ?? defaults.words
        separator = (try? container.decode(Separator.self, forKey: .separator)) ?? defaults.separator
        customSeparator = (try? container.decode(String.self, forKey: .customSeparator)) ?? defaults.customSeparator
        capitalize = (try? container.decode(Bool.self, forKey: .capitalize)) ?? defaults.capitalize
        addNumber = (try? container.decode(Bool.self, forKey: .addNumber)) ?? defaults.addNumber
    }

    var separatorString: String {
        switch separator {
        case .hyphen: return "-"
        case .space: return " "
        case .dot: return "."
        case .underscore: return "_"
        case .none: return ""
        case .custom: return customSeparator
        }
    }

    /// Number of character classes switched on; at least one always stays on.
    var enabledClassCount: Int {
        [lowercase, uppercase, digits, symbols].filter { $0 }.count
    }
}

enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let lookAlikes = Set("0Oo1lI|")

    /// The EFF large word list (7,776 words): https://www.eff.org/dice
    static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "eff_large_wordlist", withExtension: "txt", subdirectory: "WordLists"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()

    static func generate(_ options: PasswordGeneratorOptions) -> String {
        var rng = SystemRandomNumberGenerator()
        switch options.mode {
        case .password:
            return password(options, using: &rng)
        case .passphrase:
            return passphrase(options, using: &rng)
        }
    }

    /// Symbols that are actually used: no letters, digits or spaces, no duplicates.
    static func effectiveSymbols(_ options: PasswordGeneratorOptions) -> [Character] {
        var seen = Set<Character>()
        return options.symbolSet.filter { character in
            !character.isLetter && !character.isNumber && !character.isWhitespace
                && !(options.avoidLookAlikes && lookAlikes.contains(character))
                && seen.insert(character).inserted
        }
    }

    static func pools(_ options: PasswordGeneratorOptions) -> [[Character]] {
        func filtered(_ set: [Character]) -> [Character] {
            options.avoidLookAlikes ? set.filter { !lookAlikes.contains($0) } : set
        }
        var pools: [[Character]] = []
        if options.lowercase { pools.append(filtered(lowercase)) }
        if options.uppercase { pools.append(filtered(uppercase)) }
        if options.digits { pools.append(filtered(digits)) }
        let symbols = effectiveSymbols(options)
        if options.symbols, !symbols.isEmpty { pools.append(symbols) }
        return pools
    }

    /// Digits only: the generator makes a numeric PIN.
    static func isPIN(_ options: PasswordGeneratorOptions) -> Bool {
        options.mode == .password && options.digits && !options.lowercase && !options.uppercase
            && !(options.symbols && !effectiveSymbols(options).isEmpty)
    }

    /// Entropy of what the generator produces with these options (not of a typed password).
    static func entropyBits(_ options: PasswordGeneratorOptions) -> Double {
        switch options.mode {
        case .password:
            let count = pools(options).reduce(0) { $0 + $1.count }
            return count > 1 ? Double(options.length) * log2(Double(count)) : 0
        case .passphrase:
            let wordBits = Double(options.words) * log2(Double(max(words.count, 2)))
            let numberBits = options.addNumber ? log2(Double(10 * options.words)) : 0
            return wordBits + numberBits
        }
    }

    /// Short description of the hidden options, shown next to the "Options" disclosure.
    static func summary(_ options: PasswordGeneratorOptions) -> String {
        switch options.mode {
        case .password:
            if isPIN(options) {
                return L("Digits only (PIN)")
            }
            var parts: [String] = []
            if options.lowercase { parts.append("a–z") }
            if options.uppercase { parts.append("A–Z") }
            if options.digits { parts.append("0–9") }
            if options.symbols { parts.append(L("symbols")) }
            var text = parts.joined(separator: ", ")
            if options.avoidLookAlikes { text += " · " + L("no look-alikes") }
            return text
        case .passphrase:
            var text = options.separator.title
            if options.separator == .custom, !options.customSeparator.isEmpty {
                text += " “\(options.customSeparator)”"
            }
            if options.capitalize { text += " · " + L("Capitalized") }
            if options.addNumber { text += " · " + L("With a number") }
            return text
        }
    }

    private static func password(_ options: PasswordGeneratorOptions, using rng: inout SystemRandomNumberGenerator) -> String {
        let pools = pools(options)
        let all = pools.flatMap { $0 }
        guard !all.isEmpty else {
            return ""
        }
        let length = max(options.length, pools.count)
        var result = (0..<length).map { _ in all.randomElement(using: &rng)! }
        // One character from every class, at random positions.
        var positions = Array(result.indices)
        positions.shuffle(using: &rng)
        for (pool, position) in zip(pools, positions) {
            result[position] = pool.randomElement(using: &rng)!
        }
        return String(result)
    }

    private static func passphrase(_ options: PasswordGeneratorOptions, using rng: inout SystemRandomNumberGenerator) -> String {
        guard !words.isEmpty else {
            return ""
        }
        var chosen = (0..<max(options.words, 1)).map { _ in words.randomElement(using: &rng)! }
        if options.capitalize {
            chosen = chosen.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        if options.addNumber {
            let index = Int.random(in: chosen.indices, using: &rng)
            chosen[index] += String(Int.random(in: 0...9, using: &rng))
        }
        return chosen.joined(separator: options.separatorString)
    }
}

/// The generator's options, shared by the entry panels and the generator window.
@MainActor
@Observable
final class PasswordGeneratorSettings {
    static let shared = PasswordGeneratorSettings()

    private enum Key {
        static let options = "keemac.generator.options.v2"
        static let remember = "keemac.generator.rememberOptions"
        static let defaultMode = "keemac.generator.defaultMode"
        static let defaultLength = "keemac.generator.defaultLength"
        static let defaultWords = "keemac.generator.defaultWords"
    }

    static let lengthChoices = [12, 16, 20, 24, 32, 40, 64]
    static let wordChoices = [3, 4, 5, 6, 7, 8, 10]

    var options: PasswordGeneratorOptions {
        didSet {
            if rememberOptions {
                persistOptions()
            }
        }
    }

    /// When off, the generator starts from the defaults below every time KeeMac starts.
    var rememberOptions: Bool {
        didSet {
            userDefaults.set(rememberOptions, forKey: Key.remember)
            if rememberOptions {
                persistOptions()
            }
        }
    }

    var defaultMode: PasswordGeneratorOptions.Mode {
        didSet { userDefaults.set(defaultMode.rawValue, forKey: Key.defaultMode) }
    }

    var defaultLength: Int {
        didSet { userDefaults.set(defaultLength, forKey: Key.defaultLength) }
    }

    var defaultWords: Int {
        didSet { userDefaults.set(defaultWords, forKey: Key.defaultWords) }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let remember = userDefaults.object(forKey: Key.remember) as? Bool ?? true
        let mode = userDefaults.string(forKey: Key.defaultMode).flatMap(PasswordGeneratorOptions.Mode.init(rawValue:)) ?? .password
        let length = userDefaults.object(forKey: Key.defaultLength) as? Int ?? 20
        let words = userDefaults.object(forKey: Key.defaultWords) as? Int ?? 5
        rememberOptions = remember
        defaultMode = mode
        defaultLength = length
        defaultWords = words

        if remember, let data = userDefaults.data(forKey: Key.options),
           let saved = try? JSONDecoder().decode(PasswordGeneratorOptions.self, from: data) {
            options = saved
        } else {
            var options = PasswordGeneratorOptions()
            options.mode = mode
            options.length = length
            options.words = words
            self.options = options
        }
    }

    func generate() -> String {
        PasswordGenerator.generate(options)
    }

    private func persistOptions() {
        if let data = try? JSONEncoder().encode(options) {
            userDefaults.set(data, forKey: Key.options)
        }
    }
}
