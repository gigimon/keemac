import Foundation

/// The tags popover's state for several entries: each tag is on all of them, some or none,
/// and a click cycles it. Tags compare case-insensitively, like the loader.
struct BulkTagEditor: Equatable {
    enum State: Equatable {
        case all
        case some
        case none
    }

    let entryCount: Int
    /// Every tag the popover lists, sorted: the database's tags plus new ones.
    private(set) var tags: [String]
    private let counts: [String: Int]
    private var changed: [String: State] = [:]

    /// `entryTags` holds each selected entry's tags; `databaseTags` every tag of that database.
    init(entryTags: [[String]], databaseTags: [String]) {
        entryCount = entryTags.count
        var counts: [String: Int] = [:]
        for tags in entryTags {
            for tag in Set(tags.map { $0.lowercased() }) {
                counts[tag, default: 0] += 1
            }
        }
        self.counts = counts
        var names: [String: String] = [:]
        for tag in databaseTags + entryTags.flatMap({ $0 }) where names[tag.lowercased()] == nil {
            names[tag.lowercased()] = tag
        }
        tags = Self.sorted(Array(names.values))
    }

    /// How many selected entries have the tag now (before the changes).
    func count(of tag: String) -> Int {
        counts[tag.lowercased()] ?? 0
    }

    func originalState(of tag: String) -> State {
        switch count(of: tag) {
        case 0: return .none
        case entryCount: return .all
        default: return .some
        }
    }

    func state(of tag: String) -> State {
        changed[tag.lowercased()] ?? originalState(of: tag)
    }

    func isChanged(_ tag: String) -> Bool {
        state(of: tag) != originalState(of: tag)
    }

    var changeCount: Int {
        tags.filter(isChanged).count
    }

    /// some → all → none (→ some again when it started mixed); none → all.
    mutating func cycle(_ tag: String) {
        let next: State
        switch state(of: tag) {
        case .some: next = .all
        case .all: next = .none
        case .none: next = originalState(of: tag) == .some ? .some : .all
        }
        set(tag, to: next)
    }

    /// Adds a tag checked on every entry; an existing tag in another case is reused.
    mutating func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let tag = tags.first { $0.lowercased() == trimmed.lowercased() } ?? trimmed
        if !tags.contains(tag) {
            tags = Self.sorted(tags + [tag])
        }
        set(tag, to: .all)
    }

    /// Tags starting with the query (up to four), and whether "Create “query”" is offered.
    func suggestions(for query: String, knownTags: [String] = []) -> (tags: [String], canCreate: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return ([], false)
        }
        var seen = Set<String>()
        let known = (tags + knownTags).filter { seen.insert($0.lowercased()).inserted }
        let matches = Self.sorted(known.filter { $0.lowercased().hasPrefix(trimmed) })
        return (Array(matches.prefix(4)), !known.contains { $0.lowercased() == trimmed })
    }

    /// What Done applies: tags now on all entries that weren't, tags now on none that were.
    var changes: (adding: [String], removing: [String]) {
        let changedTags = tags.filter(isChanged)
        return (changedTags.filter { state(of: $0) == .all }, changedTags.filter { state(of: $0) == .none })
    }

    private mutating func set(_ tag: String, to state: State) {
        if state == originalState(of: tag) {
            changed[tag.lowercased()] = nil
        } else {
            changed[tag.lowercased()] = state
        }
    }

    private static func sorted(_ tags: [String]) -> [String] {
        tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
