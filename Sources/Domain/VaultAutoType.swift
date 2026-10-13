import Foundation

/// KeePass's default Auto-Type sequence, used when neither the entry nor its groups set one.
public let defaultAutoTypeSequence = "{USERNAME}{TAB}{PASSWORD}{ENTER}"

/// A window an entry types into with its own sequence (KeePass "window association").
public struct VaultAutoTypeAssociation: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Window title pattern: `*` stands for any text, `//regex//` is a regular expression.
    public var windowTitle: String
    /// Empty uses the entry's sequence.
    public var sequence: String

    public init(id: UUID = UUID(), windowTitle: String, sequence: String = "") {
        self.id = id
        self.windowTitle = windowTitle
        self.sequence = sequence
    }

    /// Same pattern and sequence, ignoring the in-memory ID.
    public func hasSameContent(as other: VaultAutoTypeAssociation) -> Bool {
        windowTitle == other.windowTitle && sequence == other.sequence
    }

    /// KeePass matching: equal titles (ignoring case), `*` wildcards over the whole title, or `//regex//`.
    public func matches(windowTitle title: String) -> Bool {
        let pattern = windowTitle.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !title.isEmpty else {
            return false
        }
        if pattern.caseInsensitiveCompare(title) == .orderedSame {
            return true
        }
        let regex: String
        if pattern.count > 4, pattern.hasPrefix("//"), pattern.hasSuffix("//") {
            regex = String(pattern.dropFirst(2).dropLast(2))
        } else {
            regex = "^" + pattern.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        }
        guard let expression = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return false
        }
        return expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }
}

/// An entry's own Auto-Type settings (KeePass `<AutoType>`).
public struct VaultAutoTypeSettings: Equatable, Sendable {
    public var isEnabled: Bool
    /// Nil inherits the sequence from the groups.
    public var sequence: String?
    public var associations: [VaultAutoTypeAssociation]

    public init(isEnabled: Bool = true, sequence: String? = nil, associations: [VaultAutoTypeAssociation] = []) {
        self.isEnabled = isEnabled
        self.sequence = sequence
        self.associations = associations
    }

    public static let `default` = VaultAutoTypeSettings()

    /// Enabled, inherited sequence, no associations: nothing worth showing.
    public var isDefault: Bool {
        isEnabled && sequence == nil && associations.isEmpty
    }

    /// Same settings, ignoring association IDs.
    public func hasSameContent(as other: VaultAutoTypeSettings) -> Bool {
        isEnabled == other.isEnabled
            && sequence == other.sequence
            && associations.count == other.associations.count
            && zip(associations, other.associations).allSatisfy { $0.hasSameContent(as: $1) }
    }
}

/// KeePass's three-state group flag.
public enum VaultInheritedFlag: String, Equatable, Sendable, CaseIterable {
    case inherit
    case on
    case off
}

/// A group's own Auto-Type settings.
public struct VaultGroupAutoType: Equatable, Sendable {
    public var enabled: VaultInheritedFlag
    /// Nil inherits the sequence from the parent group.
    public var sequence: String?

    public init(enabled: VaultInheritedFlag = .inherit, sequence: String? = nil) {
        self.enabled = enabled
        self.sequence = sequence
    }

    public static let `default` = VaultGroupAutoType()
}

/// What "Inherit" means at some point of the group tree: the result of the groups above.
public struct VaultAutoTypeInheritance: Equatable, Sendable {
    public let isEnabled: Bool
    /// Title of the group that decided `isEnabled`; nil when no group did (on by default).
    public let enabledSource: String?
    public let sequence: String
    /// Title of the group that set the sequence; nil for the default sequence.
    public let sequenceSource: String?

    public init(isEnabled: Bool = true, enabledSource: String? = nil, sequence: String = defaultAutoTypeSequence, sequenceSource: String? = nil) {
        self.isEnabled = isEnabled
        self.enabledSource = enabledSource
        self.sequence = sequence
        self.sequenceSource = sequenceSource
    }

    public static let root = VaultAutoTypeInheritance()

    /// The inheritance below a group with these settings.
    public func applying(_ group: VaultGroupAutoType, title: String) -> VaultAutoTypeInheritance {
        let enabled: (Bool, String?)
        switch group.enabled {
        case .inherit:
            enabled = (isEnabled, enabledSource)
        case .on:
            enabled = (true, title)
        case .off:
            enabled = (false, title)
        }
        let ownSequence = group.sequence.flatMap { $0.isEmpty ? nil : $0 }
        return VaultAutoTypeInheritance(
            isEnabled: enabled.0,
            enabledSource: enabled.1,
            sequence: ownSequence ?? sequence,
            sequenceSource: ownSequence == nil ? sequenceSource : title
        )
    }
}

extension VaultEntry {
    /// On for the entry and not turned off by a group.
    public var isAutoTypeEnabled: Bool {
        autoType.isEnabled && autoTypeInheritance.isEnabled
    }

    /// The entry's sequence, or the one it inherits.
    public var effectiveAutoTypeSequence: String {
        autoType.sequence.flatMap { $0.isEmpty ? nil : $0 } ?? autoTypeInheritance.sequence
    }
}
