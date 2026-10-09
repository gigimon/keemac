import Domain
import Foundation

/// Describes what a KeePass merge changed (or will change) in terms of entries.
enum VaultMergeDiff {
    /// Changes actually applied: compares the local entries before and after the merge.
    /// `external` is the version read from disk, used to tell conflicts from plain updates.
    static func applied(before: [VaultEntry], after: [VaultEntry], external: [VaultEntry]) -> VaultMergeSummary {
        let beforeByID = index(before)
        let externalByID = index(external)
        var changes: [VaultMergeChange] = []

        for entry in after {
            guard let previous = beforeByID[entry.id] else {
                if !entry.isTrashed {
                    changes.append(VaultMergeChange(entryID: entry.id, kind: .added, title: entry.title, groupPath: entry.groupPath))
                }
                continue
            }
            if let change = change(from: previous, to: entry, external: externalByID[entry.id]) {
                changes.append(change)
            }
        }

        let afterIDs = Set(after.map(\.id))
        for entry in before where !afterIDs.contains(entry.id) && !entry.isTrashed {
            changes.append(VaultMergeChange(entryID: entry.id, kind: .deleted, title: entry.title, groupPath: entry.groupPath))
        }

        return VaultMergeSummary(changes: sorted(changes))
    }

    /// Changes a KeePass synchronize would bring in, predicted without touching the local tree:
    /// the newer version of an entry wins, deletions carry over through DeletedObjects.
    static func predicted(local: [VaultEntry], external: [VaultEntry], externalDeletedIDs: Set<UUID>) -> VaultMergeSummary {
        let localByID = index(local)
        var changes: [VaultMergeChange] = []

        for entry in external {
            guard let current = localByID[entry.id] else {
                if !entry.isTrashed {
                    changes.append(VaultMergeChange(entryID: entry.id, kind: .added, title: entry.title, groupPath: entry.groupPath))
                }
                continue
            }
            guard isNewer(entry.modifiedAt, than: current.modifiedAt) else {
                continue
            }
            if let change = change(from: current, to: entry, external: entry) {
                changes.append(change)
            }
        }

        let externalIDs = Set(external.map(\.id))
        for entry in local where !externalIDs.contains(entry.id) && externalDeletedIDs.contains(entry.id) && !entry.isTrashed {
            changes.append(VaultMergeChange(entryID: entry.id, kind: .deleted, title: entry.title, groupPath: entry.groupPath))
        }

        return VaultMergeSummary(changes: sorted(changes))
    }

    /// True when both versions carry content the other side has not seen.
    static func isConflict(local: VaultEntry, external: VaultEntry) -> Bool {
        guard !sameMoment(local.modifiedAt, external.modifiedAt) else {
            return false
        }
        let externalKnowsLocal = external.history.contains { sameMoment($0.modifiedAt, local.modifiedAt) }
        let localKnowsExternal = local.history.contains { sameMoment($0.modifiedAt, external.modifiedAt) }
        return !externalKnowsLocal && !localKnowsExternal
    }

    private static func change(from previous: VaultEntry, to entry: VaultEntry, external: VaultEntry?) -> VaultMergeChange? {
        if !previous.isTrashed && entry.isTrashed {
            return VaultMergeChange(entryID: entry.id, kind: .deleted, title: entry.title, groupPath: previous.groupPath)
        }
        if previous.isTrashed && !entry.isTrashed {
            return VaultMergeChange(entryID: entry.id, kind: .added, title: entry.title, groupPath: entry.groupPath)
        }

        let fields = changedFields(from: previous, to: entry)
        let moved = previous.groupPath != entry.groupPath
        if !fields.isEmpty {
            return VaultMergeChange(
                entryID: entry.id,
                kind: .updated,
                title: entry.title,
                groupPath: entry.groupPath,
                previousGroupPath: moved ? previous.groupPath : nil,
                changedFields: fields,
                isConflict: external.map { isConflict(local: previous, external: $0) } ?? false
            )
        }
        if moved {
            return VaultMergeChange(
                entryID: entry.id,
                kind: .moved,
                title: entry.title,
                groupPath: entry.groupPath,
                previousGroupPath: previous.groupPath
            )
        }
        // The local version won a conflict; the other device's version was filed into history.
        if let external,
           isConflict(local: previous, external: external),
           entry.history.contains(where: { sameMoment($0.modifiedAt, external.modifiedAt) }),
           !previous.history.contains(where: { sameMoment($0.modifiedAt, external.modifiedAt) }) {
            return VaultMergeChange(
                entryID: entry.id,
                kind: .updated,
                title: entry.title,
                groupPath: entry.groupPath,
                isConflict: true
            )
        }
        return nil
    }

    static func changedFields(from old: VaultEntry, to new: VaultEntry) -> [String] {
        var fields: [String] = []
        if old.title != new.title { fields.append("title") }
        if old.username != new.username { fields.append("username") }
        if old.password != new.password { fields.append("password") }
        if old.url != new.url { fields.append("website") }
        if old.notes != new.notes { fields.append("notes") }
        if old.tags != new.tags { fields.append("tags") }
        if old.otp != new.otp { fields.append("one-time password") }
        if old.attachments.map(\.name) != new.attachments.map(\.name)
            || old.attachments.map(\.data) != new.attachments.map(\.data) {
            fields.append("attachments")
        }
        if old.customFields != new.customFields { fields.append("custom fields") }
        if old.expiresAt != new.expiresAt { fields.append("expiry") }
        return fields
    }

    private static func index(_ entries: [VaultEntry]) -> [UUID: VaultEntry] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func sorted(_ changes: [VaultMergeChange]) -> [VaultMergeChange] {
        let order = Dictionary(uniqueKeysWithValues: VaultMergeChange.Kind.allCases.enumerated().map { ($1, $0) })
        return changes.sorted {
            if $0.kind != $1.kind {
                return order[$0.kind, default: 0] < order[$1.kind, default: 0]
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// KDBX stores timestamps with one-second precision.
    static func sameMoment(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private static func isNewer(_ lhs: Date?, than rhs: Date?) -> Bool {
        guard let lhs else {
            return false
        }
        guard let rhs else {
            return true
        }
        return lhs.timeIntervalSince(rhs) >= 1
    }
}
